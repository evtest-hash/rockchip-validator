import XCTest
@testable import AZ0XCore

/// T01 to T03, and which of the two lists each check belongs in.
final class MaskromItemTests: XCTestCase {

    private func items(_ tool: ScriptedMaskromTool) -> MaskromItems {
        MaskromItems(cli: tool, model: .az08, deviceID: "002-1.4-2207-350e-NA")
    }

    // MARK: - T01: records the part, judges nothing

    func testT01RecordsTheSpecAndClaimsNothing() async {
        let tool = ScriptedMaskromTool(["--detect": .init(
            json: ["detect": ["type": "LPDDR4X", "capacityMB": 8192, "channels": 4,
                              "csPerDie": 1, "cfg": "lpddr4x_2112MHz_AZ08.cfg",
                              "tier": "exact"]],
            exitCode: 0)])
        let r = await items(tool).runT01()

        XCTAssertEqual(r.verdict, .noCriterion, "规格是否符合订单由人判，软件不编判据")
        XCTAssertEqual(r.label, "仅记录")
        XCTAssertEqual(r.measurements.first { $0.name == "匹配 cfg" }?.value.display,
                       "lpddr4x_2112MHz_AZ08.cfg")
        XCTAssertTrue(tool.unmatched.isEmpty)
    }

    /// The classification decision worth arguing about, stated as a test.
    ///
    /// A part the tool cannot match uniquely is a part whose type and capacity are not trustworthy
    /// either, so the honest answer is that this reading did not come out. The first iteration
    /// judged 不合格 here while judging nothing at all on success — asymmetric, and it condemned
    /// material on the strength of a lookup table.
    func testT01CannotMatchTheConfigIsNoResultRatherThanADefect() async {
        let tool = ScriptedMaskromTool(["--detect": .init(
            json: ["detect": ["candidates": 3]], exitCode: 2)])
        let r = await items(tool).runT01()

        XCTAssertFalse(r.condemnsMaterial, "认不出颗粒不等于颗粒是坏的")
        XCTAssertNil(r.verdict)
        guard case let .invalid(why) = r.execution else {
            return XCTFail("\(String(describing: r.execution))")
        }
        XCTAssertTrue(why.contains("唯一匹配配置"), why)
    }

    func testT01ToolEnvironmentErrorIsNoResult() async {
        let tool = ScriptedMaskromTool(["--detect": .init(exitCode: 1)])
        let r = await items(tool).runT01()

        XCTAssertFalse(r.condemnsMaterial)
        guard case let .interrupted(why) = r.execution else {
            return XCTFail("\(String(describing: r.execution))")
        }
        XCTAssertTrue(why.contains("非物料问题"), why)
    }

    // MARK: - T02: the one item that is purely about the material

    func testT02PassIsAVerdict() async {
        let tool = ScriptedMaskromTool(["--solder": .init(
            json: ["solder": ["outcome": "PASS", "log": "Size=8192MB BW=64"]], exitCode: 0)])
        let r = await items(tool).runT02()

        XCTAssertEqual(r.verdict, .passed)
        XCTAssertEqual(r.measurements.first { $0.name == "检出容量" }?.value.display, "8192 MB")
        XCTAssertEqual(r.measurements.first { $0.name == "总线位宽" }?.value.display, "64 bit")
    }

    func testT02FailIsAVerdictAgainstTheMaterial() async {
        let tool = ScriptedMaskromTool(["--solder": .init(
            json: ["solder": ["outcome": "FAIL", "log": "Size=8192MB BW=64"]], exitCode: 2)])
        let r = await items(tool).runT02()

        XCTAssertTrue(r.condemnsMaterial, "焊接不良就是物料问题，这一条必须能判不合格")
        XCTAssertTrue(r.detail?.contains("设备 result code") == true, r.detail ?? "")
    }

    func testT02TransferErrorNeverCondemnsTheBoard() async {
        let tool = ScriptedMaskromTool(["--solder": .init(
            json: ["solder": ["error": "USB transfer failed"]], exitCode: 1)])
        let r = await items(tool).runT02()

        XCTAssertFalse(r.condemnsMaterial, "USB 传输错误报成焊接不良会退掉一块好板")
        XCTAssertTrue(r.detail?.contains("USB") == true, r.detail ?? "")
    }

    // MARK: - T03: the scan judges, the two sources agreeing is validity

    func testT03PassIsAVerdict() async {
        let tool = ScriptedMaskromTool(["--eyescan": .init(
            json: ["eyescan": ["go": true, "transcript": "all result: pass"],
                   "elapsedMs": 812_300], exitCode: 0)])
        let r = await items(tool).runT03()

        XCTAssertEqual(r.verdict, .passed)
        XCTAssertEqual(r.measurements.first { $0.name == "扫描耗时" }?.value.display, "812.3 s")
    }

    func testT03FailIsAVerdictAgainstTheMaterial() async {
        let tool = ScriptedMaskromTool(["--eyescan": .init(
            json: ["eyescan": ["go": false, "transcript": "all result: fail"]], exitCode: 2)])
        let r = await items(tool).runT03()

        XCTAssertTrue(r.condemnsMaterial)
    }

    /// Exit code says pass, the field says fail. We do not know what happened, so we claim nothing.
    func testT03DisagreeingSourcesIsNoResultNotAPassAndNotAFailure() async {
        let tool = ScriptedMaskromTool(["--eyescan": .init(
            json: ["eyescan": ["go": false, "transcript": "…"]], exitCode: 0)])
        let r = await items(tool).runT03()

        XCTAssertNil(r.verdict, "两个来源矛盾时不许猜，也不许当通过")
        XCTAssertFalse(r.condemnsMaterial)
        guard case let .invalid(why) = r.execution else {
            return XCTFail("\(String(describing: r.execution))")
        }
        XCTAssertTrue(why.contains("判据来源一致"), why)
    }

    // MARK: - The scenario contract

    /// An item that asks the tool something the scenario never declared must fail loudly.
    func testAnUndeclaredRequestFailsRatherThanDefaulting() async {
        let tool = ScriptedMaskromTool()
        let r = await items(tool).runT02()

        XCTAssertEqual(tool.unmatched, ["--solder"])
        XCTAssertFalse(r.condemnsMaterial, "场景没覆盖也绝不能变成物料判定")
    }
}
