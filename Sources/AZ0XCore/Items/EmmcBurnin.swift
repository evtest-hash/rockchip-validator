import Foundation

/// E05 read and write stress test, pass or fail, long-running.
extension EmmcItems {

    /// Equivalent full-device writes, currently 20, measured at about 1.7 hours per device.
    static let defaultTargetN = Thresholds.emmcTargetN
    static let defaultDirNum = 5
    /// Settling seconds after drop_caches.
    static let defaultSettle = 1

    func runE05(targetN: Int = Thresholds.emmcTargetN,
                dirNum: Int = EmmcItems.defaultDirNum,
                settle: Int = EmmcItems.defaultSettle,
                onProgress: ((LongTestProgress) -> Void)? = nil) async -> ItemResult {
        var r = ItemResult(code: "E05")
        guard let payload = BundledTools.payload("e05_burnin.sh") else {
            r.interrupted("板端脚本 e05_burnin.sh 未随应用打包")
            return r
        }

        // The device capacity determines the target amount written and must be read first.
        let dir = await mmcDirectory()
        let dev = await blockDevice(dir)
        let bytes = dev.isEmpty ? 0 : (await adb.int("blockdev --getsize64 \(dev) 2>/dev/null") ?? 0)
        let deviceMB = bytes / (1 << 20)
        guard deviceMB > 0 else {
            r.interrupted("读不到 eMMC 容量，无法按写入量确定测试规模")
            return r
        }

        r.measurements = [
            .num("器件容量", Double(deviceMB), "MiB"),
            .num("目标等效全盘写", Double(targetN), "次"),
            .num("目标写入量", Double(targetN * deviceMB), "MiB"),
            .num("并行目录数", Double(dirNum)),
        ]

        let bt = BoardTest(adb: adb, directory: "\(Self.root)/e05_burnin",
                           payload: payload, clock: clock)
        let lifeBefore = await adb.line("cat \(dir)life_time 2>/dev/null")

        // Payload usage: e05_burnin.sh <full-device writes N> [directories] [settle seconds]
        guard await LongTest.startFresh(bt, bound: targetN,
                                        extraArgs: "\(dirNum) \(settle)",
                                        into: &r) else { return r }

        let started = Date()
        // No clock. This item is bounded by how much the device survives writing, the way T07 and
        // T08 are bounded by how many cycles they survive, so the host asks whether the test is
        // still running rather than how long it has taken. A full-device write pass is slow by
        // nature and silence proves nothing about it.
        let wait = await bt.waitDone(
            doneMarker: "ALLDONE", pollSeconds: 30,
            patience: .whileTestIsRunning({ await bt.payloadAlive() }),
            onTick: { log in
            // A tick that reads nothing must not update the interface.
            guard let written = RE.all(#"LOOP \d+ written=(\d+)MB"#, in: log)
                .compactMap(Int.init).last else { return }
            Task { @MainActor in
                onProgress?(LongTestProgress(
                    phase: "随机文件集 cp → drop_caches → md5 校验",
                    elapsed: Date().timeIntervalSince(started),
                    // The progress metric is the amount written rather than a duration.
                    scale: .written(doneMiB: Double(written),
                                    targetMiB: Double(targetN * deviceMB)),
                    logTail: LongTest.tail(log, 18)))
            }
        },
            onOffline: { away in
            Task { @MainActor in
                onProgress?(LongTestProgress(
                    phase: "板子离线已 \(formatDuration(away))",
                    elapsed: Date().timeIntervalSince(started),
                    scale: .written(doneMiB: 0, targetMiB: Double(targetN * deviceMB)),
                    logTail: "", awayFor: away))
            }
        })

        // Same ruling as T07 and T08: a board that left and never came back did not reach the
        // amount it had to survive writing, and under this bench's premises nothing else explains
        // its absence. It fails the criterion it was bounded by rather than being filed as 未得结果.
        if case let .boardGone(away, lastLog) = wait {
            let written = RE.all(#"LOOP \d+ written=(\d+)MB"#, in: lastLog)
                .compactMap(Int.init).last ?? 0
            r.criteria = [.isTrue("写满目标量", false,
                                  expected: "\(targetN * deviceMB) MiB（等效 \(targetN) 次全盘写）")]
            r.measurements = [.num("实际写入", Double(written), "MiB"),
                              .num("最后一次离线", away.rounded(), "s")]
            r.evidence = [.log("板端 progress.log（主机最后读到的）", lastLog)]
            r.conclude()
            return r
        }

        if let bad = await LongTest.settleOrFail(wait, bt, into: &r) { return bad }

        let progress = await bt.read("progress.log")
        guard !progress.isEmpty else {
            r.invalid("读不到板端 progress.log，结果不可信")
            return r
        }
        let plan = RE.first(#"(PLAN .*)"#, in: progress) ?? ""
        let loops = RE.firstInt(#"ALLDONE loops=(\d+)"#, in: progress)
            ?? RE.all(#"LOOP (\d+) written"#, in: progress).compactMap(Int.init).last ?? 0
        let written = RE.firstInt(#"ALLDONE loops=\d+ written=(\d+)MB"#, in: progress)
            ?? RE.all(#"LOOP \d+ written=(\d+)MB"#, in: progress).compactMap(Int.init).last ?? 0

        r.measurements.append(.num("完成轮次", Double(loops)))
        r.measurements.append(.num("实际写入", Double(written), "MiB"))
        if deviceMB > 0 {
            r.measurements.append(.num("等效全盘写",
                (Double(written) / Double(deviceMB) * 10).rounded() / 10, "次"))
        }

        // The life-time registers are recorded but take no part in the verdict.
        let lifeAfter = await adb.line("cat \(dir)life_time 2>/dev/null")
        r.measurements.append(.text("寿命寄存器 前→后", "\(lifeBefore) → \(lifeAfter)"))

        let verifyFail = await bt.count("VERIFYFAIL")
        let copyFail = await bt.count("COPYFAIL")
        let devSizeFail = progress.contains("DEVSIZEFAIL")

        r.criteria = [
            // Data that came back different is the device's, and so is failing to reach the target
            // amount — this item is bounded by how much it survives writing, as T07 and T08 are
            // bounded by how many cycles they survive.
            .equals("md5 校验失败", verifyFail, 0),
            .equals("拷贝失败", copyFail, 0),
            .isTrue("写满目标量", progress.contains("ALLDONE"),
                    expected: "出现 ALLDONE（达到目标写入量）"),
        ]
        r.validity = [
            // Ours: without the device size there is no target to write, and without a loop nothing
            // was written to judge.
            .isTrue("容量探测成功", !devSizeFail, expected: "能读到器件容量"),
            .isTrue("确实执行过轮次", loops > 0, expected: "完成轮次 > 0"),
        ]
        r.conclude()

        r.evidence = [
            .markdown("压力测试总览", Self.e05Table(
                deviceMB: deviceMB, targetN: targetN, dirNum: dirNum, settle: settle,
                loops: loops, written: written, plan: plan)),
            .markdown("异常清单", LongTest.anomalyList(
                progress, markers: ["VERIFYFAIL", "COPYFAIL", "DEVSIZEFAIL"])),
        ]
        // On a verification failure the board preserves the state, which is retrieved as evidence.
        for (name, text) in await bt.fetch(["failed_source.md5", "failed_dest0.md5",
                                            "failed_dest1.md5", "failed_dest2.md5",
                                            "failed_dest3.md5", "failed_dest4.md5"]) {
            r.evidence.append(.log("校验失败现场 \(name)", text))
        }
        return r
    }

    static func e05Table(deviceMB: Int, targetN: Int, dirNum: Int, settle: Int,
                         loops: Int, written: Int, plan: String) -> String {
        var rows = ["| 项 | 值 |", "|---|---|",
                    "| 器件容量 | \(deviceMB) MiB |",
                    "| 目标等效全盘写 | \(targetN) 次 |",
                    "| 目标写入量 | \(targetN * deviceMB) MiB |",
                    "| 并行目录数 | \(dirNum) |",
                    "| drop_caches 后静置 | \(settle) s |",
                    "| **完成轮次** | **\(loops)** |",
                    "| **实际写入** | **\(written) MiB** |"]
        if deviceMB > 0 {
            let n = (Double(written) / Double(deviceMB) * 10).rounded() / 10
            rows.append("| **等效全盘写** | **\(n) 次** |")
        }
        if !plan.isEmpty { rows.append("| 板端计划 | `\(plan)` |") }
        return rows.joined(separator: "\n")
    }
}
