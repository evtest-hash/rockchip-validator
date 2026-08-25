import XCTest
@testable import AZ0XCore

/// The three axes, and the one thing the first iteration could not express.
final class ConclusionTests: XCTestCase {

    private func result(_ code: String = "T06") -> ItemResult { ItemResult(code: code) }

    // MARK: - Settling the two check lists

    /// All criteria passing is a pass.
    func testAllCriteriaPassingIsAPass() {
        var r = result()
        r.criteria = [.equals("memtester FAILURE", 0, 0)]
        r.conclude()

        XCTAssertEqual(r.execution, .completed)
        XCTAssertEqual(r.verdict, .passed)
        XCTAssertEqual(r.label, "通过")
    }

    /// A failing criterion condemns the material, and names itself.
    func testAFailingCriterionCondemnsTheMaterial() {
        var r = result()
        r.criteria = [.equals("memtester FAILURE", 3, 0)]
        r.conclude()

        XCTAssertTrue(r.condemnsMaterial)
        XCTAssertEqual(r.verdict, .notPassed("memtester FAILURE：实测 3，要求 = 0"))
        XCTAssertEqual(r.label, "不合格")
    }

    /// **The point of the whole model.** A failing validity check must never become a verdict.
    ///
    /// "memtester never looped" and "memtester found a bit error" shared one list in the first
    /// iteration, so both rendered as 不通过. One is a defect in the material; the other is our test
    /// not having run. Only the first may condemn anything.
    func testAFailingValidityCheckNeverCondemnsTheMaterial() {
        var r = result()
        r.validity = [.isTrue("memtester 实际执行（定频段）", false, expected: "日志出现 Loop")]
        r.criteria = [.equals("memtester FAILURE", 0, 0)]      // would have passed
        r.conclude()

        XCTAssertFalse(r.condemnsMaterial, "测试没跑起来不是物料缺陷")
        XCTAssertNil(r.verdict, "无效的运行没有判定，而不是一个从不可信读数算出来的判定")
        XCTAssertEqual(r.execution,
                       .invalid("memtester 实际执行（定频段）：实测 不满足，要求 日志出现 Loop"))
        XCTAssertEqual(r.label, "未得结果")
    }

    /// Validity is decided first, so a run that was not valid is never judged on its criteria.
    func testValidityIsDecidedBeforeTheCriteria() {
        var r = result()
        r.validity = [.isTrue("变频实际发生", false, expected: "成功切频次数 > 0")]
        r.criteria = [.equals("变频失败", 9, 0)]                // would have failed too
        r.conclude()

        XCTAssertNil(r.verdict, "先判有效性，不给出基于不可信读数的物料判定")
        guard case let .invalid(why) = r.execution else { return XCTFail("\(String(describing: r.execution))") }
        XCTAssertTrue(why.contains("变频实际发生"), why)
    }

    /// No criteria at all is `noCriterion`, not a pass. Four items are like this by design.
    func testNoCriteriaIsRecordedNotPassed() {
        var r = result("T05")
        r.validity = [.isTrue("锁定最高频率", true, expected: "cur_freq 等于请求值")]
        r.measurements = [.num("峰值带宽", 12164, "MB/s")]
        r.conclude()

        XCTAssertEqual(r.verdict, .noCriterion)
        XCTAssertEqual(r.label, "仅记录")
        XCTAssertFalse(r.condemnsMaterial)
    }

    /// Execution that did not complete has no verdict, whatever the check lists say.
    func testAnIncompleteExecutionHasNoVerdict() {
        for execution: Execution in [.notStarted("无 adb 设备"),
                                     .interrupted("板端报告无法继续：SATABORT"),
                                     .invalid("读不到板端 progress.log")] {
            var r = result()
            r.criteria = [.equals("memtester FAILURE", 0, 0)]   // would have passed
            r.conclude(execution)

            XCTAssertNil(r.verdict, "\(execution)")
            XCTAssertFalse(r.condemnsMaterial, "\(execution)")
            XCTAssertEqual(r.detail, execution.reason)
        }
    }

    /// The two kinds of no-result look identical to the operator; only the sentence differs.
    func testInterruptedAndInvalidReadTheSameToTheOperator() {
        var a = result(); a.interrupted("中途断了")
        var b = result(); b.invalid("跑完了但读不出")

        XCTAssertEqual(a.label, b.label)
        XCTAssertEqual(a.label, "未得结果")
        XCTAssertNotEqual(a.detail, b.detail)
    }
}
