import Foundation

/// All thresholds affecting verdicts and liveness. Basis of every value: docs/decisions.md.
enum Thresholds {

    // MARK: - Board-side progress

    /// Window within which a board-side script must prove it is running, in seconds.
    static let startupGraceSeconds = 20

    /// Limit for waiting on adb before reading final results, in seconds.
    static let settleSeconds: TimeInterval = 600

    /// How long a flash may go without reporting before the console says so, in seconds.
    ///
    /// Flashing is the one item where host-clock idleness means something: it reports percent
    /// continuously and has no board-side log to consult. Its 300 s is **ours**, chosen for a
    /// progress hint — it is not an acceptance criterion and nothing is judged by it. It used to be
    /// borrowed from T08's acceptance limit for want of a separate figure, which is how one number
    /// came to serve two unrelated purposes; see decisions.md §1.
    static let flashIdleLimitSeconds: TimeInterval = 300

    // MARK: - Per-item acceptance limits

    /// T08: upper bound on the longest boot-to-boot gap, in seconds.
    static let t08MaxBootGapSeconds = 300

    /// T06 scaling phase: tolerance between the last frequency switch and the end of the phase.
    static func scaleContinuityTolerance(flushInterval: Int) -> Int {
        max(1, flushInterval) * 3
    }

    // MARK: - Long-run scale

    /// Duration of one board-side long-run phase, in seconds: 12 hours.
    static let longRunSeconds = 43_200

    /// T07 and T08 are bounded by how many cycles the board survives, not by how many hours pass.
    /// A count is what the test is actually about, and it is comparable between boards — two boards
    /// that both "survived 12 hours" may have done 2571 and 1700 cycles, which the report could not
    /// tell apart while the count was only a measurement.
    static let longRunCycles = 3_000

    /// How long the host waits on a count-bounded item before giving up. **Not an acceptance
    /// standard**: T07 and T08 are judged on cycles alone and no clock enters their verdict. This
    /// only decides when the bench stops waiting and says 未得结果, which it must do — otherwise a
    /// board that died mid-item leaves the polling loop running forever and no report is produced.
    ///
    /// A board is never stopped by it: the payloads run to their target count whatever the clock
    /// says. Exceeding this means we stopped watching, so the result carries the achieved count and
    /// can never read as a defect. For T08 the reboot service is still removed on the way out.
    ///
    /// Its own literal rather than sharing `longRunSeconds`, so moving one cannot move the other.
    static let longRunPatienceSeconds = 43_200

    /// Slack added to a long run's declared duration before the host stops waiting, in seconds.
    ///
    /// The payload self-terminates at its declared duration, so a board that is still working has
    /// always written a terminal marker long before this expires; the margin only has to cover
    /// board-side start-up, the final writes and clock coarseness. Half an hour is far more than
    /// any of those and needs no tuning. Basis: docs/decisions.md.
    static let longRunMarginSeconds: TimeInterval = 1_800

    /// E05 is scaled by equivalent full-device writes rather than by time.
    static let emmcTargetN = 20
}
