import XCTest
@testable import ValidationCore

/// When each item ran, and for how long.
///
/// The record has carried `startedAt` and `finishedAt` per item all along and nothing displayed
/// them. What the result column showed instead was whatever duration each item happened to record
/// for itself — 工具耗时 on T03, 刷写耗时 on T04, 实际历时 on the long runs, nothing on T02 or T08 —
/// so the one question asked of every item had a different answer shape on each row, or none.
final class ItemTimingTests: XCTestCase {

    /// 22:10 local whatever the machine's timezone, so "twelve hours later" crosses midnight
    /// everywhere. Derived rather than hard-coded: 1_787_000_000 is 04:53 here and 20:53 in Denver,
    /// and a test whose premise is the tester's timezone passes or fails by accident.
    private let t0 = Calendar.current.date(bySettingHour: 22, minute: 10, second: 4,
                                           of: Date(timeIntervalSince1970: 1_787_000_000))!

    private func run(_ spans: [String: (Double, Double?)]) -> Run {
        var results: [String: ItemResult] = [:]
        for (code, span) in spans {
            var r = ItemResult(code: code)
            r.criteria = [.equals("检查", 0, 0)]
            r.startedAt = t0.addingTimeInterval(span.0)
            r.finishedAt = span.1.map { t0.addingTimeInterval($0) }
            r.conclude()
            results[code] = r
        }
        return Run(schemaVersion: Run.currentSchema, runID: "r", batchID: "b",
                   model: .az08, flow: .ddr,
                   board: .init(serial: "s", cpuid: nil, chipVariant: nil, socket: "002-1.4",
                                reported: nil, uptimeAtBind: 0),
                   burninPhases: BurninPhase.allCases, scale: .default,
                   items: TestItem.ddrItems, results: results,
                   startedAt: t0, finishedAt: nil, stoppedAt: nil,
                   toolVersions: [], appVersion: "1.0.0-3-gabc1234")
    }

    private func row(_ md: String, _ code: String) -> String {
        md.components(separatedBy: .newlines).first { $0.hasPrefix("| \(code) ") } ?? ""
    }

    /// The 起止（历时）cell alone, so an assertion about it cannot be satisfied by the prose in the
    /// 测试方法 cell beside it.
    private func span(_ md: String, _ code: String) -> String {
        let cells = row(md, code).components(separatedBy: "|")
        return cells.count > 4 ? cells[4].trimmingCharacters(in: .whitespaces) : ""
    }

    func testEveryExecutedItemStatesWhenItRanAndForHowLong() {
        let md = ReportRenderer.render(run(["T02": (0, 24), "T06": (24, 215)]))

        XCTAssertTrue(span(md, "T02").contains("（24 秒）"), span(md, "T02"))
        XCTAssertTrue(span(md, "T06").contains("（3 分 11 秒）"), span(md, "T06"))
        XCTAssertTrue(span(md, "T02").contains("→"), "起止两头都要有：\(span(md, "T02"))")
    }

    /// An item that did not run has nothing to state, and states nothing rather than a zero.
    func testAnItemThatDidNotRunShowsNoTime() {
        let md = ReportRenderer.render(run(["T02": (0, 24)]))
        let t08 = row(md, "T08")

        XCTAssertTrue(t08.contains("未执行"), t08)
        XCTAssertFalse(span(md, "T08").contains("→"), "没跑就没有起止：\(span(md, "T08"))")
        XCTAssertFalse(span(md, "T08").contains("0 秒"), "更不该是 0 秒：\(span(md, "T08"))")
    }

    /// A twelve-hour phase crosses midnight. `22:13:20 → 10:13:20` on one line reads as a run that
    /// went backwards, so the date appears — and only then, which is what makes it mean something.
    func testADayBoundaryCarriesTheDate() {
        let md = ReportRenderer.render(run(["T02": (0, 24), "T06": (24, 43_224)]))

        XCTAssertTrue(row(md, "T06").contains("（12 小时 0 分）"), row(md, "T06"))
        XCTAssertEqual(span(md, "T06").components(separatedBy: "-").count - 1, 1,
                       "跨天的那一头要带日期，只带一头：\(span(md, "T06"))")
        XCTAssertFalse(span(md, "T02").contains("-"),
                       "没跨天就不带日期，否则它的出现就不说明任何事：\(span(md, "T02"))")
    }

    /// Started and never finished: said as it is, not filled in with a guess.
    func testAnUnfinishedItemSaysSo() {
        let md = ReportRenderer.render(run(["T02": (0, nil)]))

        XCTAssertTrue(span(md, "T02").contains("未结束"), span(md, "T02"))
        XCTAssertFalse(span(md, "T02").contains("（"), "没有历时可写：\(span(md, "T02"))")
    }
}
