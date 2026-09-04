import XCTest
@testable import ValidationCore

/// Waiting for one board to re-enumerate and hold still, at the level that decides it.
///
/// `settled` gates every maskrom item — the engine records 未在预期时间内重新枚举 and stops the
/// run when it answers false — and until now nothing exercised it: the only call site takes the
/// defaults, so both the two-consecutive-readings rule and the pacing were assertions in a comment.
/// What makes them testable is that the pacing is the loop's own, so a virtual clock reaches it.
final class SettlingTests: XCTestCase {

    /// A maskrom tool whose enumeration is a declared sequence, one entry consumed per reading.
    ///
    /// Same discipline as `ScriptedMaskromTool`: presence is declared, never computed. Readings past
    /// the end of the script hold `then`, which is what a board that simply never returns looks
    /// like. Each reading records the clock it was taken at, so the spacing is assertable.
    final class EnumerationScript: MaskromTool, @unchecked Sendable {
        static let board = DdrCli.Device(id: "002-1.4-2207-350e-NA", pid: "0x350e")

        private let clock: any RunClock
        private var script: [Bool]
        private let then: Bool
        private(set) var readAt: [TimeInterval] = []

        /// - Parameters:
        ///   - present: one entry per reading — whether the board is enumerated at that reading.
        ///   - then: what every reading after the script answers.
        init(present: [Bool], then: Bool = false, clock: any RunClock) {
            self.script = present
            self.then = then
            self.clock = clock
        }

        func devices() async -> [DdrCli.Device] {
            readAt.append(clock.now)
            let present = script.isEmpty ? then : script.removeFirst()
            return present ? [Self.board] : []
        }

        func runJSON(_ flag: String, deviceID: String?,
                     timeout: TimeInterval) async -> DdrCli.JSONResult {
            XCTFail("settled() 不该运行子命令，它只看枚举：\(flag)")
            return DdrCli.JSONResult(json: [:], exitCode: 127, raw: "", parseError: "不该被调用")
        }
    }

    private func settle(_ tool: EnumerationScript, clock: SimClock) async -> Bool {
        await tool.settled(deviceID: EnumerationScript.board.id, clock: clock)
    }

    // MARK: - Two readings, not one

    /// A board mid-enumeration answers once and then disappears again, so one sighting is not it.
    func testOneSightingIsNotSettled() async {
        let clock = SimClock()
        // Present, gone, present, present: the second sighting is the first that has a predecessor.
        let tool = EnumerationScript(present: [true, false, true, true], clock: clock)

        let settled = await settle(tool, clock: clock)

        XCTAssertTrue(settled)
        XCTAssertEqual(tool.readAt.count, 4, "第一次看见后消失，计数必须归零重来")
    }

    /// A board that flickers is never settled, however long it is watched.
    func testAFlickeringBoardNeverSettles() async {
        let clock = SimClock()
        let tool = EnumerationScript(present: [true, false, true, false, true, false, true],
                                     clock: clock)

        let settled = await settle(tool, clock: clock)

        XCTAssertFalse(settled, "隔次出现不是稳定")
    }

    /// The case the engine turns into 未得结果 rather than a verdict against the material.
    func testABoardThatNeverComesBackTimesOut() async {
        let clock = SimClock()
        let tool = EnumerationScript(present: [], then: false, clock: clock)

        let settled = await settle(tool, clock: clock)

        XCTAssertFalse(settled)
        // settle 5 then readings at +0…+18, the next one past the 20s budget: seven chances.
        XCTAssertEqual(tool.readAt, [5, 8, 11, 14, 17, 20, 23])
    }

    // MARK: - The pacing is the evidence

    /// The spacing is what makes two readings mean anything, so it is pinned rather than described:
    /// shortening it would make this pass sooner and mean less, and that is a test failure here.
    func testReadingsAreThreeSecondsApartAfterTheSettleDelay() async {
        let clock = SimClock()
        let tool = EnumerationScript(present: [false, true, true], clock: clock)

        let settled = await settle(tool, clock: clock)

        XCTAssertTrue(settled)
        XCTAssertEqual(tool.readAt, [5, 8, 11], "首读在 settle 之后，其后每读间隔 3 秒")
        XCTAssertEqual(clock.now, 11, "认定稳定后不再多睡一轮")
    }

    /// And the spacing is a parameter, not a constant, so a caller that knows better can say so.
    func testTheCallerCanSetTheSpacing() async {
        let clock = SimClock()
        let tool = EnumerationScript(present: [true, true], clock: clock)

        let settled = await tool.settled(deviceID: EnumerationScript.board.id, clock: clock,
                                         settle: 2, timeout: 20, pollSeconds: 7)

        XCTAssertTrue(settled)
        XCTAssertEqual(tool.readAt, [2, 9])
    }
}
