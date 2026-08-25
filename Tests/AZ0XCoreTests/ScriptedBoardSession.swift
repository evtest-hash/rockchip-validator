import Foundation
@testable import AZ0XCore

/// A board that answers from a declared scenario instead of from hardware.
///
/// The second implementation of `BoardSession`, which is what makes the flow and the verdicts testable
/// at all: a real long item runs for hours or for thousands of cycles, and the branches that
/// matter are the ones a
/// healthy board never takes. This is the shape PyVISA's `@sim` backend uses — behaviour declared as
/// data, matched against the request — and deliberately **not** a shell interpreter. Interpreting
/// shell would mean this file encodes a belief about what the board does; declaring answers means
/// each test states it, in the open, where it can be compared against a real board.
///
/// Two properties earn their keep:
///
/// - **A missing file reads as empty, not as zero.** Every board read here goes through
///   `2>/dev/null`, so on the real board an absent file yields no output. That is exactly how a
///   healthy T06 behaves — `scaleC.log` is only created when a frequency switch fails — and reading
///   it as `0` instead of as "no answer" was a live misclassification.
/// - **`shell` answers regardless of `online`.** Real adb fails when the device is away; here the
///   two are independent, because the liveness gate the production code actually uses is `isOnline`
///   and that is what these tests exercise. A scenario that needs a failing read declares it.
/// - **An uncovered command fails loudly.** Anything the scenario did not declare lands in
///   `unmatched` rather than quietly returning empty. A test asserting `unmatched.isEmpty` therefore
///   pins what this app asks a board: change the flow and the test says so.
final class ScriptedBoardSession: BoardSession, @unchecked Sendable {

    let serial: String

    /// Files the board holds, by absolute path. Absent means the read comes back empty.
    var files: [String: String] = [:]

    /// Answers for commands that are not plain file reads, matched by substring, first match wins.
    /// An empty reply is a real answer: it means the board printed nothing.
    var answers: [(match: String, reply: String)] = []

    /// Whether the link is up, asked afresh every time. A closure rather than a set of indices
    /// because the cases that matter are stated as conditions, not positions: T07 is offline for
    /// most of its run and T08 for much of its own, which is exactly why being unreachable is
    /// never treated as evidence of anything.
    var online: () -> Bool = { true }

    /// Runs before each command, given the number of commands already answered. This is where a
    /// scenario advances: it edits `files` so the board appears to make progress. Driven by the
    /// count rather than by a clock, so a test is deterministic without a virtual clock.
    var advance: ((ScriptedBoardSession, Int) -> Void)?

    /// Everything this board was asked, and what the scenario did not cover.
    ///
    /// Guarded for the same reason the maskrom double is: a batch runs several benches at once, and
    /// a double that records has to survive being used the way the real thing is.
    private let recording = NSLock()
    private var logStore: [String] = []
    private var unmatchedStore: [String] = []
    private var onlineCheckCount = 0
    private var writtenStore: [String: String] = [:]

    /// Every command asked, in order.
    var log: [String] { recording.lock(); defer { recording.unlock() }; return logStore }
    /// Commands the scenario did not cover.
    var unmatched: [String] { recording.lock(); defer { recording.unlock() }; return unmatchedStore }
    var onlineChecks: Int { recording.lock(); defer { recording.unlock() }; return onlineCheckCount }
    /// Paths written with `writeFile`, which is how the payload reaches the board.
    var written: [String: String] { recording.lock(); defer { recording.unlock() }; return writtenStore }

    private func record(_ body: () -> Void) {
        recording.lock()
        defer { recording.unlock() }
        body()
    }

    init(serial: String = "34376b2c031e323e") {
        self.serial = serial
    }

    // MARK: - BoardSession

    func shell(_ command: String, timeout: TimeInterval) async -> ShellResult {
        advance?(self, log.count)
        record { logStore.append(command) }

        // `rm -rf` / `mkdir` / launching the payload: acknowledged, nothing to say.
        if command.hasPrefix("rm -rf") || command.hasPrefix("mkdir -p")
            || command.contains("setsid bash") {
            return Self.result("")
        }
        if let path = Self.readPath(of: command) {
            guard let body = files[path] else { return Self.result("", exitCode: 1) }
            return Self.result(body)
        }
        if let answer = answers.first(where: { command.contains($0.match) }) {
            return Self.result(answer.reply)
        }
        record { unmatchedStore.append(command) }
        return Self.result("", exitCode: 127)
    }

    var isOnline: Bool {
        get async {
            record { onlineCheckCount += 1 }
            return online()
        }
    }

    func writeFile(_ content: String, to path: String, timeout: TimeInterval) async -> Bool {
        record { writtenStore[path] = content }
        return true
    }

    func pull(_ boardPath: String, to local: URL, timeout: TimeInterval) async -> Bool {
        try? (files[boardPath] ?? "").write(to: local, atomically: true, encoding: .utf8)
        return files[boardPath] != nil
    }

    func execOut(_ command: String, to local: URL, timeout: TimeInterval) async -> Bool {
        try? Data().write(to: local)
        return true
    }

    // MARK: - Helpers

    /// The path of a plain `cat <path>` read, or nil when the command is something else.
    /// Deliberately narrow: only the one shape `BoardTest.read` produces is recognised, so a
    /// different kind of read has to be declared rather than being guessed at here.
    private static func readPath(of command: String) -> String? {
        guard command.hasPrefix("cat ") else { return nil }
        let rest = command.dropFirst(4)
        guard let path = rest.split(whereSeparator: \.isWhitespace).first.map(String.init),
              // `cat a/*.log | grep …` is not a plain read; let the scenario answer it.
              !path.contains("*"), !rest.contains("|") else { return nil }
        return path
    }

    private static func result(_ stdout: String, exitCode: Int32 = 0) -> ShellResult {
        ShellResult(exitCode: exitCode, stdout: stdout, stderr: "", duration: 0,
                    timedOut: false, cancelled: false, outputTruncated: false)
    }
}
