import XCTest
@testable import ValidationCore

/// What the report says, per axis.
///
/// The report is the deliverable — this bench exists so that nobody has to type the commands and
/// paste the values by hand — so the one thing it may never do is be wrong. Most of all it may never
/// word a problem on our side as a verdict on the material: a report that does that once sends the
/// operator back to typing commands, and then the automation has bought nothing.
final class ReportTests: XCTestCase {

    private func run(_ build: (inout [String: ItemResult]) -> Void,
                     stoppedAt: String? = nil,
                     items: [TestItem] = TestItem.ddrItems,
                     flow: ValidationFlow = .ddr,
                     scale: RunScale = .default) -> Run {
        var results: [String: ItemResult] = [:]
        build(&results)
        return Run(schemaVersion: Run.currentSchema,
                   runID: "1787190336-FB1391E4", batchID: "AZ08-DDR-20260824-100000",
                   model: .az08, flow: flow,
                   board: .init(serial: "34376b2c031e323e", cpuid: "c0ffee", chipVariant: nil,
                                socket: "002-1.4", reported: "Focalcrest AZ08", uptimeAtBind: 42),
                   burninPhases: BurninPhase.allCases, scale: scale,
                   items: items, results: results,
                   startedAt: Date(timeIntervalSince1970: 1_787_000_000),
                   finishedAt: Date(timeIntervalSince1970: 1_787_130_000),
                   stoppedAt: stoppedAt,
                   toolVersions: [], appVersion: "1.0.0-3-gabc1234")
    }

    /// Every item passing, with the record-only ones recorded.
    private func allGood(_ results: inout [String: ItemResult]) {
        for item in TestItem.ddrItems {
            var r = ItemResult(code: item.code)
            r.measurements = [.num("实际历时", 43_200, "s")]
            if !item.isRecordOnly { r.criteria = [.equals("检查", 0, 0)] }
            r.conclude()
            results[item.code] = r
        }
    }

    // MARK: - The healthy report

    func testAFullPassSaysSoAndClaimsNothingElse() {
        let md = ReportRenderer.render(run(allGood))

        XCTAssertTrue(md.contains("项全部通过"), md)
        XCTAssertFalse(md.contains("未取得结果"), "没有未得结果的项，就不该出现这一行")
        XCTAssertTrue(md.contains("仅记录"), "T01/T05 无判据，报告必须点明")
        XCTAssertFalse(md.contains("失败"))
    }

    /// A run is judged against what it was asked to do, and the report says what that was.
    ///
    /// This replaces the whole 抽测 apparatus. Found on real hardware first: an eMMC run at one
    /// twentieth of the then-standard produced a document headed 初步报告 · ✅ 4 项全部通过, with the
    /// real figure visible only in an appendix. The fix at the time was a second report title and a
    /// warning banner, both derived from a compiled-in "right" amount — which meant the software was
    /// grading the operator's choice instead of reporting it.
    ///
    /// Now there is no right amount. What keeps a five-cycle pass from reading like a three-thousand
    /// cycle pass is simply that the report says five, on every run, in the same words.
    func testTheReportStatesTheAmountsItWasAskedFor() {
        var scale = RunScale.default
        scale.emmcTargetN = 1
        let md = ReportRenderer.render(run(allGood, items: TestItem.emmcItems,
                                           flow: .emmc, scale: scale))

        XCTAssertTrue(md.contains("本次范围"), "本次要求了什么，报告必须写：\n\(md)")
        XCTAssertTrue(md.contains("eMMC 拷机 1 次全盘写"), "量要写出来：\n\(md)")
        XCTAssertFalse(md.contains("1 / 20"), "不写对照 —— 对照就是那个被删掉的预设标准")
        XCTAssertFalse(md.contains("抽测"), "跑得少不是抽测，是一次小一点的验证")
        XCTAssertTrue(md.contains("# Rockchip eMMC 物料验证报告"), "只有一种标题：\n\(md)")
    }

    /// A large run and a small one produce the same document in the same form.
    ///
    /// If the amounts were only spelled out when they looked unusual, a reader would learn to infer
    /// a target from the software's silence, and the presumed standard would be back.
    func testLargeAndSmallRunsReadTheSameWay() {
        var small = RunScale.default; small.cycles = 5
        var large = RunScale.default; large.cycles = 5_000

        let a = ReportRenderer.render(run(allGood, scale: small))
        let b = ReportRenderer.render(run(allGood, scale: large))

        XCTAssertTrue(a.contains("休眠唤醒 5 次") && a.contains("重启 5 次"), a)
        XCTAssertTrue(a.contains("项全部通过"), "判据是本次的量，跑满了就是通过，不打折：\n\(a)")
        XCTAssertTrue(b.contains("休眠唤醒 5000 次") && b.contains("重启 5000 次"), b)
        for md in [a, b] {
            XCTAssertTrue(md.contains("# Rockchip DDR 物料验证报告"), "只有一种标题：\n\(md)")
            XCTAssertFalse(md.contains("抽测"), md)
        }
    }

    // MARK: - The case the first iteration could not report honestly

    /// A record-only reading that could not be taken, and a run that carried on regardless.
    ///
    /// Before, T05 failing on our side ended the run, so this report did not exist — the operator got
    /// "已在 T05 中止" and no burn-in at all. Now the run completes, and the report has to say two
    /// true things at once: the material passed everything that was judged, and one reading is
    /// missing. Neither may be worded as the other.
    func testARecordOnlyItemThatCouldNotBeMeasuredDoesNotReadAsAFailure() {
        let md = ReportRenderer.render(run { results in
            allGood(&results)
            var t05 = ItemResult(code: "T05")
            t05.interrupted("固件缺少 stress-ng —— 无法加压，采样无意义")
            results["T05"] = t05
        })

        XCTAssertTrue(md.contains("已判定的"), "被判定的项目都通过了，这句必须还在：\n\(md)")
        XCTAssertFalse(md.contains("全部通过"),
                       "有一项没测出结果时不该说「全部」——那是在夸大覆盖面")
        XCTAssertTrue(md.contains("未取得结果"), md)
        XCTAssertTrue(md.contains("stress-ng"), "原因要写进报告，操作员才知道去修什么")
        XCTAssertTrue(md.contains("环境或工具问题"), "原因要写，读者自己看得出这说明不了物料：\n\(md)")
        XCTAssertFalse(md.contains("不构成"), "解读留给人 —— 上一行已经逐项写了为什么没结果")
        XCTAssertFalse(md.contains("❌"), "我们这一侧的问题不得渲染成不合格：\n\(md)")
    }

    /// And the item's own row says 未得结果, not 失败.
    func testTheRowForSuchAnItemSaysNoResult() {
        let md = ReportRenderer.render(run { results in
            allGood(&results)
            var t05 = ItemResult(code: "T05")
            t05.validity = [.isTrue("锁定最高频率", false, expected: "cur_freq 等于请求值")]
            t05.conclude()
            results["T05"] = t05
        })
        let row = md.components(separatedBy: .newlines).first { $0.hasPrefix("| T05 ") } ?? ""

        XCTAssertTrue(row.contains("未得结果"), row)
        XCTAssertFalse(row.contains("失败"), row)
        XCTAssertTrue(row.contains("锁定最高频率"), "要写出是哪条前提没满足：\(row)")
    }

    // MARK: - A real defect still reads as one

    func testADefectIsReportedAsADefect() {
        let md = ReportRenderer.render(run({ results in
            allGood(&results)
            var t06 = ItemResult(code: "T06")
            t06.criteria = [.equals("memtester FAILURE", 3, 0)]
            t06.conclude()
            results["T06"] = t06
            for code in ["T07", "T08"] { results[code] = nil }
        }, stoppedAt: "T06"))

        XCTAssertTrue(md.contains("❌"), md)
        XCTAssertTrue(md.contains("memtester FAILURE"), md)
        XCTAssertTrue(md.contains("后续 2 项未执行"), md)
        XCTAssertFalse(md.contains("不构成"), "报告只陈述执行与判据")
    }

    /// Every failing criterion is listed, not only the first.
    func testAllFailingCriteriaAreListed() {
        let md = ReportRenderer.render(run { results in
            allGood(&results)
            var t06 = ItemResult(code: "T06")
            t06.criteria = [.equals("memtester FAILURE", 3, 0),
                            .equals("变频失败", 7, 0)]
            t06.conclude()
            results["T06"] = t06
        })
        XCTAssertTrue(md.contains("memtester FAILURE"), md)
        XCTAssertTrue(md.contains("变频失败"), md)
    }

    // MARK: - Items that never ran

    func testItemsWithNoResultAreCountedInTheHeader() {
        let md = ReportRenderer.render(run { results in
            var t01 = ItemResult(code: "T01"); t01.conclude(); results["T01"] = t01
        })
        XCTAssertTrue(md.contains("未完成"), "表头必须把未执行的项算进去：\n\(md)")
        XCTAssertFalse(md.contains("项全部通过"), "有项没跑就不能说全部通过")
    }
}
