import Foundation

/// The only symbol this library exposes.
///
/// Keeping the surface to one function is what keeps the executable thin: the CLI parses arguments
/// and prints, and every decision stays inside the core where it can be tested. It also means the
/// model never has to be made `public` to be driven, so nothing about the internal shape is
/// pinned by the fact that a command-line tool exists.
public enum AZ0X {

    /// Runs one command. Returns the process exit status.
    public static func run(_ arguments: [String]) async -> Int32 {
        var args = arguments
        let command = args.isEmpty ? "help" : args.removeFirst()

        switch command {
        case "run":
            return await runValidation(Options(args))
        case "devices":
            return await listDevices()
        case "report":
            return renderReport(path: args.first)
        case "help", "-h", "--help":
            print(usage)
            return 0
        default:
            FileHandle.standardError.write(Data("未知命令：\(command)\n\n\(usage)\n".utf8))
            return 2
        }
    }

    private static let usage = """
        az0x —— AZ0X 物料验证执行台

        用法：
          az0x devices                        列出当前处于 maskrom 的板卡
          az0x run --model AZ08 [选项]        对一块板跑完验证序列，输出报告
          az0x report <run.json>             重新渲染一次已归档的运行
          az0x help                          显示本说明

        run 的选项：
          --model <AZ05|AZ07|AZ08|AZ04A|AZ04B>   必填
          --flow <ddr|emmc>                      默认 ddr
          --device-id <id>                       默认：当前唯一在位的那块
          --serial <adb serial>                  只跑板载项（不含刷机项）时用：
                                                 指定一块已刷好测试固件的板子；
                                                 默认：当前唯一在线的那台
          --items T01,T02,…                      默认：该型号该流程的全部项目
          --out <目录>                           报告与板端日志的落地目录
          --burnin-seconds <n>                   T06 每段时长，默认 43200
          --cycles <n>                           T07/T08 次数，默认 3000
          --keep-board-logs                      保留运行中拉下来的板端原始日志目录；
                                                 默认删掉，判定证据已在 run.json 里

        缩短时长的选项只为联机调试而存在。一次缩短的运行**不是**一次完整验证，
        报告会照实写明它只覆盖了什么。
        """

    // MARK: - run

    /// Flags parsed without a dependency: this tool has none, and one argument parser is not worth
    /// the first.
    private struct Options {
        var values: [String: String] = [:]

        init(_ args: [String]) {
            var rest = args
            while !rest.isEmpty {
                let key = rest.removeFirst()
                guard key.hasPrefix("--") else { continue }
                let name = String(key.dropFirst(2))
                if let next = rest.first, !next.hasPrefix("--") {
                    values[name] = rest.removeFirst()
                } else {
                    values[name] = ""
                }
            }
        }

        func string(_ name: String) -> String? {
            values[name].flatMap { $0.isEmpty ? nil : $0 }
        }
        func int(_ name: String) -> Int? { string(name).flatMap(Int.init) }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }

    private static func listDevices() async -> Int32 {
        guard let cli = DdrCli() else { return fail("RockchipDDRTestUtilityCLI 未随程序打包") }
        let devices = await cli.devices()
        guard !devices.isEmpty else {
            print("当前没有处于 maskrom 的板卡。")
            return 1
        }
        for d in devices { print("\(d.id)  pid=\(d.pid)") }
        return 0
    }

    private static func runValidation(_ o: Options) async -> Int32 {
        guard let modelName = o.string("model"),
              let model = DeviceModel(rawValue: modelName.uppercased())
        else { return fail("--model 必填，取值：" + DeviceModel.allCases.map(\.rawValue).joined(separator: "、")) }

        let flow: ValidationFlow = (o.string("flow") ?? "ddr").lowercased() == "emmc" ? .emmc : .ddr

        let missing = BundledTools.missingTools
        guard missing.isEmpty, let cli = DdrCli() else {
            return fail("程序内嵌工具缺失：" + missing.joined(separator: "、"))
        }

        var items = TestItem.items(for: flow, model: model)
        if let picked = o.string("items") {
            let wanted = Set(picked.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            items = items.filter { wanted.contains($0.code) }
            guard !items.isEmpty else { return fail("--items 里没有该型号该流程存在的项目") }
        }
        let needsMaskrom = items.contains { $0.domain == .maskrom }

        // Which board. Naming it is required as soon as more than one is in maskrom: the whole point
        // of addressing by the tool's device id is that two boards of one model are otherwise
        // indistinguishable, and flashing the wrong one is not undoable.
        var deviceID = o.string("device-id") ?? ""
        if needsMaskrom, deviceID.isEmpty {
            let devices = await cli.devices()
            guard devices.count == 1 else {
                return fail(devices.isEmpty
                    ? "当前没有处于 maskrom 的板卡。"
                    : "有 \(devices.count) 块板在位，请用 --device-id 指定；`az0x devices` 可列出。")
            }
            deviceID = devices[0].id
        }

        // A selection with no maskrom item never sees the board there, so it is addressed by the
        // serial it reports over adb instead. Same rule as above: one board, take it; more than
        // one, say which.
        var boardSerial = o.string("serial")
        if !needsMaskrom, boardSerial == nil {
            let online = await Adb.onlineSerials()
            guard online.count == 1 else {
                return fail(online.isEmpty
                    ? "当前没有在线的 adb 板卡。板载测试要求板上已刷入我们编译的测试固件。"
                    : "有 \(online.count) 台板卡在线，请用 --serial 指定：" + online.joined(separator: "、"))
            }
            boardSerial = online[0]
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let batchID = "\(model.rawValue)-\(flow == .ddr ? "DDR" : "EMMC")-\(stamp.string(from: Date()))"

        var plan = RunPlan(batchID: batchID, runID: UUID().uuidString, model: model, flow: flow,
                           items: items, burninPhases: Set(BurninPhase.allCases),
                           deviceID: deviceID, boardSerial: boardSerial)
        if let n = o.int("burnin-seconds") { plan.burninSeconds = n }
        if let n = o.int("cycles") { plan.cycles = n }

        let out = o.string("out").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let out { try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }

        let validator = Validator(plan: plan, tool: cli,
                                  boardSession: { Adb(serial: $0) },
                                  flashTool: FlashTool(),
                                  archiveFolder: out)

        // Progress arrives many times a second; only a line that says something new is printed.
        // Without this, flashing filled the terminal with identical lines and a long run would bury
        // the item results that actually matter between them.
        var lastLine = ""
        let run = await validator.run { event in
            let line = self.line(for: event)
            guard line != lastLine else { return }
            lastLine = line
            print(line)
        }

        // The board-side logs are pulled while the run is in flight so they can be looked at then.
        // What the verdicts rest on is already in the record, so once that is written the working
        // directory has done its job: the delivered folder is a report and a record, nothing else.
        if let out, o.values["keep-board-logs"] == nil {
            try? FileManager.default.removeItem(at: out.appendingPathComponent("logs"))
        }

        let report = ReportRenderer.render(run)
        if let out {
            let name = "\(batchID)-\(run.boardName)\(run.isPartial ? "-抽测记录" : "-初步报告").md"
            try? report.write(to: out.appendingPathComponent(name), atomically: true, encoding: .utf8)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            try? encoder.encode(run).write(to: out.appendingPathComponent("run.json"))
            print("报告：\(out.appendingPathComponent(name).path)")
        } else {
            print("")
            print(report)
        }
        // A defective material is not a failure of this program: it ran and reported. Only a run
        // that could not produce a record exits non-zero.
        return run.results.isEmpty ? 1 : 0
    }

    /// One line per event. Deliberately plain: this is a log, not an interface.
    private static func line(for event: RunEvent) -> String {
        switch event {
        case let .waitingForBoard(deviceID):
            return "等待板卡进入 maskrom：\(deviceID)"
        case let .boardBound(serial, identity):
            return "已绑定板卡 \(serial)（\(identity)）"
        case let .itemStarted(item):
            return "▶ \(item.displayTitle)"
        case let .itemFinished(item, result):
            let detail = result.detail.map { "：\($0)" } ?? ""
            return "  \(item.code) \(result.label)\(detail)"
        case let .step(step):
            return "  \(step.label) \(step.valueText)"
        case let .longTest(code, p):
            return "  \(code) \(p.phase) \(p.progressText)"
        case let .finished(run):
            let stopped = run.stoppedAt.map { "，终止于 \($0)" } ?? ""
            return "运行结束\(stopped)"
        }
    }

    /// Re-renders an archived run. The record is the only input: no board, no network, no state.
    private static func renderReport(path: String?) -> Int32 {
        guard let path else {
            FileHandle.standardError.write(Data("report 需要一个 run.json 路径\n".utf8))
            return 2
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            FileHandle.standardError.write(Data("读不到 \(path)\n".utf8))
            return 1
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let run = try? decoder.decode(Run.self, from: data) else {
            FileHandle.standardError.write(Data("\(path) 不是这个程序认识的运行记录\n".utf8))
            return 1
        }
        print(ReportRenderer.render(run))
        return 0
    }
}
