import XCTest
@testable import AZ0XCore

/// T01 to T03 against the tool's v2.7 contract.
///
/// That version answers the two questions separately itself: `errorCode` says whether a verdict was
/// produced at all, `pass` is the verdict. Its own comment is the rule these tests encode — exit 1
/// means *the board is untested, not bad*.
final class MaskromItemTests: XCTestCase {

    private func items(_ tool: ScriptedMaskromTool) -> MaskromItems {
        MaskromItems(cli: tool, model: .az08, deviceID: "002-1.4-2207-350e-NA")
    }

    private func detect(_ answer: ScriptedMaskromTool.Answer) -> ScriptedMaskromTool {
        ScriptedMaskromTool(["--detect": answer])
    }

    // MARK: - No verdict produced: never a statement about the material

    /// Every `errorCode` is 未得结果, and the reason is the tool's own words.
    ///
    /// The tool reports one thing here — no verdict was produced — and that is what gets recorded.
    /// An earlier revision sorted these codes into three execution states; that sorting was ours,
    /// and it decided whether the report said 跳过 or 未得结果 on the strength of a string.
    func testEveryErrorCodeIsNoVerdict() async {
        for code in ["noDevice", "badArgument", "cfgNotFound", "unsupportedSoc", "ambiguousCfg",
                     "transport", "probeFailed", "deviceWedged", "scanIncomplete"] {
            let r = await items(detect(.init(exitCode: 1, ok: false, errorCode: code,
                                             errorMessage: "工具说：\(code)"))).runT01()

            XCTAssertNil(r.verdict, "\(code) 绝不能产生判定")
            XCTAssertFalse(r.condemnsMaterial, code)
            XCTAssertEqual(r.label, "未得结果", code)
            XCTAssertTrue(r.detail?.contains(code) == true,
                          "原因里要带上稳定短码，报告才说得清：\(r.detail ?? "")")
            XCTAssertTrue(r.detail?.contains("工具说") == true,
                          "原因要用工具自己的话：\(r.detail ?? "")")
        }
    }

    /// The tool's output being unreadable is our problem too, not the board's.
    func testUnparseableOutputIsNoVerdict() async {
        let tool = detect(.init(parseError: "输出不是合法 JSON"))
        let r = await items(tool).runT01()

        XCTAssertNil(r.verdict)
        guard case let .interrupted(why) = r.execution else {
            return XCTFail("\(String(describing: r.execution))")
        }
        XCTAssertTrue(why.contains("非物料问题"), why)
    }

    // MARK: - T01 records the part and judges nothing

    func testT01RecordsTheSpecAndClaimsNothing() async {
        let tool = detect(.init(json: ["detect": [
            "pass": true, "type": "LPDDR4X", "capacityMB": 4096, "channels": 2, "csPerDie": 2,
            "tier": "uniqueByCoarse", "cfg": "4GB LPDDR4X 焊接检测.cfg",
            "candidates": ["4GB LPDDR4X 焊接检测.cfg"],
            "geometry": [["busWidthBits": 16, "dieWidthBits": 16, "col": 10, "bank": 3, "rank": 2]]]],
            exitCode: 0))
        let r = await items(tool).runT01()

        XCTAssertEqual(r.verdict, .noCriterion, "规格符不符合订单由人判，软件不编判据")
        XCTAssertEqual(r.label, "仅记录")
        XCTAssertEqual(r.measurements.first { $0.name == "匹配 cfg" }?.value.display,
                       "4GB LPDDR4X 焊接检测.cfg")
        XCTAssertEqual(r.measurements.first { $0.name == "容量" }?.value.display, "4096 MB")
        XCTAssertEqual(r.measurements.first { $0.name == "每通道位宽" }?.value.display, "16 bit")
        XCTAssertTrue(tool.unmatched.isEmpty)
    }

    /// A non-unique match is 未得结果, and the report names what there was to choose between.
    ///
    /// v2.7 lists every matching cfg by name rather than counting them: an ambiguous result is only
    /// actionable if the reader can see the alternatives.
    func testT01AnAmbiguousMatchIsNoResultAndNamesTheCandidates() async {
        let tool = detect(.init(json: ["detect": [
            "pass": false, "tier": "ambiguous", "capacityMB": 4096,
            "candidates": ["4GB A.cfg", "4GB B.cfg"]]],
            exitCode: 1, ok: false, errorCode: "ambiguousCfg",
            errorMessage: "geometry decoded, 2 cfg matched"))
        let r = await items(tool).runT01()

        XCTAssertFalse(r.condemnsMaterial, "认不出颗粒不等于颗粒是坏的")
        XCTAssertEqual(r.label, "未得结果")
        XCTAssertTrue(r.detail?.contains("ambiguousCfg") == true, r.detail ?? "")
    }

    // MARK: - T02, the one item purely about the material

    func testT02PassIsAVerdict() async {
        let tool = ScriptedMaskromTool(["--solder": .init(json: ["solder": [
            "pass": true, "bootSucceeded": true, "cfg": "焊接检测.cfg",
            "log": "BW=16 Col=10 Bk=8 CS0 Row=17 CS=1 Die BW=16 Size=2048MB"]], exitCode: 0)])
        let r = await items(tool).runT02()

        XCTAssertEqual(r.verdict, .passed)
        XCTAssertEqual(r.measurements.first { $0.name == "检测 cfg" }?.value.display, "焊接检测.cfg")
        // Geometry is not T02's to report: scraping it out of the log's prose put a per-die figure
        // beside T01's whole-part figure with nothing saying they measured different things.
        XCTAssertNil(r.measurements.first { $0.name.contains("容量") })
        XCTAssertNil(r.measurements.first { $0.name.contains("位宽") })
    }

    func testT02FailIsAVerdictAgainstTheMaterial() async {
        let tool = ScriptedMaskromTool(["--solder": .init(json: ["solder": [
            "pass": false, "bootSucceeded": true, "log": "…"]], exitCode: 2, ok: false)])
        let r = await items(tool).runT02()

        XCTAssertTrue(r.condemnsMaterial, "焊接不良就是物料问题，这一条必须能判不合格")
        XCTAssertTrue(r.detail?.contains("solder.pass") == true, r.detail ?? "")
    }

    /// A field we do not understand must not become a gate.
    ///
    /// Taken from a real AZ08: `pass: true, errorCode: nil`, exit 0, the log reading 测试结果: 通过!
    /// — and `solder.bootSucceeded: false`. An earlier revision guessed what that flag meant and
    /// gated on it, turning a board the tool had passed into 未得结果. Whatever it tracks, the
    /// contract is `pass` plus `errorCode`; everything else is diagnostic.
    func testT02ADiagnosticFieldWeDoNotUnderstandDoesNotChangeTheVerdict() async {
        let tool = ScriptedMaskromTool(["--solder": .init(json: ["solder": [
            "pass": true, "bootSucceeded": false, "cfg": "焊接检测.cfg",
            "log": "检查 CS...\nCS 检查通过.\n测试结果: 通过!"]], exitCode: 0)])
        let r = await items(tool).runT02()

        XCTAssertEqual(r.verdict, .passed,
                       "工具说通过、退出 0、没有 errorCode —— 就是通过：\(String(describing: r.execution))")
        XCTAssertTrue(r.validity.isEmpty, "不要为看不懂的字段加闸门")
    }

    // MARK: - T03, where the two questions used to be one boolean

    func testT03PassIsAVerdict() async {
        let tool = ScriptedMaskromTool(["--eyescan": .init(json: ["eyescan": [
            "pass": true, "completed": true, "wedged": false, "bytes": 40_960,
            "transcript": "all result: pass"]], exitCode: 0)])
        let r = await items(tool).runT03()

        XCTAssertEqual(r.verdict, .passed)
        XCTAssertEqual(r.measurements.first { $0.name == "扫描判定" }?.value.display, "pass")
    }

    func testT03AFinishedScanWithABadEyeIsADefect() async {
        let tool = ScriptedMaskromTool(["--eyescan": .init(json: ["eyescan": [
            "pass": false, "completed": true, "wedged": false, "bytes": 40_960,
            "transcript": "all result:   fail"]], exitCode: 2, ok: false)])
        let r = await items(tool).runT03()

        XCTAssertTrue(r.condemnsMaterial, "扫完了而眼图不合格，这是真判定")
        XCTAssertTrue(r.detail?.contains("eyescan.pass") == true, r.detail ?? "")
    }

    /// The AZ04A case that prompted the tool change: a scan cut short at the deadline.
    ///
    /// Before v2.7 this arrived as `go: false` with exit 2 — indistinguishable from a bad eye — and
    /// the run reported 不通过 on a board whose eye was never measured. Now it carries
    /// `errorCode: scanIncomplete` and exit 1, so it can only be 未得结果.
    func testT03AScanCutShortIsNoResultRatherThanADefect() async {
        let tool = ScriptedMaskromTool(["--eyescan": .init(json: ["eyescan": [
            "pass": false, "completed": false, "wedged": false, "bytes": 4_096,
            "transcript": "ch0 ttot10\ncur eye:\nleft : -42"]],
            exitCode: 1, ok: false, errorCode: "scanIncomplete",
            errorMessage: "still streaming at the deadline")])
        let r = await items(tool).runT03()

        XCTAssertFalse(r.condemnsMaterial,
                       "扫描没跑完就判物料不合格，这正是真机上发生过的事")
        guard case let .interrupted(why) = r.execution else {
            return XCTFail("\(String(describing: r.execution))")
        }
        XCTAssertTrue(why.contains("scanIncomplete"), why)
    }

    /// A wedged device needs the fixture replugged, which is not a verdict either.
    func testT03AWedgedDeviceIsNoResult() async {
        let tool = ScriptedMaskromTool(["--eyescan": .init(json: ["eyescan": [
            "pass": false, "completed": false, "wedged": true, "bytes": 512,
            "transcript": "…"]],
            exitCode: 1, ok: false, errorCode: "deviceWedged",
            errorMessage: "device stopped responding; replug the fixture")])
        let r = await items(tool).runT03()

        XCTAssertFalse(r.condemnsMaterial)
        XCTAssertTrue(r.detail?.contains("deviceWedged") == true, r.detail ?? "")
    }

    // MARK: - The scenario contract

    func testAnUndeclaredRequestFailsRatherThanDefaulting() async {
        let tool = ScriptedMaskromTool()
        let r = await items(tool).runT02()

        XCTAssertEqual(tool.unmatched, ["--solder"])
        XCTAssertFalse(r.condemnsMaterial, "场景没覆盖也绝不能变成物料判定")
    }
}
