import Foundation

/// The T06 verdict, as a pure function that does no adb I/O.
extension BoardItems {

    /// Every input the verdict needs, all of it produced on the board.
    struct T06Inputs {
        var progress: String
        var ran: Set<BurninPhase>
        /// Whether an unexpected reboot occurred.
        var rebooted: Bool
        var memFailures: Int
        var scaleFailures: Int
        var mtBLoops: Int
        var mtCLoops: Int
        var scaleOK: Int
        var continuity: ScaleContinuity?
        var sat: SatSummary
        var durationSeconds: Int
        var elapsed: TimeInterval
    }

    struct T06Verdict {
        /// Was this run worth judging: did each selected phase actually do its work, did the
        /// frequency lock take, did our own memory pressure spoil the sampling.
        let validity: [Check]
        /// What the material did. Six of the fourteen checks this item makes are about the material;
        /// the rest are about whether the test ran, and used to render as 不通过 alongside them.
        let criteria: [Check]
        let measurements: [Measurement]
    }

    /// Which positive-evidence reads came back unreadable, for the phases that actually ran.
    ///
    /// `grep -c` prints `0` when the file is readable and has no match, so nil here can only mean
    /// the read itself failed — a missing file or an adb hiccup, both legitimate mid-run events
    /// (T07 suspends every 17 s, T08 reboots). Coercing nil to 0 made the verdict's positive
    /// evidence read it as "the phase never executed" and fail the material for our own I/O
    /// failure. error ≠ fail: decisions.md §2.1, and the T07 incident recorded there where every
    /// reading came back empty and four checks failed at once.
    ///
    /// The stressapptest summary is deliberately not covered: an empty summary means either
    /// "unreadable" or "the tool printed no summary", which are not distinguishable at this level,
    /// and `T06VerdictReplayTests.testPhaseAFailsWithoutEvidenceOfWork` pins the current intent.
    static func t06UnreadableEvidence(ran: Set<BurninPhase>,
                                     mtBLoops: Int?, mtCLoops: Int?,
                                     scaleOK: Int?) -> String? {
        var missing: [String] = []
        if ran.contains(.fixedMemtester), mtBLoops == nil {
            missing.append("定频段 memtester 循环数")
        }
        if ran.contains(.scalingMemtester) {
            if mtCLoops == nil { missing.append("变频段 memtester 循环数") }
            if scaleOK == nil { missing.append("成功切频次数") }
        }
        guard !missing.isEmpty else { return nil }
        return "读不到板端的" + missing.joined(separator: "、") + "，无法判定该段是否实际执行"
    }

    static func t06Verdict(_ i: T06Inputs) -> T06Verdict {
        let oomStart = RE.firstInt(#"OOM start=(\d+)"#, in: i.progress) ?? 0
        let oomEnd = RE.firstInt(#"OOM end=(\d+)"#, in: i.progress) ?? oomStart
        let oomDelta = max(0, oomEnd - oomStart)
        let phasesDone = i.ran.filter { i.progress.contains("PHASE_\($0.rawValue)_DONE") }.count

        // Both lists are restricted to the phases that actually ran.
        //
        // Which list a check belongs in is the whole decision. "memtester found a bit error" and
        // "memtester never looped" shared one list in the first iteration, so both reported the
        // material as defective — the second one on the strength of our own read having failed.
        var criteria: [Check] = [
            // A board that restarts on its own under memory stress is the instability this screens for.
            .equals("意外重启", i.rebooted ? 1 : 0, 0),
            .equals("memtester FAILURE", i.memFailures, 0),
        ]
        var validity: [Check] = [
            // Our own host pressure, not the board's: an OOM-kill during the load voids the sampling.
            .equals("新增 OOM-kill", max(0, oomDelta), 0),
        ]

        if i.ran.contains(.fixedSat) {
            criteria.append(.equals("stressapptest 失败",
                                    i.progress.components(separatedBy: "SATABORT").count - 1, 0))
            // The counters the tool reports about the hardware it exercised.
            criteria.append(.equals("stressapptest 硬件事件", i.sat.incidents, 0))
            criteria.append(.equals("stressapptest 报错数", i.sat.errors, 0))
            // Positive evidence: the tool can exit 0 having moved nothing at all.
            validity.append(.isTrue("stressapptest 实际搬过数据", i.sat.completedMB > 0,
                                    expected: "汇总行 Completed > 0"))
        }
        if i.ran.contains(.fixedSat) || i.ran.contains(.fixedMemtester) {
            // devfreq refusing the requested frequency is a firmware problem, not a DRAM defect.
            validity.append(.equals("定频失败",
                                    i.progress.components(separatedBy: "FIXFAIL").count - 1, 0))
        }
        if i.ran.contains(.fixedMemtester) {
            validity.append(.isTrue("memtester 实际执行（定频段）", i.mtBLoops > 0,
                                    expected: "日志出现 Loop"))
        }
        if i.ran.contains(.scalingMemtester) {
            criteria.append(.equals("变频失败", i.scaleFailures, 0))
            validity += [
                .isTrue("memtester 实际执行（变频段）", i.mtCLoops > 0, expected: "日志出现 Loop"),
                .isTrue("变频实际发生", i.scaleOK > 0, expected: "成功切频次数 > 0"),
                Check(name: "变频持续至本段结束",
                      actual: i.continuity.map { "末次切频距结束 \($0.gapAtEnd)s" } ?? "无切频记录",
                      expected: i.continuity.map { "≤ \($0.tolerance)s" } ?? "存在切频记录",
                      passed: i.continuity?.isContinuous ?? false),
            ]
        }
        // No "reached its own end" check here. Getting this far already means the board wrote a
        // terminal marker — `LongTest.settleOrFail` turns silence into an interrupted execution — and
        // `FAILED` is a terminal marker too: a payload that stops early on a defect it found has
        // reached its end deliberately. Demanding ALLDONE would invalidate exactly the runs that
        // found something, hiding a real defect behind "this run was not valid".

        var measurements: [Measurement] = [
            .text("执行段", BurninPhase.ordered(i.ran).map(\.title).joined(separator: " → ")),
            // The phase count is recorded as its own number.
            .num("执行段数", Double(i.ran.count)),
            .num("完成段数", Double(phasesDone)),
            .num("每段时长", Double(i.durationSeconds), "s"),
            .num("实际历时", i.elapsed.rounded(), "s"),
        ]
        if i.ran.contains(.fixedSat), i.sat.bandwidthMBps > 0 {
            // Corroborates the T05 peak; measured 12164 MB/s peak against 10943 MB/s average here.
            measurements.append(.num("拷机平均带宽", i.sat.bandwidthMBps, "MB/s"))
        }
        if i.ran.contains(.fixedMemtester) {
            measurements.append(.num("memtester 循环数（定频段）", Double(i.mtBLoops)))
        }
        if i.ran.contains(.scalingMemtester) {
            // Evidence that the scaling phase actually switched frequency.
            measurements.append(.num("成功切频次数", Double(i.scaleOK)))
            measurements.append(.num("memtester 循环数（变频段）", Double(i.mtCLoops)))
        }
        if let size = RE.firstInt(#"size=(\d+)M"#, in: i.progress) {
            measurements.append(.num("测试内存", Double(size), "MB"))
        }

        return T06Verdict(validity: validity, criteria: criteria,
                          measurements: measurements)
    }
}
