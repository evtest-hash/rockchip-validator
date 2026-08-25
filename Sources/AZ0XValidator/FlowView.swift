import SwiftUI
import AZ0XCore

/// Flow page: the sidebar lists every item and the detail area shows the selected one.
struct FlowView: View {
    @ObservedObject var bench: Bench

    // NavigationView with two columns rather than NavigationSplitView.
    var body: some View {
        NavigationView {
            sidebar
                .frame(minWidth: 245, idealWidth: 260, maxWidth: 300)
            detail
                .frame(minWidth: 460)
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: Binding(
            get: { bench.selection },
            set: { if let s = $0 { bench.selection = s } }
        )) {
            Section {
                ForEach(bench.items) { item in
                    row(item)
                        .tag(Bench.Selection.item(item.code))
                }
            }
            // Present throughout: mid-run it is where the operator sees the board as a whole.
            Section {
                Label(summaryTitle, systemImage: summarySymbol)
                    .tag(Bench.Selection.summary)
            }
        }
        .listStyle(.sidebar)
    }

    private var summaryTitle: String { bench.ending.title }

    private var summarySymbol: String {
        switch bench.ending {
        case .running:   return "doc.text"
        case .completed: return "flag.checkered"
        case .aborted:   return "stop.circle"
        case .failed:    return "xmark.octagon"
        case .noResult:  return "exclamationmark.triangle"
        }
    }

    private func row(_ item: TestItem) -> some View {
        let st = bench.displayState(of: item.code)
        return HStack(spacing: 7) {
            StatusMark(state: st)
            Text(item.displayTitle)
                .lineLimit(1)
                .foregroundStyle(st == .notRun ? .secondary : .primary)
            Spacer(minLength: 0)
        }
        .accessibilityLabel("\(item.displayTitle)，\(st.accessibilityLabel)")
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch bench.selection {
        case .summary:
            SummaryView(bench: bench)
        case let .item(code):
            if let item = bench.item(code) {
                ItemPageView(bench: bench, item: item)
                    .id(code)          // 切换项时重建，避免滚动位置串到别的项
            } else {
                Text("未找到 \(code)").foregroundStyle(.secondary)
            }
        }
    }
}
