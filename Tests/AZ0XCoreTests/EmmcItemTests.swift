import XCTest
@testable import AZ0XCore

/// The eMMC flow, E02 to E06, against a declared part.
///
/// The port's real work was not moving the code — it was deciding, for each check, which of the two
/// lists it belongs in. These tests are where those decisions are stated: what the part did, and
/// whether the run was worth judging. The first generation had one list, so "the health registers
/// say this part is worn out" and "we could not read the health registers" produced the same
/// conclusion, and the second one condemned a part on the strength of our own read having failed.
final class EmmcItemTests: XCTestCase {

    private func items(_ board: ScriptedBoardSession) -> EmmcItems {
        EmmcItems(adb: board, clock: SimClock())
    }

    // MARK: - E02: what the registers say, and whether we could read them

    func testAHealthyPartPassesAndRecordsItsIdentity() async {
        let board = ScriptedEmmc.board()
        let r = await items(board).runE02()

        XCTAssertEqual(r.verdict, .passed, r.detail ?? "")
        XCTAssertEqual(r.criteria.count, 2, "判据只有两条：EOL 状态和寿命消耗")
        XCTAssertTrue(r.measurements.contains { $0.name == "型号" })
        XCTAssertTrue(r.measurements.contains { $0.name == "总线位宽" },
                      "总线协商结果要记下来：\(r.measurements.map(\.name))")
        XCTAssertTrue(board.unmatched.isEmpty, "场景没覆盖：\(board.unmatched)")
    }

    /// The part reports itself worn out. That is a verdict.
    func testAWornPartIsJudgedDefective() async {
        let r = await items(ScriptedEmmc.board(lifeTime: "0x0B 0x03")).runE02()

        XCTAssertTrue(r.condemnsMaterial, String(describing: r.execution))
        XCTAssertTrue(r.criteria.contains { $0.name == "寿命消耗等级" && !$0.passed })
    }

    func testAnEolWarningIsJudgedDefective() async {
        let r = await items(ScriptedEmmc.board(preEol: "0x02")).runE02()

        XCTAssertTrue(r.condemnsMaterial)
        XCTAssertTrue(r.criteria.contains { $0.name == "pre_eol_info" && !$0.passed })
    }

    /// And the case the split exists for: the registers could not be read at all.
    ///
    /// Nothing is known about this part. Reporting that as a defect is the mistake this whole
    /// iteration was started over.
    func testAnUnreadableBusNegotiationIsNotAVerdict() async {
        let r = await items(ScriptedEmmc.board(ios: "")).runE02()

        XCTAssertFalse(r.condemnsMaterial, "读不到 debugfs 不是这颗器件的毛病")
        XCTAssertNil(r.verdict)
        XCTAssertTrue(r.detail?.contains("总线协商结果可读") == true, r.detail ?? "")
    }

    // MARK: - E03: measured, never judged

    func testPerformanceIsRecordedAndNotJudged() async {
        let board = ScriptedEmmc.board()
        let r = await items(board).runE03()

        XCTAssertEqual(r.verdict, .noCriterion, "读写性能没有自动判据，按规格书判读")
        XCTAssertTrue(r.criteria.isEmpty)
        for name in ["顺序读", "顺序写", "随机读 4K", "随机写 4K"] {
            XCTAssertTrue(r.measurements.contains { $0.name == name }, name)
        }
        XCTAssertTrue(r.measurements.contains { $0.name == "随机读 4K IOPS" },
                      "4K 的两项要带 IOPS")
        XCTAssertTrue(board.unmatched.isEmpty, "场景没覆盖：\(board.unmatched)")
    }

    // MARK: - E04: corruption is the part's; not writing enough is ours

    func testAVerifyFailureIsAVerdict() async {
        let r = await items(ScriptedEmmc.board(verifyFails: true)).runE04()

        XCTAssertTrue(r.condemnsMaterial, String(describing: r.execution))
        XCTAssertTrue(r.criteria.contains { $0.name == "校验错误行" && !$0.passed })
    }

    /// fio wrote a quarter of what it was told to and read nothing back. Nothing was verified, so
    /// there is nothing to conclude — and in particular no grounds to call the part bad.
    func testACheckThatNeverRanIsNotAVerdict() async {
        let r = await items(ScriptedEmmc.board(shortWrite: true)).runE04()

        XCTAssertFalse(r.condemnsMaterial)
        XCTAssertNil(r.verdict)
        XCTAssertTrue(r.validity.contains { $0.name == "确实写满 256M" && !$0.passed })
    }

    func testAGoodVerifyPasses() async {
        let r = await items(ScriptedEmmc.board()).runE04()
        XCTAssertEqual(r.verdict, .passed, r.detail ?? "")
    }

    // MARK: - E05: bounded by how much it survives writing

    func testTheBurnInPassesWhenItReachesItsTargetWithNoCorruption() async {
        let board = ScriptedEmmc.board()
        let r = await items(board).runE05(targetN: 20)

        XCTAssertEqual(r.verdict, .passed, r.detail ?? String(describing: r.execution))
        XCTAssertTrue(r.criteria.contains { $0.name == "写满目标量" && $0.passed })
        XCTAssertTrue(r.measurements.contains { $0.name == "等效全盘写" })
    }

    /// Corruption found while writing. The board says so itself and stops.
    func testCorruptionDuringTheBurnInIsAVerdict() async {
        let board = ScriptedEmmc.board(burninLog: """
        1000 PLAN target=20 dirs=5 settle=1
        1001 LOOP 1 written=14800MB
        1002 VERIFYFAIL dest2
        1003 FAILED VERIFYFAIL
        """)
        board.answers.insert(("grep -c 'VERIFYFAIL'", "1"), at: 0)
        let r = await items(board).runE05(targetN: 20)

        XCTAssertTrue(r.condemnsMaterial, String(describing: r.execution))
        XCTAssertTrue(r.criteria.contains { $0.name == "md5 校验失败" && !$0.passed })
    }

    /// The device size could not be read, so there was never a target to write. Ours, not the part's.
    func testWithoutADeviceSizeThereIsNoJudgement() async {
        let board = ScriptedEmmc.board(burninLog: """
        1000 DEVSIZEFAIL
        1001 ABORTED DEVSIZEFAIL
        """)
        let r = await items(board).runE05(targetN: 20)

        XCTAssertFalse(r.condemnsMaterial)
        XCTAssertNil(r.verdict)
    }
}
