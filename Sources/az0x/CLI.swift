import Foundation
import AZ0XCore

/// The debugging entry point: one board, one sequence, one record.
///
/// It lives in its own target rather than in the core, where it sat until now. The core had been
/// swept of one front end — a test fails the build if it imports SwiftUI — while this one stayed
/// inside it doing the same kind of work: parsing arguments, deciding what to run, printing. A
/// library that runs boards should not also be a program that talks to a person.
///
/// Only I use it. Operators validate material through the window; this exists so that a sequence can
/// be driven against real hardware without one — short runs, single items, two at once from a
/// shell, output piped somewhere. Every hardware defect found so far was found through it.
enum AZ0X {

    /// Runs one command. Returns the process exit status.
    static func run(_ arguments: [String]) async -> Int32 {
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
        az0x —— AZ0X 物料验证执行台（一次一块板）

        这是联机调试用的入口。操作员用界面做验证；多块板同时跑由界面安排。

        用法：
          az0x devices [--model AZ08]         列出当前处于 maskrom 的板卡
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
          --out <目录>                           报告与记录的落地目录
          --batch <批次号>                       盖在记录与报告名上，默认按型号-流程-时间戳
          --burnin-seconds <n>                   T06 每段时长，默认 43200
          --cycles <n>                           T07/T08 次数，默认 3000
          --emmc-target <n>                      E05 等效全盘写次数，默认 20
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
        let model = o.string("model").flatMap { DeviceModel(rawValue: $0.uppercased()) }
        let devices = await MaskromScan.attached()
        guard !devices.isEmpty else {
            print("当前没有处于 maskrom 的板卡。")
            return 1
        }
        let mine = model.map { m in devices.filter { $0.matches(m) } } ?? devices
        for d in mine {
            print("插座 \(d.socket)   \(d.deviceID)   pid=\(d.pid)")
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

        let missing = MaskromScan.missingTools
        guard missing.isEmpty else {
            return fail("程序内嵌工具缺失：" + missing.joined(separator: "、"))
        }

        var items = TestItem.items(for: flow, model: model)
        if let picked = o.string("items") {
            let wanted = Set(picked.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            items = items.filter { wanted.contains($0.code) }
            guard !items.isEmpty else { return fail("--items 里没有该型号该流程存在的项目") }
        }
        let needsMaskrom = items.contains { $0.domain == .maskrom }

        // Which board. One per invocation: this program's job is one board's sequence, and
        // running several at once is the caller's to arrange — which for the product means the
        // window, the only thing an operator uses. Fanning out used to live in here; see
        // docs/decisions.md for what that cost.
        var deviceID = ""
        var boardSerial: String?
        if needsMaskrom {
            if let given = o.string("device-id") {
                deviceID = given
            } else {
                let devices = await MaskromScan.attached()
                guard devices.count == 1 else {
                    return fail(devices.isEmpty
                        ? "当前没有处于 maskrom 的板卡。"
                        : "有 \(devices.count) 块板在位，请用 --device-id 指定；`az0x devices` 可列出。")
                }
                deviceID = devices[0].deviceID
            }
        } else {
            // A selection with no maskrom item never sees the board there, so it is addressed by
            // the serial it reports over adb instead.
            if let given = o.string("serial") {
                boardSerial = given
            } else {
                let online = await MaskromScan.onlineSerials()
                guard online.count == 1 else {
                    return fail(online.isEmpty
                        ? "当前没有在线的 adb 板卡。板载测试要求板上已刷入我们编译的测试固件。"
                        : "有 \(online.count) 台板卡在线，请用 --serial 指定：" + online.joined(separator: "、"))
                }
                boardSerial = online[0]
            }
        }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let batchID = o.string("batch")
            ?? "\(model.rawValue)-\(flow == .ddr ? "DDR" : "EMMC")-\(stamp.string(from: Date()))"

        var plan = RunPlan(batchID: batchID, model: model, flow: flow, items: items,
                           burninPhases: Set(BurninPhase.allCases),
                           deviceID: deviceID, boardSerial: boardSerial)
        if let n = o.int("burnin-seconds") { plan.burninSeconds = n }
        if let n = o.int("cycles") { plan.cycles = n }
        if let n = o.int("emmc-target") { plan.emmcTargetN = n }

        let out = o.string("out").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let out { try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }

        // Fetching is a step before the run, not part of the flashing item. One board here, so
        // "once" is trivially true; the window does the same thing once before its boards start.
        if items.contains(where: { TestItem.flashCodes.contains($0.code) }) {
            var lastPct = -1
            do {
                plan.image = try await ImageSupply.prepare(model: model) { done, total in
                    guard let total, total > 0 else { return }
                    let pct = Int(Double(done) / Double(total) * 100)
                    guard pct != lastPct else { return }
                    lastPct = pct
                    print("取镜像 \(pct)%")
                }
            } catch {
                // Nothing is ready to flash, so no board is opened.
                return fail("取镜像失败：\(error.localizedDescription)")
            }
            print("镜像：\(plan.image?.asset ?? "")"
                + (plan.image?.digestVerified == true ? "（sha256 与 CI 记录一致）" : "（未校验）"))
        }

        guard let validator = Validator.live(plan: plan, archiveFolder: out) else {
            return fail("程序内嵌工具缺失")
        }

        // Progress arrives many times a second; only a line that says something new is printed.
        // The engine calls this back synchronously and in order, so nothing here has to keep order.
        var lastLine = ""
        let run = await validator.run { event in
            let line = AZ0X.line(for: event)
            guard line != lastLine else { return }
            lastLine = line
            print(line)
        }

        if let out {
            // The board-side logs are pulled while the run is in flight so they can be looked at
            // then. What the verdicts rest on is already in the record, so the delivered folder is
            // a report and a record, nothing else.
            if !o.has("keep-board-logs") {
                try? FileManager.default.removeItem(at: out.appendingPathComponent("logs"))
            }
            if let url = RunStore.write(run, into: out) { print("报告：\(url.path)") }
        } else {
            print("")
            print(ReportRenderer.render(run))
        }

        // A defective material is not a failure of this program: it ran and reported. Only a run
        // that could not produce a record exits non-zero.
        return run.results.isEmpty ? 1 : 0
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
