import Foundation

/// What a booted board says it is, for the report's "device under test" row.
///
/// Reported, never interpreted. This used to extract a catalog code out of the device tree and
/// offer a `check` against the selected model; nothing ever called the check, and the code it
/// derived was already stated twice in the same report — in 被测型号 and in the batch id. What is
/// worth having is the board's own words beside the serial it answers to, so that is all this is.
struct BoardIdentity: Equatable {

    /// `/proc/device-tree/model`, verbatim.
    let model: String
    let serial: String

    /// The "device under test" row of the report. Missing halves are dropped rather than
    /// rendered as a gap.
    var display: String {
        [model.isEmpty ? nil : model, serial.isEmpty ? nil : serial]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
