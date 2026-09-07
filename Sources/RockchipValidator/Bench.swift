import Foundation
import ValidationCore

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
    /// Addresses this board in maskrom: the tool's device id, whose first two parts name the socket.
    let deviceID: String
    /// What to run on it. Handed to the core, which runs exactly one board.
    let plan: RunPlan
    let model: BoardModel
    let flow: ValidationFlow
    let items: [TestItem]

    /// Read from OTP during the first maskrom item; nil until then.
    @Published var serial: String?

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

    init(deviceID: String, plan: RunPlan) {
        self.deviceID = deviceID
        self.plan = plan
        self.model = plan.model
        self.flow = plan.flow
        self.items = plan.items
    }

    // MARK: - What the views ask of it

    var portChain: String { deviceID.split(separator: "-").prefix(2).joined(separator: "-") }
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

    /// Whether this board is still being validated.
    ///
    /// One predicate, because two consumers ask it and they must not drift: the console counts
    /// boards still working, and the quit guard decides whether Cmd+Q costs anything. `refuse(_:)`
    /// marks a bench finished, so a board that never started is not running either.
    var isRunning: Bool { ending == .running }

    /// Where the run got to. A manual stop and a defect are never merged: one is the operator's
    /// action, the other a statement about the board.
    var ending: Ending {
        if let refusedWhy { return .noResult(refusedWhy) }
        guard isFinished else { return .running }
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
        case let .boardBound(serial, _):
            self.serial = serial
            // The identity the board reports over adb is not kept here: nothing on screen shows it,
            // and the report takes it from the engine's own record. `rkval` prints it from the event.
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
            terminatedAt = run.stoppedAt
            finishedAt = Date()
            isFinished = true
            runningCode = nil
            step = nil; long = nil; longCode = nil
        }
    }

    /// This window refused to start the board, so it shows with a reason and no record.
    ///
    /// Nothing ran, so there is nothing to write: a report for a board that never started would be
    /// a document about nothing. The console and the summary read this through `ending`.
    func refuse(_ why: String) {
        refusedWhy = why
        isFinished = true
        finishedAt = Date()
    }
}

/// One click of 开始验证: a configuration and the boards confirmed for it.
///
/// A batch groups work. It is not a unit of result — every board carries its own, and there is no
/// such thing as a batch verdict.
@MainActor
final class Batch: ObservableObject, Identifiable {

    let id = UUID()
    let batchID: String
    let model: BoardModel
    let flow: ValidationFlow
    let items: [TestItem]
    let burninPhases: Set<BurninPhase>
    let folder: URL?
    let scale: RunScale
    let startedAt: Date
    /// Formatted once: the console redraws every second and this cannot change.
    let startedText: String
    @Published var benches: [Bench]

    init(batchID: String, model: BoardModel, flow: ValidationFlow, items: [TestItem],
         burninPhases: Set<BurninPhase>, deviceIDs: [String], folder: URL?,
         scale: RunScale = .default, image: PreparedImage? = nil) {
        self.batchID = batchID
        self.model = model
        self.flow = flow
        self.items = items
        self.burninPhases = burninPhases
        self.folder = folder
        self.scale = scale
        self.startedAt = Date()
        self.startedText = operatorStamp.string(from: Date())
        self.benches = deviceIDs.map { id in
            Bench(deviceID: id,
                  plan: RunPlan(batchID: batchID, model: model, flow: flow, items: items,
                                burninPhases: burninPhases, deviceID: id,
                                scale: scale, image: image))
        }
    }

    func bench(_ deviceID: String) -> Bench? {
        benches.first { $0.deviceID == deviceID }
    }

    var finishedCount: Int { benches.filter(\.isFinished).count }
    var runningCount: Int { benches.filter(\.isRunning).count }
    var isRunning: Bool { runningCount > 0 }

}
