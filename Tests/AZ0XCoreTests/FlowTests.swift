import XCTest
@testable import AZ0XCore

/// What the sequence does next — decided separately from the verdict.
///
/// This is the axis the first iteration did not have. There, stopping the run was a computed
/// property of the outcome's class, so **anything** that was not a pass or a record ended the run.
/// T05 is a record-only bandwidth reading with no criteria at all and seven ways to fail on our own
/// side; a firmware missing `stress-ng` therefore cost the operator T06, T07 and T08 — more than
/// thirty-six hours — over a diagnostic binary that says nothing about the material.
final class FlowTests: XCTestCase {

    private func item(_ code: String) -> TestItem {
        let all = TestItem.ddrItems + TestItem.emmcItems
        return all.first { $0.code == code }!
    }

    private func result(_ code: String, _ build: (inout ItemResult) -> Void) -> ItemResult {
        var r = ItemResult(code: code)
        build(&r)
        return r
    }

    // MARK: - Only the material stops the run on its own account

    func testDefectiveMaterialStopsTheRun() {
        let r = result("T06") { r in
            r.criteria = [.equals("memtester FAILURE", 3, 0)]
            r.conclude()
        }
        XCTAssertEqual(Flow.after(r, item: item("T06")), .stop,
                       "物料有缺陷就不必再烧三十六小时")
    }

    func testAPassCarriesOn() {
        let r = result("T06") { r in
            r.criteria = [.equals("memtester FAILURE", 0, 0)]
            r.conclude()
        }
        XCTAssertEqual(Flow.after(r, item: item("T06")), .cont)
    }

    func testARecordOnlyResultCarriesOn() {
        let r = result("T05") { $0.conclude() }
        XCTAssertEqual(r.verdict, .noCriterion)
        XCTAssertEqual(Flow.after(r, item: item("T05")), .cont)
    }

    // MARK: - Our own problems stop the run only where something downstream needs the result

    /// The regression this model exists to prevent, stated as a test.
    func testAProblemOnOurSideInARecordOnlyItemDoesNotCostTheBurnIn() {
        for execution: Execution in [.interrupted("固件缺少 stress-ng —— 无法加压，采样无意义"),
                                     .invalid("探针未产生有效带宽读数"),
                                     .notStarted("读不到 dmc 可用频点")] {
            let r = result("T05") { $0.conclude(execution) }

            XCTAssertFalse(r.condemnsMaterial, "\(execution)")
            XCTAssertEqual(Flow.after(r, item: item("T05")), .cont,
                           "T05 测不成，绝不能因此不跑 T06/T07/T08：\(execution)")
        }
    }

    /// Same for the eMMC flow: a record-only performance reading must not cost E05's thirty-odd hours.
    func testARecordOnlyPerformanceProblemDoesNotCostE05() {
        let r = result("E03") { $0.invalid("有 2 项未实际搬运数据（带宽读数不可信）") }
        XCTAssertEqual(Flow.after(r, item: item("E03")), .cont)
    }

    /// Flashing is the one thing the rest of the sequence genuinely depends on.
    func testAFlashingProblemStopsTheRunBecauseNothingAfterItCanRun() {
        for code in ["T04", "E01"] {
            let r = result(code) { $0.interrupted("无法访问 CI 快照通道") }
            XCTAssertTrue(item(code).gatesRest, "\(code) 必须 gate 后续")
            XCTAssertEqual(Flow.after(r, item: item(code)), .stop,
                           "没有固件，板端项目根本没有可运行的环境")
        }
    }

    /// And nothing else gates: that is a property of the item table, not of a call site.
    func testOnlyFlashingGatesTheRest() {
        let gating = (TestItem.ddrItems + TestItem.emmcItems).filter(\.gatesRest).map(\.code)
        XCTAssertEqual(Set(gating), TestItem.flashCodes)
    }

    /// An item with no result yet does not decide anything.
    func testAnItemWithNoResultDoesNotStopAnything() {
        XCTAssertEqual(Flow.after(ItemResult(code: "T06"), item: item("T06")), .cont)
    }

    /// A defect stops the run even in an item that gates nothing — the verdict is enough.
    func testAVerdictStopsTheRunWithoutNeedingToGate() {
        let r = result("T02") { r in
            r.criteria = [.isTrue("设备 result code", false, expected: "solder.outcome 为 PASS")]
            r.conclude()
        }
        XCTAssertFalse(item("T02").gatesRest)
        XCTAssertEqual(Flow.after(r, item: item("T02")), .stop)
    }
}
