import XCTest

/// No control in the interface is wired to a closure that does nothing.
///
/// Two stop buttons were. Both asked the operator to confirm the most expensive action in the
/// application — 将终止 2 块板，已运行 3 小时 12 分。拷机一旦停止无法续跑 — and then ran `{ }`.
/// The run carried on and the screen carried on with it. Nothing failed, because nothing was
/// supposed to happen.
///
/// The stop was removed rather than wired: a validation runs to its end by design. This guard is
/// not about the stop, though. It is about the shape — a control whose action is empty is a control
/// that lies, and the compiler is perfectly happy with it.
final class NoDeadControlsTests: XCTestCase {

    func testNoActionIsAnEmptyClosure() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RockchipValidator")
        let sources = ((FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }) ?? []).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(sources.isEmpty, "没找到界面源码，这条测试就没在检查任何东西")

        for url in sources {
            for (n, line) in try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines).enumerated() {
                let code = line.components(separatedBy: "//")[0]
                // A cancel button genuinely does nothing: dismissing the dialog is the whole action,
                // and SwiftUI needs a body to attach the role to.
                guard !code.contains("role: .cancel") else { continue }
                XCTAssertNil(code.range(of: #"(action:|on[A-Z]\w*:)\s*\{\s*\}"#, options: .regularExpression),
                             "\(url.lastPathComponent):\(n + 1) 有一个什么都不做的动作 —— "
                           + "界面上的控件要么真的做事，要么不该存在：\(code.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
}
