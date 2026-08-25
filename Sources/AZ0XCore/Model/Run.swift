import Foundation

/// Everything one board's run produced, and the only durable record of it.
///
/// The chain that talks to hardware fills this in and stops there. Every renderer is a pure function
/// over it and knows nothing about adb, the CLIs or the boards, which is why a recorded run can be
/// re-rendered — or tested — without a board anywhere near it.
///
/// In-item progress is deliberately absent: it arrives every few seconds, is reconstructable from
/// the board-side log, and is interface state rather than something the run produced.
public struct Run: Codable {

    /// A renderer refuses a version it does not know rather than guessing at the shape.
    public static let currentSchema = 1
    public let schemaVersion: Int

    /// Identifies this run; one per board, never shared across a batch.
    public let runID: String
    public let batchID: String

    public let model: DeviceModel
    public let flow: ValidationFlow
    public let board: Board
    public let burninPhases: [BurninPhase]

    public let items: [TestItem]
    public let results: [String: ItemResult]

    public let startedAt: Date?
    public let finishedAt: Date?

    /// The item where `Flow` said stop.
    public let stoppedAt: String?
    /// Set instead when the operator stopped it. Never a statement about the material.
    public let abortedAt: String?

    public let toolVersions: [String]
    public let appVersion: String

    /// How the board was identified: from OTP before the run, over adb after flashing.
    public struct Board: Codable {
        /// Derived from the SoC CPUID; the same value before and after flashing.
        public let serial: String?
        public let cpuid: String?
        /// Separates models the USB PID cannot, such as AZ04A from AZ04B.
        public let chipVariant: String?
        /// Bus and port chain: what addressed the board before its serial was known.
        public let socket: String
        /// What the board reported about itself once booted.
        public let reported: String?
        public let uptimeAtBind: Int?
    
        public init(serial: String?, cpuid: String?, chipVariant: String?, socket: String,
                    reported: String?, uptimeAtBind: Int?) {
            self.serial = serial; self.cpuid = cpuid; self.chipVariant = chipVariant
            self.socket = socket; self.reported = reported; self.uptimeAtBind = uptimeAtBind
        }
    }
}

public extension Run {

    private func results(where predicate: (ItemResult) -> Bool) -> [TestItem] {
        items.filter { results[$0.code].map(predicate) ?? false }
    }

    /// Items that produced no result at all, which is not the same as passing. The header verdict
    /// must count these: a table saying 未执行 beside a header claiming everything passed is the
    /// contradiction this record exists to make impossible.
    var notRunItems: [TestItem] {
        items.filter { results[$0.code]?.execution == nil }
    }

    /// Items the criteria passed.
    var passedItems: [TestItem] { results { $0.verdict == .passed } }

    /// Items the criteria condemned. Nothing else belongs here.
    var notPassedItems: [TestItem] { results { $0.condemnsMaterial } }

    /// Items measured with no criterion implemented for them. Nothing is pending on these inside
    /// the app: the report lists their readings and says so.
    var recordOnlyItems: [TestItem] { results { $0.verdict == .noCriterion } }

    /// Items that ran but reached no conclusion — our environment, our tooling, or a board that
    /// could not be read. Never a statement about the material.
    var noResultItems: [TestItem] {
        results { $0.execution.map { !$0.isCompleted } ?? false }
    }

    /// Burn-in segments the board actually completed, read back from T06's own measurement.
    /// nil when T06 did not run or did not report it.
    var ranBurninPhases: Int? {
        guard let m = results["T06"]?.measurements.first(where: { $0.name == "执行段数" }),
              case let .number(v, _) = m.value else { return nil }
        return Int(v)
    }

    /// A partial run is a different document, so this decides a title, a warning and a file name —
    /// all three from here, or they contradict each other.
    var isPartial: Bool {
        if TestItem.isPartial(items, flow: flow, model: model,
                              burninPhases: burninPhases.count) { return true }
        return (ranBurninPhases ?? BurninPhase.allCases.count) < BurninPhase.allCases.count
    }

    /// How this board is named on disk: the serial once read, the socket before that.
    var boardName: String { board.serial ?? board.socket }
}
