import Foundation
import AZ0XCore

/// What the operator has selected, and the batches under way.
///
/// This object holds policy: which boards, in what configuration, when. The mechanism — running
/// them all at once, keeping two benches off one board — belongs to the core and is only called
/// from here.
@MainActor
final class AppModel: ObservableObject {

    enum Screen: Equatable {
        case console
        case newBatch(step: Int)
    }

    @Published var screen: Screen = .console

    // What the wizard is collecting.
    @Published var model: DeviceModel = .az08 { didSet { resetSelection() } }
    @Published var flow: ValidationFlow = .ddr { didSet { resetSelection() } }
    @Published var picked: Set<String> = []
    @Published var burninPhases: Set<BurninPhase> = Set(BurninPhase.allCases)
    /// Device ids the operator has ticked.
    @Published var confirmed: Set<String> = []

    @Published var batches: [BatchState] = []
    /// Which board's pages are open; nil shows the console.
    @Published var openBench: UUID?

    // What the bus looks like, sampled while the wizard is open.
    @Published var attached: [MaskromScan.Board] = []
    @Published var isScanning = false
    /// Boards this process is already driving, read from the registry rather than kept in parallel
    /// with it — two records of the same fact is how the previous generation's lists came to
    /// disagree with its own admission rule.
    @Published private var inUse: Set<String> = []

    /// Missing bundled tools. Nothing can run without them, so it is said on the console.
    let missingTools = MaskromScan.missingTools

    /// The one registry for this process, so a second batch cannot take a board the first is on.
    private let registry = BenchRegistry()

    init() { resetSelection() }

    // MARK: - Selection

    private func resetSelection() {
        picked = Set(TestItem.optionalItems(for: flow, model: model).map(\.code))
        burninPhases = Set(BurninPhase.allCases)
    }

    var resolvedItems: [TestItem] {
        TestItem.resolveSelection(picked, flow: flow, model: model)
    }

    var isPartialRun: Bool {
        TestItem.isPartial(resolvedItems, flow: flow, model: model,
                           burninPhases: burninPhases.count)
    }

    var hasLongRun: Bool { resolvedItems.contains(where: \.isLongRunning) }

    /// What this batch will ask of each board, in the unit each item is actually bounded by.
    var scaleSummary: [(String, String)] {
        var out: [(String, String)] = []
        if resolvedItems.contains(where: { $0.code == "T06" }) {
            out.append(("拷机", TestItem.hoursText(Thresholds.longRunSeconds * burninPhases.count)))
        }
        if resolvedItems.contains(where: { $0.code == "T07" }) {
            out.append(("休眠唤醒", "\(Thresholds.longRunCycles) 次"))
        }
        if resolvedItems.contains(where: { $0.code == "T08" }) {
            out.append(("重启", "\(Thresholds.longRunCycles) 次"))
        }
        if resolvedItems.contains(where: { $0.code == "E05" }) {
            out.append(("eMMC 拷机", "\(Thresholds.emmcTargetN) 次全盘写"))
        }
        return out
    }

    // MARK: - Which boards this batch may take

    /// Boards of the selected model that nothing is already driving.
    ///
    /// A board already in use is simply absent — not listed and refused, which would only invite the
    /// operator to tick something that cannot be taken.
    var candidates: [MaskromScan.Board] {
        attached.filter { $0.matches(model) && !inUse.contains($0.deviceID) }
    }

    /// Boards left out, so their absence is accounted for rather than mysterious. Counted from the
    /// same values the list above filters on, so the two cannot describe different sets.
    var excluded: (inUse: Int, otherModel: Int) {
        let mine = attached.filter { $0.matches(model) }
        return (mine.filter { inUse.contains($0.deviceID) }.count, attached.count - mine.count)
    }

    var excludedNote: String {
        let (used, others) = excluded
        var parts: [String] = []
        if others > 0 { parts.append("\(others) 块其它型号") }
        if used > 0 { parts.append("\(used) 块已在其它批次中") }
        return parts.isEmpty ? "" : "另有 " + parts.joined(separator: "、") + "，不在本批次候选内"
    }

    // MARK: - Transitions

    /// Samples the bus and the registry together, so the list and the admission rule agree.
    func scan() async {
        isScanning = true
        attached = await MaskromScan.attached()
        inUse = await registry.inUse
        confirmed.formIntersection(Set(attached.map(\.deviceID)))
        isScanning = false
    }

    func openNewBatch() {
        confirmed = Set(candidates.map(\.deviceID))
        screen = .newBatch(step: 1)
    }

    func cancelNewBatch() {
        confirmed = []
        screen = .console
    }

    /// Starts a batch on exactly the boards ticked here, and nothing else afterwards changes that.
    func startBatch(root: URL = ArchiveRoot.default) {
        let boards = candidates.filter { confirmed.contains($0.deviceID) }
            .map { BoardAddress.maskrom($0.deviceID) }
        guard !boards.isEmpty, !resolvedItems.isEmpty else { return }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let batchID = "\(model.rawValue)-\(flow == .ddr ? "DDR" : "EMMC")-\(stamp.string(from: Date()))"
        let folder = root.appendingPathComponent(batchID, isDirectory: true)

        let plan = BatchPlan(batchID: batchID, model: model, flow: flow,
                             items: resolvedItems, burninPhases: burninPhases, boards: boards)
        let batch = BatchState(plan: plan, folder: folder)
        batches.append(batch)
        confirmed = []
        screen = .console

        drive(batch)
    }

    /// Hands the batch to the core and folds what comes back into observable state.
    ///
    /// The engine emits and forgets; everything main-actor stops here.
    private func drive(_ batch: BatchState) {
        guard let runner = BatchRunner.live(plan: batch.plan, registry: registry,
                                            folder: batch.folder) else { return }
        Task { [weak self] in
            _ = await runner.run { event in
                Task { @MainActor [weak self] in self?.receive(event, in: batch) }
            }
            await self?.scan()          // a finished batch has given its sockets back
        }
    }

    private func receive(_ event: BatchEvent, in batch: BatchState) {
        switch event {
        case let .refused(board, why):
            batch.bench(board)?.refuse(why)
        case let .benchStarted(board):
            batch.bench(board)?.startedAt = Date()
        case let .bench(board, e):
            batch.bench(board)?.apply(e)
        case let .benchFinished(board, run, folder):
            guard let bench = batch.bench(board) else { return }
            bench.apply(.finished(run))
            // Written here rather than in the engine: rendering is presentation, and the same
            // function writes it for the command line.
            if let folder { bench.reportURL = RunStore.write(run, into: folder) }
        case .finished:
            break
        }
    }
}
