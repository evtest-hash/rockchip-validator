import XCTest
@testable import ValidationCore

/// The whole DDR sequence, run through the real item code against a declared board, and rendered.
///
/// Not a unit test of anything: it exercises T01 to T08 exactly as the engine will, then reads the
/// report as a document. That is the only way to judge whether a check ended up in the right list —
/// the question "is 变频实际发生 a criterion or a validity check" is much easier to answer by looking
/// at what the report says than in the abstract.
///
/// Set `REPORT_DUMP_DIR` to write the three reports out and read them.
final class WholeFlowReportTests: XCTestCase {

    private let ddrDir = "/userdata/az0x-ddr"

    // MARK: - A board that behaves

    private func healthyTool() -> ScriptedMaskromTool {
        ScriptedMaskromTool([
            "--detect": .init(json: ["detect": ["pass": true, "type": "LPDDR4X", "capacityMB": 8192,
                                                "channels": 4, "csPerDie": 1,
                                                "tier": "uniqueByCoarse",
                                                "cfg": "lpddr4x_2112MHz_AZ08.cfg"]], exitCode: 0),
            "--solder": .init(json: ["solder": ["pass": true, "bootSucceeded": true,
                                                "log": "Size=8192MB BW=64"]], exitCode: 0),
            "--eyescan": .init(json: ["eyescan": ["pass": true, "completed": true, "wedged": false,
                                      "bytes": 40_960, "transcript": "all result: pass"],
                                      "elapsedMs": 812_300], exitCode: 0),
        ])
    }

    // MARK: - Running the sequence the way the engine will

    private func runSequence(tool: ScriptedMaskromTool,
                             board: ScriptedBoardSession) async -> [String: ItemResult] {
        var results: [String: ItemResult] = [:]
        let clock = SimClock()
        let maskrom = MaskromItems(cli: tool, model: .az08, deviceID: "002-1.4-2207-350e-NA")
        results["T01"] = await maskrom.runT01()
        results["T02"] = await maskrom.runT02()
        results["T03"] = await maskrom.runT03()
        // T04 needs a real flash tool and network; the engine covers it. Recorded as a pass here so
        // the sequence around it is complete.
        var t04 = ItemResult(code: "T04")
        t04.measurements = [.text("镜像", "image-raw-format-AZ08.img"),
                            .text("镜像校验", "sha256 与 CI 记录一致"),
                            .num("刷写耗时", 92.4, "s")]
        t04.validity = [.isTrue("防误刷 · 目标设备在位", true, expected: "002-1.4-2207-350e-NA"),
                        .isTrue("防误刷 · 型号相符", true, expected: "PID 350e")]
        t04.criteria = [.equals("刷机工具退出码", 0, 0)]
        t04.conclude()
        results["T04"] = t04

        let bi = BoardItems(adb: board, model: .az08, channels: 4,
                            busBitsPerChannel: 16, clock: clock)
        results["T05"] = await bi.runT05()
        results["T06"] = await bi.runT06(durationSeconds: 43_200)
        results["T07"] = await bi.runT07(targetCycles: 3_000)
        results["T08"] = await bi.runT08(targetBoots: 3_000)
        return results
    }

    private func makeRun(_ results: [String: ItemResult], stoppedAt: String? = nil) -> Run {
        Run(schemaVersion: Run.currentSchema, runID: "1787190336-FB1391E4",
            batchID: "AZ08-DDR-20260824-100000", model: .az08, flow: .ddr,
            board: .init(serial: "34376b2c031e323e", cpuid: "c0ffee0102030405",
                         chipVariant: nil, socket: "002-1.4",
                         reported: "Focalcrest AZ08 / RK3576", uptimeAtBind: 42),
            burninPhases: BurninPhase.allCases, scale: .default, items: TestItem.ddrItems, results: results,
            startedAt: Date(timeIntervalSince1970: 1_787_000_000),
            finishedAt: Date(timeIntervalSince1970: 1_787_130_000),
            stoppedAt: stoppedAt,
            toolVersions: ["RockchipDDRTestUtilityCLI 1.4.2"], appVersion: "1.0.0-3-gabc1234")
    }

    private func dump(_ name: String, _ md: String) {
        guard let dir = ProcessInfo.processInfo.environment["REPORT_DUMP_DIR"] else { return }
        try? md.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name),
                      atomically: true, encoding: .utf8)
    }

    // MARK: - Scenario 1: everything passes

    func testAHealthyBoardPasses() async {
        let board = ScriptedBench.board()
        let results = await runSequence(tool: healthyTool(), board: board)
        let md = ReportRenderer.render(makeRun(results))
        dump("1-通过.md", md)

        for code in ["T02", "T03", "T06", "T07", "T08"] {
            XCTAssertEqual(results[code]?.verdict, .passed,
                           "\(code)：\(results[code]?.detail ?? String(describing: results[code]?.execution))")
        }
        XCTAssertEqual(results["T01"]?.verdict, .noCriterion)
        XCTAssertEqual(results["T05"]?.verdict, .noCriterion)
        XCTAssertTrue(board.unmatched.isEmpty, "场景没覆盖：\(board.unmatched)")
        XCTAssertTrue(md.contains("项全部通过"), md)
    }

    // MARK: - Scenario 2: the burn-in finds a defect

    func testADefectInTheBurnInCondemnsTheMaterialAndStopsThere() async {
        let results = await runSequence(tool: healthyTool(),
                                       board: ScriptedBench.board(t06Defect: true))
        var trimmed = results
        trimmed["T07"] = nil; trimmed["T08"] = nil          // Flow stopped the run at T06
        let md = ReportRenderer.render(makeRun(trimmed, stoppedAt: "T06"))
        dump("2-检出缺陷.md", md)

        XCTAssertTrue(results["T06"]?.condemnsMaterial == true,
                      "\(String(describing: results["T06"]?.execution))")
        XCTAssertEqual(Flow.after(results["T06"]!, item: TestItem.ddrItems[5]), .stop)
        XCTAssertTrue(md.contains("❌"), md)
    }

    // MARK: - Scenario 3: our side fails on a record-only item, the burn-in still runs

    func testAMissingDiagnosticBinaryDoesNotCostTheBurnIn() async {
        let board = ScriptedBench.board(t05Missing: true)
        let results = await runSequence(tool: healthyTool(), board: board)
        let md = ReportRenderer.render(makeRun(results))
        dump("3-我们这边出问题.md", md)

        XCTAssertFalse(results["T05"]?.condemnsMaterial ?? true, "缺个诊断程序不是物料缺陷")
        XCTAssertEqual(Flow.after(results["T05"]!, item: TestItem.ddrItems[4]), .cont,
                       "T05 测不成绝不能不跑 T06/T07/T08")
        XCTAssertEqual(results["T06"]?.verdict, .passed, "拷机照样跑完并通过")
        XCTAssertEqual(results["T08"]?.verdict, .passed)
        XCTAssertTrue(md.contains("未取得结果"), md)
        XCTAssertFalse(md.contains("❌"), "我们这一侧的问题不得渲染成不合格：\n\(md)")
    }
}
