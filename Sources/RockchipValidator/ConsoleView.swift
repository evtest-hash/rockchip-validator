import SwiftUI
import ValidationCore
import Combine

/// The console: every batch at once. Home screen of the application.
struct ConsoleView: View {
    @EnvironmentObject var app: AppState
    /// Redraws the elapsed and idle texts, and the counts aggregated over live benches.
    @State private var beat = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var tick = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                OverviewStrip(benches: app.allBenches)
                Spacer()
                // Secondary on purpose: 开始验证 is what this screen is for, and past batches are
                // one click away rather than in the way.
                Button { app.screen = .history } label: {
                    Label("以往批次", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.borderless)
                Button { app.newBatch() } label: {
                    Label("开始验证", systemImage: "plus")
                }
                .controlSize(.large)
                .keyboardShortcut("n")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            Divider()
            batchList
        }
        // Nothing reads the value; the redraw is the point — the elapsed and idle texts and
        // the aggregate counts are all computed in the bodies below.
        .onReceive(beat) { _ in tick &+= 1 }
    }

    @ViewBuilder
    private var batchList: some View {
        if app.batches.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "tray")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("没有进行中的批次")
                    .foregroundStyle(.secondary)
                Text("将待测板置于 MASKROM 模式后，点「开始验证」")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(app.batches) { batch in
                        BatchCard(batch: batch,
                                  onOpen: { bench, target in
                                      bench.selection = target
                                      app.openBench = bench.id
                                  })
                    }
                }
                .padding(18)
            }
        }
    }
}

/// Counts across every batch: what needs the operator, at a glance.
@MainActor
private struct OverviewStrip: View {
    let benches: [Bench]

    var body: some View {
        HStack(spacing: 18) {
            // Three counts, each answering something the operator acts on: what is still
            // occupying a socket, what is done with, and what needs looking into. Whether a
            // finished board's material is acceptable is not shown here and is not ours to say.
            stat("进行中", running, .accentColor)
            stat("已结束", benches.filter(\.isFinished).count, .green)
            stat("未得结果", withoutResult, .orange)
        }
    }

    private var running: Int { benches.filter { !$0.isFinished }.count }

    /// Ran but produced no conclusion: our environment, a precondition, or nothing arrived in
    /// time. These are the ones worth investigating, possibly re-running. A board that produced a
    /// finding — pass or fail — is done as far as this bench is concerned; the report carries it.
    private var withoutResult: Int {
        benches.filter { if case .noResult = $0.ending { return true } else { return false } }.count
    }

    private func stat(_ name: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text("\(value)")
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
            Text(name).font(.callout).foregroundStyle(.secondary)
        }
    }
}

/// One batch: its configuration in the header, its boards below.
@MainActor
private struct BatchCard: View {
    @ObservedObject var batch: Batch
    var onOpen: (Bench, Bench.Selection) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ForEach(batch.benches) { bench in
                BoardRow(bench: bench, onOpen: { onOpen(bench, $0) })
                if bench.id != batch.benches.last?.id { Divider() }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.025)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Chip(text: batch.model.code, color: .blue)
            Chip(text: batch.flow.displayName, color: .secondary)
            Text("开始于 \(batch.startedText)")
                .font(.callout.weight(.semibold))
            Spacer()
            Text("\(batch.finishedCount)/\(batch.benches.count) 完成")
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

}

/// One board, with two entry points: the row shows what it is doing, 查看报告 shows the
/// report. Fixed columns, so rows line up rather than drifting with the text length.
@MainActor
private struct BoardRow: View {
    @ObservedObject var bench: Bench
    var onOpen: (Bench.Selection) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button { onOpen(processTarget) } label: {
                HStack(spacing: 14) {
                    Text(bench.serial ?? "插座 \(bench.portChain)")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 200, alignment: .leading)
                        .foregroundStyle(bench.serial == nil ? .secondary : .primary)
                    stateCell
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Chip(text: chip.0, color: chip.1)
                        .frame(width: 92, alignment: .leading)
                }
                .padding(.leading, 14)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Outside the row's tap region, so the two destinations never conflict.
            if bench.isFinished {
                Button { onOpen(.summary) } label: {
                    Text("查看报告 →")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("打开这块板的验证报告")
            }
        }
        .padding(.trailing, 14)
    }

    /// Where the row lands: what the board is doing, or where it stopped.
    private var processTarget: Bench.Selection {
        if let code = bench.runningCode { return .item(code) }
        if let code = bench.terminatedAt { return .item(code) }
        if let last = bench.items.last(where: { bench.results[$0.code] != nil }) {
            return .item(last.code)
        }
        return .summary
    }

    @ViewBuilder
    private var stateCell: some View {
        if bench.isFinished {
            Text(finishedText).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(runningText).foregroundStyle(livenessTint)
            }
        }
    }

    private var runningText: String {
        guard let code = bench.runningCode, let item = bench.item(code) else {
            return bench.maskromSeen ? "准备中" : "等待设备"
        }
        let head = "\(code) \(item.title)"
        // Only flashing reports liveness; a long run is expected to be quiet.
        switch bench.liveness {
        case .late, .stalled: return head + " · 最后活跃 \(bench.idleText)"
        case .normal, nil:    return head
        }
    }

    /// Only an idle flash is coloured, and only because flashing is the one item where an idle
    /// host clock means anything. Slow-but-reporting is stated, not flagged.
    private var livenessTint: Color {
        bench.liveness == .stalled ? .red : .secondary
    }

    /// The one-line fact under the chip: how the run ended, and how long it took.
    ///
    /// This is where "it stopped at T06" belongs — a fact about the run. The chip above stays at
    /// 已结束 for it, because what T06 found is the report's business, not this row's.
    private var finishedText: String {
        let took = bench.totalDuration.map { " · 历时 \(formatDuration($0))" } ?? ""
        switch bench.ending {
        case let .failed(at):   return "在 \(at) 得出结论后结束\(took)"
        case let .noResult(at): return "未得结果，中止于 \(at)\(took)"
        case .completed, .running:
            return took.isEmpty ? "执行完毕" : "跑完全部选定项\(took)"
        }
    }

    /// Where this bench's run got to — never what its material amounts to.
    ///
    /// A finished run says 已结束 whether or not the automation found something. Both mean the same
    /// thing here: the flow did its job and the report is ready for whoever holds the requirements
    /// table. Which way that report reads is theirs to decide, and putting 失败 on this row would be
    /// this software claiming a material verdict it is not responsible for.
    ///
    /// The two that are not just "done" are the two an operator acts on: no result was produced, so
    /// it may be worth investigating or re-running; or they stopped it themselves.
    ///
    /// A long run never reaches the idle branch: it has no liveness, because being quiet is what a
    /// twelve-hour memory test looks like. It ends on a terminal marker or its budget instead.
    private var chip: (String, Color) {
        switch bench.ending {
        case .running:
            return bench.liveness == .stalled ? ("刷写无进度", .red) : ("验证中", .secondary)
        case .noResult:             return ("未得结果", .orange)
        case .completed, .failed:   return ("已结束", .green)
        }
    }
}

/// Small status pill.
struct Chip: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }
}
