import XCTest
@testable import AZ0XValidator

/// What the Dock says while nobody is looking at the window.
///
/// A validation runs for days and nothing told the operator when one ended. The console said it, and
/// only to someone already looking at the console.
@MainActor
final class DockAttentionTests: XCTestCase {

    @MainActor
    private final class Dock {
        var frontmost = false
        var badge: String? = "untouched"
        var bounced = 0
        var stopped: [Int] = []
        var attention: DockAttention!

        init() {
            var next = 100
            attention = DockAttention(
                isFrontmost: { self.frontmost },
                setBadge: { self.badge = $0 },
                bounce: { self.bounced += 1; next += 1; return next },
                stopBouncing: { self.stopped.append($0) })
        }
    }

    func testAFinishedBatchBadgesAndBouncesWhileTheWindowIsAway() {
        let d = Dock()
        d.attention.batchFinished()

        XCTAssertEqual(d.badge, "1")
        XCTAssertEqual(d.bounced, 1)
        XCTAssertEqual(d.attention.unread, 1)
    }

    /// Being called back to something you are watching happen is not a service.
    func testNothingHappensWhileTheWindowIsInFront() {
        let d = Dock()
        d.frontmost = true
        d.badge = nil

        d.attention.batchFinished()

        XCTAssertNil(d.badge)
        XCTAssertEqual(d.bounced, 0)
        XCTAssertEqual(d.attention.unread, 0)
    }

    /// The two signals are not alternatives. A second batch asks again rather than being suppressed
    /// because the Dock happens to already be bouncing.
    func testASecondBatchCountsAndAsksAgain() {
        let d = Dock()
        d.attention.batchFinished()
        d.attention.batchFinished()

        XCTAssertEqual(d.badge, "2")
        XCTAssertEqual(d.bounced, 2, "徽标和弹跳互不压制")
    }

    func testComingForwardClearsBothAndCallsOffEveryRequest() {
        let d = Dock()
        d.attention.batchFinished()
        d.attention.batchFinished()

        d.attention.windowCameForward()

        XCTAssertNil(d.badge, "零的时候必须是 nil —— \"0\" 是一个写着 0 的红点")
        XCTAssertEqual(d.stopped.count, 2, "两次请求都要撤，不能只撤最后一次")
        XCTAssertEqual(d.attention.unread, 0)
    }

    /// Activating the application for any other reason must not clear a badge that was never set,
    /// nor touch the Dock at all.
    func testComingForwardWithNothingUnreadTouchesNothing() {
        let d = Dock()
        d.badge = "untouched"

        d.attention.windowCameForward()

        XCTAssertEqual(d.badge, "untouched")
        XCTAssertTrue(d.stopped.isEmpty)
    }
}
