import SwiftUI
import ValidationCore

/// Summary page: an overview of every item, the items pending confirmation, and the
/// report actions. Starting work is the console's job, not a finished board's.
struct SummaryView: View {
    @ObservedObject var bench: Bench

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                verdict
                itemOverview
                if !bench.recordOnlyItems.isEmpty { recordOnlyNotice }
                ReportActions(bench: bench)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(bench.ending.title)
                .font(.system(size: 21, weight: .medium))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
        }
    }

    private var subtitle: String {
        var parts: [String] = ["\(bench.model.displayName) · \(bench.flow.displayName)"]
        if let s = bench.startedAt {
            parts.append("\(operatorStamp.string(from: s)) 起")
        }
        if let d = bench.totalDuration {
            parts.append("历时 \(formatDuration(d))")
        } else if let s = bench.startedAt {
            parts.append("已运行 \(formatDuration(Date().timeIntervalSince(s)))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Two-part verdict

    private var verdict: some View {
        VStack(alignment: .leading, spacing: 9) {
            switch bench.ending {
            case .running:
                // Mid-run there is no verdict yet; saying where it is is the honest thing.
                verdictRow("arrow.triangle.2.circlepath", .secondary, "验证进行中",
                           detail: runningDetail)
            case let .failed(at):
                verdictRow("xmark.octagon.fill", .red,
                           "已在 \(at) 终止", detail: terminationDetail(at))
            case let .noResult(at):
                // Our environment or a precondition. The report says the same; these two
                // used to disagree, with the page calling it a failure.
                verdictRow("exclamationmark.triangle.fill", .orange,
                           "已在 \(at) 中止：未得结果",
                           detail: terminationDetail(at) + "（非物料判定）")
            case .completed:
                verdictRow("checkmark.circle.fill", .green, "执行结果",
                           detail: bench.recordOnlyItems.isEmpty
                               ? "\(bench.passedItems.count) 项全部通过"
                               : "\(bench.passedItems.count) 项通过，"
                                 + "另有 \(bench.recordOnlyItems.count) 项仅记录")
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var runningDetail: String {
        let done = bench.items.filter { bench.results[$0.code] != nil }.count
        guard let code = bench.runningCode, let item = bench.item(code) else {
            return "已完成 \(done)/\(bench.items.count) 项"
        }
        return "当前 \(code) \(item.title) · 已完成 \(done)/\(bench.items.count) 项"
    }

    private func terminationDetail(_ code: String) -> String {
        bench.results[code]?.detail ?? "见该项页面"
    }

    private func verdictRow(_ symbol: String, _ tint: Color,
                            _ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(title).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Text(detail).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    // MARK: - Item overview

    private var itemOverview: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("全部项")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(bench.items.enumerated()), id: \.element.id) { idx, item in
                    if idx > 0 { Divider() }
                    overviewRow(item)
                }
            }
            .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func overviewRow(_ item: TestItem) -> some View {
        let st = bench.displayState(of: item.code)
        let key = keyValues(item)
        return Button {
            bench.selection = .item(item.code)      // 一览可点回看
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                StatusMark(state: st)
                Text(item.displayTitle)
                    .frame(width: 150, alignment: .leading)
                    .foregroundStyle(st == .notRun ? .secondary : .primary)
                Text(st.accessibilityLabel)
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .leading)
                Text(key)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The overview carries one or two values per item; the rest are in the report.
    private func keyValues(_ item: TestItem) -> String {
        guard let r = bench.results[item.code], !r.measurements.isEmpty else { return "" }
        return r.measurements.prefix(2)
            .map { "\($0.name) \($0.value.display)" }
            .joined(separator: " · ")
    }

    // MARK: - Record-only notice

    /// Not a task for the operator: a statement of what the report leaves to its reader.
    private var recordOnlyNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: "square.text.square")
                .foregroundStyle(.blue)
            Text("\(bench.recordOnlyItems.map(\.code).joined(separator: " / ")) "
               + "无自动判据，报告如实列出实测值，由判定方依物料规格书判读。")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
    }
}
