import SwiftUI
import AZ0XCore

/// Past batches, read off the archive.
///
/// A separate screen, not a strip on the console. The console is what is happening now — an operator
/// watching a three-day burn-in should not have last week scrolling past it.
///
/// Read-only throughout. Nothing here deletes, renames or re-runs; clearing the archive is done in
/// Finder, where it is obvious what is being thrown away.
struct HistoryView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { app.screen = .console } label: {
                    Label("返回", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text("以往批次").font(.headline)
                Spacer()
                if app.historyLoading { ProgressView().controlSize(.small).scaleEffect(0.8) }
                Button {
                    NSWorkspace.shared.open(ArchiveRoot.default)
                } label: {
                    Label("在 Finder 中打开归档", systemImage: "folder")
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            Divider()
            list
        }
        .task { await app.loadHistory() }
    }

    @ViewBuilder
    private var list: some View {
        if app.history.isEmpty && !app.historyLoading {
            VStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("还没有已完成的批次").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(app.history) { BatchRow(batch: $0) }
                }
                .padding(18)
            }
        }
    }
}

/// One past batch, expanding to its boards.
private struct BatchRow: View {
    let batch: RunStore.PastBatch
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 12)
                Text(batch.startedAt.map { operatorStamp.string(from: $0) } ?? batch.batchID)
                    .font(.callout.monospacedDigit())
                if let m = batch.model, let f = batch.flow {
                    Chip(text: m.rawValue, color: .blue)
                    Chip(text: f.displayName, color: .secondary)
                }
                Text(batch.runs.count > 1 ? "\(batch.runs.count) 块板" : "1 块板")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(tally).font(.callout)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { open.toggle() }

            if open {
                Divider()
                ForEach(batch.runs) { BoardLine(past: $0) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12)))
    }

    /// Boards, not items: at this zoom the question is how many boards came out how.
    private var tally: String {
        let bad = batch.runs.filter { !$0.run.notPassedItems.isEmpty || $0.run.stoppedAt != nil }
        let short = batch.runs.filter { $0.run.notPassedItems.isEmpty && $0.run.stoppedAt == nil
                                     && !$0.run.notRunItems.isEmpty }
        if !bad.isEmpty { return "❌ \(bad.count) 块不合格" }
        if !short.isEmpty { return "⚠️ \(short.count) 块未跑完" }
        return "✅ \(batch.runs.count) 块通过"
    }
}

/// One board inside a past batch. Its line is the same sentence the report's 执行结果 row carries.
private struct BoardLine: View {
    let past: RunStore.Past

    var body: some View {
        HStack(spacing: 12) {
            Text(past.run.boardName)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(ReportRenderer.outcome(past.run))
                .font(.callout)
                .lineLimit(1)
            Spacer()
            if let url = past.reportURL {
                Button("打开报告") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.borderless).font(.callout)
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([past.reportURL ?? past.folder])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
    }
}
