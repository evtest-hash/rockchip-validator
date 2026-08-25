import XCTest
@testable import AZ0XCore

/// When the host stops waiting on an item bounded by a count.
///
/// T07 and T08 are judged on how many cycles the board survives. So the host may hold no opinion
/// about how long one cycle takes — not as a wall clock, and not as an inference from how quickly
/// the board has been cycling so far. Both are the same claim, and both abandon a board whose
/// cycles are slower or merely uneven, part-way through a run it would have finished, recording a
/// healthy material as having produced no result.
///
/// Two facts end the wait instead, and neither is about speed:
///
/// - the board says the test is no longer set up to run — T08's reboot service gone, T07's script
///   no longer holding a pid;
/// - the board has been **absent** longer than a board in this test may be, which is the same 300
///   seconds T08 already judges its boot-to-boot gap by. One question, one number.
final class PatienceTests: XCTestCase {

    private let t08 = "/userdata/az0x-ddr/t08_reboot"
    private let initd = "/etc/init.d/S99-az0x-reboot"

    /// A board that lets one more reboot record appear every `everyPolls` commands, and reports its
    /// service armed or not according to `armed`.
    private func pacedBoard(records: Int, everyPolls: Int, ending: String?,
                            armed: @escaping (Int) -> Bool = { _ in true },
                            onto base: ScriptedBoardSession? = nil) -> ScriptedBoardSession {
        let b = base ?? ScriptedBoardSession()
        let path = "\(t08)/progress.log"
        b.files[path] = "1000 INSTALLED"
        b.advance = { board, count in
            let shown = min(records, count / max(1, everyPolls))
            var lines = ["1000 INSTALLED"]
            if shown > 0 { for n in 1...shown { lines.append("\(1000 + n * 20) boot \(n)") } }
            if shown >= records, let ending {
                lines.append("\(1000 + (records + 1) * 20) \(ending)")
            }
            board.files[path] = lines.joined(separator: "\n")
            board.answers.removeAll { $0.match.hasPrefix("[ -x") }
            board.answers.insert(("[ -x \(self.initd) ]", armed(shown) ? "yes" : ""), at: 0)
        }
        return b
    }

    private func waitOn(_ board: ScriptedBoardSession,
                        clock: SimClock) async -> BoardTest.WaitOutcome {
        let bt = BoardTest(adb: board, directory: t08, payload: "", clock: clock)
        return await bt.waitDone(doneMarker: "STOP", pollSeconds: 15,
                                 patience: .whileTestIsRunning({
                                     await bt.rebootServiceArmed(initd: self.initd)
                                 }))
    }

    // MARK: - What is timed is absence, not slowness

    /// A board that spends almost all of its run off the bus, in stretches that each stay inside the
    /// limit. Hours of absence add up; none of it counts, because each absence ends with the board
    /// coming back.
    ///
    /// This is the distinction the whole design rests on. Time the run and this board is abandoned;
    /// time the gaps since its last record and it is abandoned; time only how long it has been
    /// **absent**, resetting on any contact, and it is carried to its end.
    func testAbsenceIsTimedPerStretchAndResetsOnAnyContact() async {
        let clock = SimClock()
        let board = pacedBoard(records: 15, everyPolls: 1, ending: "STOP target=15")
        var checks = 0
        board.online = { checks += 1; return checks % 20 == 0 }   // away 19 polls out of every 20
        let began = clock.now

        let outcome = await waitOn(board, clock: clock)

        XCTAssertEqual(outcome, .done, "每次都回得来，累计离线再久也不该放弃：\(outcome)")
        XCTAssertGreaterThan(clock.now - began, Double(Thresholds.maxOfflineSeconds) * 5,
                             "这一轮的累计离线必须远超单次上限，否则测不到「按段计时」")
    }

    /// And a board that goes and stays gone is concluded on, at that same limit — as a **verdict**.
    ///
    /// Every other way of not finishing is 未得结果, and rightly so. This one is not. Under this
    /// bench's premises the host, the USB ports and the operator are all given and the board is
    /// physically present throughout, so a board that stopped coming back failed to reboot — which
    /// is the whole of what T08 measures.
    func testABoardThatStaysAwayIsConcludedAtTheLimit() async {
        let clock = SimClock()
        let board = pacedBoard(records: 15, everyPolls: 1, ending: "STOP target=15")
        var checks = 0
        board.online = { checks += 1; return checks <= 3 }        // answers briefly, then gone
        let began = clock.now

        let outcome = await waitOn(board, clock: clock)

        guard case let .boardGone(away, lastLog) = outcome else {
            return XCTFail("走了不回来就该收尾：\(outcome)")
        }
        XCTAssertGreaterThan(away, Double(Thresholds.maxOfflineSeconds))
        XCTAssertTrue(lastLog.contains("boot"), "要带上主机最后读到的进度，判定得从它来：\(lastLog)")
        XCTAssertLessThan(clock.now - began, Double(Thresholds.maxOfflineSeconds) * 3,
                          "不该等到远超上限才收尾")
    }

    /// The item turns that into 不合格, naming the two things the absence itself decides.
    func testT08JudgesAVanishedBoardAsDefective() async {
        let clock = SimClock()
        let base = ScriptedBench.board()
        let board = pacedBoard(records: 3000, everyPolls: 1, ending: nil, onto: base)
        var checks = 0
        board.online = { checks += 1; return checks <= 6 }
        let items = BoardItems(adb: board, model: .az08, channels: 4,
                               busBitsPerChannel: 16, clock: clock)

        let r = await items.runT08(targetBoots: 3_000)

        XCTAssertTrue(r.condemnsMaterial, "起不来就是起不来：\(String(describing: r.execution))")
        XCTAssertTrue(r.criteria.contains { $0.name == "最长起回间隔" && !$0.passed },
                      "要指名是哪条判据不通过：\(r.criteria.map(\.name))")
        XCTAssertTrue(r.criteria.contains { $0.name == "跑满目标重启次数" && !$0.passed })
    }

    /// T07 likewise: a board that suspended and never woke.
    func testT07JudgesABoardThatNeverWokeAsDefective() async {
        let clock = SimClock()
        let board = ScriptedBench.board()
        board.files["/userdata/az0x-ddr/t07_suspend/progress.log"] =
            "1000 SUSPEND_SUCCESS start=0\n1017 cycle 1 rc=0 fail=0"
        var checks = 0
        board.online = { checks += 1; return checks <= 6 }
        let items = BoardItems(adb: board, model: .az08, channels: 4,
                               busBitsPerChannel: 16, clock: clock)

        let r = await items.runT07(targetCycles: 3_000)

        XCTAssertTrue(r.condemnsMaterial, String(describing: r.execution))
        XCTAssertTrue(r.criteria.contains { $0.name == "唤醒后返回" && !$0.passed },
                      "\(r.criteria.map(\.name))")
    }

    /// The limit the host waits out and the limit T08 judges by are the same number, on purpose:
    /// once a board has been absent longer than a reboot may take, that criterion is already
    /// decided and waiting longer buys nothing.
    func testTheHostWaitsExactlyAsLongAsTheCriterionAllows() {
        XCTAssertEqual(Thresholds.maxOfflineSeconds, 300,
                       "起回间隔判据和主机等待上限必须是同一个数")
    }

    /// A board that is reachable the whole time but records nothing for far longer than the limit.
    ///
    /// The separating case. Absence and progress usually arrive together — the board comes back and
    /// writes a record in the same breath — so a rule that times "no new record" looks identical to
    /// one that times "not reachable" until they are pulled apart. Here they are: this board never
    /// leaves the bus, so nothing may be concluded about it however long its count sits still. What
    /// answers for it is the service still being armed, not a clock.
    func testAnOnlineBoardWhoseCountSitsStillIsNeverTimedOut() async {
        let clock = SimClock()
        let board = ScriptedBoardSession()
        let path = "\(t08)/progress.log"
        board.files[path] = "1000 INSTALLED"
        board.answers = [("[ -x \(initd) ]", "yes")]           // armed throughout
        // Nothing at all for the first 80 commands — well past the limit — then it finishes.
        board.advance = { b, count in
            guard count > 80 else { return }
            b.files[path] = "1000 INSTALLED\n1020 boot 1\n1040 STOP target=1"
        }
        let began = clock.now

        let outcome = await waitOn(board, clock: clock)

        XCTAssertEqual(outcome, .done, "板子一直在线、服务还armed，次数不动也不能收尾：\(outcome)")
        XCTAssertGreaterThan(clock.now - began, Double(Thresholds.maxOfflineSeconds),
                             "这一轮的静止必须超过上限，否则区分不出计时对象")
    }

    // MARK: - The count proves life; it cannot prove death

    /// While the count is moving, the board is not asked anything else at all.
    ///
    /// The count is the direct evidence and it is already on screen; the liveness question exists
    /// only for the case the count cannot answer. Asking it anyway would let one bad read of a
    /// service file end a run that is visibly progressing.
    func testWhileTheCountIsMovingNothingElseIsAsked() async {
        let clock = SimClock()
        let board = pacedBoard(records: 40, everyPolls: 1, ending: "STOP target=40",
                               armed: { _ in false })

        let outcome = await waitOn(board, clock: clock)

        XCTAssertEqual(outcome, .done, "次数一直在涨，就不该去问、更不该收尾：\(outcome)")
    }

    /// A board sitting online with the count still and its reboot service gone: the test cannot
    /// continue, and that is evidence, acted on at once rather than waited out.
    func testATestThatIsNoLongerRunningIsConcludedWithoutWaiting() async {
        let clock = SimClock()
        let board = pacedBoard(records: 60, everyPolls: 5, ending: "STOP target=60",
                               armed: { shown in shown < 3 })
        let began = clock.now

        let outcome = await waitOn(board, clock: clock)

        guard case let .stopped(why) = outcome else {
            return XCTFail("服务没了就该当场收尾：\(outcome)")
        }
        XCTAssertTrue(why.contains("已不在运行"), why)
        XCTAssertLessThan(clock.now - began, Double(Thresholds.maxOfflineSeconds),
                          "有证据就立即结论，不该再等")
    }

    // MARK: - Neither ending is a verdict

    func testStoppingIsNeverAVerdictOnTheMaterial() async {
        let clock = SimClock()
        var r = ItemResult(code: "T08")
        let board = pacedBoard(records: 60, everyPolls: 5, ending: nil, armed: { $0 < 3 })
        let bt = BoardTest(adb: board, directory: t08, payload: "", clock: clock)
        let outcome = await bt.waitDone(doneMarker: "STOP", pollSeconds: 15,
                                        patience: .whileTestIsRunning({
                                            await bt.rebootServiceArmed(initd: self.initd)
                                        }))

        _ = await LongTest.settleOrFail(outcome, bt, into: &r)

        XCTAssertFalse(r.condemnsMaterial, "读不到 ≠ 不合格")
        XCTAssertNil(r.verdict)
    }

    /// T08 disarms itself just before writing its terminal marker, so a poll can land between the
    /// two and see a test that is no longer running on a run that in fact finished. The answer that
    /// exists must win.
    func testARunThatFinishedIsNotLostToTheDisarmRace() async {
        let clock = SimClock()
        let board = ScriptedBoardSession()
        board.files["\(t08)/progress.log"] = "1000 INSTALLED\n1020 boot 1\n1040 STOP target=1"
        board.answers = [("[ -x \(initd) ]", "")]      // already disarmed

        let outcome = await waitOn(board, clock: clock)
        XCTAssertEqual(outcome, .done, "结论已经写出来了，就不能因为服务先一步消失而丢掉")
    }

    // MARK: - The real T08 call site

    /// The guard on the item itself rather than on the helper: `runT08` must reach its verdict on a
    /// board that is absent for most of its run. Put a wall clock over the whole item back into that
    /// call and this fails — checked by mutation, not assumed.
    func testT08PassesOnABoardAbsentForMostOfItsRun() async {
        let clock = SimClock()
        let base = ScriptedBench.board()
        let board = pacedBoard(records: 15, everyPolls: 1, ending: "STOP target=15", onto: base)
        var checks = 0
        board.online = { checks += 1; return checks % 20 == 0 }
        let items = BoardItems(adb: board, model: .az08, channels: 4,
                               busBitsPerChannel: 16, clock: clock)

        let r = await items.runT08(targetBoots: 15)

        XCTAssertEqual(r.verdict, .passed,
                       "\(String(describing: r.execution))｜\(String(describing: r.detail))")
        XCTAssertEqual(r.measurements.first { $0.name == "重启次数" }?.value.display, "15",
                       "验收标准是次数，报告里也必须是次数")
    }
}
