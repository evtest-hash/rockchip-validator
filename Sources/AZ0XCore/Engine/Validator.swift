import Foundation

/// What to validate. Chosen once, then fixed for the run's life.
struct RunPlan {
    let batchID: String
    let runID: String
    let model: DeviceModel
    let flow: ValidationFlow
    let items: [TestItem]
    let burninPhases: Set<BurninPhase>
    /// The maskrom tool's device id — the bus and port chain that addresses this socket.
    let deviceID: String
    /// Serial of a board that is already running our test firmware, for a sequence that contains no
    /// flashing item. nil in the full flow, where the serial is read out of OTP in maskrom instead.
    var boardSerial: String?

    /// Durations and counts, so a bring-up run can be short without the shipping defaults moving.
    var burninSeconds: Int = Thresholds.longRunSeconds
    var cycles: Int = Thresholds.longRunCycles
    var emmcTargetN: Int = Thresholds.emmcTargetN
}

/// What the engine tells whoever is watching. A caller maps these to whatever it needs —
/// lines on a terminal, observable state in a view — at its own boundary.
///
/// The engine emits and forgets. In the first iteration it drove an `ObservableObject` directly,
/// which is how `@MainActor` spread from a view all the way into the board I/O.
enum RunEvent {
    case waitingForBoard(deviceID: String)
    case boardBound(serial: String, identity: String)
    case itemStarted(TestItem)
    case itemFinished(TestItem, ItemResult)
    /// Progress inside a flashing item.
    case step(StepProgress)
    /// Progress inside a long-running item.
    case longTest(code: String, LongTestProgress)
    /// The run ended, for whatever reason. Always emitted exactly once.
    case finished(Run)
}

/// Runs one board's sequence.
///
/// Everything it touches is injected, so the whole sequence can be exercised against a declared
/// board — which is the only way the decisions in here are reachable at all: on real hardware one
/// pass costs upwards of sixty hours.
struct Validator {

    let plan: RunPlan
    let tool: any MaskromTool
    /// Builds the adb session once the board's serial is known, which is only after flashing.
    let boardSession: (String) -> (any BoardSession)?
    let flashTool: (any Flasher)?
    var clock: any RunClock = SystemClock()
    /// Where board-side logs are pulled to. nil skips archiving.
    var archiveFolder: URL?

    // MARK: - Running

    func run(onEvent: @escaping (RunEvent) -> Void) async -> Run {
        var state = State(plan: plan)

        // A sequence that cannot work is refused before a board is touched, not halfway through.
        if let refusal = sequenceRefusal() {
            state.finish(refusing: refusal, plan: plan)
            let run = state.run(plan: plan)
            onEvent(.finished(run))
            return run
        }

        if plan.items.contains(where: { $0.domain == .maskrom }) {
            onEvent(.waitingForBoard(deviceID: plan.deviceID))
            guard await waitForBoard() else {                       // cancelled
                let run = state.run(plan: plan)
                onEvent(.finished(run))
                return run
            }

            if let identity = await tool.identity(deviceID: plan.deviceID) {
                state.serial = identity.serial
                state.cpuid = identity.cpuid
                state.chipVariant = identity.variant
            }

            // Caught before flashing, not after: writing an image to the wrong part is not undoable.
            if let variant = state.chipVariant, plan.model.contradicts(chipVariant: variant) {
                let named = DeviceModel.named(byChipVariant: variant)?.rawValue ?? variant
                state.finish(refusing: "本工位插的是 \(named) 的板子（芯片 \(variant)），"
                                     + "与所选型号 \(plan.model.rawValue) 不符。"
                                     + "两者 USB PID 相同，只能靠芯片 OTP 区分 —— 请换板子或改所选型号。",
                             plan: plan, asPrecondition: true)
                let run = state.run(plan: plan)
                onEvent(.finished(run))
                return run
            }
        } else {
            // Nothing in this sequence happens in maskrom, so there is no OTP read to take the
            // serial from: the board named here is already running our test firmware, and reports
            // that serial itself over adb. Only a partial selection gets here — `sequenceRefusal`
            // keeps the full sequence starting in maskrom, where the anti-misflash gates live.
            state.serial = plan.boardSerial
        }

        await runItems(&state, onEvent: onEvent)

        state.finishedAt = Date()
        let run = state.run(plan: plan)
        onEvent(.finished(run))
        return run
    }

    /// A sequence that cannot work is refused before a board is touched.
    private func sequenceRefusal() -> String? {
        if plan.flow == .emmc {
            // Stated plainly rather than letting each eMMC item report its own confusion.
            return "eMMC 流程尚未接入本引擎。"
        }
        if plan.items.contains(where: { $0.domain == .board }),
           !plan.items.contains(where: { TestItem.flashCodes.contains($0.code) }),
           plan.boardSerial == nil {
            // Board items need our test firmware on the board. Normally the sequence puts it there
            // itself; naming an already-flashed board is the other way to satisfy that, and it is
            // what makes a board-item selection re-runnable without spending a flash on each try.
            return "序列不自洽：含板载测试项，却既不含刷机项，也没有指定一块已刷好测试固件的板子。"
                 + "板载测试要求板上跑着我们编译的测试固件。"
        }
        // Whether the bundled CLIs are present is the caller's business: the engine is handed the
        // tools it needs, and reaching for a global here is what made it untestable last time.
        return nil
    }

    /// Polls until this bench's own board is enumerated. No limit: putting a board into maskrom is
    /// a manual step and the operator is standing there.
    private func waitForBoard() async -> Bool {
        while !Task.isCancelled {
            if await tool.device(id: plan.deviceID) != nil { return true }
            await clock.sleep(seconds: 1.5)
        }
        return false
    }

    // MARK: - The sequence

    private func runItems(_ state: inout State,
                          onEvent: @escaping (RunEvent) -> Void) async {
        let power = PowerAssertion()
        power.begin(reason: "AZ0X 物料验证进行中（长测可达 60 小时）")
        defer { power.end() }

        let maskrom = MaskromItems(cli: tool, model: plan.model, deviceID: plan.deviceID)
        var board: BoardItems?

        for item in plan.items {
            if Task.isCancelled { return }
            onEvent(.itemStarted(item))
            let startedAt = Date()

            // A maskrom item waits for its own board to settle first.
            if item.domain == .maskrom, await !tool.settled(deviceID: plan.deviceID, clock: clock) {
                state.record(item, interrupted:
                    "设备 \(plan.deviceID) 未在预期时间内重新枚举回 maskrom",
                    startedAt: startedAt, onEvent: onEvent)
                return
            }

            // After flashing, this board is the one reporting the serial read from its OTP before
            // the run. Other boards are flashing at the same time; only the serial tells them apart.
            if item.domain == .board, board == nil {
                guard let serial = state.serial else {
                    state.record(item, interrupted: "未能在 maskrom 阶段读到芯片 serial，"
                               + "无法在多板并行下确认哪台是本工位的板子。",
                               startedAt: startedAt, onEvent: onEvent)
                    return
                }
                guard let adb = boardSession(serial) else {
                    state.record(item, interrupted: "adb 未随应用打包",
                                 startedAt: startedAt, onEvent: onEvent)
                    return
                }
                guard await adb.waitOnline(timeout: 180, clock: clock) else {
                    if Task.isCancelled { return }
                    state.record(item, interrupted:
                        "刷机后板子 \(serial) 未在预期时间内启动并连上 adb。",
                        startedAt: startedAt, onEvent: onEvent)
                    return
                }
                state.boardUptimeAtBind = await adb.uptimeSeconds()
                let reported = await adb.identity().display
                state.boardIdentity = reported
                onEvent(.boardBound(serial: serial, identity: reported))

                board = BoardItems(adb: adb, model: plan.model,
                                   channels: state.measurementInt("T01", "通道数"),
                                   busBitsPerChannel: state.measurementInt("T01", "每通道位宽"),
                                   clock: clock)
            }

            var result = await execute(item, maskrom: maskrom, board: board,
                                       state: state, onEvent: onEvent)
            result.startedAt = startedAt
            result.finishedAt = Date()

            // Archival happens after the verdict and never changes it: new I/O must not become a
            // new source of misjudgement.
            await archive(item, adb: board?.adb)

            state.results[item.code] = result
            onEvent(.itemFinished(item, result))

            if Flow.after(result, item: item) == .stop {
                state.stoppedAt = item.code
                return
            }
        }
    }

    private func execute(_ item: TestItem,
                         maskrom: MaskromItems,
                         board: BoardItems?,
                         state: State,
                         onEvent: @escaping (RunEvent) -> Void) async -> ItemResult {
        let long: (LongTestProgress) -> Void = { onEvent(.longTest(code: item.code, $0)) }

        switch item.code {
        case "T01": return await maskrom.runT01()
        case "T02": return await maskrom.runT02()
        case "T03": return await maskrom.runT03()
        case "T04", "E01":
            return await maskrom.runFlash(code: item.code, flashTool: flashTool) { stage in
                switch stage {
                case let .downloading(done, total):
                    onEvent(.step(StepProgress(code: item.code, label: "下载镜像",
                                               done: done, total: total)))
                case let .flashing(pct):
                    onEvent(.step(StepProgress(metric: .percent, code: item.code,
                                               label: "刷入镜像", done: Int64(pct ?? 0),
                                               total: pct == nil ? nil : 100)))
                }
            }
        default:
            guard let board else {
                var r = ItemResult(code: item.code)
                r.interrupted("板载测试未就绪（adb 未连上）")
                return r
            }
            switch item.code {
            case "T05": return await board.runT05()
            case "T06": return await board.runT06(durationSeconds: plan.burninSeconds,
                                                  phases: plan.burninPhases, onProgress: long)
            case "T07": return await board.runT07(targetCycles: plan.cycles, onProgress: long)
            case "T08": return await board.runT08(targetBoots: plan.cycles, onProgress: long)
            default:
                // Unreachable: an eMMC plan is refused in `sequenceRefusal`. Kept explicit so the
                // gap is visible here rather than looking like an oversight.
                var r = ItemResult(code: item.code)
                r.interrupted("eMMC 流程尚未接入本引擎")
                return r
            }
        }
    }

    /// Pulls one item's raw board-side logs, so the report carries what a person would have copied.
    private func archive(_ item: TestItem, adb: (any BoardSession)?) async {
        guard let folder = archiveFolder,
              let src = LongTest.archiveSource(for: item.code),
              let adb else { return }
        _ = await BoardArchive.capture(adb: adb, boardDirectory: src.dir, code: item.code,
                                       runFolder: folder, extraPaths: src.extras)
    }
}

// MARK: - The run being built

extension Validator {

    /// Mutable while the run is in progress; frozen into a `Run` at the end. Not observable: a
    /// caller learns what happened from `RunEvent`, which is what keeps the engine off any actor.
    struct State {
        var results: [String: ItemResult] = [:]
        var serial: String?
        var cpuid: String?
        var chipVariant: String?
        var boardIdentity: String?
        var boardUptimeAtBind: Int?
        var startedAt = Date()
        var finishedAt: Date?
        var stoppedAt: String?
        var abortedAt: String?

        init(plan: RunPlan) {}

        func measurementInt(_ code: String, _ name: String) -> Int? {
            guard let m = results[code]?.measurements.first(where: { $0.name == name }),
                  case let .number(v, _) = m.value else { return nil }
            return Int(v)
        }

        mutating func record(_ item: TestItem, interrupted why: String, startedAt: Date,
                             onEvent: (RunEvent) -> Void) {
            var r = ItemResult(code: item.code)
            r.interrupted(why)
            r.startedAt = startedAt
            r.finishedAt = Date()
            results[item.code] = r
            stoppedAt = item.code
            onEvent(.itemFinished(item, r))
        }

        /// Ends the run before it starts. The class matters: a missing tool is our environment,
        /// while a board that is not the one selected is a precondition, not a fault.
        mutating func finish(refusing why: String, plan: RunPlan, asPrecondition: Bool = false) {
            guard let first = plan.items.first else { return }
            var r = ItemResult(code: first.code)
            if asPrecondition { r.notStarted(why) } else { r.interrupted(why) }
            r.startedAt = Date()
            r.finishedAt = Date()
            results[first.code] = r
            stoppedAt = first.code
            finishedAt = Date()
        }

        func run(plan: RunPlan) -> Run {
            Run(schemaVersion: Run.currentSchema,
                runID: plan.runID, batchID: plan.batchID,
                model: plan.model, flow: plan.flow,
                board: .init(serial: serial, cpuid: cpuid, chipVariant: chipVariant,
                             socket: plan.deviceID, reported: boardIdentity,
                             uptimeAtBind: boardUptimeAtBind),
                burninPhases: BurninPhase.ordered(plan.burninPhases),
                items: plan.items, results: results,
                startedAt: startedAt, finishedAt: finishedAt,
                stoppedAt: stoppedAt, abortedAt: abortedAt,
                toolVersions: BundledTools.toolVersions, appVersion: AppVersion.display)
        }
    }
}
