import SwiftUI
import AZ0XCore

/// The window, switching on which screen is showing.
struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            switch app.screen {
            case .console:
                if let id = app.openBench,
                   let bench = app.batches.flatMap(\.benches).first(where: { $0.id == id }) {
                    BoardView(bench: bench, onBack: { app.openBench = nil })
                } else {
                    ConsoleView()
                }
            case let .newBatch(step):
                NewBatchView(step: step)
            }
        }
        .frame(minWidth: 900, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                switch app.screen {
                case .console:
                    Button("开始验证") { app.openNewBatch() }
                        .disabled(!app.missingTools.isEmpty)
                case .newBatch:
                    Button("取消") { app.cancelNewBatch() }
                }
            }
        }
        .task {
            // One scan on launch, so the console can say whether anything is plugged in.
            await app.scan()
        }
    }
}

@main
struct AZ0XValidatorApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup("AZ0X 物料验证台") {
            RootView().environmentObject(app)
        }
        .commands {
            // The benches live in one window; a second one would show the same batches twice.
            CommandGroup(replacing: .newItem) { }
        }
    }
}
