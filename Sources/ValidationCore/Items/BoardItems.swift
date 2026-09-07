import Foundation

/// Test items of the on-board Linux domain (T05 to T08, E02 to E06).
struct BoardItems {

    let adb: any BoardSession
    let soc: RockchipSoC
    /// Channel count probed by T01 and bus width per channel probed by T02.
    let channels: Int?
    let busBitsPerChannel: Int?
    /// Source of time for the long runs' polling loops. Production passes nothing; a test passes a
    /// virtual clock so the loop runs every one of its ~4 300 iterations without waiting for them.
    var clock: any RunClock = SystemClock()

    static let dmc = "/sys/class/devfreq/dmc"

    // MARK: - T05 DDR bandwidth, record-only

    /// Locks the maximum frequency, applies full load and samples the peak bandwidth.
    func runT05() async -> ItemResult {
        var r = ItemResult(code: "T05")

        // Read the operating points and lock the highest.
        let freqLine = await adb.line("cat \(Self.dmc)/available_frequencies")
        let freqs = freqLine.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard let top = freqs.max() else {
            r.interrupted("读不到 dmc 可用频点（\(Self.dmc)/available_frequencies）")
            return r
        }

        // The governor must be restored afterwards.
        defer {
            Task.detached { [adb] in
                _ = await adb.sh("echo dmc_ondemand > \(Self.dmc)/governor 2>/dev/null")
            }
        }

        _ = await adb.sh("echo userspace > \(Self.dmc)/governor")
        _ = await adb.sh("echo \(top) > \(Self.dmc)/userspace/set_freq")
        let locked = await adb.int("cat \(Self.dmc)/cur_freq") ?? 0
        let topMHz = top / 1_000_000

        r.validity.append(.isTrue("锁定最高频率", locked == top,
                                expected: "cur_freq = \(topMHz) MHz"))
        guard locked == top else {
            r.interrupted("定频未生效：期望 \(topMHz) MHz，实际 \(locked / 1_000_000) MHz")
            return r
        }

        let oomBefore = await adb.int("awk '/oom_kill/{print $2}' /proc/vmstat") ?? 0

        // Load: four concurrent streams totalling at most 50 percent of available memory.
        let availMB = await adb.int("awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo") ?? 512
        let perStreamMB = max(32, availMB * 50 / 100 / 4)
        let stressResult = await adb.sh(
            "stress-ng --memrate 4 --memrate-bytes \(perStreamMB)M --timeout 25s "
          + ">/dev/null 2>&1 &", timeout: 15)
        if Adb.isCommandMissing(stressResult) {
            r.interrupted("固件缺少 stress-ng —— 无法加压，采样无意义")
            return r
        }
        // Allow the load to reach steady state; the first loops would otherwise sample the ramp-up.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        let probe = await adb.sh(
            "rk-msch-probe -c \(soc.probeChip) -f \(topMHz) -d 1000 -t 8", timeout: 90)
        _ = await adb.sh("pkill -9 stress-ng 2>/dev/null")

        if Adb.isCommandMissing(probe) {
            r.interrupted("固件缺少 rk-msch-probe —— 无法采样带宽")
            return r
        }

        let oomAfter = await adb.int("awk '/oom_kill/{print $2}' /proc/vmstat") ?? oomBefore
        if oomAfter > oomBefore {
            r.interrupted("加压期间发生 OOM-kill（+\(oomAfter - oomBefore)），采样作废")
            r.evidence = [.log("rk-msch-probe 输出", probe.combined)]
            return r
        }

        let parsed = ProbeOutput(probe.combined)
        guard let peak = parsed.peak, let peakLoad = peak.loadMBps else {
            r.invalid("探针未产生有效带宽读数")
            r.evidence = [.log("rk-msch-probe 输出", probe.combined)]
            return r
        }

        r.measurements.append(.num("峰值带宽", (peakLoad * 100).rounded() / 100, "MB/s"))
        if let pct = peak.loadPercent {
            r.measurements.append(.num("峰值利用率", pct, "%"))
        }
        r.measurements.append(.num("DDR 频率", Double(topMHz), "MHz"))
        r.measurements.append(.num("加压内存", Double(perStreamMB * 4), "MB"))

        // The frequency reported by the probe must equal the locked value.
        if let probeFreq = peak.freqMHz {
            r.validity.append(.equals("探针实测频率", probeFreq, topMHz))
            if probeFreq != topMHz {
                r.invalid("探针报出频率 \(probeFreq) MHz 与锁定的 \(topMHz) MHz 不一致，"
                                 + "读数不可用")
                r.evidence = [.log("rk-msch-probe 峰值轮次（第 \(peak.index) 轮）", peak.text)]
                return r
            }
        }

        // Theoretical bandwidth = 2 (double data rate) × frequency in MHz × bus width in bits ÷ 8.
        if let ch = channels, let bits = busBitsPerChannel ?? soc.busBitsPerChannel {
            let totalBits = ch * bits
            let theoretical = 2.0 * Double(topMHz) * Double(totalBits) / 8.0
            r.measurements.append(.num("理论带宽", theoretical.rounded(), "MB/s"))
            r.measurements.append(.num("带宽效率",
                                       ((peakLoad / theoretical * 1000).rounded() / 10), "%"))
        }

        // Plausibility check, advisory only; the requirements table sets no efficiency threshold.
        let suspicions = parsed.suspicions
        r.measurements.append(.text("读数自检",
                                    suspicions.isEmpty ? "无异常" : suspicions.joined(separator: "；")))

        // As required, the evidence is the complete section of the peak loop rather than grepped.
        r.evidence = [.log("rk-msch-probe 峰值轮次（第 \(peak.index) / \(parsed.rounds.count) 轮）",
                           peak.text)]

        r.conclude()          // whether the value is acceptable is decided by a human
        return r
    }
}
