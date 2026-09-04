import XCTest
@testable import ValidationCore

/// The boundary this iteration exists to establish, enforced rather than documented.
///
/// In the first iteration the interface lived inside the core library. A view observed `Bench`, so
/// `Bench` became `@MainActor` and `ObservableObject`; the engine drove `Bench`, so `Sequencer`
/// became `@MainActor` too. The result was that every board's I/O orchestration ran on the main
/// actor and all eight benches shared it — not a decision anyone made, but SwiftUI's observation
/// model spreading backwards through `@Published`.
///
/// The interface will come back as its own target depending on this one. Nothing here may depend on
/// it, and the cheapest way to keep that true is to fail the build's tests when it stops being true.
final class CoreHasNoUITests: XCTestCase {

    private var coreRoot: URL {
        URL(fileURLWithPath: #filePath)                    // Tests/ValidationCoreTests/ThisFile.swift
            .deletingLastPathComponent()                   // Tests/ValidationCoreTests
            .deletingLastPathComponent()                   // Tests
            .deletingLastPathComponent()                   // package root
            .appendingPathComponent("Sources/ValidationCore")
    }

    private func coreSources() throws -> [URL] {
        let e = FileManager.default.enumerator(at: coreRoot, includingPropertiesForKeys: nil)
        return (e?.compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" }
    }

    /// Code only. This check is about what the core *depends on*, and the comments explaining why it
    /// must not depend on those things naturally name them — the first version of this test failed on
    /// its own rationale.
    private func code(of url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .components(separatedBy: .newlines)
            .map { line -> String in
                guard let i = line.range(of: "//") else { return line }
                return String(line[..<i.lowerBound])
            }
            .joined(separator: "\n")
    }

    func testTheCoreImportsNoInterfaceFramework() throws {
        let sources = try coreSources()
        XCTAssertGreaterThan(sources.count, 10, "没找到核心源码，这条测试就没在检查任何东西")

        let forbidden = ["SwiftUI", "AppKit", "Combine"]
        for url in sources {
            let text = try code(of: url)
            for framework in forbidden {
                XCTAssertFalse(text.contains("import \(framework)"),
                               "\(url.lastPathComponent) 引入了 \(framework)。"
                             + "界面是另一个 target 的事；让它爬回核心，引擎就又会被钉在主线程上。")
            }
        }
    }

    /// And no front end of any kind: a library that runs boards must not also be a program that
    /// talks to a person.
    ///
    /// The window was swept out and this test kept it out, while the command line sat in the core
    /// the whole time doing the same kind of work — parsing arguments, deciding what to run,
    /// printing. Both are callers. Neither belongs here, and the two of them keeping their own
    /// copies of the same decisions is how the previous generation came to judge one thing in three
    /// places by three different rules.
    func testTheCoreTalksToNobody() throws {
        for url in try coreSources() {
            let text = try code(of: url)
            XCTAssertFalse(text.contains("print("),
                           "\(url.lastPathComponent) 在往终端打印。核心库只发事件，谁看、怎么显示"
                         + "是调用方的事 —— 命令行和界面各是一个调用方。")
            XCTAssertFalse(text.contains("CommandLine."),
                           "\(url.lastPathComponent) 在读命令行参数。那是某一个前端的策略。")
        }
    }

    /// And no observation attributes either: those are how the coupling arrived last time.
    func testTheCoreDeclaresNoObservableState() throws {
        for url in try coreSources() {
            let text = try code(of: url)
            for marker in ["@Published", "ObservableObject", "@StateObject", "@EnvironmentObject"] {
                XCTAssertFalse(text.contains(marker),
                               "\(url.lastPathComponent) 用了 \(marker)。核心的状态由核心自己表达，"
                             + "界面在它自己那一侧适配。")
            }
        }
    }
}
