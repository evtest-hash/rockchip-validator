import Foundation
@testable import AZ0XCore

/// Virtual time: a sleep advances the clock by exactly its own duration and returns at once.
///
/// This removes the waiting and nothing else. The loop under test still runs every one of its
/// iterations, still accumulates elapsed time from its own pacing, still compares that against the
/// budget, and still decides — which is why a run of ~13 000 polls can be asserted on at all. The
/// board's state advances by how many times it was asked, never by this clock, so no test can move
/// the board and the clock together into a state the two could not reach on their own.
final class SimClock: RunClock, @unchecked Sendable {

    private let lock = NSLock()
    private var value: TimeInterval

    init(from start: TimeInterval = 0) { value = start }

    var now: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func sleep(nanoseconds: UInt64) async {
        // Scoped rather than lock/unlock: taking a lock by hand across an async boundary is an
        // error in Swift 6, and this method is the one that has an await after it.
        lock.withLock { value += TimeInterval(nanoseconds) / 1_000_000_000 }
        // A real sleep lets other work run; keep that so a loop under test is not a tight spin.
        await Task.yield()
    }
}
