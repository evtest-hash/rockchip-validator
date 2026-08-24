import Foundation

/// Monotonic seconds and delays for the polling loops.
///
/// Named `RunClock` rather than `Clock` on purpose: Swift's own `Clock` protocol exists in the SDK
/// from macOS 13, and a module-local type of the same name would shadow it for every later reader.
/// It also would not help — the standard library ships `ContinuousClock` and `SuspendingClock` but
/// no test clock, so a virtual one has to be written either way, which is why this seam does not
/// depend on raising the deployment target.
///
/// This is not a convenience. Without it the only thing a test can reach is a loop that finds its
/// answer on the first or second poll, and a real long run polls about 4 300 times over twelve
/// hours. The behaviour that matters — that all that accumulated time is still inside the budget,
/// so a healthy board is not reported as 未得结果 — is unreachable at wall clock. What a virtual
/// clock removes is the waiting, never the logic: the loop still runs every iteration, still
/// accumulates, still compares against the budget, still decides. See docs/architecture.md 第 4 章.
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
