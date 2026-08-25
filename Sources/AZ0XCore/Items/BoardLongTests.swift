import Foundation

/// Board-side long runs: T06 burn-in, T07 suspend and resume, T08 reboot.
extension BoardItems {

    /// Duration of one phase in a formal validation: 12 hours.
    static let standardDuration = Thresholds.longRunSeconds

    static let boardRoot = "/userdata/az0x-ddr"

    // MARK: - T06 burn-in, fixed and scaling frequency, pass or fail

    /// Three phases in order: maximum frequency with stressapptest.
    ///
    /// Single exit, so that the rule about raw output holds on every path out of it — including the
    /// ones that end in 未得结果, which is exactly when someone needs to see what the tools printed.
    func runT06(durationSeconds: Int = BoardItems.standardDuration,
                phases: Set<BurninPhase> = Set(BurninPhase.allCases),
                onProgress: ((LongTestProgress) -> Void)? = nil) async -> ItemResult {
        guard let payload = BundledTools.payload("t06_burnin.sh") else {
            var r = ItemResult(code: "T06")
            r.interrupted("板端脚本 t06_burnin.sh 未随应用打包")
            return r
        }
        let bt = BoardTest(adb: adb, directory: "\(Self.boardRoot)/t06_burnin",
                           payload: payload, clock: clock)
        var r = await burnIn(bt, durationSeconds: durationSeconds, phases: phases,
                             onProgress: onProgress)
        // A passing run keeps only its summaries; anything else keeps what the tools actually
        // printed, because that is the only thing left to work from.
        if r.verdict != .passed {
            for (name, text) in await bt.fetch(["satA.out", "mtB.log", "mtC.log", "scaleC.log"]) {
                r.evidence.append(.log(name, LongTest.tail(LongTest.normalize(text), 80)))
            }
        }
        return r
    }

    /// The body of T06. Never call this directly: `runT06` owns attaching the raw output.
    private func burnIn(_ bt: BoardTest, durationSeconds: Int, phases: Set<BurninPhase>,
                        onProgress: ((LongTestProgress) -> Void)?) async -> ItemResult {
        var r = ItemResult(code: "T06")

        let bootBefore = await bt.currentBootID()
        guard await LongTest.startFresh(bt, bound: durationSeconds,
                                        extraArgs: BurninPhase.mask(phases),
                                        into: &r) else { return r }

        let started = Date()
        let wait = await bt.waitDone(
            doneMarker: "ALLDONE",
            pollSeconds: 10,
            patience: .untilDeclaredDuration(
                BoardTest.budget(wallClock: durationSeconds, phases: phases.count))) { log in
            Task { @MainActor in
                onProgress?(LongTestProgress(
                    phase: Self.t06Phase(log, requested: phases),
                    elapsed: Date().timeIntervalSince(started),
                    scale: .duration(Double(durationSeconds * phases.count)),
                    logTail: LongTest.tail(log, 18)))
            }
        }

        if let bad = await LongTest.settleOrFail(wait, bt, into: &r) { return bad }

        let progress = await bt.read("progress.log")
        guard !progress.isEmpty else {
            r.invalid("读不到板端 progress.log，结果不可信")
            return r
        }

        // Which phases ran is taken from the board-side record.
        let ran = BurninPhase.parseMask(RE.first(#"PHASES ([ABC]+)"#, in: progress) ?? "")
        guard !ran.isEmpty else {
            r.invalid("板端未记录执行段（progress.log 无 PHASES 行），无法判定")
            r.evidence = [.log("板端 progress.log", progress)]
            return r
        }
        guard let didReboot = await bt.rebooted(since: bootBefore) else {
            r.invalid("读不到板端 boot_id，无法判断是否意外重启")
            r.evidence = [.log("板端 progress.log", progress)]
            return r
        }
        // These two count *failures*, so `?? 0` is the safe direction and must stay. `scaleC.log` is
        // only created when a frequency switch fails, so on a healthy run it does not exist and the
        // read legitimately comes back empty — verified on an AZ04A, 132 successful switches and no
        // file. Treating that as unreadable would turn every passing T06 into 未得结果. The positive
        // evidence below is the opposite case: there, an empty read must never become a zero.
        let memFailures = await adb.int(
            "cat \(bt.directory)/mt*.log 2>/dev/null | grep -ic FAILURE") ?? 0
        let scaleFailures = await adb.int(
            "grep -c SCALEFAIL \(bt.directory)/scaleC.log 2>/dev/null") ?? 0

        // The three values below are positive evidence that a phase actually executed.
        let satSummary = ran.contains(.fixedSat)
            ? await adb.line("grep 'Stats: Completed:' \(bt.directory)/satA.log 2>/dev/null | tail -1")
            : ""
        let satStats = SatSummary(satSummary)
        // Read as optionals: nil is "the read failed", which must not arrive at the verdict as a
        // zero. `grep -c` prints 0 for a readable file with no match, so the two are separable.
        let mtBRan = await adb.int("grep -c Loop \(bt.directory)/mtB.log 2>/dev/null")
        let mtCRan = await adb.int("grep -c Loop \(bt.directory)/mtC.log 2>/dev/null")
        let scaleOK = Int(await bt.read("scale_ok"))
        if let why = Self.t06UnreadableEvidence(ran: ran, mtBLoops: mtBRan,
                                               mtCLoops: mtCRan, scaleOK: scaleOK) {
            r.invalid(why)
            r.evidence = [.log("板端 progress.log", progress)]
            return r
        }

        // Switching must continue to the end of the phase.
        let continuity = await Self.scaleContinuity(bt, progress: progress)

        let v = Self.t06Verdict(.init(
            progress: progress, ran: ran, rebooted: didReboot,
            memFailures: memFailures, scaleFailures: scaleFailures,
            // Safe to default here: the guard above proved every value a judged phase needs is
            // present, so a zero can only belong to a phase that did not run and is not checked.
            mtBLoops: mtBRan ?? 0, mtCLoops: mtCRan ?? 0, scaleOK: scaleOK ?? 0,
            continuity: continuity, sat: satStats,
            durationSeconds: durationSeconds,
            elapsed: Date().timeIntervalSince(started)))
        r.validity = v.validity
        r.criteria = v.criteria
        r.measurements = v.measurements

        r.conclude()
        r.evidence = [
            .markdown("各段总览", Self.t06Table(progress, duration: durationSeconds, ran: ran)),
            .markdown("异常清单", LongTest.anomalyList(progress,
                markers: ["SATABORT", "FIXFAIL", "SCALEFAIL", "SUSPENDFAIL"])),
            .log("板端 progress.log", progress),
        ]
        return r
    }

    // MARK: - T07 suspend and resume, pass or fail

    /// Loops: set the RTC wake alarm, call pm-suspend, then stay awake after resuming.
    func runT07(targetCycles: Int = Thresholds.longRunCycles,
                onProgress: ((LongTestProgress) -> Void)? = nil) async -> ItemResult {
        var r = ItemResult(code: "T07")
        guard let payload = BundledTools.payload("t07_suspend.sh") else {
            r.interrupted("板端脚本 t07_suspend.sh 未随应用打包")
            return r
        }
        let bt = BoardTest(adb: adb, directory: "\(Self.boardRoot)/t07_suspend",
                           payload: payload, clock: clock)

        let bootBefore = await bt.currentBootID()
        // Payload usage: t07_suspend.sh <cycles> [dwell]
        guard await LongTest.startFresh(bt, bound: targetCycles,
                                        into: &r) else { return r }

        let started = Date()
        // The count last read, so an offline line keeps reporting the same one instead of dropping
        // to zero: the board is away, not back at the beginning.
        let seen = LastCount()
        let wait = await bt.waitDone(
            doneMarker: "ALLDONE", pollSeconds: 10,
            // No clock, and no view on how fast a cycle should be: the host waits while the
            // board still has the suspend loop running.
            patience: .whileTestIsRunning({ await bt.payloadAlive() }),
            onTick: { log in
            let cycles = RE.all(#"cycle (\d+)"#, in: log).compactMap(Int.init).last ?? 0
            seen.value = cycles
            Task { @MainActor in
                onProgress?(LongTestProgress(
                    phase: "RTC 唤醒 + pm-suspend 循环",
                    elapsed: Date().timeIntervalSince(started),
                    scale: .count(done: Double(cycles), target: Double(targetCycles)),
                    logTail: LongTest.tail(log, 18)))
            }
        },
            onOffline: { away in
            Task { @MainActor in
                onProgress?(LongTestProgress(
                    phase: "板子离线（休眠中）已 \(formatDuration(away))",
                    elapsed: Date().timeIntervalSince(started),
                    scale: .count(done: Double(seen.value), target: Double(targetCycles)),
                    logTail: ""))
            }
        })

        // A board that left and never came back is a verdict, not a missing result: the host, the
        // USB ports and the operator are all given, and the board is present throughout, so what is
        // left is a suspend it did not wake from. That is what this item measures.
        if case let .boardGone(away, lastLog) = wait {
            return Self.t07BoardGone(&r, lastLog: lastLog, away: away, target: targetCycles,
                                     elapsed: Date().timeIntervalSince(started))
        }
        // The polling outcome must be handled.
        if let bad = await LongTest.settleOrFail(wait, bt, into: &r) { return bad }

        let progress = await bt.read("progress.log")
        guard !progress.isEmpty else {
            r.invalid("读不到板端 progress.log，结果不可信")
            return r
        }
        // Three-state: an unreadable boot_id must not be guessed.
        guard let didReboot = await bt.rebooted(since: bootBefore) else {
            r.invalid("读不到板端 boot_id，无法判断是否意外重启")
            r.evidence = [.log("板端 progress.log", progress)]
            return r
        }

        let v = Self.t07Verdict(progress: progress, rebooted: didReboot,
                                targetCycles: targetCycles,
                                elapsed: Date().timeIntervalSince(started))
        r.validity = v.validity
        r.criteria = v.criteria
        r.measurements = v.measurements
        let cycles = v.cycles

        r.conclude()
        // The path is /sys/power/suspend_stats/; newer kernels moved it out of /sys/kernel/debug/.
        let stats = await adb.line(
            "for f in /sys/power/suspend_stats/*; do "
          + "[ -f \"$f\" ] && printf '%s: %s\\n' \"$(basename $f)\" \"$(cat $f 2>/dev/null)\"; done")
        r.evidence = [
            .markdown("周期总览", Self.t07Table(progress, cycles: cycles,
                                              target: targetCycles)),
            .markdown("异常清单", LongTest.anomalyList(progress, markers: ["SUSPENDFAIL", "rc=[1-9]"])),
            .log("首尾周期样本", LongTest.headTail(progress, 3)),
            .log("内核 suspend_stats", stats),
            .log("板端 progress.log", progress),
        ]
        return r
    }

    // MARK: - T08 reboot, pass or fail

    /// Installs an init service that reboots repeatedly.
    ///
    /// Single exit on purpose. This is the one item that leaves something running on the board, and
    /// every path out of it — a defect found, no result, the operator stopping, the budget expiring —
    /// must still take that service back off, or the board reboots forever and someone has to notice
    /// and fix it by hand. Swift forbids `await` in a `defer`, so the body is an inner function and
    /// the removal happens here, once, after it returns.
    func runT08(targetBoots: Int = Thresholds.longRunCycles,
                onProgress: ((LongTestProgress) -> Void)? = nil) async -> ItemResult {
        var r = ItemResult(code: "T08")
        guard let payload = BundledTools.payload("t08_reboot.sh") else {
            r.interrupted("板端脚本 t08_reboot.sh 未随应用打包")
            return r
        }
        let bt = BoardTest(adb: adb, directory: "\(Self.boardRoot)/t08_reboot",
                           payload: payload, clock: clock)
        let initd = "/etc/init.d/S99-az0x-reboot"

        r = await rebootRun(bt, targetBoots: targetBoots, initd: initd,
                            onProgress: onProgress, into: r)
        await Self.removeRebootService(adb: adb, dir: bt.directory, initd: initd,
                                       clock: clock, into: &r)
        return r
    }

    /// The body of T08. Never call this directly: `runT08` owns removing the init service.
    private func rebootRun(_ bt: BoardTest, targetBoots: Int, initd: String,
                           onProgress: ((LongTestProgress) -> Void)?,
                           into result: ItemResult) async -> ItemResult {
        var r = result
        // Payload usage: t08_reboot.sh <reboots>
        guard await LongTest.startFresh(bt, bound: targetBoots, into: &r) else {
            return r
        }

        let started = Date()
        let seen = LastCount()
        // The board is off for much of this run, so only the terminal marker ends it — or the
        // reboot service being gone, which says the test is no longer set up to continue. How long
        // any one reboot takes is the board's business and is never asked.
        let wait = await bt.waitDone(
            doneMarker: "STOP", pollSeconds: 15,
            patience: .whileTestIsRunning({ await bt.rebootServiceArmed(initd: initd) }),
            onTick: { log in
            let boots = RE.all(#"boot (\d+)"#, in: log).compactMap(Int.init).last ?? 0
            seen.value = boots
            Task { @MainActor in
                onProgress?(LongTestProgress(
                    phase: "自启服务反复重启",
                    elapsed: Date().timeIntervalSince(started),
                    scale: .count(done: Double(boots), target: Double(targetBoots)),
                    logTail: LongTest.tail(log, 18)))
            }
        },
            onOffline: { away in
            Task { @MainActor in
                onProgress?(LongTestProgress(
                    phase: "板子离线（重启中）已 \(formatDuration(away))",
                    elapsed: Date().timeIntervalSince(started),
                    scale: .count(done: Double(seen.value), target: Double(targetBoots)),
                    logTail: ""))
            }
        })

        // Same as T07: a board that stopped coming back failed to reboot, and rebooting is the whole
        // of this item. `runT08` still removes the reboot service on the way out.
        if case let .boardGone(away, lastLog) = wait {
            return Self.t08BoardGone(&r, lastLog: lastLog, away: away, target: targetBoots)
        }
        if let bad = await LongTest.settleOrFail(wait, bt, into: &r) { return bad }

        let progress = await bt.read("progress.log")
        guard !progress.isEmpty else {
            r.invalid("读不到板端 progress.log，结果不可信")
            return r
        }
        // Only intervals between boot lines are counted.
        let gaps = await bt.progressGaps(matching: "boot ")
        let boots = RE.all(#"boot (\d+)"#, in: progress).compactMap(Int.init).max() ?? 0

        // The criterion uses the largest interval during the run, not the stall time at the end.
        let maxGap = gaps.max() ?? 0
        let avgGap = gaps.isEmpty ? 0 : gaps.reduce(0, +) / gaps.count

        r.criteria = [
            // An unexplained panic under reboot cycling is what this item screens for.
            .equals("pstore panic", progress.contains("PANIC") ? 1 : 0, 0),
            .lessThan("最长起回间隔", maxGap, Thresholds.maxOfflineSeconds, unit: "s"),
            .isTrue("跑满目标重启次数", boots >= targetBoots, expected: "≥ \(targetBoots) 次"),
        ]
        r.validity = [
            // Positive evidence: with zero reboots, gaps is empty and maxGap counts as 0, so a
            // "largest gap under 300 s" check would sail straight through an empty set.
            .isTrue("确实反复重启过", boots >= 2 && gaps.count >= 1,
                    expected: "至少 2 次启动记录（才谈得上起回间隔）"),
        ]
        r.measurements = [
            .num("重启次数", Double(boots)),
            .num("平均起回间隔", Double(avgGap), "s"),
            .num("最长起回间隔", Double(maxGap), "s"),
            .num("要求重启次数", Double(targetBoots), "次"),
        ]
        r.conclude()

        r.evidence = [
            .markdown("重启总览", Self.t08Table(boots: boots, gaps: gaps,
                                             target: targetBoots)),
            .markdown("起回间隔分段统计", Self.gapSegments(gaps)),
            .markdown("异常清单", LongTest.anomalyList(progress, markers: ["PANIC"])),
            .log("板端 progress.log", progress),
        ]
        // pstore is attached only when a panic was detected.
        if progress.contains("PANIC") {
            let pstore = await adb.line(
                "cat /sys/fs/pstore/console-ramoops-0 2>/dev/null | tail -200")
            r.evidence.append(.log("pstore console-ramoops-0（检出 panic）",
                                   pstore.isEmpty ? "（读不到 pstore 内容）" : pstore))
        }

        return r
    }

    /// Removes the reboot init service and confirms the removal.
    /// T07's verdict when the board suspended and never came back.
    ///
    /// Built from the last progress this host saw rather than from the board, which cannot be read.
    /// Nothing unknown is filled in: the checks that need a live board — whether it rebooted, what
    /// the kernel counted — are simply absent, and the two that the absence itself decides are
    /// stated.
    private static func t07BoardGone(_ r: inout ItemResult, lastLog: String,
                                     away: TimeInterval, target: Int,
                                     elapsed: TimeInterval) -> ItemResult {
        let cycles = RE.all(#"cycle (\d+)"#, in: lastLog).compactMap(Int.init).max() ?? 0
        r.criteria = [
            Check(name: "唤醒后返回", actual: "离线 \(Int(away.rounded())) s 未返回",
                  expected: "≤ \(Thresholds.maxOfflineSeconds) s 内返回", passed: false),
            .isTrue("跑满目标周期数", false, expected: "≥ \(target) 个周期"),
        ]
        r.measurements = [
            .num("完成周期", Double(cycles)),
            .num("要求周期数", Double(target), "次"),
            .num("最后一次离线", away.rounded(), "s"),
            .num("实际历时", elapsed.rounded(), "s"),
        ]
        r.evidence = [.log("板端 progress.log 尾部（主机最后读到的）", LongTest.tail(lastLog, 20))]
        r.conclude()
        return r
    }

    /// T08's verdict when the board rebooted and never came back.
    private static func t08BoardGone(_ r: inout ItemResult, lastLog: String,
                                     away: TimeInterval, target: Int) -> ItemResult {
        let boots = RE.all(#"boot (\d+)"#, in: lastLog).compactMap(Int.init).max() ?? 0
        r.criteria = [
            // The same criterion a completed run is judged by, filled with what the host observed:
            // the board was off the bus for longer than a reboot of it may take.
            .lessThan("最长起回间隔", Int(away.rounded()), Thresholds.maxOfflineSeconds, unit: "s"),
            .isTrue("跑满目标重启次数", false, expected: "≥ \(target) 次"),
        ]
        r.measurements = [
            .num("重启次数", Double(boots)),
            .num("要求重启次数", Double(target), "次"),
            .num("最后一次离线", away.rounded(), "s"),
        ]
        r.evidence = [.log("板端 progress.log 尾部（主机最后读到的）", LongTest.tail(lastLog, 20))]
        r.conclude()
        return r
    }

    private static func removeRebootService(adb: any BoardSession, dir: String, initd: String,
                                           clock: any RunClock,
                                           into r: inout ItemResult) async {
        var removed = false
        for attempt in 1...10 {
            // The board may be rebooting; wait up to 60 s each time.
            if !(await adb.waitOnline(timeout: 60, clock: clock)), attempt < 10 {
                continue
            }
            _ = await adb.sh("echo manual > \(dir)/stop; rm -f \(initd); sync")
            let gone = await adb.line("[ -f \(initd) ] && echo no || echo yes")
            if gone == "yes" { removed = true; break }
        }
        // Cleanup, not a criterion — but it must override any other conclusion, because a board
        // left rebooting is the worst outcome this whole test can produce. Appending it to
        // `validity` and settling again does exactly that, with no special case.
        r.validity.append(.isTrue("已移除自启重启服务", removed,
                                  expected: "\(initd) 不存在"))
        if !removed {
            r.invalid("⚠️ 未能确认移除 \(initd) —— 板子可能仍在自动重启，"
                    + "请手动执行：adb shell rm -f \(initd)")
        }
    }
}
