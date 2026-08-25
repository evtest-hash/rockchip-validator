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
    /// a payload always says so in writing.
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

    // MARK: - How long the host waits

    /// How the host decides it has waited long enough.
    ///
    /// Never a verdict either way: an item that produced no terminal marker is 未得结果, and the
    /// board is never stopped by anything here — the payloads run to their own end whatever the
    /// host does.
    enum Patience {
        /// The payload stops itself at a declared duration, so the host can name a wall clock:
        /// that duration, plus settling and slack. T06 is the only item that works this way, and
        /// only because a duration is what it was told to run for.
        case untilDeclaredDuration(TimeInterval)

        /// Bounded by a count. The host waits while the board says the test is still set up to run,
        /// and stops only when the board says it is not.
        ///
        /// The question is whether the test is still running — never whether it is running fast
        /// enough. Any wall clock, and equally any judgement made from how quickly the board has
        /// been cycling so far, is an opinion about how long one cycle takes; a board whose cycles
        /// are simply slower, or merely uneven, then gets abandoned part-way through a run it would
        /// have finished, and a healthy material is recorded as having produced no result.
        ///
        /// The closure answers `true` still set up to run, `false` definitely not, and nil when the
        /// board cannot be asked at all — which is most of the time, because suspending and
        /// rebooting is precisely what these items do.
        case whileTestIsRunning(() async -> Bool?)
    }

    /// Wall clock for a duration-bounded item: what it declared, plus settling, plus slack.
    ///
    /// Reaching it is not a statement about the board — it says only that no result arrived. It
    /// cannot false-fail a working board: such a payload self-terminates at its declared duration,
    /// so a live board has written a terminal marker long before.
    static func budget(wallClock: Int, phases: Int = 1) -> TimeInterval {
        Double(wallClock * max(1, phases))
            + Thresholds.settleSeconds
            + Thresholds.longRunMarginSeconds
    }

    // MARK: - Is the test still running

    /// Whether the board still holds the process that was started for this item.
    ///
    /// The payload records its own pid; a pid that no longer has a `/proc` entry means the script is
    /// gone — killed, crashed, or ended without writing a terminal marker. That is a fact about the
    /// test, available at once, and it replaces waiting out a clock to discover the same thing.
    func payloadAlive() async -> Bool? {
        let pid = await read("pid").trimmingCharacters(in: .whitespacesAndNewlines)
        // No pid yet is not evidence of anything: the script may not have written it.
        guard !pid.isEmpty, pid.allSatisfy(\.isNumber) else { return nil }
        return await adb.line("[ -d /proc/\(pid) ] && echo yes").contains("yes")
    }

    /// Whether T08's reboot service is still installed and has not disarmed itself.
    func rebootServiceArmed(initd: String) async -> Bool? {
        await adb.line("[ -x \(initd) ] && [ ! -f \(directory)/stop ] && echo yes").contains("yes")
    }

    // MARK: - Polling

    /// Outcome of waiting. Each case says who decided and on what evidence.
    enum WaitOutcome: Equatable {
        /// The payload reached its own end. Hand it to the verdict — this covers a run that
        /// completed and one that stopped early on a defect it found; both have an answer.
        case done
        /// The payload said it could not continue, and why. Never a verdict on the material.
        case aborted(String)
        /// The host stopped waiting with no terminal marker in hand, and why. Says only that no
        /// result arrived — never anything about the material.
        case stopped(String)
        /// The operator left.
        case cancelled
    }

    /// Waits for the board to say it is finished.
    ///
    /// The host never judges whether the board is healthy, and never judges how fast it ought to be
    /// going. It waits for one of the three terminal markers, and for a count-bounded item it stops
    /// on one of two facts the board itself supplies: the test is no longer set up to run, or the
    /// board has been off the bus longer than a board in this test may be.
    ///
    /// What is timed is being **absent**, never being slow. Any contact at all resets it, so a board
    /// that takes as long as it likes between cycles is followed to its end for as long as it keeps
    /// coming back. Only a board that has gone and stayed gone runs the clock out.
    ///
    /// - Parameter onOffline: called each poll the board cannot be reached, with how long it has
    ///   been absent. Without it the console goes silent exactly when the operator most needs to
    ///   know whether the board is rebooting or dead.
    func waitDone(doneMarker: String,
                  pollSeconds: Int = 15,
                  patience: Patience,
                  onTick: ((String) -> Void)? = nil,
                  onOffline: ((TimeInterval) -> Void)? = nil) async -> WaitOutcome {
        // Monotonic, so the host sleeping does not consume a duration-bounded item's time.
        let began = clock.now
        var lastSeen = ""
        var awaySince: TimeInterval?

        while !Task.isCancelled {
            var giveUp: String?

            if await adb.isOnline {
                awaySince = nil
                let log = await read("progress.log")
                onTick?(log)
                if let terminal = Self.classifyTerminal(log, doneMarker: doneMarker) {
                    return Self.outcome(of: terminal)
                }
                // A new record is the board counting, and counting is proof it is running. Nothing
                // more is asked while that keeps happening.
                //
                // What it cannot prove is the opposite. A count that has not moved may be a board
                // mid-cycle or a board that has stopped, and the only thing separating them is how
                // long one cycle is supposed to take — the assumption this design exists to avoid.
                // So a still count decides nothing, and the board is asked outright instead.
                let counting = log != lastSeen
                lastSeen = log
                if !counting, case let .whileTestIsRunning(stillRunning) = patience,
                   await stillRunning() == false {
                    giveUp = "板端测试已不在运行，且没有写出结论"
                }
            } else if case .whileTestIsRunning = patience {
                let away = awaySince ?? clock.now
                awaySince = away
                onOffline?(clock.now - away)
                if clock.elapsed(since: away, exceeds: Double(Thresholds.maxOfflineSeconds)) {
                    giveUp = "板子已离线 \(Self.spell(Double(Thresholds.maxOfflineSeconds)))未返回"
                }
            }
            if case let .untilDeclaredDuration(limit) = patience,
               clock.elapsed(since: began, exceeds: limit) {
                giveUp = "等待 \(Self.spell(limit)) 后板端仍未给出结论"
            }

            if let giveUp {
                // Read once more before concluding. This is not politeness about timing: T08 writes
                // its `stop` file just before its terminal marker, so a poll landing between the two
                // sees a disarmed test on a run that in fact finished. An answer that exists must
                // never be discarded.
                let last = await adb.isOnline ? await read("progress.log") : ""
                if let terminal = Self.classifyTerminal(last, doneMarker: doneMarker) {
                    return Self.outcome(of: terminal)
                }
                return .stopped(last.isEmpty ? giveUp + "，也读不到板端进度" : giveUp)
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

    /// A span an operator reads. Now that the host follows the board's pace, these run from seconds
    /// to days, so the unit is chosen rather than fixed at hours.
    static func spell(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        if total < 3600 { return "\(total / 60) 分钟" }
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
