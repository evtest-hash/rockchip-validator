import XCTest
@testable import AZ0XCore

/// What the appendix carries, and what it deliberately does not.
///
/// The appendix is the part of the report that leaves the building: someone else reads it to judge
/// the material. Two rules decide what belongs there, and both were got wrong on a real AZ08 run.
final class AppendixTests: XCTestCase {

    private func run(_ code: String, _ evidence: [Evidence],
                     items: [TestItem] = TestItem.ddrItems) -> Run {
        var r = ItemResult(code: code)
        r.criteria = [.equals("检查", 0, 0)]
        r.evidence = evidence
        r.conclude()
        return Run(schemaVersion: Run.currentSchema, runID: "r", batchID: "b",
                   model: .az08, flow: .ddr,
                   board: .init(serial: "s", cpuid: nil, chipVariant: nil, socket: "002-1.4",
                                reported: nil, uptimeAtBind: 0),
                   burninPhases: BurninPhase.allCases, scale: .default,
                   items: items, results: [code: r],
                   startedAt: nil, finishedAt: nil, stoppedAt: nil, abortedAt: nil,
                   toolVersions: [], appVersion: "2.0")
    }

    private var longLog: String {
        (1...400).map { "line \($0)" }.joined(separator: "\n")
    }

    /// A maskrom item's evidence is one tool invocation's transcript. It is the same length whatever
    /// the run asks for, and it is the whole of what the device said.
    ///
    /// A real AZ08's eye scan is 570 lines. The report showed 25 of them, then 略去 1082 行, then 25
    /// more — and the elision was applied by the renderer, so nothing in the item could say "this one
    /// is complete". Which lines a reader needs is not something a line count can decide.
    func testAMaskromTranscriptIsShownWhole() {
        let md = ReportRenderer.render(run("T03", [.log("DQ 眼图扫描 transcript", longLog)]))

        XCTAssertTrue(md.contains("line 200"), "工具输出必须整段贴，不许中间挖掉：\n\(md.prefix(600))")
        XCTAssertFalse(md.contains("略去"), "maskrom 项的证据不缩略")
    }

    /// Board-side evidence grows with the run, so the reading copy is shortened — and the record is
    /// not: every line stays in run.json, which is where a figure would be checked against.
    func testBoardEvidenceIsShortenedForReadingOnly() {
        let r = run("T06", [.log("板端 progress.log", longLog)])
        let md = ReportRenderer.render(r)

        XCTAssertTrue(md.contains("略去"), "板端日志随次数增长，读的那份要缩")
        XCTAssertTrue(r.results["T06"]!.evidence[0].body.contains("line 200"),
                      "缩略只发生在渲染时；记录必须是全的")
    }

    /// T07 and T08 write one line per cycle, so at the acceptance amount the log is three thousand
    /// lines of the same sentence. Both appendices already carry its two ends in readable form.
    func testAPassingCycleItemDoesNotCarryItsWholeProgressLog() async {
        let clock = SimClock()
        let board = ScriptedBench.board()
        board.files["/userdata/az0x-ddr/t07_suspend/progress.log"] =
            (1...30).map { "\(1000 + $0 * 16) cycle \($0) rc=0 fail=0" }
                .joined(separator: "\n") + "\n1500 SUSPEND_SUCCESS end=30\n1501 ALLDONE 30"
        let items = BoardItems(adb: board, model: .az08, channels: 4,
                               busBitsPerChannel: 16, clock: clock)

        let r = await items.runT07(targetCycles: 30)
        let titles = r.evidence.map(\.title)

        XCTAssertEqual(r.verdict, .passed, String(describing: r.detail))
        XCTAssertFalse(titles.contains("板端 progress.log"), "跑通了就不贴全文：\(titles)")
        XCTAssertTrue(titles.contains("首尾周期样本"), "但两端要留下：\(titles)")
    }

    /// The failure paths keep it whole. That is where nothing else says what happened — there is no
    /// summary table to fall back on when the board stopped answering.
    func testAVanishedBoardStillCarriesWhatTheHostLastSaw() async {
        let clock = SimClock()
        let board = ScriptedBench.board()
        board.files["/userdata/az0x-ddr/t07_suspend/progress.log"] =
            "1000 SUSPEND_SUCCESS start=0\n1017 cycle 1 rc=0 fail=0"
        var checks = 0
        board.online = { checks += 1; return checks <= 6 }
        let items = BoardItems(adb: board, model: .az08, channels: 4,
                               busBitsPerChannel: 16, clock: clock)

        let r = await items.runT07(targetCycles: 3_000)

        XCTAssertTrue(r.condemnsMaterial, "起不来就是起不来")
        XCTAssertTrue(r.evidence.contains { $0.title.contains("progress.log") },
                      "没有结论的时候，主机最后看到的东西是唯一线索：\(r.evidence.map(\.title))")
    }

    /// A bandwidth figure without its ceiling is not a reading, it is a number.
    ///
    /// T05 has no criterion — whoever holds the material spec does the judging — so the report has to
    /// hand them the proportion, not make them go and find the divisor.
    func testTheBandwidthRowCarriesWhatMakesItAProportion() {
        for name in ["峰值带宽", "理论带宽", "峰值利用率"] {
            XCTAssertTrue(ReportRenderer.keyMeasurementNames["T05"]!.contains(name),
                          "T05 那一行少了 \(name)")
        }
    }
}
