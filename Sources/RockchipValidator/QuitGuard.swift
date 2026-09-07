import AppKit
import ValidationCore

/// What Cmd+Q should do.
enum QuitDecision: Equatable {
    /// Nothing is running; go.
    case allow
    /// Boards are mid-validation. The operator decides, having been told the cost.
    case ask(message: String)
}

/// Stands between Cmd+Q and boards that are still being validated.
///
/// There is deliberately no stop inside the application — a validation runs to its end by design,
/// and the two buttons that once offered one were removed rather than wired, because cancelling the
/// task chain also kills the command T08 needs on its way out. That left quitting as the only way
/// to interrupt a run, and it was the one nobody guarded: Cmd+Q terminated the process at once, no
/// report written, no record saved, and hours of burn-in gone with nothing on screen having said so.
///
/// `applicationShouldTerminate` rather than a `CommandGroup` replacing the Quit item: this is asked
/// on every route out — Cmd+Q, the menu, the Dock's context menu, and logging out or shutting down.
/// A menu command would only cover the first two.
///
/// This asks and nothing more. It does not become the stop it sits next to: on 仍然退出 the process
/// ends exactly as it did before, and nothing here reaches a board.
@MainActor
final class QuitGuard: NSObject, NSApplicationDelegate {

    /// Set by `RootView` once the state it has to read exists. Weak because the delegate outlives
    /// nothing here — `NSApp` holds it for the life of the process either way.
    weak var app: AppState?

    /// Asking, injected for the same reason `DockAttention`'s platform calls are: `NSAlert` cannot
    /// run in a test, and whether the operator's answer is honoured is the whole behaviour.
    /// Returns true to quit anyway.
    var confirmQuit: (String) -> Bool = QuitGuard.runAlert

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch Self.decision(forQuitting: app?.allBenches ?? [], now: Date()) {
        case .allow:
            return .terminateNow
        case let .ask(message):
            return confirmQuit(message) ? .terminateNow : .terminateCancel
        }
    }

    /// Pure, so the wording and the boundary are testable without AppKit.
    ///
    /// A refused board does not count: `refuse(_:)` marks the bench finished, nothing ran on it,
    /// and there is nothing to lose by quitting. Neither does one that has already written its
    /// report.
    static func decision(forQuitting benches: [Bench], now: Date) -> QuitDecision {
        let running = benches.filter(\.isRunning)
        guard !running.isEmpty else { return .allow }

        var lines = ["有 \(running.count) 块板正在验证"]
        // The earliest start, because that is how long the operator stands to lose.
        if let began = running.compactMap(\.startedAt).min() {
            lines[0] += "，已运行 \(formatDuration(now.timeIntervalSince(began)))"
        }
        lines[0] += "。"
        lines.append("")
        lines.append("退出会立即终止它们：本次验证不生成报告，记录也不保存，"
                   + "拷机无法续跑，这些板需要从头重新验证。")
        return .ask(message: lines.joined(separator: "\n"))
    }

    /// The default `confirmQuit`. Safe choice first, so it is the one Return picks.
    private static func runAlert(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "验证正在进行"
        alert.informativeText = message
        alert.addButton(withTitle: "继续验证")
        let quit = alert.addButton(withTitle: "仍然退出")
        quit.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
