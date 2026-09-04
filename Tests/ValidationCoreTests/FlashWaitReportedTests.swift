import XCTest
@testable import ValidationCore

/// Flashing reports both of its halves.
///
/// The tool exiting 0 is not the end of T04: the board it wrote has to come back on adb, and whether
/// it does is a criterion of this item. That wait ran for up to three minutes emitting nothing, so
/// the screen sat at 刷入镜像 100% and read as though the software had stopped — which is what it
/// was reported as.
final class FlashWaitReportedTests: XCTestCase {

    private func tool() -> ScriptedMaskromTool {
        ScriptedMaskromTool([
            "--detect": .init(json: ["detect": ["pass": true, "type": "LPDDR4X",
                                                "capacityMB": 4096, "channels": 2, "csPerDie": 2,
                                                "cfg": "az08.cfg"],
                                     "cpuid": "c0ffee01", "serial": "34376b2c031e323e"],
                              exitCode: 0),
        ])
    }

    /// The board never comes back, so the wait runs to its limit — the longest this can be, and the
    /// case that has to be legible while it happens.
    func testTheWaitAfterWritingIsReportedInSecondsAgainstItsLimit() async {
        let board = ScriptedBench.board()
        board.online = { false }                 // flashed, never boots
        var p = RunPlan(batchID: "AZ08-DDR", model: .az08, flow: .ddr,
                        items: TestItem.ddrItems.filter { $0.code == "T04" },
                        burninPhases: Set(BurninPhase.allCases),
                        deviceID: "002-1.4-2207-350e-NA")
        p.image = readyImage
        let v = Validator(plan: p, tool: tool(), boardSession: { _ in board },
                          flashTool: ScriptedFlasher(), clock: SimClock())

        var steps: [StepProgress] = []
        let run = await v.run { if case let .step(s) = $0 { steps.append(s) } }

        let waits = steps.filter { $0.label == "等待板子启动" }
        XCTAssertFalse(waits.isEmpty, "写完之后那段等待必须报出来：\(steps.map(\.label))")
        XCTAssertEqual(waits.first?.metric, .seconds, "秒，不是百分比")
        XCTAssertEqual(waits.first?.total, Int64(Thresholds.bootBackSeconds),
                       "上限要写出来 —— 它就是判据本身")
        XCTAssertTrue(waits.map(\.done) == waits.map(\.done).sorted(), "已等的秒数只增不减")
        XCTAssertEqual(waits.first?.valueText.contains("上限"), true, waits.first?.valueText ?? "")

        // And the item still concludes the way it did: a board that never came back failed T04.
        XCTAssertEqual(run.results["T04"]?.criteria.first { $0.name == "刷机后设备上线" }?.passed,
                       false)
    }

    /// A board that answers at once produces the verdict without a wait to report.
    func testABoardThatIsAlreadyThereReportsNoWait() async {
        var p = RunPlan(batchID: "AZ08-DDR", model: .az08, flow: .ddr,
                        items: TestItem.ddrItems.filter { $0.code == "T04" },
                        burninPhases: Set(BurninPhase.allCases),
                        deviceID: "002-1.4-2207-350e-NA")
        p.image = readyImage
        let v = Validator(plan: p, tool: tool(), boardSession: { _ in ScriptedBench.board() },
                          flashTool: ScriptedFlasher(), clock: SimClock())

        var steps: [StepProgress] = []
        let run = await v.run { if case let .step(s) = $0 { steps.append(s) } }

        XCTAssertTrue(steps.filter { $0.label == "等待板子启动" }.isEmpty,
                      "没等就不该报等待：\(steps.map(\.label))")
        XCTAssertEqual(run.results["T04"]?.verdict, .passed,
                       String(describing: run.results["T04"]?.detail))
    }

    /// Seconds read as seconds. A percentage of an allowance is not a reading of anything.
    func testSecondsAreWordedAsSeconds() {
        let waiting = StepProgress(metric: .seconds, code: "T04", label: "等待板子启动",
                                   done: 42, total: 180)
        XCTAssertEqual(waiting.valueText, "已等 42 秒 / 上限 180 秒")
        XCTAssertEqual(StepProgress(metric: .seconds, code: "T04", label: "等待板子启动",
                                    done: 42, total: nil).valueText, "已等 42 秒")
    }
}
