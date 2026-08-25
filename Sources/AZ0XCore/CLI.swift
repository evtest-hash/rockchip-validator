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
            return await listDevices(Options(args))
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
          az0x devices [--model AZ08]         列出当前处于 maskrom 的板卡
          az0x run --model AZ08 [选项]        对一块板跑完验证序列，输出报告
          az0x report <run.json>             重新渲染一次已归档的运行
          az0x help                          显示本说明

        run 的选项：
          --model <AZ05|AZ07|AZ08|AZ04A|AZ04B>   必填
          --flow <ddr|emmc>                      默认 ddr
          --device-id <id>                       可重复，一块板一个；默认：当前唯一在位的那块
          --serial <adb serial>                  只跑板载项（不含刷机项）时用：
                                                 指定一块已刷好测试固件的板子；
                                                 默认：当前唯一在线的那台
          --items T01,T02,…                      默认：该型号该流程的全部项目
          --out <目录>                           批次落地的根目录
                                                 默认 ~/Documents/AZ0X 物料验证/
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
        /// Flags in the order given, so a repeated one keeps every value rather than the last.
        private var pairs: [(String, String)] = []

        init(_ args: [String]) {
            var rest = args
            while !rest.isEmpty {
                let key = rest.removeFirst()
                guard key.hasPrefix("--") else { continue }
                let name = String(key.dropFirst(2))
                if let next = rest.first, !next.hasPrefix("--") {
                    pairs.append((name, rest.removeFirst()))
                } else {
                    pairs.append((name, ""))
                }
            }
        }

        func string(_ name: String) -> String? {
            pairs.last { $0.0 == name }.map(\.1).flatMap { $0.isEmpty ? nil : $0 }
        }
        func strings(_ name: String) -> [String] {
            pairs.filter { $0.0 == name && !$0.1.isEmpty }.map(\.1)
        }
        func has(_ name: String) -> Bool { pairs.contains { $0.0 == name } }
        func int(_ name: String) -> Int? { string(name).flatMap(Int.init) }
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return 2
    }

    /// What is plugged in right now, and nothing more.
    ///
    /// Deliberately not a statement about availability: another invocation may already be driving one
    /// of these and nothing here can see across processes. Which boards to use is the caller's to
    /// decide — this only saves typing the device ids out of thin air.
    private static func listDevices(_ o: Options) async -> Int32 {
        guard let cli = DdrCli() else { return fail("RockchipDDRTestUtilityCLI 未随程序打包") }
        let model = o.string("model").flatMap { DeviceModel(rawValue: $0.uppercased()) }
        let devices = await cli.devices()
        guard !devices.isEmpty else {
            print("当前没有处于 maskrom 的板卡。")
            return 1
        }
        let mine = model.map { m in devices.filter { $0.pid == m.maskromPID } } ?? devices
        for d in mine {
            print("插座 \(DdrCli.socket(d.id))   \(d.id)   pid=\(d.pid)")
        }
        let others = devices.count - mine.count
        if others > 0 { print("另有 \(others) 块其它型号，不在候选内") }
        if mine.isEmpty { print("没有与所选型号相符的板卡。") }
        return mine.isEmpty ? 1 : 0
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

        // Which boards. Naming them is required as soon as more than one is in maskrom: the whole
        // point of addressing by the tool's device id is that two boards of one model are otherwise
        // indistinguishable, and flashing the wrong one is not undoable.
        //
        // There is deliberately no --all or --count. Both would mean this program knows which boards
        // are free, and it does not: another invocation may be driving one, and nothing here can see
        // across processes. Naming them is the only honest way.
        var boards: [BoardAddress] = []
        if needsMaskrom {
            let named = o.strings("device-id")
            if named.isEmpty {
                let devices = await cli.devices()
                guard devices.count == 1 else {
                    return fail(devices.isEmpty
                        ? "当前没有处于 maskrom 的板卡。"
                        : "有 \(devices.count) 块板在位，请用 --device-id 逐块指定；`az0x devices` 可列出。")
                }
                boards = [.maskrom(devices[0].id)]
            } else {
                boards = named.map { .maskrom($0) }
            }
        } else {
            // A selection with no maskrom item never sees the board there, so it is addressed by
            // the serial it reports over adb instead.
            let named = o.strings("serial")
            if named.isEmpty {
                let online = await Adb.onlineSerials()
                guard online.count == 1 else {
                    return fail(online.isEmpty
                        ? "当前没有在线的 adb 板卡。板载测试要求板上已刷入我们编译的测试固件。"
                        : "有 \(online.count) 台板卡在线，请用 --serial 指定：" + online.joined(separator: "、"))
                }
                boards = [.flashed(serial: online[0])]
            } else {
                boards = named.map { .flashed(serial: $0) }
            }
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let batchID = "\(model.rawValue)-\(flow == .ddr ? "DDR" : "EMMC")-\(stamp.string(from: Date()))"

        var plan = BatchPlan(batchID: batchID, model: model, flow: flow, items: items,
                             burninPhases: Set(BurninPhase.allCases), boards: boards)
        if let n = o.int("burnin-seconds") { plan.burninSeconds = n }
        if let n = o.int("cycles") { plan.cycles = n }

        let root = o.string("out").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? ArchiveRoot.default
        let folder = root.appendingPathComponent(batchID, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let runner = BatchRunner(
            plan: plan, registry: BenchRegistry(),
            makeValidator: { runPlan, dir in
                Validator(plan: runPlan, tool: cli, boardSession: { Adb(serial: $0) },
                          flashTool: FlashTool(), archiveFolder: dir)
            },
            folder: folder)

        let console = Console(many: boards.count > 1)
        let keepLogs = o.has("keep-board-logs")
        let runs = await runner.run { event in
            console.show(event)
            if case let .benchFinished(_, run, dir) = event, let dir {
                // The board-side logs are pulled while the run is in flight so they can be looked at
                // then. What the verdicts rest on is already in the record, so the delivered folder
                // is a report and a record, nothing else.
                if !keepLogs { try? FileManager.default.removeItem(at: dir.appendingPathComponent("logs")) }
                write(run, into: dir)
            }
        }
        print("批次目录：\(folder.path)")

        // A defective material is not a failure of this program: it ran and reported. Only a batch
        // that could not produce a single record exits non-zero.
        return runs.contains { !$0.results.isEmpty } ? 0 : 1
    }

    /// Writes one board's record and report into its folder.
    private static func write(_ run: Run, into dir: URL) {
        let name = "\(run.batchID)-\(run.boardName)\(run.isPartial ? "-抽测记录" : "-初步报告").md"
        try? ReportRenderer.render(run).write(to: dir.appendingPathComponent(name),
                                              atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        try? encoder.encode(run).write(to: dir.appendingPathComponent("run.json"))
    }

    /// Prints one line per event, prefixed by the board once a batch has more than one.
    ///
    /// Progress arrives many times a second; a line identical to the last is dropped. Without that,
    /// flashing filled the terminal with identical lines and a long run buried the item results
    /// between them.
    private final class Console: @unchecked Sendable {
        private let many: Bool
        private var lastLine = ""
        init(many: Bool) { self.many = many }

        func show(_ event: BatchEvent) {
            switch event {
            case let .refused(board, why):
                emit("⚠ \(board) 未开始：\(why)")
            case let .benchStarted(board):
                if many { emit("▷ \(board)") }
            case let .bench(board, e):
                emit((many ? "[\(board)] " : "") + AZ0X.line(for: e))
            case let .benchFinished(board, run, _):
                let where_ = run.stoppedAt.map { "，终止于 \($0)" } ?? ""
                emit("■ \(board) 结束\(where_)")
            case .finished:
                break
            }
        }

        private func emit(_ line: String) {
            guard line != lastLine else { return }
            lastLine = line
            print(line)
        }
    }

    /// One line per event. Deliberately plain: this is a log, not an interface.
    static func line(for event: RunEvent) -> String {
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
