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

    /// The chip this board carries, as a report and a picker name it.
    ///
    /// Defaults to the SoC family, and is written out only where the board carries a marking
    /// specific enough to be worth stating: AZ04B is built from RK3588S2 and its report has always
    /// said so, where the family name would be true but less so.
    public let chip: String

    /// Upper-case fragments this board's device tree is expected to contain. Defaults to the code,
    /// which is what every board here spells; the field exists for one that spells something else.
    public let deviceTreeAliases: [String]

    public var id: String { code }

    public init(code: String, name: String? = nil, soc: RockchipSoC,
                chip: String? = nil, deviceTreeAliases: [String]? = nil) {
        self.code = code
        self.name = name ?? code
        self.soc = soc
        self.chip = chip ?? soc.family
        self.deviceTreeAliases = deviceTreeAliases ?? [code.uppercased()]
    }
}

// MARK: - The catalog

public extension BoardModel {

    static let az05  = BoardModel(code: "AZ05",  soc: .rk3288)
    static let az07  = BoardModel(code: "AZ07",  soc: .rk3566)
    static let az08  = BoardModel(code: "AZ08",  soc: .rk3576)
    static let az04a = BoardModel(code: "AZ04A", soc: .rk3588)
    static let az04b = BoardModel(code: "AZ04B", soc: .rk3588, chip: "RK3588S2")

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

    var displayName: String { "\(name) · \(chip)" }
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
