import Foundation

/// The link to one board: everything this app does to a board goes through here.
///
/// Named as a role rather than as a tool so it can have a second implementation. That is the shape
/// every mature hardware-test framework converged on — OpenHTF calls it a plug, labgrid a driver,
/// PyVISA a backend — and the reason is always the same: the flow and the verdicts are the parts
/// that get things wrong, and they cannot be tested against a board that takes sixty hours to
/// answer. See docs/decisions.md.
///
/// Only the five operations that actually reach the hardware are requirements. Everything derived
/// from them lives in the extension below, so it is exercised by every implementation instead of
/// being stubbed out per implementation — a fake board that reimplemented `identity()` would not
/// be testing the parsing this app really uses.
protocol BoardSession {
    /// Serial of the board this link addresses, fixed for its life.
    var serial: String { get }

    /// Runs one command on the board. The one primitive: everything textual is built on it.
    func shell(_ command: String, timeout: TimeInterval) async -> ShellResult

    /// Whether the board is reachable right now.
    var isOnline: Bool { get async }

    /// Writes text to a path on the board, verifying what arrived.
    func writeFile(_ content: String, to path: String, timeout: TimeInterval) async -> Bool

    /// Copies a file off the board.
    func pull(_ boardPath: String, to local: URL, timeout: TimeInterval) async -> Bool

    /// Runs a command and writes its raw stdout bytes to a local file.
    func execOut(_ command: String, to local: URL, timeout: TimeInterval) async -> Bool
}

/// Everything derived from the five primitives. Protocol requirements cannot carry default
/// arguments, so the call-site ergonomics live here too.
extension BoardSession {

    func sh(_ command: String, timeout: TimeInterval = 120) async -> ShellResult {
        await shell(command, timeout: timeout)
    }

    /// Returns one line of output, trimmed.
    func line(_ command: String, timeout: TimeInterval = 60) async -> String {
        await shell(command, timeout: timeout)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// nil when the output is not a number, which includes the read having failed. Callers must
    /// keep that distinction: turning nil into 0 is how an unreadable board became a passing one.
    func int(_ command: String, timeout: TimeInterval = 60) async -> Int? {
        Int(await line(command, timeout: timeout))
    }

    /// Waits for this board to come back online.
    ///
    /// `onWait` fires each time it is still absent, with how long it has been. Without it the
    /// longest of these waits — the one after flashing — was three minutes of silence with the
    /// screen still reading 刷入镜像 100%.
    func waitOnline(timeout: TimeInterval,
                    clock: any RunClock = SystemClock(),
                    onWait: ((TimeInterval) -> Void)? = nil) async -> Bool {
        let began = clock.now
        while !clock.elapsed(since: began, exceeds: timeout), !Task.isCancelled {
            if await isOnline { return true }
            onWait?(clock.now - began)
            await clock.sleep(seconds: 2)
        }
        return false
    }

    /// Seconds since the board booted.
    func uptimeSeconds() async -> Int? {
        await int("cut -d. -f1 /proc/uptime")
    }

    /// Reads the identity the board reports about itself in one round trip.
    func identity() async -> BoardIdentity {
        let raw = await line(
            "printf '%s\\n' \"$(tr -d '\\0' < /proc/device-tree/model 2>/dev/null)\" "
          + "\"$(tr '\\0' ' ' < /proc/device-tree/compatible 2>/dev/null)\" "
          + "\"$(uname -n)\"")
        let parts = raw.components(separatedBy: .newlines)
        func at(_ i: Int) -> String {
            i < parts.count ? parts[i].trimmingCharacters(in: .whitespaces) : ""
        }
        return BoardIdentity(model: at(0), compatible: at(1), uname: at(2), serial: serial)
    }

    func writeFile(_ content: String, to path: String) async -> Bool {
        await writeFile(content, to: path, timeout: 60)
    }

    @discardableResult
    func pull(_ boardPath: String, to local: URL) async -> Bool {
        await pull(boardPath, to: local, timeout: 300)
    }

    @discardableResult
    func execOut(_ command: String, to local: URL) async -> Bool {
        await execOut(command, to: local, timeout: 300)
    }
}
