import Foundation
import ValidationCore

/// What the operator has selected, and the batches under way.
///
/// This object holds policy: which boards, in what configuration, when. The mechanism — running
/// them all at once, keeping two benches off one board — belongs to the core and is only called
/// from here.
@MainActor
final class AppState: ObservableObject {

    enum Screen: Equatable { case console, newBatch, history }

    @Published var screen: Screen = .console

    // What the wizard is collecting.
    @Published var model: BoardModel = .az08 { didSet { resetSelection() } }
    @Published var flow: ValidationFlow = .ddr { didSet { resetSelection() } }
    @Published var picked: Set<String> = []
    @Published var burninPhases: Set<BurninPhase> = Set(BurninPhase.allCases)
    /// How much this batch asks of each board — and therefore what its items are judged against.
    ///
    /// There is no amount the software considers correct. A shorter run is a smaller run, not a
    /// failed attempt at a larger one: five cycles means the criterion is five cycles. The report
    /// states whatever was set here, so nobody has to be warned about it beforehand.
    @Published var scale = RunScale.default
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

    /// What the one step that precedes a batch is doing, so the screen can say so.
    ///
    /// It used to be a published tuple that no view read: the operator pressed 开始验证 and the
    /// wizard sat there unchanged for as long as a 766 MB transfer takes, with the button still
    /// live, and a failure set a message nothing displayed. Written, never shown — which no
    /// compiler and no test could see.
    enum ImageFetch: Equatable {
        /// Asking CI which build is current. No byte count exists yet.
        case asking
        /// Transferring. `total` is nil when the server did not say how large it is.
        case fetching(asset: String, done: Int64, total: Int64?)
    }
    @Published var imageFetch: ImageFetch?
    @Published var fetchError: String?

    // MARK: - Past batches

    @Published var history: [RunStore.PastBatch] = []
    @Published private(set) var historyLoading = false

    /// Read when the history screen opens, not at launch.
    ///
    /// At launch it would slow the first thing an operator sees for something most of them are not
    /// there for, and the archive only grows. Off the main actor because it parses every record it
    /// lists — a batch's `run.json` is tens of kilobytes and there may be fifty of them.
    func loadHistory(limit: Int = 50) async {
        historyLoading = true
        let found = await Task.detached(priority: .userInitiated) {
            RunStore.past(limit: limit)
        }.value
        history = found
        historyLoading = false
    }

    /// The Dock, for the stretch of a run when nobody is looking at the window.
    let dock = DockAttention.live

    /// The one registry for this process, so a second batch cannot take a board the first is on.
    private let registry = BenchRegistry()

    init() { resetSelection() }

    // MARK: - Selection

    private func resetSelection() {
        picked = Set(TestItem.optionalItems(for: flow, model: model).map(\.code))
        burninPhases = Set(BurninPhase.allCases)
        scale = RunScale.default
    }

    /// Zero would be no test at all, so one is the floor. There is no ceiling: a stricter run is
    /// the operator's to ask for, and the report records what was actually asked.
    func setScale(_ keyPath: WritableKeyPath<RunScale, Int>, _ value: Int) {
        scale[keyPath: keyPath] = max(1, value)
    }


    var resolvedItems: [TestItem] {
        TestItem.resolveSelection(picked, flow: flow, model: model)
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
            parts.append("拷机 \(TestItem.hoursText(scale.burninSeconds * burninPhases.count))")
        }
        if resolvedItems.contains(where: { $0.code == "T07" }) {
            parts.append("休眠唤醒 \(scale.cycles) 次")
        }
        if resolvedItems.contains(where: { $0.code == "T08" }) {
            parts.append("重启 \(scale.cycles) 次")
        }
        if resolvedItems.contains(where: { $0.code == "E05" }) {
            parts.append("eMMC 拷机 \(scale.emmcTargetN) 次全盘写")
        }
        return parts.isEmpty ? "本次不含长测项" : parts.joined(separator: "；")
    }

    // MARK: - Which boards this batch may take

    /// Boards of the selected model that nothing is already driving.
    ///
    /// A board already in use is simply absent — not listed and refused, which would only invite the
    /// operator to tick something that cannot be taken.
    var candidates: [MaskromScan.Board] {
        attached.filter { $0.matches(model.soc) && !inUse.contains($0.deviceID) }
    }

    /// Boards left out, counted from the same values the list above filters on, so the explanation
    /// cannot describe a different set than the rows beside it.
    var excludedCounts: (claimed: Int, otherModel: Int) {
        let mine = attached.filter { $0.matches(model.soc) }
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
    ///
    /// The image is fetched once, here, before any board is opened. If it cannot be had, no board is
    /// touched: a bench that cannot be served should not be taken apart to find that out five times.
    func startBatch(root: URL = ArchiveRoot.default) {
        let boards = candidates.filter { confirmed.contains($0.deviceID) }.map(\.deviceID)
        guard !boards.isEmpty, !resolvedItems.isEmpty else { return }

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let batchID = "\(model.code)-\(flow == .ddr ? "DDR" : "EMMC")-\(stamp.string(from: Date()))"
        let folder = root.appendingPathComponent(batchID, isDirectory: true)
        let flashes = resolvedItems.contains { TestItem.flashCodes.contains($0.code) }
        let chosen = model, chosenFlow = flow, items = resolvedItems, phases = burninPhases
        let asked = scale

        fetchError = nil
        // Set before the task starts, so the screen changes on the click rather than whenever the
        // first callback happens to arrive.
        imageFetch = flashes ? .asking : nil
        Task { [weak self] in
            var image: PreparedImage?
            if flashes {
                var named = ""
                do {
                    image = try await ImageSupply.prepare(
                        model: chosen,
                        onAsset: { asset in
                            named = asset
                            Task { @MainActor [weak self] in
                                self?.imageFetch = .fetching(asset: asset, done: 0, total: nil)
                            }
                        },
                        onProgress: { done, total in
                            Task { @MainActor [weak self] in
                                self?.imageFetch = .fetching(asset: named, done: done, total: total)
                            }
                        })
                } catch {
                    await MainActor.run {
                        self?.imageFetch = nil
                        self?.fetchError = "\(error.localizedDescription)。验证未开始。"
                    }
                    return
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.imageFetch = nil
                let batch = Batch(batchID: batchID, model: chosen, flow: chosenFlow, items: items,
                                  burninPhases: phases, deviceIDs: boards, folder: folder,
                                  scale: asked, image: image)
                self.batches.append(batch)
                self.confirmed = []
                self.screen = .console
                for bench in batch.benches { self.drive(bench, in: batch) }
            }
        }
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
            self?.finish(bench, folder: dir, of: batch)
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
    private func finish(_ bench: Bench, folder: URL?, of batch: Batch) {
        if let run = bench.run, let folder {
            bench.runFolder = folder
            if let url = RunStore.write(run, into: folder) { bench.reportURL = url }
            else { bench.reportError = "无法写入 \(folder.lastPathComponent)" }
        }
        // This bench is already marked finished — the event stream ended above — so the others'
        // state is all that is left to read. A board that was refused before it started counts as
        // finished too: it is done, and something has to be done about it.
        if !batch.isRunning { dock.batchFinished() }
    }
}
