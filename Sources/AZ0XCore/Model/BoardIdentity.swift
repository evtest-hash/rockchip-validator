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

    /// The AZ0X model code extracted from the device tree.
    var code: String? { Self.extractCode(from: model + " " + compatible) }

    /// The rule must tolerate three inconsistencies observed across five real device trees.
    static func extractCode(from text: String) -> String? {
        // Upper-case the whole text to absorb the case inconsistency.
        let found = Set(RE.all(#"(AZ0\d[AB]?)"#, in: text.uppercased()))
        // Conflicting codes are reported as unidentifiable rather than resolved by picking one.
        guard found.count == 1, let code = found.first,
              DeviceModel(rawValue: code) != nil else { return nil }
        return code
    }

    /// The "device under test" row of the report.
    var display: String {
        [code, model.isEmpty ? nil : model, serial.isEmpty ? nil : serial]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

extension DeviceModel {

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
        guard let code = identity.code else { return .unidentifiable }
        return code == rawValue ? .matched : .mismatched(actual: code)
    }
}
