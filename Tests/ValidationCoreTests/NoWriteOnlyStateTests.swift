import XCTest

/// No `@Published` field is written and never read.
///
/// It happened three times, the same shape each time and invisible each time. `ItemResult.progress`
/// was declared and read by a view but never assigned, so a twelve-hour item would have shown
/// 正在启动 for twelve hours. Two stop buttons called an empty closure. And `fetching` / `fetchError`
/// carried a 766 MB transfer's progress and its failure reason to nobody: the operator pressed
/// 开始验证 and the wizard sat unchanged, the button still live, with a message set that nothing
/// displayed.
///
/// None of that is visible to a compiler and none of it fails a test that exercises behaviour,
/// because the behaviour is correct — it just never reaches the screen. What can be checked is the
/// shape: state that is only ever assigned is state nobody is using.
final class NoWriteOnlyStateTests: XCTestCase {

    private var sources: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RockchipValidator")
        return ((FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }) ?? []).filter { $0.pathExtension == "swift" }
    }

    func testEveryPublishedFieldIsReadSomewhere() throws {
        let files = sources
        XCTAssertFalse(files.isEmpty, "没找到界面源码，这条测试就没在检查任何东西")

        var text: [URL: [String]] = [:]
        for url in files {
            text[url] = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines)
                .map { $0.components(separatedBy: "//")[0] }      // comments are not readers
        }

        var declared: [(name: String, where: String)] = []
        for (url, lines) in text {
            for line in lines where line.contains("@Published") {
                guard let name = line.range(of: #"var\s+([a-zA-Z][a-zA-Z0-9]*)"#,
                                            options: .regularExpression)
                        .map({ String(line[$0]) })?
                        .split(separator: " ").last.map(String.init)
                else { continue }
                declared.append((name, url.lastPathComponent))
            }
        }
        XCTAssertGreaterThan(declared.count, 10, "一个 @Published 都没解析到")

        for (name, file) in declared {
            var reads = 0
            for (_, lines) in text {
                for line in lines {
                    guard line.range(of: #"\b\#(name)\b"#, options: .regularExpression) != nil
                    else { continue }
                    if line.contains("@Published") { continue }              // the declaration
                    // An assignment is not a read — but only when the name is what is being
                    // assigned to. `if let fetchError = app.fetchError` also contains `name =`
                    // and is the reader; the first version of this test skipped it and reported
                    // the field it had just been given as still unread.
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.range(of: #"^([A-Za-z_][A-Za-z0-9_]*\??\.)*\#(name)\s*=[^=]"#,
                                     options: .regularExpression) != nil { continue }
                    reads += 1
                }
            }
            XCTAssertGreaterThan(reads, 0,
                                 "\(file) 的 @Published \(name) 只被写、没有被读 —— "
                               + "这种状态送不到屏幕上，而编译器和行为测试都看不见")
        }
    }
}
