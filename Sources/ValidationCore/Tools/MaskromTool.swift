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
    ///
    /// The three-second spacing is not arbitrary and was measured against hardware: two readings one
    /// second apart are weak evidence, because a board can appear, vanish and reappear inside that
    /// second. Shortening it makes this pass sooner and mean less.
    func settled(deviceID: String, clock: any RunClock = SystemClock(),
                 settle: TimeInterval = 5, timeout: TimeInterval = 20,
                 pollSeconds: TimeInterval = 3) async -> Bool {
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
            await clock.sleep(seconds: pollSeconds)
        }
        return false
    }

    /// One `--detect`, whole.
    ///
    /// The envelope carries both of its readers' answers — the OTP identity at the top level, the
    /// DDR geometry under `detect` — so it is read once and handed to both. It used to be run twice
    /// on every DDR board: once here for the identity the engine needs before it may flash, and
    /// again by T01 for the spec. Nobody decided that; the two callers sit in different layers and
    /// neither could see the other. The cost was eight seconds, and the real problem was that the
    /// serial in the report's header and the spec in its table came from two separate invocations
    /// with nothing saying they agreed.
    func detect(deviceID: String) async -> DdrCli.JSONResult {
        await runJSON("--detect", deviceID: deviceID, timeout: 120)
    }
}

extension DdrCli.Identity {
    /// Read out of a `--detect` envelope. Top level, which is where v2.7 puts these — verified
    /// against a real AZ08, where `detect` carries none of the three. An earlier revision looked
    /// inside `detect` first and fell back to the top level; that nesting was a v2.6 shape and the
    /// fallback was doing all the work.
    init?(from jr: DdrCli.JSONResult) {
        guard jr.parseError == nil,
              let cpuid = jr.json.str("cpuid"), !cpuid.isEmpty,
              let serial = jr.json.str("serial"), !serial.isEmpty
        else { return nil }
        self.init(cpuid: cpuid, serial: Self.sixteenHexDigits(serial),
                  variant: jr.json.str("chipVariant"))
    }

    /// The serial as the board itself will answer to it: sixteen hex digits.
    ///
    /// It is a 64-bit value, and the tool prints it without leading zeros while the firmware pads it
    /// to width. Measured on a real AZ07: OTP gave 883265bf7fee7c8, fifteen digits, and the board it
    /// flashed called itself 0883265bf7fee7c8 on adb. So the run addressed a name nothing answers
    /// to, T04 waited out its whole 180-second allowance and failed a board that had written
    /// correctly and booted correctly. AZ05 and AZ08 matched all along by luck — their top nibble
    /// is not zero.
    ///
    /// Fixed at the source in the tool's v3.0, which pads it — verified against the same AZ07. This
    /// stays anyway: `tools.lock` pins a version, a build pinned to an older one has to work, and
    /// this is the one string joining the two domains. It costs nothing once the tool is right.
    ///
    /// Padding rather than parsing: the two strings are the same number, and this is the width the
    /// other domain uses. Anything that is not short hex is left exactly as it came.
    private static func sixteenHexDigits(_ raw: String) -> String {
        guard raw.count < 16, raw.allSatisfy(\.isHexDigit) else { return raw }
        return String(repeating: "0", count: 16 - raw.count) + raw
    }
}

extension DdrCli: MaskromTool {}
