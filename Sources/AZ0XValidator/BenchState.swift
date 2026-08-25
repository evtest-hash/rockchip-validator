import Foundation
import AZ0XCore

/// One board under validation, as the interface sees it.
///
/// Built from the events the engine emits, never by touching the engine. In the previous generation
/// this type lived inside the core library and the engine wrote to it directly, which is how `Bench`
/// became a main-actor object and dragged every board's USB and adb work onto the main thread with
/// it. The engine here does not know this type exists.
@MainActor
final class BenchState: ObservableObject, Identifiable {

    let id = UUID()
    let address: BoardAddress
    let items: [TestItem]

    /// What an operator calls this board: its serial once known, its socket before that.
    @Published var serial: String?
    /// What the board says about itself once it has booted.
    @Published var identity: String?

    @Published var results: [String: ItemResult] = [:]
    /// Code of the item currently running; nil means nothing is.
    @Published var runningCode: String?
    /// Progress inside a flashing item.
    @Published var step: StepProgress?
    /// Progress inside a long-running item, including the periods the board is away.
    @Published var long: LongTestProgress?

    @Published var startedAt: Date?
    @Published var finishedAt: Date?
    @Published var run: Run?
    @Published var reportURL: URL?
    /// Set when the board could not be taken at all. Never a verdict.
    @Published var refusedWhy: String?

    init(address: BoardAddress, items: [TestItem]) {
        self.address = address
        self.items = items
    }

    var name: String { serial ?? address.display }
    var isFinished: Bool { finishedAt != nil || refusedWhy != nil }

    /// The item that ended the run, when one did.
    var stoppedAt: String? { run?.stoppedAt }

    // MARK: - Taking events

    func apply(_ event: RunEvent) {
        switch event {
        case .waitingForBoard:
            startedAt = startedAt ?? Date()
        case let .boardBound(serial, identity):
            self.serial = serial
            self.identity = identity
        case let .itemStarted(item):
            runningCode = item.code
            step = nil
            long = nil
            startedAt = startedAt ?? Date()
        case let .itemFinished(item, result):
            results[item.code] = result
            runningCode = nil
            step = nil
            long = nil
        case let .step(s):
            step = s
        case let .longTest(code, p):
            guard code == runningCode else { return }
            long = p
        case let .finished(run):
            self.run = run
            self.serial = run.board.serial ?? self.serial
            finishedAt = Date()
            runningCode = nil
            step = nil
            long = nil
        }
    }

    func refuse(_ why: String) {
        refusedWhy = why
        finishedAt = Date()
    }

    // MARK: - What the console shows

    /// One line about where this board is right now.
    var statusLine: String {
        if let refusedWhy { return refusedWhy }
        if let run {
            if let stopped = run.stoppedAt,
               let r = run.results[stopped], r.condemnsMaterial {
                return "\(title(stopped)) 不合格\(r.detail.map { "：\($0)" } ?? "")"
            }
            let judged = items.compactMap { run.results[$0.code] }.filter { $0.verdict != nil }
            let record = judged.filter { $0.verdict == .noCriterion }.count
            let ok = judged.filter { $0.verdict == .passed }.count
            var parts = ["已判定的 \(ok) 项均通过"]
            if record > 0 { parts.append("\(record) 项仅记录") }
            return parts.joined(separator: " · ")
        }
        if let code = runningCode { return title(code) }
        return startedAt == nil ? "等待板卡进入 MASKROM" : "准备中"
    }

    /// The detail under the status line: whatever the current item is reporting.
    var detailLine: String? {
        if let long { return "\(long.phase) · \(long.progressText)" }
        if let step { return "\(step.label) \(step.valueText)" }
        if let run, run.stoppedAt != nil {
            let notRun = run.notRunItems.count
            return notRun > 0 ? "后续 \(notRun) 项未执行" : nil
        }
        if let finishedAt, let startedAt {
            return "历时 \(formatDuration(finishedAt.timeIntervalSince(startedAt)))"
        }
        return nil
    }

    var fraction: Double? {
        if let long { return long.fraction }
        if let step { return step.fraction }
        return nil
    }

    private func title(_ code: String) -> String {
        items.first { $0.code == code }?.displayTitle ?? code
    }
}

/// One click of 开始验证: a configuration and the boards confirmed for it.
///
/// A batch groups work. It is not a unit of result — every board carries its own, and there is no
/// such thing as a batch verdict.
@MainActor
final class BatchState: ObservableObject, Identifiable {

    let id = UUID()
    let plan: BatchPlan
    let startedAt: Date
    /// Formatted once: the console redraws every second and this cannot change.
    let startedText: String
    @Published var benches: [BenchState]
    @Published var folder: URL?
    /// Whether the operator has collapsed this batch's rows.
    @Published var collapsed = false

    init(plan: BatchPlan, folder: URL?) {
        self.plan = plan
        self.folder = folder
        self.startedAt = Date()
        self.startedText = operatorStamp.string(from: Date())
        self.benches = plan.boards.map { BenchState(address: $0, items: plan.items) }
    }

    func bench(_ address: BoardAddress) -> BenchState? {
        benches.first { $0.address == address }
    }

    var finishedCount: Int { benches.filter(\.isFinished).count }
    var isRunning: Bool { finishedCount < benches.count }

    /// A partial selection states its scope; it cannot conclude that material may be imported.
    /// The same rule the report's title and file name use, so the three cannot disagree.
    var isPartial: Bool {
        TestItem.isPartial(plan.items, flow: plan.flow, model: plan.model,
                           burninPhases: plan.burninPhases.count)
    }

    /// What was cut, for the chip beside the batch.
    var scopeText: String {
        var parts: [String] = []
        let full = TestItem.items(for: plan.flow, model: plan.model).count
        if plan.items.count < full { parts.append("\(plan.items.count)/\(full) 项") }
        if plan.burninPhases.count < BurninPhase.allCases.count {
            parts.append("拷机 \(plan.burninPhases.count)/\(BurninPhase.allCases.count) 段")
        }
        return parts.joined(separator: " · ")
    }
}
