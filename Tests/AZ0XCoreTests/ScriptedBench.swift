import Foundation
@testable import AZ0XCore

/// One declared board, shared by every test that needs a whole sequence.
///
/// Two copies of a fixture this size drift, and a drifting fixture is worse than none: the tests
/// keep passing while describing two different boards.
enum ScriptedBench {

    static func t06Log(defect: Bool = false) -> String {
        """
        1000 OOM start=0
        1001 PHASES ABC
        1002 PHASE_A_START freq=2112000000 size=1800M
        1020 PHASE_A_DONE
        1021 PHASE_B_START
        1040 PHASE_B_DONE
        1041 PHASE_C_START
        1060 PHASE_C_DONE scale_ok=132
        1061 OOM end=0
        \(defect ? "1062 FAILED SATABORT status_fail" : "1062 ALLDONE")
        """
    }

    static var t07Log: String {
        var lines = ["1000 SUSPEND_SUCCESS start=100"]
        for n in 1...3_000 { lines.append("\(1000 + n * 17) cycle \(n) rc=0 fail=0") }
        lines.append("52020 SUSPEND_SUCCESS end=3101")
        lines.append("52021 ALLDONE 3000")
        return lines.joined(separator: "\n")
    }

    static var t08Log: String {
        var lines = ["1000 INSTALLED"]
        for n in 1...3_000 { lines.append("\(1000 + n * 20) boot \(n)") }
        lines.append("61020 STOP target=3000")
        return lines.joined(separator: "\n")
    }

    static func board(t06Defect: Bool = false,
                              t05Missing: Bool = false) -> ScriptedBoardSession {
        let b = ScriptedBoardSession()
        let t06 = "/userdata/az0x-ddr/t06_burnin", t07 = "/userdata/az0x-ddr/t07_suspend", t08 = "/userdata/az0x-ddr/t08_reboot"
        b.files = [
            "/proc/sys/kernel/random/boot_id": "9f8e-0001",
            "\(t06)/progress.log": t06Log(defect: t06Defect),
            "\(t06)/scale_ok": "132",
            "\(t06)/scale_prog": "1050 100 2112000000\n1060 132 1560000000",
            "\(t07)/progress.log": t07Log,
            "\(t08)/progress.log": t08Log,
            // Plain `cat <path>` reads go to the file table, not to `answers`.
            "/sys/class/devfreq/dmc/available_frequencies": "528000000 1068000000 2112000000",
            "/sys/class/devfreq/dmc/cur_freq": "2112000000",
        ]
        let bootStamps = (1...3_000).map { String(1000 + $0 * 20) }.joined(separator: "\n")
        b.answers = [
            // T05
            ("echo userspace >", ""), ("echo 2112000000 >", ""), ("echo dmc_ondemand >", ""),
            ("oom_kill", "0"),
            ("MemAvailable", "8000"),
            ("stress-ng", t05Missing ? "sh: stress-ng: not found" : ""),
            // The shape a real AZ08 prints: the master table *and* the LOAD / RD / WR rows.
            // The fixture used to carry only the table, which is the fallback the parser keeps for
            // versions that print no LOAD line — so the shape that actually ran on hardware was
            // never exercised, and 峰值利用率 (which only the LOAD line carries) looked optional.
            ("rk-msch-probe", """
                ========================================loop 1/8====================================
                ddr freq: 2112Mhz      cpu   others    total
                master bw(MB/s)   11800.00     0.00 11800.00
                bw prorated(%)       98.00     0.00   100.00
                utilization(%)       59.40     0.00    59.40
                ---------------------ALL--------------CH0--------
                       recorded LOAD: max 11800.00MB/s(59.40%), avg 10400.00MB/s(52.20%)
                                LOAD:  11800.00MB/s(59.40%),  5900.00MB/s(59.40%)
                                  RD:   3000.00MB/s(15.10%),  1500.00MB/s(15.10%)
                                  WR:   8800.00MB/s(44.30%),  4400.00MB/s(44.30%)
                ========================================loop 2/8====================================
                ddr freq: 2112Mhz      cpu   others    total
                master bw(MB/s)   12164.00     0.00 12164.00
                bw prorated(%)       98.00     0.00   100.00
                utilization(%)       61.20     0.00    61.20
                ---------------------ALL--------------CH0--------
                       recorded LOAD: max 12164.00MB/s(61.20%), avg 10400.00MB/s(52.20%)
                                LOAD:  12164.00MB/s(61.20%),  6082.00MB/s(61.20%)
                                  RD:   3164.00MB/s(15.90%),  1582.00MB/s(15.90%)
                                  WR:   9000.00MB/s(45.30%),  4500.00MB/s(45.30%)
                """),
            // T06
            ("grep -ic FAILURE", "0"),
            ("grep -c SCALEFAIL", ""),
            ("Stats: Completed:", "Stats: Completed: 470000000.00M in 43200.00s 10943.00MB/s, "
                                + "with 0 hardware incidents, 0 errors"),
            ("grep -c Loop \(t06)/mtB.log", "5"),
            ("grep -c Loop \(t06)/mtC.log", "7"),
            // T07
            ("/sys/power/suspend_stats", "success: 3101\nfail: 0"),
            // T08
            ("awk '{print $1}'", bootStamps),
            ("echo manual >", ""),
            ("[ -f /etc/init.d/S99-az0x-reboot ]", "yes"),
            ("pstore/console-ramoops-0", ""),
        ]
        if t05Missing {
            b.answers.insert(("stress-ng", "sh: stress-ng: not found"), at: 0)
        }
        return b
    }

}
