import Foundation

/// Renderer for the preliminary test report. Invariants: docs/decisions.md.
public struct ReportRenderer {

    init() {}

    // MARK: - Entry point

    /// Renders the whole preliminary report from one run's record.
    /// A version this renderer does not know is refused rather than guessed at.
    public static func render(_ run: Run) -> String {
        guard run.schemaVersion == Run.currentSchema else {
            return "# 无法渲染报告\n\n本报告数据的 schemaVersion 为 \(run.schemaVersion)，"
                 + "当前程序只认识 \(Run.currentSchema)。请用生成它的版本打开。\n"
        }
        var out: [String] = []
        let isDDR = run.flow == .ddr

        // One title. There used to be two — 抽测记录 for a run that asked less than a compiled-in
        // standard, 初步报告 otherwise — which only worked because the software held an opinion
        // about the right amount. It no longer does: a run is judged against what it was asked to
        // do, so every run produces the same document, and 本次范围 below says what was asked.
        out.append("# AZ0X 系列 \(isDDR ? "DDR" : "eMMC") 物料验证报告")
        out.append("")
        out += headerTable(run)
        out.append("")
        out += resultTable(items: run.items, results: run.results,
                          terminatedAt: run.stoppedAt)
        out.append("")
        out += appendices(items: run.items, results: run.results)
        return out.joined(separator: "\n") + "\n"
    }

    // MARK: - Header table

    private static func headerTable(_ run: Run) -> [String] {
        let model = run.model, flow = run.flow, items = run.items, results = run.results
        let toolVersions = run.toolVersions, appVersion = run.appVersion
        let boardIdentity = run.board.reported
        let cpuid = run.board.cpuid, serial = run.board.serial
        let chipVariant = run.board.chipVariant
        let startedAt = run.startedAt, finishedAt = run.finishedAt
        let isDDR = flow == .ddr
        var rows: [(String, String)] = []

        rows.append(("被测型号", "\(model.soc)（\(model.rawValue)）"))

        // Items unsupported by the model never enter the sequence.
        let excluded = TestItem.excluded(for: flow, model: model)
            .filter { ex in !items.contains { $0.code == ex.code } }
        if !excluded.isEmpty {
            rows.append(("序列范围",
                         "本型号无 \(excluded.map(\.title).joined(separator: "、"))功能，"
                       + "验证序列不含 \(excluded.map(\.code).joined(separator: "、"))"))
        }

        // What this run was asked to do — always stated, never measured against anything.
        //
        // This one row replaces the whole 抽测 apparatus. It is stronger than a warning banner was:
        // a banner appeared once on the cover and only when something looked short, whereas this
        // names every amount every time, so a pass of five cycles reads 休眠唤醒 5 次 and cannot be
        // read as a pass of three thousand.
        var scope: [String] = []
        let deselected = Self.deselected(flow: flow, model: model, items: items)
        if deselected.isEmpty {
            scope.append("\(items.count) 项全部执行")
        } else {
            scope.append("执行 \(items.count) 项；未选 "
                       + deselected.map(\.code).joined(separator: "、")
                       + "（\(deselected.count) 项）")
        }
        // The phase count comes from the board-side record, which is a measurement of T06.
        let phases = run.ranBurninPhases ?? run.burninPhases.count
        scope += run.scale.summary(for: items, burninPhases: phases)
        rows.append(("本次范围", scope.joined(separator: "；")))

        // The spec summary comes from the probing items' measurements.
        if isDDR {
            rows.append(("DDR 规格", measurement(results, "T01", "匹配 cfg")
                                        .map(specFromCfgName) ?? "—"))
        } else {
            let parts = ["型号", "容量", "时序档位"].compactMap { measurement(results, "E02", $0) }
            rows.append(("eMMC 规格", parts.isEmpty ? "—" : parts.joined(separator: "，")))
        }

        rows.append(("测试工具", toolList(items: items)))
        if !toolVersions.isEmpty {
            rows.append(("工具版本", toolVersions.joined(separator: "；")))
        }
        // Named separately from 工具版本, which is about the bundled third-party CLIs.
        if !appVersion.isEmpty {
            rows.append(("验证程序", "AZ0XValidator \(appVersion)"))
        }
        rows.append(("镜像", measurement(results, isDDR ? "T04" : "E01", "镜像") ?? "—"))
        // Which board produced this report. The serial is the board's own identity,
        // derived from the cpuid burned into its OTP.
        if let chipVariant {
            // Otherwise 被测型号 states the selection and 芯片型号 states the board, and the
            // two contradict each other with nothing saying which is which.
            let clash = model.contradicts(chipVariant: chipVariant)
            rows.append(("芯片型号", clash
                         ? "\(chipVariant)（与所选型号 \(model.rawValue) 不符）"
                         : chipVariant))
        }
        if let serial { rows.append(("板卡序列号", serial)) }
        if let cpuid { rows.append(("芯片 ID", cpuid)) }
        if let boardIdentity { rows.append(("被测设备", boardIdentity)) }

        if let s = startedAt {
            // A 60-hour validation spans days, so the end time must carry a date.
            var t = stamp.string(from: s)
            if let f = finishedAt {
                t += " → \(stamp.string(from: f))"
                t += "（历时 \(durationText(f.timeIntervalSince(s)))）"
            }
            rows.append(("测试时间", t))
        }

        rows += verdictRows(run)

        var out = ["| 项目 | 信息 |", "|------|------|"]
        out += rows.map { "| \($0.0) | \(escape($0.1)) |" }
        return out
    }

    /// Number of T06 phases actually run, taken from the board-side record; nil if T06 did not run.
    static func burninPhaseCount(_ results: [String: ItemResult]) -> Int? {
        guard let m = results["T06"]?.measurements.first(where: { $0.name == "执行段数" }),
              case let .number(v, _) = m.value else { return nil }
        return Int(v)
    }

    static func burninPhasesReduced(_ results: [String: ItemResult]) -> Bool {
        (burninPhaseCount(results) ?? BurninPhase.allCases.count) < BurninPhase.allCases.count
    }

    /// Items not selected this run: supported by the model but absent from this sequence.
    static func deselected(flow: ValidationFlow, model: DeviceModel,
                           items: [TestItem]) -> [TestItem] {
        let ran = Set(items.map(\.code))
        return TestItem.items(for: flow, model: model).filter { !ran.contains($0.code) }
    }

    /// The summary rows: one per axis, rather than one sentence trying to carry all three.
    ///
    /// The first iteration crammed the verdict, the execution problems and the unjudged items into a
    /// single 自动判定 line, so a run where a record-only reading could not be taken had nowhere to
    /// say so except by sounding like a failure. Three rows say three different things and none of
    /// them can be mistaken for another.
    private static func verdictRows(_ run: Run) -> [(String, String)] {
        var rows: [(String, String)] = []
        let notRun = run.notRunItems
        let notPassed = run.notPassedItems
        let passed = run.passedItems
        func title(_ code: String) -> String {
            run.items.first { $0.code == code }?.displayTitle ?? code
        }

        // Row 1 — what this run did. It reports the outcome of the criteria and stops there.
        //
        // Every clause that told the reader what to make of that is gone: 不构成物料导入结论 said
        // whether the material may be imported, which is a decision for a person, and 不构成物料判定
        // interpreted a fact the row below already explains item by item. The counts are the facts;
        // reading them is not the software's job.
        if let stopped = run.abortedAt {
            rows.append(("执行结果",
                         "⏹ 操作员已于 \(title(stopped)) 手动终止本次验证"
                       + "；后续 \(notRun.count) 项未执行"))
        } else if let stopped = run.stoppedAt, run.results[stopped]?.condemnsMaterial == true {
            let why = run.results[stopped]?.detail ?? ""
            rows.append(("执行结果",
                         "❌ 已在 \(title(stopped)) 终止\(why.isEmpty ? "" : "：\(why)")"
                       + "；后续 \(notRun.count) 项未执行"))
        } else if !notPassed.isEmpty {
            rows.append(("执行结果",
                         "❌ \(notPassed.count) 项未通过（"
                       + notPassed.map(\.displayTitle).joined(separator: "、") + "）"))
        } else if !notRun.isEmpty {
            rows.append(("执行结果",
                         "⚠️ 未完成：\(passed.count) 项通过，\(notRun.count) 项未执行（"
                       + notRun.map(\.displayTitle).joined(separator: "、")
                       + "）"))
                } else if !run.noResultItems.isEmpty {
            // "全部通过" would overclaim: something was not measured, and the row below says which.
            rows.append(("执行结果", "✅ 已判定的 \(passed.count) 项均通过"))
        } else {
            rows.append(("执行结果", "✅ \(passed.count) 项全部通过"))
        }

        // Row 2 — items that reached no conclusion. Our side, never the material's.
        let noResult = run.noResultItems
        if !noResult.isEmpty {
            let detail = noResult.map { item -> String in
                let why = run.results[item.code]?.detail ?? ""
                return why.isEmpty ? item.displayTitle : "\(item.displayTitle)：\(why)"
            }
            rows.append(("未得结果",
                         "⚠️ \(noResult.count) 项未取得结果（" + detail.joined(separator: "；")
                       + "）—— 环境或工具问题"))
        }

        // Row 3 — measured, with no criterion for the software to apply.
        let recordOnly = run.recordOnlyItems
        if !recordOnly.isEmpty {
            rows.append(("仅记录",
                         "📊 \(recordOnly.count) 项无自动判据（"
                       + recordOnly.map(\.displayTitle).joined(separator: "、")
                       + "）—— 本报告如实列出实测值，请依物料规格书判读"))
        }
        return rows
    }

    // MARK: - Result table

    private static func resultTable(
        items: [TestItem], results: [String: ItemResult], terminatedAt: String?
    ) -> [String] {
        var out = ["## 测试结果", "",
                   "| 编号 | 测试项 | 测试方法 | 测试结果 |",
                   "|------|--------|----------|----------|"]
        for item in items {
            let cell = results[item.code].map { resultCell(item: item, result: $0) } ?? "— 未执行"
            out.append("| \(item.code) | \(item.title) | \(escape(item.method)) | \(escape(cell)) |")
        }
        return out
    }

    /// Result cell of one item, read off the two axes.
    ///
    /// A verdict and an execution problem must never render alike: 失败 says the material is
    /// defective, 未得结果 says we did not establish anything. That is the one distinction a reader
    /// acts on, so it is the one the mark carries.
    private static func resultCell(item: TestItem, result: ItemResult) -> String {
        let key = keyValues(item: item, result: result)
        let suffix = key.isEmpty ? "" : "（\(key)）"

        guard let execution = result.execution else { return "— 未执行" }
        switch execution {
        case let .notStarted(why):
            return "⏭️ 跳过：\(why)"
        case let .interrupted(why):
            return "⚠️ 未得结果：\(why)"
        case let .invalid(why):
            // It ran, so whatever it did measure is worth carrying: the reader needs to see that the
            // board did the work before deciding whether to re-read it or re-run it.
            return "⚠️ 未得结果\(suffix)：\(why)"
        case .completed:
            switch result.verdict {
            case .passed?:
                return "✅ 通过\(suffix)"
            case let .notPassed(why)?:
                return "❌ 失败\(suffix)：\(why)"
            case .noCriterion?:
                // Measured, not judged. Deliberately neither ✅ nor ❌: there is no criterion here,
                // and a mark that reads like a verdict would claim one.
                return "📊 仅记录\(suffix)"
            case nil:
                return "⚠️ 未得结果\(suffix)"
            }
        }
    }

    /// Key values carried in the result column: one or two per item, with the rest in the appendix.
    private static func keyValues(item: TestItem, result: ItemResult) -> String {
        // On a verdict against the material every failing criterion is listed, not only the first:
        // showing one made an empty read look like a specific hardware event, when in truth nothing
        // had been read at all. Validity failures are not listed here — the execution's own reason
        // already names the one that decided it, and repeating it reads as two separate problems.
        let bad = result.criteria.filter { !$0.passed }
        if !bad.isEmpty {
            return bad.map { "\($0.name) \($0.actual)，要求 \($0.expected)" }
                .joined(separator: "；")
        }
        var picks = keyMeasurementNames[item.code] ?? []
        // A long-running item must show its actual duration.
        if item.isLongRunning { picks.append("实际历时") }
        let vals = picks.compactMap { name -> String? in
            guard let m = result.measurements.first(where: { $0.name == name }) else { return nil }
            return "\(m.name) \(m.value.display)"
        }
        if !vals.isEmpty { return vals.joined(separator: "；") }

        // Fallback when no key matched but measurements exist: list them all.
        return result.measurements.prefix(4)
            .map { "\($0.name) \($0.value.display)" }
            .joined(separator: "；")
    }

    /// Which values each item shows in the result column. Internal, not private, so
    /// `KeyMeasurementNameTests` can assert every name here is one a producer actually records.
    /// The measurements worth showing beside an item's name, in the report row and in the
    /// interface alike — so the two never pick different ones out of the same record.
    public static func keyMeasurements(for code: String) -> [String] {
        keyMeasurementNames[code] ?? []
    }

    static let keyMeasurementNames: [String: [String]] = [
        // The cfg name already carries the capacity and the topology, so it is the whole column.
        "T01": ["匹配 cfg"],
        // T02's verdict is the information; the cfg says which test produced it. It asked for
        // 检出容量 and 总线位宽 until v2.7, when both stopped being recorded here — the geometry is
        // T01's, from the tool's structured field, rather than scraped out of T02's log.
        "T02": ["检测 cfg"],
        // The ✅ already carries the verdict. What a reader wants beside it is how long the scan took
        // and whether it ran to the end: 11.7 s on an RK3576, against an RK3588 cut off at 122 s.
        "T03": ["工具耗时", "扫描跑完"],
        // T04 and E01 carry only the image name and the flashing duration, as required.
        "T04": ["镜像", "镜像校验", "刷写耗时"],
        "T05": ["峰值带宽", "DDR 频率"],
        "T06": ["完成段数", "拷机平均带宽", "成功切频次数", "memtester 循环数（变频段）"],
        "T07": ["完成周期", "内核记录挂起次数"],
        "T08": ["重启次数", "最长起回间隔"],
        "E01": ["镜像", "镜像校验", "平均写入速率"],
        "E02": ["型号", "容量", "时序档位", "EOL 状态"],
        "E03": ["顺序读", "顺序写", "随机读 4K", "随机写 4K"],
        "E04": ["fio 退出码"],
        "E05": ["完成轮次", "实际写入"],
        "E06": ["顺序读", "顺序写", "随机读 4K", "随机写 4K"],
    ]

    // MARK: - Appendices

    /// The report is self-contained: it never points at files the reader does not receive.
    private static func appendices(items: [TestItem],
                                  results: [String: ItemResult]) -> [String] {
        // Only items with actual evidence get an appendix.
        let withEvidence = items.filter { !(results[$0.code]?.evidence.isEmpty ?? true) }
        guard !withEvidence.isEmpty else { return [] }

        var out = ["## 附录：原始测试输出", ""]
        var letter = UnicodeScalar("A").value
        for item in withEvidence {
            guard let r = results[item.code] else { continue }
            let tag = String(UnicodeScalar(letter)!)
            letter += 1
            out.append("<details><summary>附录 \(tag) — \(item.displayTitle)</summary>")
            out.append("")
            for e in r.evidence {
                out.append("**\(e.title)**")
                out.append("")
                switch e.kind {
                case .log:
                    out.append("```text")
                    out.append(abridged(e.body.trimmingCharacters(in: .newlines)))
                    out.append("```")
                case .markdown:
                    out.append(e.body.trimmingCharacters(in: .newlines))
                }
                out.append("")
            }
            out.append("</details>")
            out.append("")
        }
        return out
    }

    /// Shortens a long log for reading, keeping both ends.
    ///
    /// The record keeps every line — a three-thousand-cycle `progress.log` is what each number in
    /// this report was derived from, and it stays whole in `run.json`. A person reading the appendix
    /// wants the start and the end, not three thousand lines between them.
    ///
    /// Shortening is not parsing: nothing here reads a value out of a log. Every figure in this
    /// report came from a measurement or a check that was recorded when the item ran.
    static func abridged(_ body: String, head: Int = 25, tail: Int = 25) -> String {
        let lines = body.components(separatedBy: .newlines)
        guard lines.count > head + tail + 1 else { return body }
        let cut = lines.count - head - tail
        return (lines.prefix(head)
                + ["…（略去 \(cut) 行）…"]
                + lines.suffix(tail)).joined(separator: "\n")
    }

    // MARK: - Helpers

    private static let toolsByCode: [String: String] = [
        "T01": "RockchipDDRTestUtilityCLI --detect（规格）",
        "T02": "RockchipDDRTestUtilityCLI --solder（焊接）",
        "T03": "RockchipDDRTestUtilityCLI --eyescan（眼图）",
        "T04": "rockchip-flash-tool-cli + CI 快照镜像（刷机）",
        "E01": "rockchip-flash-tool-cli + CI 快照镜像（刷机）",
        "T05": "rk-msch-probe + stress-ng（带宽）",
        "T06": "stressapptest + memtester（拷机）",
        "T07": "pm-suspend + RTC（休眠唤醒）",
        "T08": "自启服务 + pstore（重启）",
        "E02": "sysfs + debugfs ios（规格 / 健康 / 总线协商）",
        "E03": "fio（性能 / 完整性）",
        "E04": "fio（性能 / 完整性）",
        "E05": "vendor flash_stress_test 逻辑（拷机）",
        "E06": "fio（性能 / 完整性）",
    ]

    /// Lists only the tools this sequence actually used.
    private static func toolList(items: [TestItem]) -> String {
        var seen = Set<String>()
        return items.compactMap { toolsByCode[$0.code] }
            .filter { seen.insert($0).inserted }
            .joined(separator: "；")
    }

    private static func measurement(_ results: [String: ItemResult],
                                    _ code: String, _ name: String) -> String? {
        results[code]?.measurements.first { $0.name == name }?.value.display
    }

    /// Extracts a spec summary from the cfg file name.
    static func specFromCfgName(_ cfg: String) -> String {
        var s = cfg
        if let dot = s.range(of: ".cfg", options: [.backwards, .caseInsensitive]) {
            s = String(s[s.startIndex..<dot.lowerBound])
        }
        for suffix in ["焊接检测", "眼图", "测试"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
            break
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// A `|` inside a cell breaks the Markdown table structure.
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
         .replacingOccurrences(of: "\n", with: " ")
    }

    static func durationText(_ t: TimeInterval) -> String { formatDuration(t) }

    private static var stamp: DateFormatter { operatorStamp }
}
