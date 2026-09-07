import AppKit
import ValidationCore

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

    /// Set by `RootView` once the state it has to read exists. Not weak: `NSApp` holds the
    /// delegate for the life of the process, `AppState` is the `App` struct's `@StateObject` for
    /// the same span, and nothing here is held back — there is no cycle to break, and `weak` would
    /// only leave a reader wondering whether the state could vanish mid-quit. Optional it must be:
    /// the delegate adaptor constructs this, so the state arrives afterwards.
    var app: AppState?

    /// Asking, injected for the same reason `DockAttention`'s platform calls are: `NSAlert` cannot
    /// run in a test, and whether the operator's answer is honoured is the whole behaviour.
    /// Returns true to quit anyway.
    var confirmQuit: (String) -> Bool = QuitGuard.runAlert

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let warning = Self.quitWarning(forQuitting: app?.allBenches ?? [], now: Date())
        else { return .terminateNow }
        return confirmQuit(warning) ? .terminateNow : .terminateCancel
    }

    /// What to tell the operator, or nil when quitting costs nothing.
    ///
    /// Pure, so the wording and the boundary are testable without AppKit — and the wording is the
    /// whole feature: this is read once, under a keystroke the operator has already committed to.
    ///
    /// A refused board does not count: `refuse(_:)` marks the bench finished, nothing ran on it,
    /// and there is nothing to lose by quitting. Neither does one that has already written its
    /// report.
    static func quitWarning(forQuitting benches: [Bench], now: Date) -> String? {
        let running = benches.filter(\.isRunning)
        guard !running.isEmpty else { return nil }

        // The earliest start, because that is how long the operator stands to lose.
        let elapsed = running.compactMap(\.startedAt).min()
            .map { "，已运行 \(formatDuration(now.timeIntervalSince($0)))" } ?? ""

        // Three short paragraphs, not one sentence with four clauses. Rendered, that sentence
        // wrapped to four lines of grey text in `NSAlert`'s narrow box, with 无法续跑 — the only
        // part that decides anything — buried mid-paragraph. This is read at a glance or not at
        // all. Counted rather than pronouned, too: 「它们」 read wrong at one board.
        return """
            有 \(running.count) 块板正在验证\(elapsed)。

            退出会立即终止，且无法续跑。

            不生成报告、不保存记录，这 \(running.count) 块板需要从头重新验证。
            """
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
