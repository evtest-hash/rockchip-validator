import SwiftUI
import AZ0XCore

/// Panel shown while a long-running item executes.
struct LongTestRunningPane: View {
    let progress: LongTestProgress?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let p = progress {
                // 1.
                Text(p.phase)
                    .font(.callout)

                // 2.
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: p.fraction)
                        .progressViewStyle(.linear)
                    HStack {
                        Text(p.progressText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(p.fraction * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }

                // 3. No liveness row: a long run is expected to be quiet, so there is nothing
                // honest to say about it beyond the phase and the elapsed time already shown above.
                LogPane(title: "运行日志", text: p.logTail, followTail: true)
                    .frame(minHeight: 220)
            } else {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small).scaleEffect(0.8)
                    Text("正在启动").foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }
}
