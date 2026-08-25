import Foundation

/// Deployment and outcome handling shared by the long-running tests T06, T07, T08 and E05.
enum LongTest {

    /// Wipes the board-side directory and starts the test. Always from scratch.
    ///
    /// There is no attach-or-take-over decision any more. A run is one invocation: if the app dies
    /// mid-run the run is lost, and the next start begins again. That is safe without stopping
    /// anything on the board because every board item is preceded by a flash in the same run —
    /// `Sequencer` refuses a sequence without one — so the previous instance died with the reboot.
    static func startFresh(_ bt: BoardTest, bound: Int, extraArgs: String = "",
                           into r: inout ItemResult) async -> Bool {
        await bt.clean()
        guard await bt.start(bound: bound, extraArgs: extraArgs) else {
            r.interrupted("板端测试未能启动：推送 run.sh 后 "
                             + "\(BoardTest.startupGraceSeconds) 秒内没有任何进度记录")
            return false
        }
        // No blind wait follows: start() already waited for the first progress record.
        return true
    }

    /// Shared handling of the polling outcome.
    ///
    /// Two of the four cases end the item here, and both are 未得结果 rather than 不通过: the board
    /// said it could not continue, or it said nothing at all. Neither exercised the criterion, so
    /// neither may be reported as a defect in the material. Only `.done` goes on to the verdict —
    /// including a run that stopped early on a defect it found, which is why that case must reach
    /// the verdict rather than being intercepted here.
    static func settleOrFail(_ wait: BoardTest.WaitOutcome, _ bt: BoardTest,
                             into r: inout ItemResult) async -> ItemResult? {
        switch wait {
        case .cancelled:
            return r
        // These two never reached the end, so they land inside the report's
        // "已在 <项> 中止：未得结果（…）" sentence: they say only what happened and let the renderer
        // supply the framing. Repeating 中止 here read as "已在 T06 中止：未得结果（板端测试中止：…）".
        case let .aborted(why):
            r.interrupted("板端报告无法继续：\(why)")
            r.evidence = await evidence(from: bt)
            return r
        case .boardGone:
            // The item intercepts this before calling here, because reaching a verdict from it needs
            // that item's own criteria. Arriving here means a count-bounded item forgot to, and that
            // is said out loud rather than quietly filed as 未得结果.
            r.invalid("板子离线未返回，但本测试项未处理这种情况")
            return r
        case let .stopped(why):
            r.interrupted(why)
            r.evidence = await evidence(from: bt)
            return r
        case .done:
            guard await bt.settle() else {
                // The board finished; only our way back to it failed. That is `indeterminate`, not
                // `error`, so the report says 已执行完毕，但未能读出判据 instead of 中止 — the
                // difference between re-reading a board and running the whole item again. The
                // message states that sleep is excluded.
                r.invalid("板端已完成，但 adb 未在 "
                                 + "\(Int(Thresholds.settleSeconds))s（不含休眠）内恢复，"
                                 + "读不到结果")
                return r
            }
            return nil
        }
    }

    /// Whatever the board can still tell us about an item that produced no verdict.
    private static func evidence(from bt: BoardTest) async -> [Evidence] {
        let progress = await bt.read("progress.log")
        guard !progress.isEmpty else { return [] }
        return [.log("板端 progress.log 尾部", tail(progress, 20))]
    }

    /// Board-side directory of each long-running item, plus any evidence paths outside it.
    static func archiveSource(for code: String) -> (dir: String, extras: [String])? {
        switch code {
        case "T06": return ("\(BoardItems.boardRoot)/t06_burnin", [])
        case "T07": return ("\(BoardItems.boardRoot)/t07_suspend", [])
        // pstore is the only source of evidence for the pstore panic check.
        case "T08": return ("\(BoardItems.boardRoot)/t08_reboot",
                            ["/sys/fs/pstore/console-ramoops-0"])
        case "E05": return ("/userdata/az0x-emmc/e05_burnin", [])
        default:    return nil
        }
    }

    // MARK: - Text helpers, operating on strings only

    /// Rewrites board-side timestamps as seconds relative to the first line.
    static func relativeTimestamps(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        func epoch(_ line: String) -> Int? {
            guard let tok = line.split(whereSeparator: \.isWhitespace).first,
                  tok.count >= 10, let v = Int(tok) else { return nil }
            return v
        }
        guard let base = lines.compactMap(epoch).first else { return text }
        return lines.map { line -> String in
            guard let t = epoch(line),
                  let sp = line.firstIndex(where: \.isWhitespace) else { return line }
            return "+\(t - base)s" + line[sp...]
        }.joined(separator: "\n")
    }

    /// Removes terminal redraw control characters.
    static func sanitize(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for u in text.unicodeScalars {
            switch u {
            case "\u{08}":                       // backspace: erase the previous character
                if let last = out.last, last != "\n" { out.removeLast() }
            case "\n", "\t":
                out.append(u)
            default:
                if u.value >= 0x20 || u.value > 0x7F { out.append(u) }
            }
        }
        return String(out)
    }

    /// Returns the last n lines, truncating each to a readable length.
    static func tail(_ text: String, _ n: Int, maxLineLength: Int = 400) -> String {
        relativeTimestamps(sanitize(text)).components(separatedBy: .newlines).suffix(n).map { line in
            line.count <= maxLineLength
                ? line
                : String(line.prefix(maxLineLength / 2)) + " …（本行省略 "
                  + "\(line.count - maxLineLength) 字）… "
                  + String(line.suffix(maxLineLength / 2))
        }.joined(separator: "\n")
    }

    static func headTail(_ text: String, _ n: Int) -> String {
        let lines = relativeTimestamps(text)
            .components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > n * 2 else { return lines.joined(separator: "\n") }
        return (lines.prefix(n) + ["…（省略 \(lines.count - n * 2) 行）…"]
                + lines.suffix(n)).joined(separator: "\n")
    }

    /// Anomaly list: only the lines that actually indicate an anomaly.
    static func anomalyList(_ progress: String, markers: [String]) -> String {
        var hits: [String] = []
        for line in relativeTimestamps(progress).components(separatedBy: .newlines) {
            for m in markers where RE.first("(" + m + ")", in: line) != nil {
                hits.append(line.trimmingCharacters(in: .whitespaces))
                break
            }
        }
        guard !hits.isEmpty else { return "无异常。" }
        return "```text\n" + hits.prefix(50).joined(separator: "\n")
             + (hits.count > 50 ? "\n…（共 \(hits.count) 条，此处列前 50）" : "")
             + "\n```"
    }
}

/// The T07 verdict, as a pure function that does no adb I/O.
extension BoardItems {

    struct T07Verdict {
        let validity: [Check]
        let criteria: [Check]
        let measurements: [Measurement]
        let cycles: Int
    }

    /// - Parameter rebooted: whether an unexpected reboot occurred.
    static func t07Verdict(progress: String, rebooted: Bool,
                           targetCycles: Int, elapsed: TimeInterval) -> T07Verdict {
        let cycles = RE.all(#"cycle (\d+)"#, in: progress).compactMap(Int.init).max() ?? 0
        // Early-stop marker: the payload writes SUSPENDFAIL and stops on the first failing cycle.
        let suspendFail = progress.contains("SUSPENDFAIL")

        // Positive evidence: the kernel's count of successful suspends must actually increase.
        let s0 = RE.firstInt(#"SUSPEND_SUCCESS start=(\d+)"#, in: progress) ?? 0
        let s1 = RE.firstInt(#"SUSPEND_SUCCESS end=(\d+)"#, in: progress) ?? s0
        let actualSuspends = max(0, s1 - s0)

        // The count is the acceptance standard, so it is a criterion. Whether the board really
        // suspended, and whether it reached its own end, are facts about the run.
        let criteria: [Check] = [
            .equals("意外重启", rebooted ? 1 : 0, 0),
            .equals("挂起失败", suspendFail ? 1 : 0, 0),
            .isTrue("跑满目标周期数", cycles >= targetCycles,
                    expected: "≥ \(targetCycles) 个周期"),
        ]
        let validity: [Check] = [
            // pm-suspend can exit 0 without the kernel ever suspending.
            .isTrue("确实挂起过", actualSuspends > 0,
                    expected: "内核 suspend_stats.success 递增"),
            .isTrue("挂起次数与周期数相符", cycles > 0 && actualSuspends >= cycles - 1,
                    expected: "内核计数 ≥ 周期数 − 1"),
        ]
        return T07Verdict(
            validity: validity, criteria: criteria,
            measurements: [
                .num("完成周期", Double(cycles)),
                .num("内核记录挂起次数", Double(actualSuspends)),
                .num("要求周期数", Double(targetCycles), "次"),
                .num("实际历时", elapsed.rounded(), "s"),
            ],
            cycles: cycles)
    }
}

/// Report tables for the long-running tests.
extension BoardItems {

    /// Whether frequency switching continued to the end of the scaling phase.
    struct ScaleContinuity {
        /// Seconds between the last switch record and PHASE_C_DONE.
        let gapAtEnd: Int
        /// Flush cadence in seconds, derived from the record intervals, used to set the tolerance.
        let flushInterval: Int
        /// Derived from the flush interval rather than hard-coded.
        var tolerance: Int { Thresholds.scaleContinuityTolerance(flushInterval: flushInterval) }
        var isContinuous: Bool { gapAtEnd >= 0 && gapAtEnd <= tolerance }
    }

    static func scaleContinuity(_ bt: BoardTest, progress: String) async -> ScaleContinuity? {
        let prog = await bt.read("scale_prog")
        let stamps = prog.components(separatedBy: .newlines).compactMap { line -> Int? in
            Int(line.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "")
        }
        guard let last = stamps.last else { return nil }

        func stamp(of marker: String) -> Int? {
            for line in progress.components(separatedBy: .newlines) where line.contains(marker) {
                if let t = Int(line.split(whereSeparator: \.isWhitespace).first
                                .map(String.init) ?? "") { return t }
            }
            return nil
        }
        guard let end = stamp(of: "PHASE_C_DONE") else { return nil }

        // The flush cadence is the median of the record intervals.
        let gaps = zip(stamps, stamps.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }.sorted()
        let median = gaps.isEmpty ? 10 : gaps[gaps.count / 2]
        return ScaleContinuity(gapAtEnd: end - last, flushInterval: median)
    }

    /// Plain description of the current T06 phase.
    static func t06Phase(_ log: String, requested: Set<BurninPhase>) -> String {
        let order = BurninPhase.ordered(requested)
        for (i, phase) in order.enumerated().reversed()
        where log.contains("PHASE_\(phase.rawValue)_START") {
            return "第 \(i + 1) 段 / 共 \(order.count) 段 · \(phase.detail)"
        }
        return "正在启动"
    }

    // MARK: - Report tables

    /// Phase overview.
    static func t06Table(_ progress: String, duration: Int,
                         ran: Set<BurninPhase>) -> String {
        var rows = ["| 阶段 | 内容 | 要求时长 | 结论 |", "|---|---|---|---|"]
        for (i, phase) in BurninPhase.ordered(ran).enumerated() {
            let done = progress.contains("PHASE_\(phase.rawValue)_DONE")
            rows.append("| 第 \(i + 1) 段 | \(phase.detail) | \(fmt(duration)) "
                      + "| \(done ? "已完成" : "未完成") |")
        }
        let skipped = BurninPhase.allCases.filter { !ran.contains($0) }
        if !skipped.isEmpty {
            rows.append("")
            rows.append("本次未选：" + skipped.map(\.title).joined(separator: "、"))
        }
        return rows.joined(separator: "\n")
    }

    static func t07Table(_ progress: String, cycles: Int, target: Int) -> String {
        let failures = RE.all(#"rc=([1-9]\d*)"#, in: progress).count
        let statFails = RE.all(#"fail=([1-9]\d*)"#, in: progress).count
        let s0 = RE.firstInt(#"SUSPEND_SUCCESS start=(\d+)"#, in: progress) ?? 0
        let s1 = RE.firstInt(#"SUSPEND_SUCCESS end=(\d+)"#, in: progress) ?? s0
        return """
            | 项 | 值 |
            |---|---|
            | 完成周期数 | \(cycles) |
            | **内核记录的成功挂起次数** | **\(max(0, s1 - s0))** |
            | 要求周期数 | \(target) |
            | pm-suspend 返回非 0 的周期 | \(failures) |
            | suspend_stats fail 递增的周期 | \(statFails) |
            """
    }

    static func t08Table(boots: Int, gaps: [Int], target: Int) -> String {
        let maxGap = gaps.max() ?? 0
        let avgGap = gaps.isEmpty ? 0 : gaps.reduce(0, +) / gaps.count
        return """
            | 项 | 值 |
            |---|---|
            | 重启次数 | \(boots) |
            | 要求重启次数 | \(target) |
            | 平均起回间隔 | \(avgGap)s |
            | 最长起回间隔 | \(maxGap)s |
            """
    }

    /// Segmented statistics of the boot gaps.
    static func gapSegments(_ gaps: [Int], segments: Int = 5) -> String {
        guard gaps.count >= 2 else { return "（重启次数不足，无法分段统计）" }
        let size = max(1, gaps.count / segments)
        var rows = ["| 区段 | 次数 | 平均起回 | 最长起回 |", "|---|---|---|---|"]
        var idx = 0
        while idx < gaps.count {
            let chunk = Array(gaps[idx..<min(idx + size, gaps.count)])
            let avg = chunk.reduce(0, +) / chunk.count
            rows.append("| 第 \(idx + 1)–\(idx + chunk.count) 次 | \(chunk.count) "
                      + "| \(avg)s | \(chunk.max() ?? 0)s |")
            idx += size
        }
        let all = gaps.reduce(0, +) / gaps.count
        rows.append("| **总计** | **\(gaps.count)** | **\(all)s** | **\(gaps.max() ?? 0)s** |")
        return rows.joined(separator: "\n")
    }

    private static func fmt(_ s: Int) -> String {
        if s >= 3600 { return "\(s / 3600) 小时" + (s % 3600 > 0 ? " \((s % 3600) / 60) 分" : "") }
        if s >= 60 { return "\(s / 60) 分" + (s % 60 > 0 ? " \(s % 60) 秒" : "") }
        return "\(s) 秒"
    }
}

/// Parser for the stressapptest summary line.
struct SatSummary: Equatable {
    var completedMB: Double = 0
    var seconds: Double = 0
    var bandwidthMBps: Double = 0
    var incidents: Int = 0
    var errors: Int = 0

    init(_ line: String) {
        // The magnitudes are large, around 4.7e8 M, so Double is used.
        if let v = RE.first(#"Completed:\s+([0-9.]+)M"#, in: line) { completedMB = Double(v) ?? 0 }
        if let v = RE.first(#"in\s+([0-9.]+)s"#, in: line) { seconds = Double(v) ?? 0 }
        if let v = RE.first(#"([0-9.]+)MB/s"#, in: line) { bandwidthMBps = Double(v) ?? 0 }
        if let v = RE.first(#"(\d+)\s+hardware incidents"#, in: line) { incidents = Int(v) ?? 0 }
        if let v = RE.first(#"(\d+)\s+errors"#, in: line) { errors = Int(v) ?? 0 }
    }
}
