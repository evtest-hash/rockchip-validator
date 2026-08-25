import Foundation

/// E03 read and write performance and E04 data integrity, both based on fio.
extension EmmcItems {

    /// Result of one fio run.
    struct FioResult {
        let readKBps: Double
        let readIOPS: Double
        let writeKBps: Double
        let writeIOPS: Double
        let readBytes: Int
        let writeBytes: Int
        /// fio's plain-text output, used for the report appendix.
        let normal: String
        /// The complete raw output including the JSON, used only to diagnose a parse failure.
        let raw: String
        let exitCode: Int32
    }

    /// Runs fio once.
    func runFio(name: String, rw: String, blockSize: String, size: String,
                extra: [String] = [], timeout: TimeInterval = 900) async -> FioResult? {
        let cmd = "cd \(Self.work) && fio --name=\(name) --rw=\(rw) --bs=\(blockSize) "
                + "--size=\(size) --direct=1 --ioengine=sync --output-format=json,normal "
                + extra.joined(separator: " ")
                + " ; rc=$?; rm -f \(Self.work)/\(name).0.0; exit $rc"
        let res = await adb.sh(cmd, timeout: timeout)
        let text = res.combined

        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}"),
              let data = String(text[start...end]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = obj["jobs"] as? [[String: Any]], let job = jobs.first
        else { return nil }

        // The plain-text part is the concatenation of the content on both sides of the JSON block.
        let before = String(text[text.startIndex..<start])
        let after = String(text[text.index(after: end)...])
        let normal = (before + after).trimmingCharacters(in: .whitespacesAndNewlines)

        func metric(_ side: String, _ key: String) -> Double {
            ((job[side] as? [String: Any])?[key] as? NSNumber)?.doubleValue ?? 0
        }
        func bytes(_ side: String) -> Int {
            ((job[side] as? [String: Any])?["io_bytes"] as? NSNumber)?.intValue ?? 0
        }
        return FioResult(readKBps: metric("read", "bw"), readIOPS: metric("read", "iops"),
                         writeKBps: metric("write", "bw"), writeIOPS: metric("write", "iops"),
                         readBytes: bytes("read"), writeBytes: bytes("write"),
                         normal: normal, raw: text, exitCode: res.exitCode)
    }

    // MARK: - E03 read and write performance, record-only; E06 reuses this implementation

    /// Definition of the performance cases, shared by E03 and E06.
    static let fioPerfCases:
        [(label: String, rw: String, bs: String, isRead: Bool, is4K: Bool)] = [
        ("顺序读", "read", "1M", true, false),
        ("顺序写", "write", "1M", false, false),
        ("随机读 4K", "randread", "4k", true, true),
        ("随机写 4K", "randwrite", "4k", false, true),
    ]

    /// Sequential read and write at 1M over 256M; random read and write at 4K over 256M.
    func runE03() async -> ItemResult { await runFioPerf(code: "E03") }

    /// Shared body of E03 and E06.
    func runFioPerf(code: String, baseline: [String: Double]? = nil) async -> ItemResult {
        var r = ItemResult(code: code)
        _ = await adb.sh("mkdir -p \(Self.work)")

        var measuredCount = 0
        var measured: [String: Double] = [:]
        for c in Self.fioPerfCases {
            guard let f = await runFio(name: c.rw, rw: c.rw, blockSize: c.bs, size: "256M") else {
                r.interrupted("\(c.label)：fio 未产生可解析的 JSON 输出")
                return r
            }
            let kbps = c.isRead ? f.readKBps : f.writeKBps
            let iops = c.isRead ? f.readIOPS : f.writeIOPS
            let moved = c.isRead ? f.readBytes : f.writeBytes

            let mbps = (kbps / 1024 * 10).rounded() / 10
            measured[c.label] = mbps
            r.measurements.append(.num(c.label, mbps, "MB/s"))
            if c.is4K { r.measurements.append(.num("\(c.label) IOPS", iops.rounded())) }
            if moved > 0 { measuredCount += 1 }
            r.evidence.append(.log("fio --rw=\(c.rw) --bs=\(c.bs) --size=256M", f.normal))
        }

        // No criteria: this item measures and records, and the numbers are read against the
        // material's own specification. What it does have is a precondition — a bandwidth figure
        // from a case that moved nothing is not a slow device, it is no reading at all.
        r.validity = [.equals("实际完成的测项", measuredCount, Self.fioPerfCases.count)]
        r.conclude()

        // The comparison table is produced only when the readings are trustworthy.
        if code == "E06", r.verdict == .noCriterion {
            r.evidence.insert(.markdown("拷机前后对比",
                                        Self.perfDeltaTable(before: baseline, after: measured)),
                              at: 0)
        }
        return r
    }

    // MARK: - E06 post-burn-in performance, record-only

    /// Repeats the measurement after the burn-in (E05) to see whether 20 full-device writes caused.
    func runE06(baseline: [String: Double]?) async -> ItemResult {
        await runFioPerf(code: "E06", baseline: baseline)
    }

    /// Pre- and post-burn-in comparison table.
    static func perfDeltaTable(before: [String: Double]?,
                               after: [String: Double]) -> String {
        guard let before, !before.isEmpty else {
            var rows = ["> 本次未跑 E03，**没有拷机前的对照读数**，下表只有拷机后的绝对值。",
                        "", "| 测项 | 拷机后 |", "|---|---|"]
            for c in fioPerfCases where after[c.label] != nil {
                rows.append("| \(c.label) | \(after[c.label]!) MB/s |")
            }
            return rows.joined(separator: "\n")
        }

        var rows = ["| 测项 | 拷机前 | 拷机后 | 变化 |", "|---|---|---|---|"]
        for c in fioPerfCases {
            guard let b = before[c.label], let a = after[c.label] else { continue }
            // No percentage is computed against a zero baseline.
            let delta = b > 0
                ? String(format: "%+.1f%%", (a - b) / b * 100)
                : "—"
            rows.append("| \(c.label) | \(b) MB/s | \(a) MB/s | \(delta) |")
        }
        rows.append("")
        rows.append("> 两组读数用**完全相同**的 fio 参数（同一张 `fioPerfCases` 表）。")
        rows.append("> 单次采样，未测波动范围 —— 小幅变化可能是噪声而非退化，"
                  + "请结合 E05 的 md5 结果与寿命寄存器一并判断。")
        return rows.joined(separator: "\n")
    }

    // MARK: - E04 data integrity, pass or fail

    /// Writes 256M and verifies it on read-back with crc32c.
    func runE04() async -> ItemResult {
        var r = ItemResult(code: "E04")
        _ = await adb.sh("mkdir -p \(Self.work)")

        guard let f = await runFio(
            name: "vfy", rw: "write", blockSize: "1M", size: "256M",
            extra: ["--verify=crc32c", "--verify_fatal=1", "--do_verify=1"]) else {
            r.interrupted("fio 未产生可解析的 JSON 输出")
            return r
        }

        let expected = 256 * 1024 * 1024
        r.measurements.append(.num("fio 退出码", Double(f.exitCode)))
        r.measurements.append(.num("写入量", Double(f.writeBytes) / 1_048_576, "MB"))
        r.measurements.append(.num("回读量", Double(f.readBytes) / 1_048_576, "MB"))
        if f.writeKBps > 0 {
            r.measurements.append(.num("校验写入带宽",
                (f.writeKBps / 1024 * 10).rounded() / 10, "MB/s"))
        }

        let errorLines = RE.all(#"(verify.*fail|checksum.*mismatch|bad magic)"#,
                                in: f.raw, options: [.caseInsensitive]).count

        // Corruption is the device's; not having written or read enough to judge is ours.
        r.criteria = [
            .equals("fio 退出码", Int(f.exitCode), 0),
            .equals("校验错误行", errorLines, 0),
        ]
        r.validity = [
            .isTrue("确实写满 256M", f.writeBytes >= expected, expected: "写入 ≥ 256 MB"),
            .isTrue("确实执行了回读校验", f.readBytes > 0, expected: "回读量 > 0"),
        ]
        r.conclude()
        r.evidence = [.log("fio --verify=crc32c --verify_fatal=1 --do_verify=1", f.normal)]
        return r
    }
}
