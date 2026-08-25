import XCTest
@testable import AZ0XCore

/// The engine, driving the whole sequence against a declared board.
///
/// The behaviour worth testing here is not any one item — it is what the sequence does *between*
/// items. That decision was a property of the outcome enum in the first iteration, so it could not
/// be varied or tested; here it is `Flow.after`, and these are the cases that matter.
final class EngineTests: XCTestCase {

    private func plan(items: [TestItem] = TestItem.ddrItems,
                      flow: ValidationFlow = .ddr) -> RunPlan {
        var p = RunPlan(batchID: "AZ08-DDR-20260824", runID: "run-1", model: .az08, flow: flow,
                        items: items, burninPhases: Set(BurninPhase.allCases),
                        deviceID: "002-1.4-2207-350e-NA")
        p.burninSeconds = 43_200
        p.cycles = 3_000
        return p
    }

    private func tool() -> ScriptedMaskromTool {
        ScriptedMaskromTool([
            "--detect": .init(json: ["detect": ["pass": true, "type": "LPDDR4X", "capacityMB": 8192,
                                                "channels": 4, "csPerDie": 1,
                                                "tier": "uniqueByCoarse", "cfg": "lpddr4x.cfg"],
                                    "cpuid": "c0ffee01", "serial": "34376b2c031e323e"],
                              exitCode: 0),
            "--solder": .init(json: ["solder": ["pass": true, "bootSucceeded": true,
                                                "log": "Size=8192MB BW=64"]],
                              exitCode: 0),
            "--eyescan": .init(json: ["eyescan": ["pass": true, "completed": true, "wedged": false,
                                      "bytes": 40_960, "transcript": "all result: pass"],
                                      "elapsedMs": 800_000], exitCode: 0),
        ])
    }

    /// Runs the plan and returns the record plus every event, in order.
    private func execute(_ p: RunPlan, tool: ScriptedMaskromTool,
                         board: ScriptedBoardSession) async -> (Run, [RunEvent]) {
        var events: [RunEvent] = []
        let v = Validator(plan: p, tool: tool, boardSession: { _ in board },
                          flashTool: ScriptedFlasher(), clock: SimClock())
        let run = await v.run { events.append($0) }
        return (run, events)
    }

    // MARK: - What the sequence does between items

    /// The regression this whole iteration exists to prevent, at the level that decides it.
    ///
    /// T05 is record-only and has seven ways to fail on our side. Here the firmware has no
    /// `stress-ng`, and the engine must carry straight on into the long items.
    func testTheEngineCarriesOnPastARecordOnlyItemThatCouldNotBeMeasured() async {
        let board = ScriptedBench.board(t05Missing: true)
        let (run, events) = await execute(plan(items: Array(TestItem.ddrItems.prefix(6))),
                                         tool: tool(), board: board)

        XCTAssertNil(run.stoppedAt, "T05 测不成不该终止整轮：\(String(describing: run.stoppedAt))")
        XCTAssertFalse(run.results["T05"]?.condemnsMaterial ?? true)
        XCTAssertEqual(run.results["T06"]?.verdict, .passed, "拷机必须照样跑完")
        XCTAssertTrue(events.contains { if case .itemStarted(let i) = $0 { return i.code == "T06" }
                                        else { return false } },
                      "T06 必须真的被启动过")
    }

    /// A defect stops the run, and the items after it are absent rather than guessed at.
    func testTheEngineStopsAtADefect() async {
        let (run, _) = await execute(plan(), tool: tool(),
                                     board: ScriptedBench.board(t06Defect: true))

        XCTAssertEqual(run.stoppedAt, "T06")
        XCTAssertTrue(run.results["T06"]?.condemnsMaterial == true)
        XCTAssertNil(run.results["T07"], "终止之后的项目不该有结果")
        XCTAssertEqual(run.notRunItems.map(\.code), ["T07", "T08"])
    }

    /// A healthy board runs the whole sequence.
    func testAHealthyBoardRunsEveryItem() async {
        let (run, events) = await execute(plan(), tool: tool(), board: ScriptedBench.board())

        XCTAssertNil(run.stoppedAt)
        XCTAssertTrue(run.notRunItems.isEmpty, "\(run.notRunItems.map(\.code))")
        XCTAssertEqual(run.notPassedItems.count, 0)
        XCTAssertEqual(run.noResultItems.count, 0)
        let finished = events.filter { if case .finished = $0 { return true } else { return false } }
        XCTAssertEqual(finished.count, 1, "finished 必须恰好发一次")
    }

    // MARK: - Flashing is done when the board comes back, not when the tool exits 0

    /// A board that takes the image and never boots. The write path this item tests is the whole
    /// path, so this is a defect in the material — and it must be named on T04, which has criteria,
    /// rather than on the first board item, which is record-only and can only say 未得结果.
    func testAFlashedBoardThatNeverComesUpFailsT04AndStopsTheRun() async {
        let board = ScriptedBench.board()
        board.online = { false }
        let (run, _) = await execute(plan(), tool: tool(), board: board)

        let t04 = run.results["T04"]
        XCTAssertTrue(t04?.condemnsMaterial == true,
                      "\(String(describing: t04?.execution))｜\(String(describing: t04?.detail))")
        XCTAssertTrue(t04?.criteria.contains { $0.name == "刷机后设备上线" && !$0.passed } == true,
                      "\(t04?.criteria.map(\.name) ?? [])")
        XCTAssertEqual(run.stoppedAt, "T04", "刷机项不通过必须停在这儿，别再往下跑板载项")
        XCTAssertNil(run.results["T05"], "T05 不该被执行，更不该由它来背这个锅")
    }

    /// And when it does come up, the flash records how long that took.
    func testABoardThatComesUpRecordsItsFirstBootTime() async {
        let (run, _) = await execute(plan(), tool: tool(), board: ScriptedBench.board())

        let t04 = run.results["T04"]
        XCTAssertEqual(t04?.verdict, .passed, String(describing: t04?.detail))
        XCTAssertTrue(t04?.criteria.contains { $0.name == "刷机后设备上线" && $0.passed } == true)
        XCTAssertTrue(t04?.measurements.contains { $0.name == "首次启动耗时" } == true,
                      "\(t04?.measurements.map(\.name) ?? [])")
    }

    // MARK: - Sequences that cannot work are refused before a board is touched

    func testABoardSequenceWithoutFlashingIsRefused() async {
        let items = TestItem.ddrItems.filter { $0.code != "T04" }
        let (run, events) = await execute(plan(items: items), tool: tool(),
                                         board: ScriptedBench.board())

        XCTAssertEqual(run.stoppedAt, items.first?.code)
        XCTAssertTrue(run.results[items.first!.code]?.detail?.contains("序列不自洽") == true)
        XCTAssertFalse(events.contains { if case .waitingForBoard = $0 { return true }
                                         else { return false } },
                       "拒绝要发生在碰板子之前")
    }

    /// The other way to satisfy "the board must carry our test firmware": say which board already
    /// does. Without this, re-running only the board items costs a maskrom entry and a flash each
    /// time, which is minutes of a person's attention per attempt.
    func testABoardOnlySequenceBindsToTheNamedBoardAndNeverWaitsForMaskrom() async {
        var p = plan(items: TestItem.ddrItems.filter { $0.domain == .board })
        p.boardSerial = "7413b4e0bbc37640"
        var askedFor: String?
        var events: [RunEvent] = []
        let v = Validator(plan: p, tool: tool(),
                          boardSession: { askedFor = $0; return ScriptedBench.board() },
                          flashTool: ScriptedFlasher(), clock: SimClock())
        let run = await v.run { events.append($0) }

        XCTAssertEqual(askedFor, "7413b4e0bbc37640", "必须去连指定的那块板")
        XCTAssertNil(run.stoppedAt, String(describing: run.results.values.first?.detail))
        XCTAssertEqual(run.results["T06"]?.verdict, .passed)
        XCTAssertEqual(run.results["T08"]?.verdict, .passed)
        XCTAssertFalse(events.contains { if case .waitingForBoard = $0 { return true }
                                         else { return false } },
                       "序列里没有 maskrom 项，就不该去等 maskrom")
        XCTAssertTrue(ReportRenderer.render(run).contains("抽测"), "只跑一部分必须写明是抽测")
    }

    func testAnEmmcPlanIsRefusedPlainly() async {
        let (run, _) = await execute(plan(items: TestItem.emmcItems, flow: .emmc),
                                     tool: tool(), board: ScriptedBench.board())
        XCTAssertTrue(run.results["E01"]?.detail?.contains("尚未接入") == true,
                      String(describing: run.results["E01"]?.detail))
    }

    // MARK: - The record it produces

    func testTheRunCarriesTheBoardItActuallyTalkedTo() async {
        let (run, _) = await execute(plan(), tool: tool(), board: ScriptedBench.board())

        XCTAssertEqual(run.board.serial, "34376b2c031e323e")
        XCTAssertEqual(run.board.cpuid, "c0ffee01")
        XCTAssertEqual(run.board.socket, "002-1.4-2207-350e-NA")
        XCTAssertNotNil(run.finishedAt)
    }
}
