import Foundation

/// Prevents idle system sleep during a validation run and avoids App Nap throttling.
final class PowerAssertion {

    private var token: NSObjectProtocol?

    /// Uses `ProcessInfo.beginActivity` rather than a `caffeinate` child process.
    func begin(reason: String) {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: [
                .idleSystemSleepDisabled,      // no idle system sleep
                .userInitiated,                // exempt from App Nap throttling
                .automaticTerminationDisabled, // do not terminate us when we look idle
            ],
            reason: reason)
    }

    /// Display sleep is not prevented.
    func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }

    var isActive: Bool { token != nil }

    deinit { end() }
}

/// A monotonic clock that does not count time spent asleep.
enum Monotonic {
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Whether `seconds` of awake time have elapsed since `start`.
    static func elapsed(since start: TimeInterval, exceeds seconds: TimeInterval) -> Bool {
        now - start > seconds
    }
}
