import SwiftUI
import ValidationCore

/// Status marks, each state carrying its own glyph rather than being distinguished by colour alone.
struct StatusMark: View {
    let state: ItemDisplayState
    var size: CGFloat = 13

    var body: some View {
        switch state {
        case .running:
            // A spinner rather than a static glyph: a running item should look like it is moving.
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
                .frame(width: size + 3, height: size + 3)
        case .pending:
            glyph("circle", .secondary)
        case .notRun:
            glyph("minus.circle", .secondary)
        case let .done(outcome):
            glyph(outcome.glyphName, outcome.tint)
        }
    }

    private func glyph(_ name: String, _ color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: size))
            .foregroundStyle(color)
            .frame(width: size + 3, height: size + 3)
    }
}

extension ItemDisplayState {
    /// Short label for accessibility announcements and text contexts.
    var accessibilityLabel: String {
        switch self {
        case .pending: return "未开始"
        case .running: return "正在执行"
        case .notRun:  return "未执行"
        case let .done(outcome):
            return outcome.label
        }
    }
}

/// Conclusion banner at the top of an item page.
struct OutcomeBanner: View {
    let outcome: Conclusion

    var body: some View {
        HStack(spacing: 8) {
            StatusMark(state: .done(outcome), size: 16)
            Text(outcome.label)
                .font(.headline)
                .foregroundStyle(outcome.tint)
        }
    }
}
