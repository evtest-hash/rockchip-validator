import Foundation

/// The maskrom-domain tool, named as a role so it can have a second implementation.
///
/// Same reason as `BoardSession`: T01 to T03 decide what a report says about a board, and those
/// decisions cannot be exercised against a real tool that needs a physical board in maskrom mode.
/// Only what actually reaches the hardware is a requirement — `runJSON` and enumeration; anything
/// derived from them stays in an extension so a scripted tool runs the same derivation the app does.
protocol MaskromTool {
    /// Runs one `--json` subcommand against one board.
    func runJSON(_ flag: String, deviceID: String?, timeout: TimeInterval) async -> DdrCli.JSONResult
    /// The devices enumerated in maskrom mode right now.
    func devices() async -> [DdrCli.Device]
}

extension MaskromTool {
    /// Protocol requirements cannot carry default arguments, so the ergonomics live here.
    func runJSON(_ flag: String, deviceID: String?) async -> DdrCli.JSONResult {
        await runJSON(flag, deviceID: deviceID, timeout: 600)
    }

    /// The board with this tool device id, if it is enumerated right now.
    func device(id: String) async -> DdrCli.Device? {
        await devices().first { $0.id == id }
    }
}

extension DdrCli: MaskromTool {}
