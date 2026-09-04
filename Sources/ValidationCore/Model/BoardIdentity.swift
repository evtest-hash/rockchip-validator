import Foundation

/// The identity a board reports through its device tree.
struct BoardIdentity: Equatable {

    /// `/proc/device-tree/model`
    let model: String
    /// `/proc/device-tree/compatible`.
    let compatible: String
    /// `uname -n`.
    let uname: String
    let serial: String

    /// The board code extracted from the device tree.
    var code: String? { Self.extractCode(from: model + " " + compatible) }

    /// Which catalog entry this device tree names.
    ///
    /// This used to be a regex, `(AZ0\d[AB]?)`, which is a rule about one product line's naming
    /// scheme rather than about what this bench validates. It cannot see a board called anything
    /// else, and no amount of adding catalog entries would have taught it to. Matching each board's
    /// declared aliases asks the catalog instead, so a board is identifiable exactly when it is
    /// known — which is the question being asked.
    ///
    /// Two or more entries matching is reported as unidentifiable rather than resolved by picking
    /// one, as before: a device tree naming two boards has told us nothing we can act on.
    ///
    /// One edge case does answer differently now, and it is worth stating rather than discovering.
    /// A device tree containing `AZ08` beside some other `AZ0`-shaped token — `AZ09`, a board that
    /// does not exist — used to come back unidentifiable, because the regex counted both tokens and
    /// saw a conflict. It now reads AZ08: a token no board is built under is not a competing claim,
    /// it is noise.
    static func extractCode(from text: String) -> String? {
        let haystack = text.uppercased()
        let hits = BoardModel.catalog.filter { board in
            board.deviceTreeAliases.contains { haystack.contains($0) }
        }
        guard hits.count == 1 else { return nil }
        return hits[0].code
    }

    /// The "device under test" row of the report.
    var display: String {
        [code, model.isEmpty ? nil : model, serial.isEmpty ? nil : serial]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

extension BoardModel {

    /// Result of the identity check.
    enum IdentityCheck: Equatable {
        case matched
        /// The board reports a different model.
        case mismatched(actual: String)
        /// The device tree could not be read, or no model code could be extracted.
        case unidentifiable
    }

    /// Whether the identity reported by the board is the model selected for this run.
    func check(_ identity: BoardIdentity) -> IdentityCheck {
        guard let reported = identity.code else { return .unidentifiable }
        return reported == code ? .matched : .mismatched(actual: reported)
    }
}
