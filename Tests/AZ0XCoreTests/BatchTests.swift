import XCTest
@testable import AZ0XCore

/// A batch: several boards, each independent, sharing nothing but a folder and a download.
///
/// What is worth testing here is not any one board — the engine already covers that — but what a
/// batch does *between* boards: that one board's trouble stays with it, that a board gives its
/// socket back the moment it is done, and that a board it could not take is said out loud.
final class BatchTests: XCTestCase {

    private func plan(_ boards: [BoardAddress],
                      items: [TestItem] = Array(TestItem.ddrItems.prefix(6))) -> BatchPlan {
        var p = BatchPlan(batchID: "AZ08-DDR-20260825-101149", model: .az08, flow: .ddr,
                          items: items, burninPhases: Set(BurninPhase.allCases), boards: boards)
        p.burninSeconds = 43_200
        p.cycles = 3_000
        return p
    }

    private static let sockets = ["002-1.4-2207-350e-NA",
                                 "002-1.5-2207-350e-NA",
                                 "002-1.6-2207-350e-NA"]

    private func tool() -> ScriptedMaskromTool {
        let t = ScriptedMaskromTool([
            "--detect": .init(json: ["detect": ["pass": true, "type": "LPDDR4X", "capacityMB": 8192,
                                                "channels": 4, "csPerDie": 1,
                                                "tier": "uniqueByCoarse", "cfg": "lpddr4x.cfg"],
                                    "cpuid": "c0ffee01", "serial": "34376b2c031e323e"], exitCode: 0),
            "--solder": .init(json: ["solder": ["pass": true, "log": "Size=8192MB BW=64"]], exitCode: 0),
            "--eyescan": .init(json: ["eyescan": ["pass": true, "bytes": 40_960,
                                                  "transcript": "all result: pass"],
                                      "elapsedMs": 800_000], exitCode: 0),
        ])
        // Every board of the batch is enumerated; `waitForBoard` has no limit on purpose, so a
        // socket the tool does not report would simply be waited on for ever.
        t.enumerated = Self.sockets.map { .init(id: $0, pid: "0x350e") }
        return t
    }

    /// Runs a batch where each board behaves as its own closure says.
    private func execute(_ p: BatchPlan,
                         registry: BenchRegistry = BenchRegistry(),
                         board: @escaping (BoardAddress) -> ScriptedBoardSession
                            = { _ in ScriptedBench.board() })
        async -> ([Run], [BatchEvent], BenchRegistry) {
        let events = Box()
        let scriptedTool = tool()
        let runner = BatchRunner(
            plan: p, registry: registry,
            makeValidator: { runPlan, _ in
                let session = board(runPlan.boardSerial.map { .flashed(serial: $0) }
                                    ?? .maskrom(runPlan.deviceID))
                return Validator(plan: runPlan, tool: scriptedTool, boardSession: { _ in session },
                                 flashTool: ScriptedFlasher(), clock: SimClock())
            })
        let runs = await runner.run { events.append($0) }
        return (runs, events.all, registry)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [BatchEvent] = []
        func append(_ e: BatchEvent) { lock.lock(); events.append(e); lock.unlock() }
        var all: [BatchEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    // MARK: - Boards are independent

    func testEveryBoardOfABatchGetsItsOwnRecord() async {
        let (runs, events, _) = await execute(plan([.maskrom("002-1.4-2207-350e-NA"),
                                                    .maskrom("002-1.5-2207-350e-NA"),
                                                    .maskrom("002-1.6-2207-350e-NA")]))

        XCTAssertEqual(runs.count, 3)
        XCTAssertEqual(Set(runs.map(\.runID)).count, 3, "每块板一份独立记录，不是一份批次结论")
        let finished = events.filter { if case .finished = $0 { return true } else { return false } }
        XCTAssertEqual(finished.count, 1, "批次结束只发一次")
    }

    /// The property the whole design rests on: a batch of eight must not become a batch of none
    /// because one board is bad.
    func testOneBoardsDefectDoesNotTouchTheOthers() async {
        let bad = BoardAddress.maskrom("002-1.5-2207-350e-NA")
        let (runs, _, _) = await execute(plan([.maskrom("002-1.4-2207-350e-NA"), bad,
                                               .maskrom("002-1.6-2207-350e-NA")]),
                                         board: { ScriptedBench.board(t06Defect: $0 == bad) })

        XCTAssertEqual(runs.count, 3, "一块板有缺陷，其余照跑到底")
        XCTAssertEqual(runs.filter { $0.results["T06"]?.condemnsMaterial == true }.count, 1)
        XCTAssertEqual(runs.filter { $0.results["T06"]?.verdict == .passed }.count, 2)
    }

    // MARK: - The socket goes back

    func testABoardReleasesItsSocketAsSoonAsItIsDone() async {
        let reg = BenchRegistry()
        _ = await execute(plan([.maskrom("002-1.4-2207-350e-NA")]), registry: reg)

        let stillHeld = await reg.inUse
        XCTAssertTrue(stillHeld.isEmpty, "跑完插座必须立刻回到可用，否则物理空着、软件不让用：\(stillHeld)")
    }

    /// Including when the board was judged defective and the run stopped early.
    func testASocketIsReleasedEvenWhenTheBoardFails() async {
        let reg = BenchRegistry()
        _ = await execute(plan([.maskrom("002-1.4-2207-350e-NA")]), registry: reg,
                          board: { _ in ScriptedBench.board(t06Defect: true) })

        let stillHeld = await reg.inUse
        XCTAssertTrue(stillHeld.isEmpty, stillHeld.description)
    }

    /// And when the sequence was refused before a board was touched.
    func testASocketIsReleasedWhenTheSequenceItselfIsRefused() async {
        let reg = BenchRegistry()
        // Board items with no flashing item and no named serial: refused up front.
        _ = await execute(plan([.maskrom("002-1.4-2207-350e-NA")],
                               items: TestItem.ddrItems.filter { $0.code != "T04" }),
                          registry: reg)

        let stillHeld = await reg.inUse
        XCTAssertTrue(stillHeld.isEmpty, stillHeld.description)
    }

    // MARK: - A board it cannot take is said out loud

    func testABoardAlreadyDrivenIsRefusedAndNamed() async {
        let reg = BenchRegistry()
        _ = await reg.take("002-1.5-2207-350e-NA")          // another batch already has it

        let (runs, events, _) = await execute(plan([.maskrom("002-1.4-2207-350e-NA"),
                                                    .maskrom("002-1.5-2207-350e-NA")]),
                                              registry: reg)

        XCTAssertEqual(runs.count, 1, "拿不到的那块不跑，拿得到的照跑")
        let refusals = events.compactMap { e -> String? in
            if case let .refused(board, _) = e { return board } else { return nil }
        }
        XCTAssertEqual(refusals, ["插座 002-1.5"],
                       "少跑一块板绝不能是静默的——旧版正是这样把四块变成三块")
    }

    func testNamingTheSameBoardTwiceOnlyRunsItOnce() async {
        let (runs, events, _) = await execute(plan([.maskrom("002-1.4-2207-350e-NA"),
                                                    .maskrom("002-1.4-2207-350e-NA")]))
        XCTAssertEqual(runs.count, 1)
        XCTAssertTrue(events.contains { if case .refused = $0 { return true } else { return false } })
    }
}
