import SwiftUI
import AZ0XCore

/// Every batch, side by side, each board a row.
///
/// Nothing here waits on anything else: a batch is added while others run, and a board that reaches
/// its end releases its socket without the rest of its batch being involved.
struct ConsoleView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !app.missingTools.isEmpty {
                    Callout(tint: Palette.fail, icon: "exclamationmark.triangle",
                            text: "程序内嵌工具缺失：\(app.missingTools.joined(separator: "、"))"
                                + "。补齐后才能开始验证。")
                }
                if app.batches.isEmpty {
                    Empty()
                } else {
                    ForEach(app.batches) { batch in
                        BatchCard(batch: batch)
                    }
                }
            }
            .padding(16)
        }
    }

    private struct Empty: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text("没有进行中的批次").font(.callout)
                Text("将待测板置于 MASKROM 模式后，点右上角「开始验证」")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// One batch: its configuration, and a row per board.
struct BatchCard: View {
    @ObservedObject var batch: BatchState
    @EnvironmentObject var app: AppModel
    @State private var confirmingStop = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if !batch.collapsed {
                ForEach(batch.benches) { bench in
                    Divider()
                    BenchRow(bench: bench)
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.22)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Chip(text: batch.plan.model.rawValue, tint: .accentColor)
            Chip(text: batch.plan.flow.displayName)
            if batch.isPartial {
                Chip(text: "抽测 · \(batch.scopeText)", tint: Palette.hold)
            }
            Text("开始于 \(batch.startedText)")
                .font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("\(batch.finishedCount)/\(batch.benches.count) 完成")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Button(batch.collapsed ? "展开" : "收起") { batch.collapsed.toggle() }
                .buttonStyle(.link).font(.caption)
            if !batch.isRunning {
                Button("清除") { app.batches.removeAll { $0.id == batch.id } }
                    .buttonStyle(.link).font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// One board's line: who it is, where it is, and what it produced.
struct BenchRow: View {
    @ObservedObject var bench: BenchState
    @EnvironmentObject var app: AppModel

    private var mark: Mark {
        if bench.refusedWhy != nil { return .noResult }
        guard let run = bench.run else { return bench.startedAt == nil ? .notRun : .running }
        if let stopped = run.stoppedAt, run.results[stopped]?.condemnsMaterial == true {
            return .notPassed
        }
        return run.notRunItems.isEmpty ? .passed : .noResult
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(mark.tint).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(bench.name).font(.system(.callout, design: .monospaced))
                Text(bench.address.display).font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 190, alignment: .leading)
            .padding(.leading, 11)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(bench.statusLine).font(.callout)
                    if bench.isFinished || bench.runningCode == nil {
                        Chip(text: mark.label, tint: mark.tint)
                    }
                }
                if let f = bench.fraction {
                    ProgressView(value: f).controlSize(.small).frame(maxWidth: 340)
                }
                if let d = bench.detailLine {
                    Text(d).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Button(bench.run == nil ? "查看" : "查看报告") { app.openBench = bench.id }
                    .buttonStyle(.link).font(.callout)
                    .disabled(bench.refusedWhy != nil)
            }
            .padding(.trailing, 12)
        }
        .padding(.vertical, 10)
    }
}

/// A one-line notice with an icon, used for the few things the console has to say out loud.
struct Callout: View {
    let tint: Color
    let icon: String
    let text: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(tint)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }
}
