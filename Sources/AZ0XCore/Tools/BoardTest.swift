import Foundation

/// Start, polling and settling of the long runs. Reliability model: docs/architecture.md ch3.
struct BoardTest {

    let adb: any BoardSession
    /// Board-side working directory.
    let directory: String
    let payload: String
    /// Source of monotonic time and delays for the three loops below. Production passes nothing.
    var clock: any RunClock = SystemClock()

    func read(_ name: String) async -> String {
        await adb.line("cat \(directory)/\(name) 2>/dev/null")
    }

    func clean() async {
        _ = await adb.sh("rm -rf \(directory); sync")
    }

    // MARK: - Start

    static let startupGraceSeconds = Thresholds.startupGraceSeconds

    /// Pushes the payload and launches it detached under setsid. adb may disconnect afterwards.
    ///
    /// `bound` is the payload's own primary limit in whatever unit that payload counts in: seconds
    /// for T06, cycles for T07 and T08, equivalent full-device writes for E05. It was called
    /// `durationSeconds` while three of the four happened to be seconds, which E05 already
    /// contradicted.
    func start(bound: Int, extraArgs: String = "") async -> Bool {
        _ = await adb.sh("mkdir -p \(directory)")
        guard await adb.writeFile(payload, to: "\(directory)/run.sh") else { return false }
        // bash is invoked explicitly rather than relying on the shebang, which `sh run.sh` ignores.
        _ = await adb.sh("setsid bash \(directory)/run.sh \(bound) \(extraArgs) "
                       + ">/dev/null 2>&1 &", timeout: 30)

        // No `meta` file: it existed only to tell one run's leftovers from another's, which mattered
        // only for taking a run over. Nothing is taken over now — a re-open starts from scratch, and
        // the preceding flash guarantees the board is clean — so there is nothing to disambiguate.

        // Wait for the first progress record, which is the evidence that the script started.
        let began = clock.now
        while !Task.isCancelled,
              !clock.elapsed(since: began, exceeds: Double(Self.startupGraceSeconds)) {
            if !(await read("progress.log")).isEmpty { return true }
            await clock.sleep(seconds: 1)
        }
        return false
    }

    // MARK: - Terminal markers

    /// Markers a payload writes as the last line of progress.log. Contract: architecture.md ch3.
    static let abortedMarker = "ABORTED"
    static let failedMarker = "FAILED"

    /// What a terminal marker means to the host.
    enum Terminal: Equatable {
        /// `ALLDONE` / `STOP timeup` / `FAILED <reason>` — the payload reached its own end, so the
        /// verdict decides. A fail-fast stop is an end too: the test has an answer.
        case reachedEnd
        /// `ABORTED <reason>` — the payload could not run or could not continue. Never a material
        /// verdict; the reason travels to the report.
        case aborted(String)
    }

    /// Classifies progress.log by its terminal marker, or nil while the run is still going.
    ///
    /// Every payload writes through one helper that prefixes an epoch, so a line reads
    /// `<epoch> MARKER <reason…>` and the marker is a whole word at the front of the message.
    /// Matching that position rather than anywhere in the line removes a whole class of mistake:
    /// a completion word quoted inside an abort reason, or a future incident line that happens to
    /// contain a marker as a substring, can no longer end the run. Scanning backwards means a
    /// trailing blank or a stray line cannot hide the terminal either. Silence is never an ending —
    /// that is what the deadline is for.
    static func classifyTerminal(_ progressLog: String, doneMarker: String) -> Terminal? {
        for line in progressLog.components(separatedBy: .newlines).reversed() {
            // The epoch, then the message; a malformed line without the epoch still classifies.
            let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let marker = words.prefix(2).last(where: { $0 == abortedMarker
                                                          || $0 == failedMarker
                                                          || $0 == doneMarker })
            else { continue }
            guard marker == abortedMarker else { return .reachedEnd }
            let reason = words.drop(while: { $0 != abortedMarker }).dropFirst()
            return .aborted(reason.isEmpty ? abortedMarker : reason.joined(separator: " "))
        }
        return nil
    }

    /// Wall-clock budget for one long-run item: what it declared, plus settling, plus slack.
    ///
    /// Reaching this is not a statement about the board — it says only that no result arrived, so
    /// it maps to 未得结果. It cannot false-fail a working board: the payload self-terminates at
    /// its declared duration, so a live board has written a terminal marker long before.
    static func budget(wallClock: Int, phases: Int = 1) -> TimeInterval {
        Double(wallClock * max(1, phases))
            + Thresholds.settleSeconds
            + Thresholds.longRunMarginSeconds
    }

    // MARK: - Polling

    /// Outcome of waiting. Each case says who decided and on what evidence.
    enum WaitOutcome: Equatable {
        /// The payload reached its own end. Hand it to the verdict — this covers a run that
        /// completed and one that stopped early on a defect it found; both have an answer.
        case done
        /// The payload said it could not continue, and why. Never a verdict on the material.
        case aborted(String)
        /// The budget expired with no terminal marker. Says only that no result arrived.
        case timedOut(String)
        /// The operator left.
        case cancelled
    }

    /// Waits for the board to say it is finished, or for the budget to expire.
    ///
    /// The host never judges whether the board is alive. It waits for one of the three terminal
    /// markers, and if the declared budget passes without one it reports that no result arrived.
    /// A long silence is not evidence of anything: T07 suspends for most of its run and T08 is
    /// rebooting, so both look identical to a dead board from here.
    ///
    /// - Parameter deadline: total wall clock allowed, or nil for an item bounded by something
    ///   other than time (E05 is bounded by bytes written, so a time cap would be arbitrary).
    func waitDone(doneMarker: String,
                  pollSeconds: Int = 15,
                  deadline: TimeInterval? = nil,
                  onTick: ((String) -> Void)? = nil) async -> WaitOutcome {
        // Monotonic, so the host sleeping does not consume the board's budget.
        let began = clock.now
        while !Task.isCancelled {
            if await adb.isOnline {
                let log = await read("progress.log")
                onTick?(log)
                if let terminal = Self.classifyTerminal(log, doneMarker: doneMarker) {
                    return Self.outcome(of: terminal)
                }
            }
            if let deadline, clock.elapsed(since: began, exceeds: deadline) {
                // Read once more before concluding: the board may have come back moments ago, and
                // an answer that exists must not be thrown away over timing.
                let last = await adb.isOnline ? await read("progress.log") : ""
                if let terminal = Self.classifyTerminal(last, doneMarker: doneMarker) {
                    return Self.outcome(of: terminal)
                }
                return .timedOut(last.isEmpty
                    ? "等待 \(Self.hours(deadline)) 后仍读不到板端结果"
                    : "等待 \(Self.hours(deadline)) 后板端仍未给出结论")
            }
            await clock.sleep(seconds: Double(pollSeconds))
        }
        return .cancelled
    }

    private static func outcome(of terminal: Terminal) -> WaitOutcome {
        switch terminal {
        case .reachedEnd:            return .done
        case let .aborted(reason):   return .aborted(reason)
        }
    }

    /// Hours and minutes, for a message an operator reads.
    private static func hours(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60
        return m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时"
    }

    // MARK: - Settling

    /// Waits for adb to return before reading final results.
    func settle(timeout: TimeInterval = Thresholds.settleSeconds) async -> Bool {
        await adb.waitOnline(timeout: timeout, clock: clock)
    }

    /// Whether the board rebooted unexpectedly during the test.
    func rebooted(since before: String) async -> Bool? {
        guard !before.isEmpty else { return nil }
        let after = await currentBootID()
        guard !after.isEmpty else { return nil }
        return before != after
    }

    /// Intervals between adjacent progress records.
    func progressGaps(matching: String) async -> [Int] {
        let out = await adb.line(
            "grep '\(matching)' \(directory)/progress.log 2>/dev/null | awk '{print $1}'")
        let ts = out.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard ts.count >= 2 else { return [] }
        return zip(ts, ts.dropFirst()).map { $1 - $0 }
    }

    /// Retrieves raw board-side log files.
    func fetch(_ names: [String]) async -> [String: String] {
        var got: [String: String] = [:]
        for n in names {
            let txt = await adb.line("cat \(directory)/\(n) 2>/dev/null", timeout: 90)
            if !txt.isEmpty { got[n] = txt }
        }
        return got
    }

    /// Number of lines in progress.log matching a pattern.
    func count(_ pattern: String) async -> Int {
        await adb.int("grep -c '\(pattern)' \(directory)/progress.log 2>/dev/null") ?? 0
    }

    /// The board's boot_id, used to detect an unexpected reboot during a test.
    func currentBootID() async -> String {
        await adb.line("cat /proc/sys/kernel/random/boot_id")
    }
}
