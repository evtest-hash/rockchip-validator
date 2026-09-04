import Foundation

/// One board this bench validates.
///
/// A catalog entry, not an enum case. Every SoC-level fact now comes from `soc`, so adding a board
/// is adding a row rather than filling in four `switch`es — and filling those in was where the
/// same RK3588 constants got written twice.
///
/// What stays here is what genuinely varies per board: what it is called, which silicon it is built
/// on, which marking of that silicon, and how it names itself in a device tree.
public struct BoardModel: Identifiable {

    /// Short code. This is the identity: it names the archive directory, leads the batch id, goes
    /// into the report, keys the CI image index, and is what a recorded run stores. Kept free of
    /// spaces and separators for that reason.
    public let code: String

    /// What a person calls this board, when that is not just the code — "Mixtile Core3588E".
    public let name: String

    public let soc: RockchipSoC

    /// The OTP markings this board is built from.
    ///
    /// A board can span more than one: AZ08 is RK3576 and RK3576S alike. It is also the only thing
    /// separating boards that share a maskrom PID, which is what makes it a board fact rather than
    /// a SoC one — AZ04A is RK3588 and AZ04B is RK3588S2 behind the same 0x350b.
    public let markings: Set<String>

    /// Upper-case fragments this board's device tree is expected to contain. Defaults to the code,
    /// which is what every board here spells; the field exists for one that spells something else.
    public let deviceTreeAliases: [String]

    public var id: String { code }

    public init(code: String, name: String? = nil, soc: RockchipSoC,
                markings: Set<String>, deviceTreeAliases: [String]? = nil) {
        self.code = code
        self.name = name ?? code
        self.soc = soc
        self.markings = markings
        self.deviceTreeAliases = deviceTreeAliases ?? [code.uppercased()]
    }
}

// MARK: - The catalog

public extension BoardModel {

    static let az05  = BoardModel(code: "AZ05",  soc: .rk3288, markings: ["RK3288"])
    static let az07  = BoardModel(code: "AZ07",  soc: .rk3566, markings: ["RK3566"])
    static let az08  = BoardModel(code: "AZ08",  soc: .rk3576, markings: ["RK3576", "RK3576S"])
    static let az04a = BoardModel(code: "AZ04A", soc: .rk3588, markings: ["RK3588"])
    static let az04b = BoardModel(code: "AZ04B", soc: .rk3588, markings: ["RK3588S2"])

    /// Every board this build knows, in the order the picker offers them.
    static let catalog: [BoardModel] = [.az05, .az07, .az08, .az04a, .az04b]

    /// The board a code names, or nil for one this build does not know.
    ///
    /// Case-insensitive, which is what lets an operator type `az08` on the command line and what
    /// keeps a mixed-case code such as `Core3588E` matchable without upper-casing the input first.
    static func named(_ code: String) -> BoardModel? {
        catalog.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }
}

// MARK: - Naming

public extension BoardModel {

    /// The chip named in a report and in the picker: the specific marking when this board is built
    /// from exactly one, the family when it spans several.
    ///
    /// Not `soc.family` flat. AZ04B is built from RK3588S2, and a report saying RK3588 would be
    /// less true than the string it replaced. Not a stored field either — that would be a third
    /// place the same fact is written, and the two that already exist are the ones the rest of the
    /// code reasons with.
    var socName: String {
        markings.count == 1 ? (markings.first ?? soc.family) : soc.family
    }

    var displayName: String { "\(name) · \(socName)" }
}

// MARK: - Chip markings

public extension BoardModel {

    private func accepts(_ marking: String) -> Bool {
        markings.contains { $0.caseInsensitiveCompare(marking) == .orderedSame }
    }

    /// Every board built from this marking.
    ///
    /// Replaces a `named(byChipVariant:)` that returned the *first* match. On silicon where one
    /// marking names one board that read correctly; on RK3588 it picked AZ04A out of a list and
    /// presented the guess as fact. A caller that wants to name what is in the socket has to be
    /// told when the answer is more than one board.
    static func modelsAccepting(_ marking: String) -> [BoardModel] {
        catalog.filter { $0.accepts(marking) }
    }

    /// Whether a marking read from OTP names a board other than this one.
    ///
    /// A marking no board is built from contradicts nothing: stopping a legitimate board over a
    /// marking we have no information about is worse than not gating a board we do not build. This
    /// is why the check is "some board accepts it" rather than "no board accepts it uniquely" —
    /// weakening it to the latter would stop catching an RK3588 board in an AZ05 run.
    func contradicts(chipVariant: String?) -> Bool {
        guard let chipVariant else { return false }
        if accepts(chipVariant) { return false }
        return !Self.modelsAccepting(chipVariant).isEmpty
    }
}

// MARK: - Capabilities

public extension BoardModel {

    /// Items requiring an unsupported capability never enter the sequence.
    func supports(_ capability: Capability) -> Bool {
        switch capability {
        case .eyescan: return soc.hasEyeScan
        }
    }
}

// MARK: - Equality and the wire format

extension BoardModel: Hashable {
    /// By code alone: it is the identity, and two entries cannot share one.
    public static func == (a: BoardModel, b: BoardModel) -> Bool { a.code == b.code }
    public func hash(into hasher: inout Hasher) { hasher.combine(code) }
}

extension BoardModel: Codable {

    /// A recorded run stores the code and nothing else, exactly as the enum's raw value did, so
    /// every `run.json` written before this type existed still reads.
    ///
    /// An unknown code throws rather than decoding to some placeholder. `RunStore.past` skips a
    /// record it cannot read without a word, which is the behaviour a code from a future build has
    /// to land on — a run rendered against the wrong board would be worse than one not listed.
    public init(from decoder: Decoder) throws {
        let code = try decoder.singleValueContainer().decode(String.self)
        guard let board = BoardModel.named(code) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "本版本不认识型号 \(code)"))
        }
        self = board
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}
