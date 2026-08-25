import SwiftUI
import AZ0XCore

/// Log view, monospaced, with optional auto-scroll to the bottom.
struct LogPane: View {
    let title: String
    let text: String
    /// A live log follows its tail; a completed item's log must not take over the scroll position.
    var followTail: Bool = false

    private static let bottomAnchor = "log-bottom"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(text.isEmpty ? "（暂无输出）" : text)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(text.isEmpty ? .secondary : .primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id(Self.bottomAnchor)
                    }
                    .padding(9)
                }
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: text) { _ in
                    guard followTail else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                    }
                }
            }
        }
    }
}

/// Measurement table: names left-aligned and values right-aligned in a monospaced font.
struct MeasurementTable: View {
    let measurements: [AZ0XCore.Measurement]

    var body: some View {
        if !measurements.isEmpty {
            VStack(spacing: 5) {
                ForEach(measurements) { m in
                    HStack(alignment: .firstTextBaseline) {
                        Text(m.name)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 20)
                        Text(m.value.display)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

/// One list of checks, written the way a manufacturing report writes a verdict: name, measured,
/// limit, outcome. Four columns of data and no prose — the limit is the explanation.
///
/// `Grid` aligns them for real, across every row, whatever the names are and whatever text size the
/// operator has chosen.
///
/// A group where everything is satisfied starts closed, for the same reason such a report can be set
/// to record only the steps that failed: nobody reads a passing check one by one, and leaving them
/// all open buries the one that matters. A failure opens its group regardless.
struct CheckGroup: View {
    let title: String
    /// The consequence of this list, in four words rather than a paragraph.
    let rule: String
    let checks: [Check]
    var limitHeader = "限值"
    @State private var open: Bool

    init(title: String, rule: String, checks: [Check],
         limitHeader: String = "限值", startOpen: Bool) {
        self.title = title
        self.rule = rule
        self.checks = checks
        self.limitHeader = limitHeader
        _open = State(initialValue: startOpen || checks.contains { !$0.passed })
    }

    private var failed: Int { checks.filter { !$0.passed }.count }

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 0) {
                GridRow {
                    Text("检查项")
                    Text("实测").gridColumnAlignment(.trailing)
                    Text(limitHeader).gridColumnAlignment(.trailing)
                    Text("")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.vertical, 5)

                ForEach(checks) { c in
                    Divider().gridCellColumns(4)
                    GridRow {
                        Text(c.name)
                        Text(c.actual)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(c.passed ? Color.primary : .red)
                            .fontWeight(c.passed ? .regular : .semibold)
                            .textSelection(.enabled)
                        Text(c.expected)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Image(systemName: c.passed ? "checkmark" : "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(c.passed ? .green : .red)
                    }
                    .font(.callout)
                    .padding(.vertical, 5)
                    .background(c.passed ? Color.clear : Color.red.opacity(0.08))
                }
            }
            .padding(.horizontal, 11)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Text(title).font(.callout.weight(.medium))
                Text(failed > 0 ? "\(failed) / \(checks.count) 不通过"
                                : "\(checks.count) / \(checks.count) 满足")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background((failed > 0 ? Color.red : .green).opacity(0.14), in: Capsule())
                    .foregroundStyle(failed > 0 ? Color.red : .green)
                Text(rule)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
