import Foundation

/// Monotonic seconds and delays for the polling loops.
///
/// Named `RunClock` rather than `Clock` on purpose: Swift's own `Clock` protocol is available at the
/// deployment target, so a module-local type of that name would shadow it for every later reader.
/// Conforming to it would not help either — the standard library ships `ContinuousClock` and
/// `SuspendingClock` but no test clock, so a virtual one has to be written whichever protocol this
/// seam is spelled against.
///
/// This is not a convenience. Without it the only thing a test can reach is a loop that finds its
/// answer on the first or second poll, and a real long run polls thousands of times across many
/// hours. The behaviour that matters — that a board is carried all the way to its own end and a
/// healthy one is never reported as 未得结果 — is unreachable at wall clock. What a virtual clock
/// removes is the waiting, never the logic: the loop still runs every iteration, still reads the
/// board, still decides. See docs/architecture.md 第 4 章.
protocol RunClock {
    /// Seconds on a monotonic scale. Only differences are meaningful.
    var now: TimeInterval { get }
    func sleep(nanoseconds: UInt64) async
}

extension RunClock {
    /// Whether `seconds` have elapsed since `start`.
    func elapsed(since start: TimeInterval, exceeds seconds: TimeInterval) -> Bool {
        now - start > seconds
    }

    func sleep(seconds: TimeInterval) async {
        await sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

/// Production: real time that does not count the host being asleep, so a closed lid does not
/// consume a board's budget.
struct SystemClock: RunClock {
    var now: TimeInterval { Monotonic.now }

    func sleep(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }
}
