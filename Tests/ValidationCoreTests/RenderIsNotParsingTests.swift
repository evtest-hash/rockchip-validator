import XCTest
@testable import ValidationCore

/// Every figure in the report was extracted when the item ran, never parsed at render time.
///
/// This is the discipline four mature frameworks share: OpenHTF has you set a measurement and
/// attach the raw output separately, Tradefed reports metrics and logs through different calls,
/// TestStand's report row is name / measured / limits / status. The value in the record is never
/// re-derived from an attachment.
///
/// Breaking it re-welds judgement to evidence, which is the exact tangle this iteration exists to
/// undo — and it breaks quietly, because the numbers stay right until a log's format shifts.
final class RenderIsNotParsingTests: XCTestCase {

    private func run(withLogs bodies: String) -> Run {
        var results: [String: ItemResult] = [:]
        for item in TestItem.ddrItems {
            var r = ItemResult(code: item.code)
            r.measurements = [.num("实际历时", 43_200, "s"), .num("完成周期", 3_000)]
            if !item.isRecordOnly { r.criteria = [.equals("memtester FAILURE", 0, 0)] }
            // A board-side progress.log on a maskrom item is not a shape that occurs: those items
            // run before the board boots. It mattered once the appendix started treating the two
            // domains differently — the long log was reaching T01's appendix, where it is shown
            // whole, and the assertion about shortening passed on the wrong item.
            r.evidence = [.markdown("各段总览", "| 项 | 值 |\n|---|---|\n| 完成段数 | 3 |")]
            if item.domain == .board { r.evidence.insert(.log("板端 progress.log", bodies), at: 0) }
            r.conclude()
            results[item.code] = r
        }
        return Run(schemaVersion: Run.currentSchema, runID: "r", batchID: "AZ08-DDR-20260825-101149",
                   model: .az08, flow: .ddr,
                   board: .init(serial: "7413b4e0bbc37640", cpuid: "c0ffee", chipVariant: nil,
                                socket: "002-1.4", reported: "AZ08", uptimeAtBind: 42),
                   burninPhases: BurninPhase.allCases, scale: .default, items: TestItem.ddrItems, results: results,
                   startedAt: Date(timeIntervalSince1970: 1_787_000_000),
                   finishedAt: Date(timeIntervalSince1970: 1_787_130_000),
                   stoppedAt: nil, toolVersions: [], appVersion: "1.0.0-3-gabc1234")
    }

    /// Replace every log body with something that contradicts the record. Nothing above the
    /// appendix may move.
    func testTheReportSaysTheSameThingWhateverTheLogsContain() {
        let real = ReportRenderer.render(run(withLogs:
            "1000 PHASES ABC\n1020 PHASE_A_DONE\n1060 ALLDONE"))
        let lies = ReportRenderer.render(run(withLogs:
            "FAILURE FAILURE FAILURE\n完成段数 99\n实际历时 1 s\nPANIC\nALLDONE 0"))

        func aboveAppendix(_ md: String) -> String {
            String(md[md.startIndex..<(md.range(of: "## 附录")?.lowerBound ?? md.endIndex)])
        }
        XCTAssertEqual(aboveAppendix(real), aboveAppendix(lies),
                       "报告里的每个数都必须来自记录下来的测量值和判据，不能是渲染时从日志里解析的")
    }

    /// A long log stays whole in the record and is shortened only for reading.
    func testALongLogIsKeptWholeAndOnlyShortenedForReading() {
        let long = (1...3_000).map { "cycle \($0) rc=0 fail=0" }.joined(separator: "\n")
        let r = run(withLogs: long)

        XCTAssertEqual(r.results["T07"]?.evidence.first?.body, long, "记录里必须是全文")
        let md = ReportRenderer.render(r)
        XCTAssertTrue(md.contains("略去"), "附录里要写明略去了多少行")
        XCTAssertTrue(md.contains("cycle 1 rc=0"), "首尾都要留")
        XCTAssertTrue(md.contains("cycle 3000 rc=0"))
        XCTAssertFalse(md.contains("cycle 1500 rc=0"), "中间该被略掉")
    }
}
