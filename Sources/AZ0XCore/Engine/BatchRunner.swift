import Foundation

/// How a bench addresses its board.
///
/// The two domains do not share an identifier and cannot be made to: the maskrom tool reports
/// `002-1.4-2207-350E-NA` for a board that adb, minutes later, reports as `usb:2-2.4`. What bridges
/// them is the serial read out of OTP before flashing, which is the same string the board reports
/// once it has booted — so a full sequence is addressed one way and learns the other, and a
/// board-only sequence is addressed by the serial from the start.
public enum BoardAddress: Equatable, Hashable {
    /// A sequence that starts in maskrom: the tool's device id.
    case maskrom(String)
    /// A sequence with no flashing item: the serial an already-flashed board reports over adb.
    case flashed(serial: String)

    /// What the registry and the board's folder are keyed by.
    public var key: String {
        switch self {
        case let .maskrom(id):     return id
        case let .flashed(serial): return serial
        }
    }

    /// What an operator reads. The socket is the half of a device id that names a physical position.
    public var display: String {
        switch self {
        case let .maskrom(id):     return "插座 \(DdrCli.socket(id))"
        case let .flashed(serial): return serial
        }
    }
}

/// One click of 开始验证: a configuration, and the boards confirmed for it.
///
/// A batch is how work is grouped, not a unit of result. It produces one independent record per
/// board and a folder to hold them; there is no such thing as a batch verdict.
public struct BatchPlan {
    public let batchID: String
    public let model: DeviceModel
    public let flow: ValidationFlow
    public let items: [TestItem]
    public let burninPhases: Set<BurninPhase>
    /// The boards, fixed at the moment the operator confirmed them.
    public let boards: [BoardAddress]

    public var burninSeconds: Int = Thresholds.longRunSeconds
    public var cycles: Int = Thresholds.longRunCycles

    public init(batchID: String, model: DeviceModel, flow: ValidationFlow,
                items: [TestItem], burninPhases: Set<BurninPhase>, boards: [BoardAddress],
                burninSeconds: Int = Thresholds.longRunSeconds,
                cycles: Int = Thresholds.longRunCycles) {
        self.batchID = batchID
        self.model = model
        self.flow = flow
        self.items = items
        self.burninPhases = burninPhases
        self.boards = boards
        self.burninSeconds = burninSeconds
        self.cycles = cycles
    }

    func runPlan(for board: BoardAddress) -> RunPlan {
        var p = RunPlan(batchID: batchID, runID: UUID().uuidString,
                        model: model, flow: flow, items: items,
                        burninPhases: burninPhases,
                        deviceID: { if case let .maskrom(id) = board { return id } else { return "" } }(),
                        boardSerial: { if case let .flashed(s) = board { return s } else { return nil } }())
        p.burninSeconds = burninSeconds
        p.cycles = cycles
        return p
    }
}

/// What a batch tells whoever is watching.
public enum BatchEvent {
    /// A named board could not be taken, and why. Never silent: an operator who named four boards
    /// and got three must be told, or the batch quietly becomes a different batch.
    case refused(board: BoardAddress, why: String)
    case benchStarted(board: BoardAddress)
    /// Something happened inside one bench.
    case bench(board: BoardAddress, RunEvent)
    case benchFinished(board: BoardAddress, Run, folder: URL?)
    /// Every bench has ended. Always emitted exactly once.
    case finished([Run])
}

/// Runs one batch: every board at once, each independent of the others.
///
/// Concurrency is the mechanism and lives here; which boards, in what configuration, and when is the
/// caller's policy. There is no limit on how many run at once — the boards are on one host's USB and
/// the tools address them individually, which the previous generation of this bench established in
/// service.
public struct BatchRunner {

    public let plan: BatchPlan
    /// Shared across every batch in this process, so a second batch cannot take a board the first
    /// one is still driving.
    public let registry: BenchRegistry
    /// Builds the engine for one board. Injected, so a test drives declared boards through the real
    /// sequence without any hardware.
    let makeValidator: (RunPlan, URL?) -> Validator
    /// This batch's folder; each board gets one inside it. nil archives nothing.
    public var folder: URL?

    /// The bench as it ships: the bundled tools, real adb, real flashing.
    ///
    /// Exists so that a caller — the interface, or anything else — never has to assemble an engine.
    /// The injectable form stays for tests, which drive declared boards through the same sequence.
    public static func live(plan: BatchPlan, registry: BenchRegistry, folder: URL?) -> BatchRunner? {
        guard let cli = DdrCli() else { return nil }
        return BatchRunner(plan: plan, registry: registry,
                           makeValidator: { runPlan, dir in
                               Validator(plan: runPlan, tool: cli,
                                         boardSession: { Adb(serial: $0) },
                                         flashTool: FlashTool(), archiveFolder: dir)
                           },
                           folder: folder)
    }

    public func run(onEvent: @escaping (BatchEvent) -> Void) async -> [Run] {
        // Benches run concurrently, so emission is funnelled through one actor: two boards finishing
        // at the same moment must not interleave inside a caller that assumed one at a time.
        let emit = Emitter(sink: onEvent)

        // Every board is taken before any board is touched.
        var taken: [BoardAddress] = []
        for board in plan.boards {
            if await registry.take(board.key) {
                taken.append(board)
            } else {
                await emit.send(.refused(board: board,
                                         why: "本机已有另一个工位正在验这块板"))
            }
        }
        guard !taken.isEmpty else {
            await emit.send(.finished([]))
            return []
        }

        let runs = await withTaskGroup(of: Run.self) { group -> [Run] in
            for board in taken {
                group.addTask { await drive(board, emit: emit) }
            }
            var out: [Run] = []
            for await r in group { out.append(r) }
            return out
        }
        await emit.send(.finished(runs))
        return runs
    }

    /// Drives one board and gives it back afterwards.
    ///
    /// Single exit on purpose: a board that is not released stays unusable for the rest of the
    /// session even though its socket is physically free — the same fault the twelve-hour wall clock
    /// used to cause on the board itself, one level up.
    private func drive(_ board: BoardAddress, emit: Emitter) async -> Run {
        await emit.send(.benchStarted(board: board))

        let dir = folder.map { $0.appendingPathComponent(SafePath.component(board.key) ?? "board",
                                                         isDirectory: true) }
        if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }

        let validator = makeValidator(plan.runPlan(for: board), dir)
        let run = await validator.run { event in
            Task { await emit.send(.bench(board: board, event)) }
        }

        await registry.release(board.key)

        // The folder was created before the board had said who it is. Now that it has, the folder
        // takes its name: months later a person looks for a serial, not for a socket.
        var landed = dir
        if let dir, let serial = run.board.serial, let named = SafePath.component(serial),
           named != dir.lastPathComponent {
            let target = dir.deletingLastPathComponent()
                .appendingPathComponent(named, isDirectory: true)
            if (try? FileManager.default.moveItem(at: dir, to: target)) != nil { landed = target }
        }

        await emit.send(.benchFinished(board: board, run, folder: landed))
        return run
    }

    /// Serialises emission across concurrent benches.
    private actor Emitter {
        let sink: (BatchEvent) -> Void
        init(sink: @escaping (BatchEvent) -> Void) { self.sink = sink }
        func send(_ e: BatchEvent) { sink(e) }
    }
}
