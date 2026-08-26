import XCTest
@testable import AZ0XCore

/// Reading the archive back, for the list of past batches.
///
/// The archive is the history: every run has always written `run.json` and a report there, and
/// nothing was ever lost — the application simply did not look. So this reads, and only reads.
final class ArchiveReadTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("az0x-archive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func run(_ boardSerial: String, stoppedAt: String? = nil) -> Run {
        var results: [String: ItemResult] = [:]
        for item in TestItem.ddrItems {
            var r = ItemResult(code: item.code)
            if !item.isRecordOnly {
                r.criteria = [.equals("检查", stoppedAt == item.code ? 1 : 0, 0)]
            }
            r.conclude()
            results[item.code] = r
        }
        return Run(schemaVersion: Run.currentSchema, runID: "r", batchID: "b",
                   model: .az08, flow: .ddr,
                   board: .init(serial: boardSerial, cpuid: nil, chipVariant: nil,
                                socket: "002-1.4", reported: nil, uptimeAtBind: 0),
                   burninPhases: BurninPhase.allCases, scale: .default,
                   items: TestItem.ddrItems, results: results,
                   startedAt: Date(timeIntervalSince1970: 1_787_000_000), finishedAt: nil,
                   stoppedAt: stoppedAt, toolVersions: [], appVersion: "2.0")
    }

    /// Writes one board folder the way a real run does, and returns it.
    private func archive(_ run: Run, batch: String, board: String,
                         report: Bool = true) throws -> URL {
        let dir = root.appendingPathComponent(batch).appendingPathComponent(board)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = RunStore.write(run, into: dir)
        if !report {
            for f in (try? FileManager.default.contentsOfDirectory(at: dir,
                        includingPropertiesForKeys: nil))! where f.pathExtension == "md" {
                try FileManager.default.removeItem(at: f)
            }
        }
        return dir
    }

    /// The same record as an older build would have written it: complete, one version behind.
    private func olderVersion(of run: Run) throws -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        let text = String(data: try e.encode(run), encoding: .utf8)!
        let older = text.replacingOccurrences(of: "\"schemaVersion\":\(Run.currentSchema)",
                                              with: "\"schemaVersion\":\(Run.currentSchema - 1)")
        XCTAssertNotEqual(older, text, "版本号没被改掉，这条测试就没在测版本")
        return older
    }

    private func writeRaw(_ text: String, batch: String, board: String) throws {
        let dir = root.appendingPathComponent(batch).appendingPathComponent(board)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("run.json"), atomically: true,
                       encoding: .utf8)
    }

    func testABatchIsReadWithEveryBoardInIt() throws {
        _ = try archive(run("aaa"), batch: "AZ08-DDR-20260826-100000", board: "002-1.4")
        _ = try archive(run("bbb"), batch: "AZ08-DDR-20260826-100000", board: "002-2.1")

        let found = RunStore.past(in: root)

        XCTAssertEqual(found.count, 1, "一个批次目录就是一个批次")
        XCTAssertEqual(found.first?.runs.map(\.run.boardName), ["aaa", "bbb"])
        XCTAssertEqual(found.first?.model, .az08)
        XCTAssertNotNil(found.first?.runs.first?.reportURL, "报告也要找到")
    }

    /// Whatever this build cannot read is skipped without a word. The archive accumulates across
    /// versions of this program and the generation before it, and a list that explained every
    /// unreadable folder would be mostly explanations.
    func testUnreadableRecordsAreSkippedSilently() throws {
        _ = try archive(run("good"), batch: "AZ08-DDR-20260826-100000", board: "002-1.4")
        try writeRaw("{ not json at all", batch: "AZ08-DDR-20260826-090000", board: "002-1.4")
        // A complete record from an older build: every field present, only the version behind.
        // A stub would not reach the version check at all — it fails to decode first, which is how
        // the first version of this test passed while the check itself did nothing.
        try writeRaw(olderVersion(of: run("stale")),
                     batch: "AZ08-DDR-20260825-090000", board: "002-1.4")
        // A folder from a run that never finished: created, nothing written into it.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("AZ08-DDR-20260824-090000/002-1.4"),
            withIntermediateDirectories: true)

        let found = RunStore.past(in: root)

        XCTAssertEqual(found.count, 1, "只有读得懂的那一个：\(found.map(\.batchID))")
        XCTAssertEqual(found.first?.runs.first?.run.boardName, "good")
    }

    /// Newest first, and only as many as asked for: a bench doing twenty runs a day fills this
    /// directory with thousands of folders, and none of that may be parsed to draw one screen.
    func testNewestFirstAndNoMoreThanTheLimit() throws {
        for n in 1...4 {
            let dir = try archive(run("board\(n)"),
                                  batch: "AZ08-DDR-2026082\(n)-100000", board: "002-1.4")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_787_000_000 + Double(n) * 86_400)],
                ofItemAtPath: dir.deletingLastPathComponent().path)
        }

        let found = RunStore.past(in: root, limit: 2)

        XCTAssertEqual(found.map(\.batchID),
                       ["AZ08-DDR-20260824-100000", "AZ08-DDR-20260823-100000"],
                       "新的在前，且只读要求的数量")
    }

    /// The line each board shows is the one the report's 执行结果 row carries — the same function,
    /// so a list that says one thing cannot contain a report that says another.
    func testTheBoardLineIsTheReportsOwnSentence() throws {
        _ = try archive(run("bad", stoppedAt: "T06"),
                        batch: "AZ08-DDR-20260826-100000", board: "002-1.4")

        let past = RunStore.past(in: root).first!.runs.first!
        let line = ReportRenderer.outcome(past.run)

        XCTAssertTrue(line.contains("❌"), line)
        XCTAssertTrue(try String(contentsOf: past.reportURL!, encoding: .utf8).contains(line),
                      "同一句话必须原样出现在报告里：\(line)")
    }
}
