import SwiftUI
import AZ0XCore

/// One board's pages, opened from the console. The sidebar and item pages are the
/// existing FlowView; this adds the bar the console needs above them.
struct BoardPage: View {
    @ObservedObject var bench: Bench
    var onBack: () -> Void
    var onAbort: () -> Void

    @State private var confirmingAbort = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            FlowView(bench: bench)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("返回控制台", systemImage: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            Text(bench.title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Spacer()

            if !bench.isFinished {
                Button { confirmingAbort = true } label: {
                    Label("终止验证", systemImage: "stop.circle")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.bordered)
                // Stopping is not reversible, so this is one of the two places that asks.
                .confirmationDialog("终止这块板？", isPresented: $confirmingAbort) {
                    Button("终止验证", role: .destructive, action: onAbort)
                    Button("取消", role: .cancel) { }
                } message: {
                    Text(abortWarning)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    /// States the cost, since a burn-in cannot be resumed once stopped.
    private var abortWarning: String {
        var s = bench.elapsedText
        if let code = bench.runningCode, let item = bench.item(code) {
            s += "当前正在执行 \(code) \(item.title)。"
        }
        return s + Bench.abortConsequence
    }

}
