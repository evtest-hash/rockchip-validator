import SwiftUI
import AZ0XCore

/// Top-level view, switching on the current screen.
struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            switch app.screen {
            case .console:
                if let id = app.openBench,
                   let bench = app.allBenches.first(where: { $0.id == id }) {
                    BoardPage(bench: bench,
                              onBack: { app.openBench = nil },
                              onAbort: { bench.abort() })
                } else {
                    ConsoleView()
                }
            case .newBatch:
                NewBatchView()
            }
        }
        .frame(minWidth: 900, minHeight: 660)
        .task {
            // One scan on launch, so the console can say whether anything is plugged in.
            await app.scan()
        }
    }
}

@main
struct AZ0XValidatorApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup("AZ0X 物料验证台") {
            RootView().environmentObject(app)
        }
        .defaultSize(width: 1200, height: 800)
        .windowResizability(.contentMinSize)
        // The benches live in one window; a second would show the same batches twice.
        .commands { CommandGroup(replacing: .newItem) { } }
    }
}
