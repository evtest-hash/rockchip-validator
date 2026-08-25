import Foundation
import AZ0XCore

/// One board under validation, as the interface sees it.
///
/// Built from the events the engine emits, never by touching the engine. In the previous generation
/// this type lived inside the core library and the engine wrote to it directly, which is how it
/// became a main-actor observable object and dragged every board's USB and adb work onto the main
/// thread with it. The engine here does not know this type exists.
@MainActor
final class Bench: ObservableObject, Identifiable {

    /// Sidebar selection within this board's pages.
    enum Selection: Hashable {
        case item(String)      // by code, so an index cannot drift
        case summary
    }

    let id = UUID()
    /// How this board is addressed. The two domains do not share an identifier.
    let address: BoardAddress
    let model: DeviceModel
    let flow: ValidationFlow
    let items: [TestItem]

    /// Read from OTP during the first maskrom item; nil until then.
    @Published var serial: String?
    /// What the board says about itself once it has booted.
    @Published var identity: String?

    @Published var results: [String: ItemResult] = [:]
    /// Code of the running item; nil means nothing is.
    @Published var runningCode: String?
    @Published var selection: Selection = .summary
    @Published var isFinished = false
    /// The item the run stopped at, if it did.
    @Published var terminatedAt: String?
    /// Whether this board has been seen in maskrom.
    @Published var maskromSeen = false

    @Published var reportURL: URL?
    @Published var reportError: String?
    @Published var runFolder: URL?
    @Published var startedAt: Date?
    @Published var finishedAt: Date?
    @Published var run: Run?
    /// Set when the board could not be taken at all. Never a verdict.
    @Published var refusedWhy: String?

    /// Progress inside a flashing item.
    @Published private var step: StepProgress?
    /// Progress inside a long-running item, including the stretches the board is away.
    @Published private var long: LongTestProgress?
    /// Which item the long progress belongs to.
    private var longCode: String?

    init(address: BoardAddress, model: DeviceModel, flow: ValidationFlow, items: [TestItem]) {
        self.address = address
        self.model = model
        self.flow = flow
        self.items = items
    }

    // MARK: - What the views ask of it

    var portChain: String { address.socket }
    var title: String {
        "\(model.displayName) · \(flow.displayName) · \(serial ?? "插座 \(portChain)")"
    }
    func item(_ code: String) -> TestItem? { items.first { $0.code == code } }
    func stepProgress(of code: String) -> StepProgress? { step?.code == code ? step : nil }
    func longProgress(of code: String) -> LongTestProgress? { longCode == code ? long : nil }

    var totalDuration: TimeInterval? {
        guard let startedAt, let finishedAt else { return nil }
        return finishedAt.timeIntervalSince(startedAt)
    }

    var elapsedText: String {
        guard let startedAt else { return "" }
        return "已运行 \(formatDuration(Date().timeIntervalSince(startedAt)))。"
    }

    /// How long since the board last reported. Only asked of flashing; see `liveness`.
    var idleText: String { formatDuration(long?.awayFor ?? 0) }

    /// Only flashing has an opinion here. A long run is quiet by nature, and a board that is away
    /// during one says so in its own progress line rather than being flagged as late.
    var liveness: Liveness? {
        guard let code = runningCode, item(code)?.isLongRunning == false else { return nil }
        guard let away = long?.awayFor else { return .normal }
        return away > Double(Thresholds.flashIdleLimitSeconds) ? .stalled : .normal
    }

    static let abortConsequence = "拷机一旦停止无法续跑，本板需要从头再来。"

    // MARK: - Derived readings

    func displayState(of code: String) -> ItemDisplayState {
        if runningCode == code { return .running }
        if let r = results[code], let c = Conclusion.of(r) { return .done(c) }
        // Nothing recorded: either it is still to come, or the run ended before reaching it.
        if terminatedAt != nil || isFinished { return .notRun }
        let mine = items.firstIndex { $0.code == code } ?? 0
        let now = runningCode.flatMap { c in items.firstIndex { $0.code == c } } ?? -1
        return mine < now ? .notRun : .pending
    }

    private func conclusions() -> [Conclusion] {
        items.compactMap { results[$0.code].flatMap(Conclusion.of) }
    }

    var passedItems: [TestItem] {
        items.filter { results[$0.code].flatMap(Conclusion.of) == .passed }
    }
    var recordOnlyItems: [TestItem] {
        items.filter { results[$0.code].flatMap(Conclusion.of) == .recordOnly }
    }

    /// Where the run got to. A manual stop and a defect are never merged: one is the operator's
    /// action, the other a statement about the board.
    var ending: Ending {
        if let refusedWhy { return .noResult(refusedWhy) }
        guard isFinished else { return .running }
        if let aborted = run?.abortedAt { return .aborted(aborted) }
        if let stopped = run?.stoppedAt {
            return results[stopped]?.condemnsMaterial == true ? .failed(stopped)
                                                              : .noResult(stopped)
        }
        return .completed
    }

    // MARK: - Taking events

    func apply(_ event: RunEvent) {
        switch event {
        case .waitingForBoard:
            startedAt = startedAt ?? Date()
        case let .boardBound(serial, identity):
            self.serial = serial
            self.identity = identity
            maskromSeen = true
        case let .itemStarted(item):
            runningCode = item.code
            step = nil; long = nil; longCode = nil
            startedAt = startedAt ?? Date()
            maskromSeen = true
        case let .itemFinished(item, result):
            results[item.code] = result
            runningCode = nil
            step = nil; long = nil; longCode = nil
        case let .step(s):
            step = s
        case let .longTest(code, p):
            longCode = code
            long = p
        case let .finished(run):
            self.run = run
            serial = run.board.serial ?? serial
            terminatedAt = run.stoppedAt ?? run.abortedAt
            finishedAt = Date()
            isFinished = true
            runningCode = nil
            step = nil; long = nil; longCode = nil
        }
    }

    func refuse(_ why: String) {
        refusedWhy = why
        isFinished = true
        finishedAt = Date()
    }

    func abort() {}
}

/// One click of 开始验证: a configuration and the boards confirmed for it.
///
/// A batch groups work. It is not a unit of result — every board carries its own, and there is no
/// such thing as a batch verdict.
@MainActor
final class Batch: ObservableObject, Identifiable {

    let id = UUID()
    let plan: BatchPlan
    let startedAt: Date
    /// Formatted once: the console redraws every second and this cannot change.
    let startedText: String
    @Published var benches: [Bench]
    @Published var folder: URL?

    init(plan: BatchPlan, folder: URL?) {
        self.plan = plan
        self.folder = folder
        self.startedAt = Date()
        self.startedText = operatorStamp.string(from: Date())
        self.benches = plan.boards.map {
            Bench(address: $0, model: plan.model, flow: plan.flow, items: plan.items)
        }
    }

    var model: DeviceModel { plan.model }
    var flow: ValidationFlow { plan.flow }

    func bench(_ address: BoardAddress) -> Bench? {
        benches.first { $0.address == address }
    }

    var finishedCount: Int { benches.filter(\.isFinished).count }
    var runningCount: Int { benches.filter { !$0.isFinished }.count }
    var isRunning: Bool { runningCount > 0 }

    /// A partial batch states its scope; it cannot conclude that the material may be imported. The
    /// same rule the report's title and file name use, so the three cannot disagree.
    var isPartial: Bool {
        TestItem.isPartial(plan.items, flow: plan.flow, model: plan.model,
                           burninPhases: plan.burninPhases.count)
    }

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
