import XCTest
@testable import AZ0XCore

/// The one thing that connects the two device domains: the serial burned into the chip's OTP.
///
/// A board in maskrom is addressed by where it is plugged in — `002-1.4-2207-350E-NA`, a bus and a
/// port chain. Once it boots it is addressed by `adb -s <serial>`. Nothing relates those two
/// strings. The bridge is read out of OTP before flashing and used to claim the board afterwards,
/// and both flows depend on it: the eMMC sequence has no T01 to disguise it, which is where the
/// question came from.
final class IdentityBridgeTests: XCTestCase {

    private func tool(cpuid: String? = "c0ffee01",
                      serial: String? = "34376b2c031e323e") -> ScriptedMaskromTool {
        var detect: [String: Any] = ["detect": ["pass": true, "type": "LPDDR4X",
                                                "capacityMB": 4096, "channels": 2, "csPerDie": 2,
                                                "tier": "uniqueByCoarse", "cfg": "az08.cfg",
                                                "geometry": [["busWidthBits": 16,
                                                              "dieWidthBits": 16]]]]
        if let cpuid { detect["cpuid"] = cpuid }
        if let serial { detect["serial"] = serial }
        return ScriptedMaskromTool([
            "--detect": .init(json: detect, exitCode: 0),
            "--solder": .init(json: ["solder": ["pass": true, "cfg": "az08.cfg",
                                                "log": "测试结果: 通过!"]], exitCode: 0),
            "--eyescan": .init(json: ["eyescan": ["pass": true, "completed": true, "bytes": 40,
                                                  "transcript": "all result: pass"]], exitCode: 0),
        ])
    }

    private func plan(_ items: [TestItem]) -> RunPlan {
        var p = RunPlan(batchID: "AZ08-DDR", model: .az08, flow: .ddr, items: items,
                        burninPhases: Set(BurninPhase.allCases),
                        deviceID: "002-1.4-2207-350e-NA")
        p.scale = RunScale(burninSeconds: 1, cycles: 1, emmcTargetN: 1)
        p.image = readyImage
        return p
    }

    /// `--detect` answers both of its readers at once — the OTP identity at the top level, the DDR
    /// geometry under `detect`. It used to be run twice on every DDR board: once by the engine
    /// before it may flash, once by T01 for the spec. Eight seconds, and worse, the serial in the
    /// report's header and the spec in its table came from two separate invocations.
    func testDetectRunsOncePerBoard() async {
        let t = tool()
        let items = TestItem.ddrItems.filter { ["T01", "T02", "T03"].contains($0.code) }
        let v = Validator(plan: plan(items), tool: t, boardSession: { _ in ScriptedBench.board() },
                          flashTool: ScriptedFlasher(), clock: SimClock())

        let run = await v.run { _ in }

        XCTAssertEqual(t.asked.filter { $0 == "--detect" }.count, 1,
                       "同一份信封读一次就够：\(t.asked)")
        XCTAssertEqual(run.board.serial, "34376b2c031e323e", "抬头的序列号还是要有")
        XCTAssertNotNil(run.results["T01"]?.measurements.first { $0.name == "匹配 cfg" },
                        "T01 的规格也要从同一份信封里出来")
    }

    /// Unreadable OTP with board items in the sequence: refused before a board is written to.
    ///
    /// It used to flash anyway and only notice at the first board item, which cost a write and left
    /// the whole board-side half 未得结果. The gate beside it — the chip variant contradicting the
    /// selected model — already worked this way, for the reason its comment gives: writing an image
    /// is not undoable.
    func testAnUnreadableOtpStopsTheRunBeforeItFlashes() async {
        let flasher = ScriptedFlasher()
        let v = Validator(plan: plan(TestItem.ddrItems), tool: tool(serial: nil),
                          boardSession: { _ in ScriptedBench.board() },
                          flashTool: flasher, clock: SimClock())

        let run = await v.run { _ in }

        XCTAssertTrue(flasher.flashed.isEmpty, "认不出板子就不该往上写：\(flasher.flashed)")
        XCTAssertTrue(run.results.values.allSatisfy { $0.verdict == nil },
                      "拒绝不是判定 —— 认不出是哪块板，跟板子好坏无关")
        XCTAssertTrue(ReportRenderer.render(run).contains("读不到芯片 OTP"),
                      "理由要写给操作员看")
    }

    /// A maskrom-only sequence never needs the serial, so a tool that cannot supply it is no
    /// obstacle: nothing here will be looked for on adb afterwards.
    func testAMaskromOnlySequenceRunsWithoutTheSerial() async {
        let items = TestItem.ddrItems.filter { ["T01", "T02", "T03"].contains($0.code) }
        let v = Validator(plan: plan(items), tool: tool(serial: nil),
                          boardSession: { _ in ScriptedBench.board() },
                          flashTool: ScriptedFlasher(), clock: SimClock())

        let run = await v.run { _ in }

        XCTAssertEqual(run.results["T02"]?.verdict, .passed, "不需要 serial 的序列照跑")
        XCTAssertNil(run.board.serial)
    }
}
