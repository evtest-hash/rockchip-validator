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

    /// Waits for one board to re-enumerate and hold still before its next item runs.
    ///
    /// Addressed by the tool's device id, whose port chain survives re-enumeration; the USB address
    /// inside it used to move between boards of one model. Stability is two identical readings, not
    /// one: a board mid-enumeration answers once and then disappears again.
    func settled(deviceID: String, clock: any RunClock = SystemClock(),
                 settle: TimeInterval = 5, timeout: TimeInterval = 20) async -> Bool {
        await clock.sleep(seconds: settle)
        let began = clock.now
        var seen = 0
        while !clock.elapsed(since: began, exceeds: timeout), !Task.isCancelled {
            if await device(id: deviceID) != nil {
                seen += 1
                if seen >= 2 { return true }
            } else {
                seen = 0
            }
            await clock.sleep(seconds: 1)
        }
        return false
    }

    /// What the board says about itself while still in maskrom: its OTP identity.
    func identity(deviceID: String) async -> DdrCli.Identity? {
        let jr = await runJSON("--detect", deviceID: deviceID, timeout: 120)
        guard jr.parseError == nil else { return nil }
        let det = jr.json.dict("detect") ?? jr.json
        guard let cpuid = det.str("cpuid") ?? jr.json.str("cpuid"),
              let serial = det.str("serial") ?? jr.json.str("serial"),
              !cpuid.isEmpty, !serial.isEmpty else { return nil }
        return DdrCli.Identity(cpuid: cpuid, serial: serial,
                               variant: det.str("chipVariant") ?? jr.json.str("chipVariant"))
    }
}

extension DdrCli: MaskromTool {}
