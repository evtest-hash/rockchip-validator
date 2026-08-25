import SwiftUI
import AZ0XCore

/// One board: every item down the side, the selected item's detail beside it.
///
/// The detail keeps the two check lists apart, which is the whole point of this iteration. In the
/// previous one they shared a single list, so "查出位错" and "查错程序根本没跑起来" both rendered as
/// a defect — the second one on the strength of our own read having failed.
struct BoardView: View {
    @ObservedObject var bench: BenchState
    let onBack: () -> Void
    @State private var selected: String?

    private var shown: String {
        selected ?? bench.runningCode
            ?? bench.items.last(where: { bench.results[$0.code]?.condemnsMaterial == true })?.code
            ?? bench.items.first(where: { bench.results[$0.code] != nil })?.code
            ?? bench.items.first?.code ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(alignment: .top, spacing: 20) {
                itemList.frame(width: 292)
                detail.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("控制台", systemImage: "chevron.left")
            }
            .buttonStyle(.link)
            Text(bench.name).font(.system(.title3, design: .monospaced).weight(.semibold))
            Text([bench.identity, bench.address.display].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let url = bench.reportURL {
                Button("在 Finder 中显示报告") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link).font(.callout)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var itemList: some View {
        VStack(spacing: 0) {
            ForEach(Array(bench.items.enumerated()), id: \.element.code) { index, item in
                if index > 0 { Divider() }
                itemRow(item)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.22)))
    }

    private func itemRow(_ item: TestItem) -> some View {
        let r = bench.results[item.code]
        let mark = Mark.of(r, running: bench.runningCode == item.code)
        let isShown = shown == item.code
        return Button(action: { selected = item.code }) {
            HStack(alignment: .top, spacing: 0) {
                Rectangle().fill(isShown ? Color.accentColor : .clear).frame(width: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayTitle).font(.callout.weight(.medium))
                    Text(subtitle(item, r) ?? " ")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .padding(.leading, 10)
                Spacer(minLength: 8)
                Chip(text: mark.label, tint: mark.tint)
            }
            .padding(.trailing, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isShown ? Color.accentColor.opacity(0.10) : .clear)
    }

    /// The one line under an item's name: its own words about what happened, never a restatement of
    /// the status chip beside it.
    private func subtitle(_ item: TestItem, _ r: ItemResult?) -> String? {
        if bench.runningCode == item.code {
            if let long = bench.long { return long.progressText }
            if let step = bench.step { return "\(step.label) \(step.valueText)" }
        }
        guard let r else { return nil }
        if let detail = r.detail { return detail }
        let names = ReportRenderer.keyMeasurements(for: item.code)
        let shown = r.measurements.filter { names.contains($0.name) }
        if !shown.isEmpty {
            return shown.map { "\($0.name) \($0.value.display)" }.joined(separator: " · ")
        }
        return r.measurements.first.map { "\($0.name) \($0.value.display)" }
    }

    // MARK: - The selected item

    @ViewBuilder private var detail: some View {
        if let item = bench.items.first(where: { $0.code == shown }) {
            let r = bench.results[item.code]
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle).font(.headline)
                    Text(item.method + duration(r))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 15).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                Divider()

                if let r {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if let why = r.detail, r.verdict == nil {
                                Callout(tint: Palette.hold, icon: "info.circle", text: why)
                            }
                            group(title: "判据", rule: "不通过 → 不合格，终止后续",
                                  checks: r.criteria, expanded: true,
                                  empty: "本项无判据，只记录实测值")
                            group(title: "前提", rule: "不满足 → 未得结果",
                                  checks: r.validity, expanded: false, empty: nil)
                            measurements(r)
                        }
                        .padding(15)
                    }
                } else {
                    Text(bench.runningCode == item.code ? "进行中" : "尚未执行")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(15).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.22)))
        }
    }

    private func duration(_ r: ItemResult?) -> String {
        guard let s = r?.startedAt, let f = r?.finishedAt else { return "" }
        return " · 历时 \(formatDuration(f.timeIntervalSince(s)))"
    }

    @ViewBuilder
    private func group(title: String, rule: String, checks: [Check],
                       expanded: Bool, empty: String?) -> some View {
        if checks.isEmpty {
            if let empty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.callout.weight(.medium))
                    Text(empty).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            CheckGroup(title: title, rule: rule, checks: checks, startOpen: expanded)
        }
    }

    @ViewBuilder
    private func measurements(_ r: ItemResult) -> some View {
        if !r.measurements.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("实测值").font(.callout.weight(.medium))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 158), spacing: 9)],
                          alignment: .leading, spacing: 9) {
                    ForEach(r.measurements) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.name).font(.caption2).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                            Text(m.value.display)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(2)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
    }
}

/// A group of checks: name, measured, limit, outcome. Four columns of data and no prose — the limit
/// is the explanation, which is how manufacturing test reports have always written a verdict.
///
/// A group where everything is satisfied starts closed, for the same reason such a report can be set
/// to record only the steps that failed: nobody reads a passing check one by one, and leaving them
/// all open buries the one that matters. It can still be opened.
struct CheckGroup: View {
    let title: String
    let rule: String
    let checks: [Check]
    @State private var open: Bool

    init(title: String, rule: String, checks: [Check], startOpen: Bool) {
        self.title = title
        self.rule = rule
        self.checks = checks
        // A failure always opens the group, whatever the caller asked for.
        _open = State(initialValue: startOpen || checks.contains { !$0.passed })
    }

    private var failed: Int { checks.filter { !$0.passed }.count }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("检查项").frame(maxWidth: .infinity, alignment: .leading)
                    Text("实测").frame(width: 110, alignment: .trailing)
                    Text("限值").frame(width: 130, alignment: .trailing)
                    Spacer().frame(width: 14)
                }
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 11).padding(.vertical, 4)
                .background(Color.secondary.opacity(0.06))
                ForEach(checks) { check in
                    Divider()
                    CheckRow(check: check)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.22)))
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text(title).font(.callout.weight(.medium))
                Chip(text: failed > 0 ? "\(failed) / \(checks.count) 不通过"
                                      : "\(checks.count) / \(checks.count) 满足",
                     tint: failed > 0 ? Palette.fail : Palette.pass)
                Text(rule).font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
