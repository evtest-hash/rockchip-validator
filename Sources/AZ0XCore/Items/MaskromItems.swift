import Foundation

/// The maskrom-domain items: T01 spec, T02 soldering, T03 eye scan, T04 and E01 flashing.
///
/// Since the tool's v2.7 contract these three read the same way, because the tool now answers the
/// two questions separately itself: `errorCode` says whether a verdict was produced at all, and
/// `pass` is the verdict. Its own comment puts it best — exit 1 means *the board is untested, not
/// bad*. So the whole of the old adaptation is gone: no exit-code table, no hunting for
/// `all dq eye scan done` in the transcript, no comparing `outcome` against the string "PASS".
struct MaskromItems {

    let cli: any MaskromTool
    let model: DeviceModel
    /// The board this instance addresses, fixed for its life.
    let deviceID: String

    // MARK: - Reading the tool

    /// The envelope every mode shares. `errorCode` non-nil means no verdict was produced.
    private struct Envelope {
        let pass: Bool
        let errorCode: String?
        let errorMessage: String?

        init(_ json: [String: Any]) {
            pass = json.bool("pass") ?? false
            errorCode = json.str("errorCode")
            errorMessage = json.str("errorMessage")
        }

        /// How this item ran, when the tool says no verdict was produced.
        ///
        /// One state, and the reason is the tool's own words. An earlier revision sorted the codes
        /// into three execution states — `noDevice` as never-started, `ambiguousCfg` as invalid, the
        /// rest as interrupted — but that sorting was ours, and it decided whether the report said
        /// 跳过 or 未得结果. The tool reports one thing here: no verdict was produced. So that is
        /// what we record, with its code and its message carried through unchanged.
        var execution: Execution? {
            guard let errorCode else { return nil }
            return .interrupted(errorMessage.map { "\($0)（\(errorCode)）" } ?? errorCode)
        }
    }

    /// Runs one mode and settles the envelope. Returns nil when a verdict was produced and the
    /// item should go on to fill in its own check lists.
    private func read(_ flag: String, into r: inout ItemResult,
                     timeout: TimeInterval = 600) async -> (json: [String: Any], mode: [String: Any])? {
        let jr = await cli.runJSON(flag, deviceID: deviceID, timeout: timeout)
        if let err = jr.parseError {
            r.evidence = [.log("RockchipDDRTestUtilityCLI \(flag) --json", jr.raw)]
            r.interrupted("工具未返回有效结果（非物料问题）：\(err)")
            return nil
        }
        if let ms = jr.json.int("elapsedMs"), ms > 0 {
            r.measurements.append(.num("工具耗时", (Double(ms) / 100).rounded() / 10, "s"))
        }
        let envelope = Envelope(jr.json)
        if let execution = envelope.execution {
            r.evidence = [.log("RockchipDDRTestUtilityCLI \(flag) --json", jr.raw)]
            r.conclude(execution)
            return nil
        }
        let modeKey = String(flag.dropFirst(2))          // "--detect" → "detect"
        return (jr.json, jr.json.dict(modeKey) ?? [:])
    }

    // MARK: - T01 spec verification

    /// Records what the DDR part is. No criterion: whether it is the part that was ordered is a
    /// question for whoever holds the material spec, not for this software.
    ///
    /// It adds no check of its own. A part the tool could not pin to one cfg arrives with
    /// `errorCode: ambiguousCfg` or `cfgNotFound`, which is 未得结果 by the envelope alone — and
    /// reading anything beyond `pass` and `errorCode` is a second opinion on a decision the tool has
    /// already made and published.
    func runT01() async -> ItemResult {
        var r = ItemResult(code: "T01")
        guard let (_, det) = await read("--detect", into: &r) else { return r }

        if let type = det.str("type"), !type.isEmpty { r.measurements.append(.text("DDR 类型", type)) }
        if let cap = det.int("capacityMB") { r.measurements.append(.num("容量", Double(cap), "MB")) }
        if let ch = det.int("channels")    { r.measurements.append(.num("通道数", Double(ch))) }
        if let cs = det.int("csPerDie")    { r.measurements.append(.num("每 die CS 数", Double(cs))) }
        if let cfg = det.str("cfg"), !cfg.isEmpty { r.measurements.append(.text("匹配 cfg", cfg)) }
        if let tier = det.str("tier"), !tier.isEmpty { r.measurements.append(.text("匹配方式", tier)) }
        // Per-channel geometry, as the tool decoded it. Read from the structured field rather than
        // from the log's prose, and labelled per channel so it cannot be read as the whole part.
        if let geometry = det["geometry"] as? [[String: Any]], let first = geometry.first {
            if let bits = first.int("busWidthBits") {
                r.measurements.append(.num("每通道位宽", Double(bits), "bit"))
            }
            if let die = first.int("dieWidthBits") {
                r.measurements.append(.num("每 die 位宽", Double(die), "bit"))
            }
        }

        // v2.7 lists every cfg that matched, by name — an ambiguous result is only actionable if the
        // reader can see what to choose between. It was a count before.
        let candidates = det["candidates"] as? [String] ?? []
        if candidates.count > 1 {
            r.measurements.append(.text("候选 cfg", candidates.joined(separator: "；")))
        }

        // No check of our own. T01 makes no claim about the material — it records what the part is
        // — and whether the tool could pin it to one cfg is already in `errorCode` (`ambiguousCfg`,
        // `cfgNotFound`), which the envelope has settled before we get here.
        //
        // And no evidence either, deliberately: T02 keeps the device's solder log and T03 the eye
        // scan transcript, so the absence here reads like an oversight. It is not. What `--detect`
        // has to say is already above, as structured readings the report can put in a table; its
        // prose would add a second, looser copy of the same facts for a reader to reconcile.
        r.conclude()
        return r
    }

    // MARK: - T02 soldering

    /// The device's own verdict is the criterion. This item is about the material and nothing else.
    func runT02() async -> ItemResult {
        var r = ItemResult(code: "T02")
        guard let (_, sol) = await read("--solder", into: &r) else { return r }

        // No geometry here. It used to be scraped out of the device's log with a regex over prose —
        // ours, not the tool's — and the two numbers it produced (2048 MB, 16 bit, per die) sat in
        // the same report as T01's whole-part figures (4096 MB, 2 channels) with nothing saying they
        // measured different things. The tool reports geometry as structured fields on `--detect`,
        // which is T01's job; T02's job is the solder verdict.
        let log = sol.str("log") ?? ""
        if let cfg = sol.str("cfg"), !cfg.isEmpty { r.measurements.append(.text("检测 cfg", cfg)) }
        // Normalised at extraction, as every other transcript is: the device speaks CRLF over
        // serial, and a stray CR on every line is invisible in a rendered code block but sits in
        // the file. Measured on a real AZ08: not one line of content changes.
        if !log.isEmpty { r.evidence = [.log("焊接检测设备输出", LongTest.normalize(log))] }

        // Only `pass` and `errorCode`. An earlier revision gated on `solder.bootSucceeded`, having
        // guessed what it meant — and a real AZ08 came back `pass: true, errorCode: nil, exit 0`
        // with the log reading 测试结果: 通过! and `bootSucceeded: false`. That guess turned a board
        // the tool had passed into 未得结果. Whatever that flag tracks, it is diagnostic; it is in
        // `log`, where the tool puts its diagnostic prose.
        r.criteria = [.isTrue("设备 result code", sol.bool("pass") ?? false,
                              expected: "solder.pass 为 true")]
        r.conclude()
        return r
    }

    // MARK: - T03 DQ eye scan

    /// The scan's own verdict is the only criterion. Everything else the tool answers itself.
    ///
    /// Before v2.7 one boolean covered both "a DQ eye is bad" and "the scan stopped part way", and a
    /// real AZ04A ended after 122 s with the transcript cut off mid eye-data and not one
    /// `all result:` line — reported as 不通过 on a board whose eye was never measured. v2.7 routes
    /// that through `errorCode: scanIncomplete`, and a wedged device through `deviceWedged`, so the
    /// envelope settles both before this body runs. `completed` is recorded as a measurement, not
    /// checked: a check here could only repeat the envelope, or contradict it.
    func runT03() async -> ItemResult {
        var r = ItemResult(code: "T03")
        // No capability check: a model without the eye scan never has this item.
        guard let (_, eye) = await read("--eyescan", into: &r, timeout: 900) else { return r }

        if let bytes = eye.int("bytes") {
            r.measurements.append(.num("transcript 字节数", Double(bytes), "B"))
        }
        r.measurements.append(.text("扫描判定", (eye.bool("pass") ?? false) ? "pass" : "fail"))
        if let transcript = eye.str("transcript"), !transcript.isEmpty {
            r.evidence = [.log("DQ 眼图扫描 transcript", LongTest.normalize(transcript))]
        }

        // `completed` and `wedged` are recorded, not gated: the tool already routes both through
        // `errorCode` (scanIncomplete / deviceWedged), so a check here would add nothing and could
        // only misfire — which is exactly what a guessed gate on `solder.bootSucceeded` did.
        if let completed = eye.bool("completed") {
            r.measurements.append(.text("扫描跑完", completed ? "是" : "否"))
        }
        r.criteria = [.isTrue("眼图扫描判定", eye.bool("pass") ?? false,
                              expected: "eyescan.pass 为 true")]
        r.conclude()
        return r
    }
    // MARK: - T04 and E01 flashing

    /// The two time-consuming stages of flashing.
    /// Progress inside the flashing item. One stage now: fetching the image is not part of this
    /// item any more, so it does not report through it either.
    enum FlashStage {
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
    /// Writes an image this run was handed onto this bench's board.
    ///
    /// It does not go and get the image. Fetching is a step of its own that happens before any board
    /// is opened — which is what makes "several boards, one download" not a concurrency question at
    /// all, and what makes every board of a batch provably the same build.
    func runFlash(code: String, image: PreparedImage?, flashTool: (any Flasher)?,
                  onStage: ((FlashStage) -> Void)? = nil) async -> ItemResult {
        var r = ItemResult(code: code)

        guard let flashTool else {
            r.interrupted("刷机工具未随应用打包（rockchip-flash-tool-cli 缺失）")
            return r
        }
        guard let image else {
            // Ours, not the board's: nothing was written, so nothing about it was learned.
            r.interrupted("本次运行没有可刷的镜像 —— 取镜像是开跑之前的一步")
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

        r.measurements.append(.text("镜像", image.asset))
        // Whether this image was proved to be the published build. Flashing an unverified one is an
        // accepted trade-off — the digest API is rate-limited — but it must not be invisible:
        // without this line a report that flashed an unverified image reads exactly like one that
        // flashed a verified image.
        r.measurements.append(.text("镜像校验", image.digestVerified
                                    ? "sha256 与 CI 记录一致"
                                    : "未校验（未能取得 CI 发布摘要）"))

        onStage?(.flashing(nil))
        let res = await flashTool.flash(image.url, device: deviceID) { onStage?(.flashing($0)) }
        r.measurements.append(.num("刷写耗时", (res.duration * 10).rounded() / 10, "s"))
        if let bytes = try? FileManager.default
            .attributesOfItem(atPath: image.url.path)[.size] as? Int,
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
