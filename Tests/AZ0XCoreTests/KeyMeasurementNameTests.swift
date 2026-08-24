import XCTest
@testable import AZ0XCore

/// Every name the report looks for must be one a producer actually records.
///
/// The two are coupled by a string across files, with nothing in the language to hold them together:
/// the renderer asks for a name, and if no producer writes it the lookup silently misses and the
/// fallback lists whatever else it finds. The column still renders, so nobody notices.
///
/// It has drifted twice. T03 asked for `all result 行数`, which no producer ever wrote. Then v2.7
/// moved T02's geometry to T01 and renamed its duration, leaving `检出容量` / `总线位宽` / `扫描耗时`
/// in the table with no producer at all — found by reading a real report, not by a test. This is that
/// test.
final class KeyMeasurementNameTests: XCTestCase {

    /// Items whose producers are not in this iteration yet. Shrinks to empty as they land; a name
    /// listed for one of these cannot be checked, and pretending otherwise would be worse.
    private let notYetPorted: Set<String> = ["E01", "E02", "E03", "E04", "E05", "E06"]

    private var itemsDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AZ0XCore/Items")
    }

    /// Every measurement name the item sources record, read out of the source itself.
    private func recordedNames() throws -> Set<String> {
        let files = (FileManager.default.enumerator(at: itemsDirectory,
                                                    includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "没找到 Items 源码，这条测试就没在检查任何东西")

        var names: Set<String> = []
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            for pattern in [#"\.num\("([^"]+)""#, #"\.text\("([^"]+)""#] {
                names.formUnion(RE.all(pattern, in: text))
            }
        }
        return names
    }

    func testEveryKeyNameIsOneAProducerRecords() throws {
        let recorded = try recordedNames()
        for (code, names) in ReportRenderer.keyMeasurementNames.sorted(by: { $0.key < $1.key })
        where !notYetPorted.contains(code) {
            for name in names {
                XCTAssertTrue(recorded.contains(name),
                              "\(code) 的报告要找「\(name)」，但没有生产者记录这个名字 —— "
                            + "结果列会静默走兜底，列出别的东西")
            }
        }
    }

    /// And the long-running items get their duration appended, so that name must exist too.
    func testTheDurationNameExists() throws {
        XCTAssertTrue(try recordedNames().contains("实际历时"),
                      "长跑项目的结果列会附上「实际历时」")
    }
}
