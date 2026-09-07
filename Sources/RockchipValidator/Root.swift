import SwiftUI
import AppKit
import ValidationCore

/// Top-level view, switching on the current screen.
struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.quitGuard) private var quitGuard

    var body: some View {
        Group {
            switch app.screen {
            case .console:
                if let id = app.openBench,
                   let bench = app.allBenches.first(where: { $0.id == id }) {
                    BoardPage(bench: bench,
                              onBack: { app.openBench = nil })
                } else {
                    ConsoleView()
                }
            case .newBatch:
                NewBatchView()
            case .history:
                HistoryView()
            }
        }
        .frame(minWidth: 900, minHeight: 660)
        .task {
            // The guard reads this state, and cannot be handed it at construction: the delegate
            // adaptor builds it. `QuitGuardWiringTests` refuses a build where this line is gone —
            // without it Cmd+Q is unguarded again and nothing on screen would say so.
            quitGuard.app = app
            // One scan on launch, so the console can say whether anything is plugged in.
            await app.scan()
        }
        .onReceive(NotificationCenter.default
            .publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            app.dock.windowCameForward()
        }
    }
}

/// Carries the delegate down to the one view that can wire it up.
private struct QuitGuardKey: EnvironmentKey {
    @MainActor static let defaultValue = QuitGuard()
}

extension EnvironmentValues {
    var quitGuard: QuitGuard {
        get { self[QuitGuardKey.self] }
        set { self[QuitGuardKey.self] = newValue }
    }
}

@main
struct RockchipValidatorApp: App {
    @StateObject private var app = AppState()
    @NSApplicationDelegateAdaptor(QuitGuard.self) private var quitGuard

    var body: some Scene {
        WindowGroup("Rockchip 物料验证台") {
            RootView()
                .environmentObject(app)
                .environment(\.quitGuard, quitGuard)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        // The benches live in one window; a second would show the same batches twice.
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}
