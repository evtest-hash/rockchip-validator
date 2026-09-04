import SwiftUI
import ValidationCore

/// How one item reads on screen.
///
/// The record keeps three axes apart — did it run, what did it conclude, does it have anything to
/// conclude — and it must, because collapsing them is exactly how the previous generation came to
/// report our own failed reads as defective material. Collapsing them *for display* is a different
/// act, and it belongs here, on this side of the boundary, where a view can be changed without
/// touching a verdict.
enum Conclusion: Equatable {
    case passed
    case notPassed(String)
    /// Measured and recorded; this item has no criteria to pass or fail.
    case recordOnly
    /// Nothing was established. Ours to fix, not the board's.
    case noResult(String)
    /// It never began, and the reason is a precondition rather than a fault.
    case skipped(String)

    var label: String {
        switch self {
        case .passed:     return "通过"
        case .notPassed:  return "不合格"
        case .recordOnly: return "仅记录"
        case .noResult:   return "未得结果"
        case .skipped:    return "跳过"
        }
    }

    var detail: String? {
        switch self {
        case let .notPassed(w), let .noResult(w), let .skipped(w): return w
        case .passed, .recordOnly: return nil
        }
    }

    /// Whether this ends the run. Only a verdict against the material does.
    var terminatesRun: Bool { if case .notPassed = self { return true }; return false }

    static func of(_ r: ItemResult) -> Conclusion? {
        guard let execution = r.execution else { return nil }
        switch execution {
        case let .notStarted(why):  return .skipped(why)
        case let .interrupted(why): return .noResult(why)
        case let .invalid(why):     return .noResult(why)
        case .completed:
            switch r.verdict {
            case .passed?:            return .passed
            case let .notPassed(why)?: return .notPassed(why)
            case .noCriterion?:       return .recordOnly
            case nil:                 return .noResult("已执行完毕，但未能读出判据")
            }
        }
    }
}

enum ItemDisplayState: Equatable {
    case pending, running, notRun
    case done(Conclusion)
}

/// How a board's run ended, or that it has not. A reading of the record, not state anyone keeps.
enum Ending: Equatable {
    case running, completed
    case failed(String), noResult(String)

    var title: String {
        switch self {
        case .running:   return "验证进行中"
        case .completed: return "验证完成"
        case .failed:    return "已得出结论"
        case .noResult:  return "未得结果"
        }
    }
}

/// Only flashing reports liveness: it is the one item where an idle host clock means anything. A
/// long run is expected to be quiet, and a board that is away says so for itself.
enum Liveness { case normal, late, stalled }

/// How a conclusion looks. Derived from what was concluded rather than from which case it is, so a
/// new case cannot land on a colour that misstates it.
extension Conclusion {
    var glyphName: String {
        switch self {
        case .passed:     return "checkmark.circle.fill"
        case .notPassed:  return "xmark.circle.fill"
        // Measured, not judged: its own glyph, deliberately neither a tick nor a cross.
        case .recordOnly: return "square.text.square"
        case .skipped:    return "slash.circle"
        case .noResult:   return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .passed:     return .green
        case .notPassed:  return .red
        case .recordOnly: return .blue
        case .skipped:    return .secondary
        case .noResult:   return .orange
        }
    }
}
