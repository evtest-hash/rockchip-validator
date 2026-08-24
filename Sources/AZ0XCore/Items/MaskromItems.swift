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

    // MARK: - T04 and E01 flashing

    /// The two time-consuming stages of flashing.
    enum FlashStage {
        /// Downloading: bytes done and total bytes.
        case downloading(Int64, Int64?)
        /// Writing: percentage, or nil before the tool reports its first.
        case flashing(Int?)
    }

    /// Flashes the latest production image from CI.
    ///
    /// The anti-misflash gates are **validity**, not criteria: the wrong board in the socket, or a
    /// model that does not match the selection, is a setup problem and says nothing about the
    /// material. They still end the run, because flashing is the one item the rest of the sequence
    /// depends on — but that is `Flow`'s decision now, not a verdict's side effect.
    ///
    /// The tool's exit code is a criterion in both flows. It asserts one thing about the board in
    /// front of us — that it accepted the production image — and that is a yes-or-no about hardware,
    /// not a measurement. An earlier attempt filed it under validity for the DDR flow, reasoning that
    /// the material there is the DRAM; the report then rendered T04 as 仅记录, because an item with no
    /// criteria at all has nothing to judge. Flashing is not a measurement item, and a report that
    /// says otherwise is worse than a classification that is arguable.
    func runFlash(code: String, flashTool: (any Flasher)?,
                  onStage: ((FlashStage) -> Void)? = nil) async -> ItemResult {
        var r = ItemResult(code: code)

        guard let flashTool else {
            r.interrupted("刷机工具未随应用打包（rockchip-flash-tool-cli 缺失）")
            return r
        }

        // Anti-misflash: this item writes to its own socket, and only if the board there is of the
        // selected model. Other boards on the bench are none of its business.
        guard let target = await cli.device(id: deviceID) else {
            r.validity = [.isTrue("防误刷 · 目标设备在位", false, expected: deviceID)]
            r.conclude()
            return r
        }
        guard target.pid == model.maskromPID else {
            r.validity = [.isTrue("防误刷 · 型号相符", false,
                                  expected: "PID \(model.maskromPID)，实际 \(target.pid)")]
            r.conclude()
            return r
        }
        r.validity = [
            .isTrue("防误刷 · 目标设备在位", true, expected: deviceID),
            .isTrue("防误刷 · 型号相符", true, expected: "PID \(model.maskromPID)"),
        ]

        let meta: FlashTool.ImageMeta?
        do { meta = try await flashTool.latestImage(for: model) }
        catch {
            r.interrupted("无法访问 CI 快照通道：\(error.localizedDescription)")
            return r
        }
        guard let meta else {
            r.interrupted("CI 快照通道没有 \(model.rawValue) 的镜像")
            return r
        }

        let fetched: FlashTool.FetchedImage
        do {
            fetched = try await flashTool.fetch(meta) { done, total in
                onStage?(.downloading(done, total))
            }
        } catch let e as FlashError {
            // Already worded for the operator: bad URL, HTTP status, or a digest mismatch.
            r.interrupted(e.localizedDescription)
            return r
        } catch {
            r.interrupted("镜像下载失败：\(error.localizedDescription)")
            return r
        }

        r.measurements.append(.text("镜像", meta.asset))
        // Whether this image was proved to be the published build. Flashing an unverified one is an
        // accepted trade-off — the digest API is rate-limited and several boards reach flashing at
        // once — but it must not be invisible: without this line a report that flashed an unverified
        // image reads exactly like one that flashed a verified image.
        r.measurements.append(.text("镜像校验", fetched.digestVerified
                                    ? "sha256 与 CI 记录一致"
                                    : "未校验（未能取得 CI 发布摘要）"))

        onStage?(.flashing(nil))
        let res = await flashTool.flash(fetched.url, device: deviceID) { onStage?(.flashing($0)) }
        r.measurements.append(.num("刷写耗时", (res.duration * 10).rounded() / 10, "s"))
        if let bytes = try? FileManager.default
            .attributesOfItem(atPath: fetched.url.path)[.size] as? Int,
           bytes > 0, res.duration > 0 {
            let rate = Double(bytes) / 1e6 / res.duration
            r.measurements.append(.num("平均写入速率", (rate * 10).rounded() / 10, "MB/s"))
        }

        r.criteria.append(.equals("刷机工具退出码", Int(res.exitCode), 0))

        if !res.ok {
            // The log is required on failure, where it is diagnostic rather than write progress.
            r.evidence = [.log("rockchip-flash-tool-cli 输出", res.combined)]
        }
        r.conclude()
        return r
    }
}
