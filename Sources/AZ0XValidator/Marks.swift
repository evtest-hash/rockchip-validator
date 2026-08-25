import SwiftUI
import AZ0XCore

/// How a result reads at a glance.
///
/// The three axes the report keeps apart are kept apart here too, and the colours carry the one
/// distinction that matters most: red means the material, amber means we did not find out. A run
/// that could not be taken must never wear the same colour as a defect.
enum Mark {
    case running
    case passed
    /// A verdict on the material.
    case notPassed
    /// Nothing was established. Ours to fix, not the board's.
    case noResult
    /// Measured and recorded; this item has no criteria to pass or fail.
    case recordOnly
    case notRun

    static func of(_ r: ItemResult?, running: Bool = false) -> Mark {
        if running { return .running }
        guard let r, let execution = r.execution else { return .notRun }
        guard execution.isCompleted else { return .noResult }
        switch r.verdict {
        case .passed?:      return .passed
        case .notPassed?:   return .notPassed
        case .noCriterion?: return .recordOnly
        case nil:           return .noResult
        }
    }

    var label: String {
        switch self {
        case .running:    return "进行中"
        case .passed:     return "通过"
        case .notPassed:  return "不合格"
        case .noResult:   return "未得结果"
        case .recordOnly: return "仅记录"
        case .notRun:     return "未执行"
        }
    }

    var tint: Color {
        switch self {
        case .running:    return .accentColor
        case .passed:     return Palette.pass
        case .notPassed:  return Palette.fail
        case .noResult:   return Palette.hold
        case .recordOnly: return Palette.record
        case .notRun:     return .secondary
        }
    }
}

/// The bench's colours. Semantic only — there is no decorative palette here.
enum Palette {
    static let pass = Color(red: 0.18, green: 0.49, blue: 0.33)
    static let fail = Color(red: 0.70, green: 0.15, blue: 0.12)
    static let hold = Color(red: 0.59, green: 0.35, blue: 0.04)
    static let record = Color(red: 0.30, green: 0.39, blue: 0.41)
}

/// A small status pill.
struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }
}

/// A check, as the mature bench reports write one: name, measured, limit, outcome. Four columns of
/// data and no prose — the limit is the explanation.
struct CheckRow: View {
    let check: Check
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(check.name)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(check.actual)
                .font(.system(.caption, design: .monospaced))
                .frame(width: 110, alignment: .trailing)
            Text(check.expected)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .trailing)
            Image(systemName: check.passed ? "checkmark" : "xmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(check.passed ? Palette.pass : Palette.fail)
                .frame(width: 14)
        }
        .font(.callout)
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(check.passed ? Color.clear : Palette.fail.opacity(0.09))
    }
}
