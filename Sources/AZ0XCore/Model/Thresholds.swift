import Foundation

/// The figures that decide verdicts and liveness, none of which the operator can reach.
///
/// How *much* a run does — hours per burn-in phase, cycles, full-device writes — is not here. That
/// is the operator's to set per run and lives in `RunScale`; a run is judged against what it was
/// asked to do. What stays here is how *good* each observation has to be, which is not theirs to
/// move: raising 起回间隔 from 300 seconds would not shorten the test, it would change what counts
/// as a working board.
public enum Thresholds {

    // MARK: - Board-side progress

    /// How long a bench waits for its own board to appear on the bus, in seconds.
    ///
    /// The board was enumerated when the batch was configured and claimed before this bench began,
    /// so this only has to cover re-enumeration jitter — the same allowance a board already gets
    /// between two maskrom items. Exhausting it means the board left, which is a precondition, not
    /// a fault of the material.
    static let maskromWaitSeconds: TimeInterval = 20

    /// Window within which a board-side script must prove it is running, in seconds.
    public static let startupGraceSeconds = 20

    /// Limit for waiting on adb before reading final results, in seconds.
    public static let settleSeconds: TimeInterval = 600

    /// How long a flash may go without reporting before the console says so, in seconds.
    ///
    /// Flashing is the one item where host-clock idleness means something: it reports percent
    /// continuously and has no board-side log to consult. Its 300 s is **ours**, chosen for a
    /// progress hint — it is not an acceptance criterion and nothing is judged by it. It used to be
    /// borrowed from T08's acceptance limit for want of a separate figure, which is how one number
    /// came to serve two unrelated purposes; see decisions.md §1.
    public static let flashIdleLimitSeconds: TimeInterval = 300

    // MARK: - Per-item acceptance limits

    /// The longest a board may be off the bus, in seconds.
    ///
    /// One number with two uses, because they are the same question asked from two seats. As T08's
    /// criterion it bounds the boot-to-boot gap the board records itself. As the host's limit it
    /// bounds how long the host keeps waiting for a board that has stopped answering — past this
    /// point that criterion is already decided, so waiting longer buys nothing.
    ///
    /// Two separate figures were drafted for these and they contradicted each other: the host would
    /// patiently wait out a gap that the verdict then called a defect, and a board whose reboots ran
    /// between the two numbers was carried to the end only to be failed for it. Whether a slow
    /// reboot is acceptable is one question and gets one answer.
    ///
    /// T07 shares it. "How long may this board be absent before it is not coming back" does not
    /// change because the board is suspended rather than rebooting.
    public static let maxOfflineSeconds = 300

    /// T06 scaling phase: tolerance between the last frequency switch and the end of the phase.
    public static func scaleContinuityTolerance(flushInterval: Int) -> Int {
        max(1, flushInterval) * 3
    }

    /// T04: how long the flashed board has to report in over adb, in seconds.
    ///
    /// A **criterion**, set by the owner. Flashing is not done when the tool exits 0 — it is done
    /// when the board it wrote comes back up, and a board that never does has failed the write path
    /// this item tests. It used to be the host's patience inside T05, where it judged nothing:
    /// T05 is record-only and has no criteria to fail.
    ///
    /// Kept separate from `maxOfflineSeconds` on purpose. A first boot after flashing does one-time
    /// initialisation that a later reboot does not, so the two are different events and their
    /// numbers may move independently.
    public static let bootBackSeconds = 180

    // MARK: - Host patience during a long run

    /// Slack added to a long run's declared duration before the host stops waiting, in seconds.
    ///
    /// The payload self-terminates at its declared duration, so a board that is still working has
    /// always written a terminal marker long before this expires; the margin only has to cover
    /// board-side start-up, the final writes and clock coarseness. Half an hour is far more than
    /// any of those and needs no tuning. Basis: docs/decisions.md.
    public static let longRunMarginSeconds: TimeInterval = 1_800
}
