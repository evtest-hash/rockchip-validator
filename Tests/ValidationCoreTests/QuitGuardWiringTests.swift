import XCTest
@testable import RockchipValidator

/// That the guard is actually installed and actually handed the state it reads.
///
/// `QuitGuardTests` proves the decision and the response are right. Neither of those runs in the
/// application unless two lines exist: the delegate adaptor that installs `QuitGuard` on `NSApp`,
/// and the assignment in `RootView` that gives it the state — `@NSApplicationDelegateAdaptor`
/// constructs the delegate itself, so the state cannot be handed over at construction.
///
/// Without the assignment `app` stays nil, `applicationShouldTerminate` allows the quit, and every
/// test above still passes. That is the same shape as the two stop buttons this project removed:
/// a guard that is present, tested, and does nothing. Textual, because there is no way to launch
/// the application from here — the same compromise the other three interface scans make.
final class QuitGuardWiringTests: XCTestCase {

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RockchipValidator/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheDelegateIsInstalledOnTheApplication() throws {
        let root = try source("Root.swift")
        XCTAssertTrue(root.contains("@NSApplicationDelegateAdaptor(QuitGuard.self)"),
                      "没有这一行，QuitGuard 根本不会被装到 NSApp 上，Cmd+Q 又变成无人看守")
    }

    func testTheGuardIsHandedTheStateItReads() throws {
        let root = try source("Root.swift")
        XCTAssertTrue(root.contains("quitGuard.app = app"),
                      "没有这一行，guard 的 app 恒为 nil —— 弹窗永不出现，"
                    + "而 QuitGuardTests 依然全绿。这正是被删掉的那两个假按钮的形状")
    }

    /// The hook has to be the one that covers every route out, not just the menu item.
    func testTheHookIsApplicationShouldTerminate() throws {
        let g = try source("QuitGuard.swift")
        XCTAssertTrue(g.contains("func applicationShouldTerminate"),
                      "Cmd+Q、菜单、Dock 右键退出、注销关机 —— 只有这个钩子全都盖住")
    }
}
