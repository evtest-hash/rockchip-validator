import XCTest
@testable import RockchipValidator
@testable import ValidationCore

/// The one thing standing between Cmd+Q and hours of burn-in.
///
/// There is no stop inside the application, by design, which left quitting as the only way to
/// interrupt a run — and it was unguarded: the process ended at once, no report, no record, and
/// nothing on screen had said what that would cost.
@MainActor
final class QuitGuardTests: XCTestCase {

    private func bench(startedAgo seconds: TimeInterval?, now: Date) -> Bench {
        let plan = RunPlan(batchID: "b", model: .az08, flow: .ddr,
                           items: TestItem.ddrItems, burninPhases: Set(BurninPhase.allCases),
                           deviceID: "002-1.4-2207-350e-NA")
        let b = Bench(deviceID: plan.deviceID, plan: plan)
        b.startedAt = seconds.map { now.addingTimeInterval(-$0) }
        return b
    }

    private func message(_ decision: QuitDecision) -> String? {
        if case let .ask(m) = decision { return m }
        return nil
    }

    // MARK: - When it gets out of the way

    func testNothingRunningQuitsWithoutAsking() {
        XCTAssertEqual(QuitGuard.decision(forQuitting: [], now: Date()), .allow)
    }

    func testAFinishedBoardIsNotSomethingToLose() {
        let now = Date()
        let b = bench(startedAgo: 3600, now: now)
        b.isFinished = true
        XCTAssertEqual(QuitGuard.decision(forQuitting: [b], now: now), .allow,
                       "报告已经写完了，退出不损失任何东西")
    }

    /// `refuse(_:)` marks the bench finished and nothing ever ran on it. Asking about a board that
    /// never started would train the operator to click through the dialog.
    func testARefusedBoardIsNotSomethingToLose() {
        let now = Date()
        let b = bench(startedAgo: nil, now: now)
        b.refuse("板卡不在 maskrom")
        XCTAssertEqual(QuitGuard.decision(forQuitting: [b], now: now), .allow)
    }

    // MARK: - When it asks

    func testOneRunningBoardIsNamedWithWhatItHasSpent() {
        let now = Date()
        let m = message(QuitGuard.decision(forQuitting: [bench(startedAgo: 3 * 3600 + 12 * 60,
                                                               now: now)], now: now))
        XCTAssertNotNil(m)
        XCTAssertTrue(m?.contains("有 1 块板正在验证") == true, m ?? "")
        XCTAssertTrue(m?.contains("已运行 3 小时 12 分") == true,
                      "已运行多久是操作员损失的度量：\n\(m ?? "")")
        XCTAssertTrue(m?.contains("不生成报告") == true && m?.contains("无法续跑") == true,
                      "代价要写明，不能只问「确定吗」：\n\(m ?? "")")
    }

    /// The earliest start, not the latest: what is at stake is the longest-running board.
    func testTheElapsedTimeIsTheEarliestStart() {
        let now = Date()
        let benches = [bench(startedAgo: 600, now: now),
                       bench(startedAgo: 5 * 3600, now: now),
                       bench(startedAgo: 1800, now: now)]
        let m = message(QuitGuard.decision(forQuitting: benches, now: now))
        XCTAssertTrue(m?.contains("有 3 块板正在验证") == true, m ?? "")
        XCTAssertTrue(m?.contains("已运行 5 小时 0 分") == true, m ?? "")
    }

    /// A board bound but not yet started has no elapsed time to report; it is still a board to warn
    /// about, and the sentence has to read without the clause.
    func testARunningBoardWithNoStartTimeStillCounts() {
        let now = Date()
        let m = message(QuitGuard.decision(forQuitting: [bench(startedAgo: nil, now: now)], now: now))
        XCTAssertEqual(m?.contains("有 1 块板正在验证。"), true, m ?? "")
        XCTAssertEqual(m?.contains("已运行"), false, "没有开始时间就不要编一个：\n\(m ?? "")")
    }

    func testOnlyRunningBoardsAreCounted() {
        let now = Date()
        let running = bench(startedAgo: 60, now: now)
        let done = bench(startedAgo: 60, now: now); done.isFinished = true
        let m = message(QuitGuard.decision(forQuitting: [running, done, running], now: now))
        XCTAssertTrue(m?.contains("有 2 块板正在验证") == true, m ?? "")
    }

    // MARK: - The answer is honoured

    func testTheOperatorsAnswerDecidesAndNothingElseDoes() {
        let now = Date()
        let plan = RunPlan(batchID: "b", model: .az08, flow: .ddr, items: TestItem.ddrItems,
                           burninPhases: Set(BurninPhase.allCases), deviceID: "002-1.4")
        let state = AppState()
        state.batches = [Batch(batchID: "b", model: .az08, flow: .ddr, items: TestItem.ddrItems,
                               burninPhases: Set(BurninPhase.allCases),
                               deviceIDs: [plan.deviceID], folder: nil)]

        for (answer, expected) in [(false, NSApplication.TerminateReply.terminateCancel),
                                   (true, .terminateNow)] {
            let guard_ = QuitGuard()
            guard_.app = state
            var asked = 0
            guard_.confirmQuit = { _ in asked += 1; return answer }
            XCTAssertEqual(guard_.applicationShouldTerminate(NSApplication.shared), expected)
            XCTAssertEqual(asked, 1, "必须问，且只问一次")
        }
    }

    /// With nothing running the operator is not asked at all.
    func testAQuietBenchIsNotInterrogated() {
        let guard_ = QuitGuard()
        guard_.app = AppState()
        var asked = 0
        guard_.confirmQuit = { _ in asked += 1; return false }
        XCTAssertEqual(guard_.applicationShouldTerminate(NSApplication.shared), .terminateNow)
        XCTAssertEqual(asked, 0)
    }

    /// No state attached means no batch was ever started, so there is nothing to guard.
    func testAGuardWithNoStateDoesNotBlockTheQuit() {
        let guard_ = QuitGuard()
        guard_.confirmQuit = { _ in XCTFail("没有状态可读时不该弹窗"); return false }
        XCTAssertEqual(guard_.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }
}
