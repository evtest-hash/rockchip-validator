import SwiftUI
import ValidationCore

/// One board's pages, opened from the console. The sidebar and item pages are the
/// existing FlowView; this adds the bar the console needs above them.
struct BoardPage: View {
    @ObservedObject var bench: Bench
    var onBack: () -> Void


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

        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

}
