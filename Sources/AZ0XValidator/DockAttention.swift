import Foundation

/// What the Dock says while nobody is looking at the window.
///
/// A validation runs for days and the operator is not at the machine for most of it. The console is
/// the whole of what the application had to say when a batch ended, and it says it only to someone
/// already looking at it.
///
/// Two signals, independent of each other. The badge persists, so a count survives a night; the
/// bounce is what someone in the room notices. A batch finishing does both.
///
/// Batches, not boards: a board failing early frees its socket, but nothing needs doing about it
/// until someone is at the bench anyway — and they will see the console when they get there.
@MainActor
final class DockAttention {

    /// Injected, all four. `NSApp` does not exist in a test, and whether the window is in front is
    /// the entire condition this turns on.
    private let isFrontmost: () -> Bool
    private let setBadge: (String?) -> Void
    private let bounce: () -> Int
    private let stopBouncing: (Int) -> Void

    private(set) var unread = 0
    /// Every outstanding attention request, so they can all be called off at once. A second batch
    /// finishing asks again rather than being suppressed because the Dock happens to be bouncing:
    /// the two signals are not alternatives to each other.
    private var requests: [Int] = []

    init(isFrontmost: @escaping () -> Bool,
         setBadge: @escaping (String?) -> Void,
         bounce: @escaping () -> Int,
         stopBouncing: @escaping (Int) -> Void) {
        self.isFrontmost = isFrontmost
        self.setBadge = setBadge
        self.bounce = bounce
        self.stopBouncing = stopBouncing
    }

    /// Every board in one batch has finished, whatever each of them concluded.
    func batchFinished() {
        // Watching it happen is not something to be called back for.
        guard !isFrontmost() else { return }
        unread += 1
        setBadge("\(unread)")
        requests.append(bounce())
    }

    /// The window came forward. The console is a better account of what happened than a number is,
    /// so there is nothing left for either signal to do.
    func windowCameForward() {
        guard unread > 0 || !requests.isEmpty else { return }
        unread = 0
        // nil, never "0" — `badgeLabel` is a string, and "0" is a red dot with a nought in it.
        setBadge(nil)
        requests.forEach(stopBouncing)
        requests.removeAll()
    }
}

#if canImport(AppKit)
import AppKit

extension DockAttention {
    /// The shipping one. `.criticalRequest` bounces until the window is brought forward, which is
    /// the point: a finished batch means every socket on the bench is idle.
    static var live: DockAttention {
        DockAttention(isFrontmost: { NSApp.isActive },
                      setBadge: { NSApp.dockTile.badgeLabel = $0 },
                      bounce: { NSApp.requestUserAttention(.criticalRequest) },
                      stopBouncing: { NSApp.cancelUserAttentionRequest($0) })
    }
}
#endif
