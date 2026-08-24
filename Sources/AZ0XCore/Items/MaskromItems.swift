import Foundation

/// The maskrom-domain items: T01 spec, T02 soldering, T03 eye scan, T04 and E01 flashing.
///
/// Each one fills in two check lists and calls `conclude()`. Which list a check goes in is the whole
/// decision: `criteria` can condemn the material, `validity` can only say this run was not worth
/// judging. The tool's exit code decides which of the two an item is even allowed to reach.
struct MaskromItems {

    let cli: any MaskromTool
    let model: DeviceModel
    /// The board this instance addresses, fixed for its life.
    let deviceID: String

    /// The tool's exit code, which is the primary source: 0 pass, 1 environment, 2 check failed.
    private enum ToolExit {
        case ok
        /// Exit 1: no device, parse, USB transfer, unsupported SoC. Our side, never the material.
        case environment(String)
        /// Exit 2: the tool's own check did not pass.
        case checkFailed
        case unexpected(Int32)
    }

    private func classify(_ exitCode: Int32) -> ToolExit {
        switch exitCode {
        case 0: return .ok
        case 1: return .environment("无设备 / 解析 / USB 传输 / 不支持的 SoC")
        case 2: return .checkFailed
        default: return .unexpected(exitCode)
        }
    }

    // MARK: - T01 spec verification

    /// Detects the DDR part and records what it is. No criterion: whether the part is the one that
    /// was ordered is a question for whoever holds the material spec, not for this software.
    ///
    /// The unique-cfg check is **validity**, not a criterion. A part the tool cannot match uniquely
    /// is a part whose type, capacity and channel count are not trustworthy either — so the honest
    /// answer is that this reading did not come out, not that the material is defective. The first
    /// iteration was asymmetric here: a unique match recorded 仅记录 (a human judges), while a
    /// failure to match judged 不合格 all by itself.
    func runT01() async -> ItemResult {
        var r = ItemResult(code: "T01")
        let jr = await cli.runJSON("--detect", deviceID: deviceID)
        let evidence = Evidence.log("RockchipDDRTestUtilityCLI --detect --json", jr.raw)

        if let err = jr.parseError {
            r.evidence = [evidence]
            r.interrupted("探测未返回有效结果：\(err)")
            return r
        }

        let det = jr.json.dict("detect") ?? jr.json
        if let type = det.str("type"), !type.isEmpty { r.measurements.append(.text("DDR 类型", type)) }
        if let cap = det.int("capacityMB") { r.measurements.append(.num("容量", Double(cap), "MB")) }
        if let ch = det.int("channels")    { r.measurements.append(.num("通道数", Double(ch))) }
        if let cs = det.int("csPerDie")    { r.measurements.append(.num("每 die CS 数", Double(cs))) }
        // The evidence T01 is asked for is the matched cfg file name.
        if let cfg = det.str("cfg"), !cfg.isEmpty { r.measurements.append(.text("匹配 cfg", cfg)) }
        if let tier = det.str("tier"), !tier.isEmpty { r.measurements.append(.text("匹配方式", tier)) }

        switch classify(jr.exitCode) {
        case .ok:
            r.validity = [.isTrue("唯一匹配配置", true, expected: "工具退出码 0")]
            r.conclude()
        case let .environment(why):
            r.evidence = [evidence]
            r.interrupted("探测环境错误（非物料问题）：\(why)")
        case .checkFailed:
            r.validity = [.isTrue("唯一匹配配置", false, expected: "工具退出码 0")]
            r.evidence = [evidence]
            r.conclude()
        case let .unexpected(code):
            r.evidence = [evidence]
            r.interrupted("探测返回未知退出码 \(code)")
        }
        return r
    }

    // MARK: - T02 soldering

    /// The device's own result code is the criterion. This one is about the material and nothing else.
    func runT02() async -> ItemResult {
        var r = ItemResult(code: "T02")
        let jr = await cli.runJSON("--solder", deviceID: deviceID)

        if let err = jr.parseError {
            r.evidence = [.log("RockchipDDRTestUtilityCLI --solder --json", jr.raw)]
            r.interrupted("焊接检测未返回有效结果（非物料问题）：\(err)")
            return r
        }
        let sol = jr.json.dict("solder") ?? [:]
        let log = sol.str("log") ?? jr.raw
        let outcome = (sol.str("outcome") ?? "").uppercased()

        // The device geometry is read from the device's own log.
        if let size = RE.firstInt(#"Size=(\d+)MB"#, in: log) {
            r.measurements.append(.num("检出容量", Double(size), "MB"))
        }
        if let bw = RE.firstInt(#"BW=(\d+)"#, in: log) {
            r.measurements.append(.num("总线位宽", Double(bw), "bit"))
        }
        if !outcome.isEmpty { r.measurements.append(.text("设备判定", outcome)) }
        r.evidence = [.log("焊接检测设备输出", log)]

        switch classify(jr.exitCode) {
        case .ok:
            r.criteria = [.isTrue("设备 result code", true, expected: "solder.outcome 为 PASS")]
            r.conclude()
        case let .environment(why):
            // Reporting a transfer problem as a failure would reject a sound board.
            r.interrupted("USB 传输或环境错误（非物料问题）：\(sol.str("error") ?? why)")
        case .checkFailed:
            r.criteria = [.isTrue("设备 result code", false, expected: "solder.outcome 为 PASS")]
            r.conclude()
        case let .unexpected(code):
            r.interrupted("焊接检测返回未知退出码 \(code)")
        }
        return r
    }

    // MARK: - T03 DQ eye scan

    /// The scan's own verdict is the criterion. The two sources agreeing is validity: when the exit
    /// code says pass and `eyescan.go` says fail, we do not know what happened and must not guess.
    func runT03() async -> ItemResult {
        var r = ItemResult(code: "T03")
        // No capability check is needed: a model without the eye scan never has this item.
        let jr = await cli.runJSON("--eyescan", deviceID: deviceID, timeout: 900)

        if let err = jr.parseError {
            r.evidence = [.log("RockchipDDRTestUtilityCLI --eyescan --json", jr.raw)]
            r.interrupted("眼图扫描未返回有效结果（非物料问题）：\(err)")
            return r
        }
        let eye = jr.json.dict("eyescan") ?? [:]
        let transcript = eye.str("transcript") ?? jr.raw
        let go = eye.bool("go") ?? false

        if let ms = jr.json.int("elapsedMs"), ms > 0 {
            r.measurements.append(.num("扫描耗时", (Double(ms) / 100).rounded() / 10, "s"))
        }
        r.measurements.append(.text("扫描判定", go ? "pass" : "fail"))
        r.evidence = [.log("DQ 眼图扫描 transcript", transcript)]

        switch classify(jr.exitCode) {
        case .ok:
            r.validity = [.isTrue("判据来源一致", go,
                                  expected: "退出码 0 时 eyescan.go 亦为 true")]
            r.criteria = [.isTrue("眼图扫描判定", go,
                                  expected: "扫描完成且所有 all result 行为 pass")]
            r.conclude()
        case let .environment(why):
            r.interrupted("USB 传输或环境错误（非物料问题）：\(why)")
        case .checkFailed:
            r.criteria = [.isTrue("眼图扫描判定", false,
                                  expected: "扫描完成且所有 all result 行为 pass")]
            r.conclude()
        case let .unexpected(code):
            r.interrupted("眼图扫描返回未知退出码 \(code)")
        }
        return r
    }
}
