import SwiftUI
import AZ0XCore
import Combine

/// Page of one item, carrying its result and logs.
struct ItemPageView: View {
    @ObservedObject var bench: Bench
    let item: TestItem

    /// Drives the elapsed text; a maskrom item reports nothing else while it runs.
    @State private var beat = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var now = Date()

    private var result: ItemResult? { bench.results[item.code] }
    private var displayState: ItemDisplayState { bench.displayState(of: item.code) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                switch displayState {
                case .pending:
                    placeholder("等待前序项完成", "clock")
                case .notRun:
                    placeholder("验证已终止，本项未执行", "minus.circle")
                case .running:
                    if item.isLongRunning {
                        LongTestRunningPane(progress: bench.longProgress(of: item.code))
                    } else if let step = bench.stepProgress(of: item.code) {
                        // The flashing image download is about 800 MB, so progress is required.
                        StepProgressPane(step: step)
                    } else {
                        runningShort
                    }
                case let .done(outcome):
                    doneBody(outcome)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Only the elapsed line reads the clock, and only while this item is the running
        // one. Ticking regardless re-evaluated a finished page — evidence logs included —
        // once a second for as long as the operator left it open.
        .onReceive(beat) { if displayState == .running { now = $0 } }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.displayTitle)
                    .font(.system(size: 19, weight: .medium))
                Spacer()
                if case let .done(outcome) = displayState {
                    OutcomeBanner(outcome: outcome)
                }
            }
            Text(item.method)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
        }
    }

    // MARK: - States

    private func placeholder(_ text: String, _ symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.top, 8)
    }

    /// Progress bar of a short step; currently only the image download before flashing.
    private struct StepProgressPane: View {
        let step: StepProgress

        var body: some View {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    Text(step.label)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text(step.valueText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                // An unknown total uses an indeterminate bar rather than a guessed denominator.
                if let f = step.fraction {
                    ProgressView(value: f)
                    Text("\(Int(f * 100))%")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            .padding(15)
            .frame(maxWidth: 420, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    /// A tool invocation that emits nothing until it returns, so elapsed time is all
    /// there is to show. Without it the page reads as though nothing is happening.
    private var runningShort: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                Text(runningText)
            }
            Text(positionText).foregroundStyle(.tertiary)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
    }

    /// Where this item sits in the run, so the page says more than "something is happening".
    private var positionText: String {
        let n = (bench.items.firstIndex { $0.code == item.code } ?? 0) + 1
        return "本板第 \(n) 项 / 共 \(bench.items.count) 项"
    }

    private var runningText: String {
        guard let started = result?.startedAt else { return "正在执行…" }
        return "正在执行 · 已用 \(formatDuration(now.timeIntervalSince(started)))"
    }

    @ViewBuilder
    private func doneBody(_ outcome: Conclusion) -> some View {
        // Failure or error: state the reason and the termination first, then the evidence.
        if let detail = outcome.detail {
            VStack(alignment: .leading, spacing: 7) {
                Text(detail)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if outcome.terminatesRun {
                    Text("验证已终止，后续项未执行。初步报告已生成。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))

            if outcome.terminatesRun {
                ReportActions(bench: bench)
            }
        }

        // A record-only item states explicitly that the software made no verdict, and that the
        // reading below is what the report carries for someone else to judge.
        if outcome == .recordOnly {
            HStack(spacing: 7) {
                Image(systemName: "square.text.square").foregroundStyle(.blue)
                Text("本项无自动判据，只记录实测值。报告会如实列出下列读数，由判定方依规格书判读。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }

        if let r = result {
            if !r.measurements.isEmpty {
                section("实测值") { MeasurementTable(measurements: r.measurements) }
            }
            // Two lists, kept apart. Which one a check sits in is the whole decision: one says
            // what the material did, the other says whether the run was worth judging.
            if !r.criteria.isEmpty {
                CheckGroup(title: "判据", rule: "不通过 → 不合格，终止后续",
                           checks: r.criteria, startOpen: true)
            }
            if !r.validity.isEmpty {
                CheckGroup(title: "前提", rule: "不满足 → 未得结果",
                           checks: r.validity, limitHeader: "期望", startOpen: false)
            }
            ForEach(r.evidence) { e in
                LogPane(title: e.title, text: e.body)
                    .frame(height: 200)
            }
        }
    }

    private func section<Content: View>(_ title: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            content()
        }
    }
}

/// The buttons for opening the preliminary report and its containing folder.
struct ReportActions: View {
    @ObservedObject var bench: Bench
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Button {
                    if let url = bench.reportURL { NSWorkspace.shared.open(url) }
                } label: {
                    Label("打开初步报告", systemImage: "doc.text")
                }
                .disabled(bench.reportURL == nil)

                Button {
                    if let url = bench.runFolder {
                        NSWorkspace.shared.activateFileViewerSelecting([bench.reportURL ?? url])
                    }
                } label: {
                    Label("打开所在文件夹", systemImage: "folder")
                }
                .disabled(bench.runFolder == nil)

                // A copy where the operator looks for downloads, since the archive lives
                // under Documents and gets forwarded from somewhere else.
                Button(action: export) {
                    Label("导出到下载", systemImage: "square.and.arrow.up")
                }
                .disabled(!bench.isFinished)
            }
            .controlSize(.large)

            if let exportError {
                Text(exportError).font(.callout).foregroundStyle(.red)
            }

            // The report is a deliverable, so a write failure is surfaced rather than swallowed.
            if let err = bench.reportError {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("报告生成失败：\(err)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func export() {
        do {
            let url = try RunStore.copyToDownloads(bench.reportURL)
            exportError = nil
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            exportError = "导出失败：\(error.localizedDescription)"
        }
    }
}
