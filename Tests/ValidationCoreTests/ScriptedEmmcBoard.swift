import Foundation
@testable import ValidationCore

/// A board carrying an eMMC, declared the same way the DDR bench is.
///
/// Same discipline: answers are declared, never computed, and an unmatched command lands in
/// `unmatched` rather than defaulting. `unmatched.isEmpty` therefore pins what this flow asks a
/// board — change E02 to read another sysfs file and the test says so.
enum ScriptedEmmc {

    static let dir = "/sys/class/mmc_host/mmc0/mmc0:0001/"
    static let work = "/userdata/az0x-emmc/work"
    static let burnin = "/userdata/az0x-emmc/e05_burnin"

    /// One fio run's output: the plain text on both sides of the JSON block, as the real tool prints.
    static func fio(readKB: Double, writeKB: Double,
                    readBytes: Int, writeBytes: Int,
                    verifyFailed: Bool = false) -> String {
        let json = """
        {"jobs":[{"read":{"bw":\(readKB),"iops":\(readKB / 4),"io_bytes":\(readBytes)},
        "write":{"bw":\(writeKB),"iops":\(writeKB / 4),"io_bytes":\(writeBytes)}}]}
        """
        let tail = verifyFailed
            ? "\nfio: verify failed at file offset 0x0a3f1c40\ncrc32c: checksum mismatch"
            : "\nRun status group 0 (all jobs): ok"
        return "fio-3.33\nStarting 1 process\n" + json + tail
    }

    /// A healthy part: normal EOL, first life-time bracket, four fio cases that all move data.
    ///
    /// `lifeTime` and `preEol` are the two values E02 actually judges, so every scenario sets them
    /// explicitly rather than inheriting a default nobody looked at.
    static func board(lifeTime: String = "0x01 0x01",
                      preEol: String = "0x01",
                      ios: String? = nil,
                      verifyFails: Bool = false,
                      shortWrite: Bool = false,
                      burninLog: String? = nil) -> ScriptedBoardSession {
        let b = ScriptedBoardSession()
        let full = 256 * 1024 * 1024
        b.files = [
            "\(dir)name": "S0J58X", "\(dir)manfid": "0x000015", "\(dir)oemid": "0x0100",
            "\(dir)serial": "0x1f2e3d4c", "\(dir)date": "07/2025",
            "\(dir)fwrev": "0x0000000000000007", "\(dir)hwrev": "0x0",
            "\(dir)cmdq_en": "1", "\(dir)preferred_erase_size": "4194304",
            "\(dir)rel_sectors": "1", "\(dir)raw_rpmb_size_mult": "0x20",
            "\(dir)ocr": "0xc0ff8080", "\(dir)dsr": "0x0404",
            "\(dir)life_time": lifeTime,
            "\(dir)pre_eol_info": preEol,
            "\(burnin)/progress.log": burninLog ?? """
            1000 PLAN target=20 dirs=5 settle=1
            1001 LOOP 1 written=14800MB
            1002 LOOP 2 written=29600MB
            1003 ALLDONE
            """,
            "\(burnin)/pid": "4711",
        ]
        b.answers = [
            // E02 locates the part through sysfs rather than assuming /dev/mmcblk0.
            ("/sys/class/mmc_host/*/mmc*:*/", dir),
            ("ls \(dir)block/", "mmcblk0"),
            ("blockdev --getsize64", "15758000128"),
            ("/sys/kernel/debug", ios ?? """
            clock:\t200000000 Hz
            actual clock:\t198000000 Hz
            vdd:\t21 (3.3 ~ 3.4 V)
            bus width:\t3 (8 bits)
            timing spec:\t9 (mmc HS200)
            signal voltage:\t1 (1.80 V)
            driver type:\t0 (driver type B)
            bus mode:\t2 (push-pull)
            power mode:\t2 (on)
            """),
            // E03 and E06: four cases, each moving its 256 MB.
            ("--rw=read",      fio(readKB: 92_160, writeKB: 0, readBytes: full, writeBytes: 0)),
            ("--rw=write",     fio(readKB: 0, writeKB: 51_200, readBytes: 0, writeBytes: full)),
            ("--rw=randread",  fio(readKB: 24_576, writeKB: 0, readBytes: full, writeBytes: 0)),
            ("--rw=randwrite", fio(readKB: 0, writeKB: 8_192, readBytes: 0, writeBytes: full)),
            ("mkdir -p", ""),
            // Asked when the engine binds this board after flashing, not by the eMMC items.
            ("/proc/uptime", "42"),
            ("/proc/device-tree/model", "FocalCrest AZ08\nrockchip,rk3576\naz08"),
            ("grep -c 'VERIFYFAIL'", "0"),
            ("grep -c 'COPYFAIL'", "0"),
        ]
        // E04 writes with verification. Declared after the plain --rw=write case so it wins:
        // `answers` is matched in order and this command carries both flags.
        b.answers.insert(
            ("--verify=crc32c", fio(readKB: 40_960, writeKB: 51_200,
                                    readBytes: shortWrite ? 0 : full,
                                    writeBytes: shortWrite ? full / 4 : full,
                                    verifyFailed: verifyFails)),
            at: 0)
        return b
    }
}
