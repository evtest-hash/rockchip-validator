import Foundation

/// One board this bench validates.
///
/// A catalog entry, not an enum case. Every SoC-level fact now comes from `soc`, so adding a board
/// is adding a row rather than filling in four `switch`es — and filling those in was where the
/// same RK3588 constants got written twice.
///
/// What stays here is what genuinely varies per board: what it is called, and which silicon — down
/// to the marking — it is built on.
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

    public var id: String { code }

    public init(code: String, name: String? = nil, soc: RockchipSoC, chip: String? = nil) {
        self.code = code
        self.name = name ?? code
        self.soc = soc
        self.chip = chip ?? soc.family
    }
}

// MARK: - The catalog

public extension BoardModel {

    static let az05  = BoardModel(code: "AZ05",  soc: .rk3288)
    static let az07  = BoardModel(code: "AZ07",  soc: .rk3566)
    static let az08  = BoardModel(code: "AZ08",  soc: .rk3576)
    static let az04a = BoardModel(code: "AZ04A", soc: .rk3588)
    static let az04b = BoardModel(code: "AZ04B", soc: .rk3588, chip: "RK3588S2")

    /// A second product line, on silicon this bench already validates.
    ///
    /// The code is short and separator-free because it names an archive directory, leads a batch
    /// id and keys the CI image index; the vendor's name for it lives in `name`, which is what a
    /// picker and a report show. Everything else comes from `.rk3588` — PID, probe chip, eye scan,
    /// bus width — which is the row this catalog exists to make possible.
    static let core3588e = BoardModel(code: "Core3588E", name: "Mixtile Core3588E", soc: .rk3588)

    /// Every board this build knows, in the order the picker offers them.
    static let catalog: [BoardModel] = [.az05, .az07, .az08, .az04a, .az04b, .core3588e]

    /// The board a code names, or nil for one this build does not know.
    static func named(_ code: String) -> BoardModel? {
        catalog.first { $0.answersTo(code) }
    }

    /// Whether a string names this board.
    ///
    /// One rule, in one place, so no call site can invent a stricter or looser one — and two did.
    /// It answers for `--model az08` typed at a command line, and for the `board` field of a CI
    /// index this repo does not publish; the second is why it is case-insensitive rather than the
    /// exact match it used to be there. `code` is the identity behind five things at once, one of
    /// them an external system's spelling, and a casing change upstream must not be able to cost
    /// the archive a rename.
    func answersTo(_ code: String) -> Bool {
        self.code.caseInsensitiveCompare(code) == .orderedSame
    }
}

// MARK: - Naming

public extension BoardModel {

    var displayName: String { "\(name) · \(chip)" }
}

// MARK: - Capabilities

public extension BoardModel {

    /// Items requiring an unsupported capability never enter the sequence.
    func supports(_ capability: Capability) -> Bool { soc.capabilities.contains(capability) }
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
