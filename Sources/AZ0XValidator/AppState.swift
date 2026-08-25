import Foundation
import AZ0XCore

/// What the operator has selected, and the batches under way.
///
/// This object holds policy: which boards, in what configuration, when. The mechanism — running
/// them all at once, keeping two benches off one board — belongs to the core and is only called
/// from here.
@MainActor
final class AppState: ObservableObject {

    enum Screen: Equatable { case console, newBatch }

    @Published var screen: Screen = .console

    // What the wizard is collecting.
    @Published var model: DeviceModel = .az08 { didSet { resetSelection() } }
    @Published var flow: ValidationFlow = .ddr { didSet { resetSelection() } }
    @Published var picked: Set<String> = []
    @Published var burninPhases: Set<BurninPhase> = Set(BurninPhase.allCases)
    /// Device ids the operator has ticked.
    @Published var confirmed: Set<String> = []

    @Published var batches: [Batch] = []
    /// Which board's pages are open; nil shows the console.
    @Published var openBench: UUID?

    // What the bus looks like, sampled while the wizard is open.
    @Published var attached: [MaskromScan.Board] = []
    @Published var isScanning = false
    /// Boards this process is already driving, read from the registry rather than kept alongside it:
    /// two records of one fact is how the previous generation's list came to disagree with its own
    /// admission rule.
    @Published private var inUse: Set<String> = []

    /// Bundled tools this build is missing. Nothing can run without them.
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

    var allBenches: [Bench] { batches.flatMap(\.benches) }

    /// What this batch asks of each board, in the unit each item is actually bounded by.
    ///
    /// The previous generation reported T07 and T08 in hours, taken from how long the host was
    /// willing to wait — a figure that said nothing about the standard and stopped being true the
    /// moment a board cycled at a different speed.
    var estimatedDuration: String {
        var parts: [String] = []
        if resolvedItems.contains(where: { $0.code == "T06" }) {
            parts.append("拷机 \(TestItem.hoursText(Thresholds.longRunSeconds * burninPhases.count))")
        }
        if resolvedItems.contains(where: { $0.code == "T07" }) {
            parts.append("休眠唤醒 \(Thresholds.longRunCycles) 次")
        }
        if resolvedItems.contains(where: { $0.code == "T08" }) {
            parts.append("重启 \(Thresholds.longRunCycles) 次")
        }
        if resolvedItems.contains(where: { $0.code == "E05" }) {
            parts.append("eMMC 拷机 \(Thresholds.emmcTargetN) 次全盘写")
        }
        return parts.isEmpty ? "本次不含长测项" : parts.joined(separator: "；")
    }

    // MARK: - Which boards this batch may take

    /// Boards of the selected model that nothing is already driving.
    ///
    /// A board already in use is simply absent — not listed and refused, which would only invite the
    /// operator to tick something that cannot be taken.
    var candidates: [MaskromScan.Board] {
        attached.filter { $0.matches(model) && !inUse.contains($0.deviceID) }
    }

    /// Boards left out, counted from the same values the list above filters on, so the explanation
    /// cannot describe a different set than the rows beside it.
    var excludedCounts: (claimed: Int, otherModel: Int) {
        let mine = attached.filter { $0.matches(model) }
        return (mine.filter { inUse.contains($0.deviceID) }.count, attached.count - mine.count)
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

    func newBatch() {
        confirmed = Set(candidates.map(\.deviceID))
        screen = .newBatch
    }

    func cancelNewBatch() {
        confirmed = []
        screen = .console
    }

    /// Starts a batch on exactly the boards ticked here; nothing afterwards changes that.
    func startBatch(root: URL = ArchiveRoot.default) {
        let boards = candidates.filter { confirmed.contains($0.deviceID) }.map(\.deviceID)
        guard !boards.isEmpty, !resolvedItems.isEmpty else { return }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let batchID = "\(model.rawValue)-\(flow == .ddr ? "DDR" : "EMMC")-\(stamp.string(from: Date()))"
        let folder = root.appendingPathComponent(batchID, isDirectory: true)

        let batch = Batch(batchID: batchID, model: model, flow: flow, items: resolvedItems,
                          burninPhases: burninPhases, deviceIDs: boards, folder: folder)
        batches.append(batch)
        confirmed = []
        screen = .console

        for bench in batch.benches { drive(bench, in: batch) }
    }

    /// Runs one board, and gives its socket back afterwards.
    ///
    /// This is the fan-out, and it lives here because it is policy: which boards, grouped how, when.
    /// The core runs one board and knows nothing about batches. It used to hold this loop, which
    /// bought one thing this window already had — a shared image download, since it is one process —
    /// and cost three classes of concurrency defect.
    ///
    /// Events reach the main actor through a stream, in the order the engine produced them. Not a
    /// task per event: tasks have no ordering guarantee, and an item's result arriving after the next
    /// item had started would overwrite what is running with stale state.
    private func drive(_ bench: Bench, in batch: Batch) {
        let dir = batch.folder.map {
            $0.appendingPathComponent(bench.deviceID, isDirectory: true)
        }
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let validator = Validator.live(plan: bench.plan, archiveFolder: dir) else { return }

        var yield: AsyncStream<RunEvent>.Continuation!
        let events = AsyncStream<RunEvent> { yield = $0 }
        let send = yield!

        Task { @MainActor [weak self] in
            for await event in events { bench.apply(event) }
            self?.finish(bench, folder: dir)
            await self?.registry.release(bench.deviceID)
            await self?.scan()          // its socket is free now
        }
        Task {
            // The safety catch: two benches on one board would be two writers on one part. Normal
            // operation never reaches it — a board already running is absent from the list above.
            guard await registry.take(bench.deviceID) else {
                await MainActor.run { bench.refuse("本窗口已有另一个工位正在验这块板") }
                send.finish()
                return
            }
            _ = await validator.run { send.yield($0) }
            send.finish()
        }
    }

    /// Writes the record and the report once a board has finished.
    private func finish(_ bench: Bench, folder: URL?) {
        guard let run = bench.run, let folder else { return }
        bench.runFolder = folder
        if let url = RunStore.write(run, into: folder) { bench.reportURL = url }
        else { bench.reportError = "无法写入 \(folder.lastPathComponent)" }
    }
}
