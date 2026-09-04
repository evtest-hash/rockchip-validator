import Foundation

/// On-board items of the eMMC validation.
struct EmmcItems {

    let adb: any BoardSession
    /// Source of time for E05's polling loop. Production passes nothing; a test passes a
    /// virtual clock. Must be spelled out here — without the property, `clock` inside an
    /// extension resolves to libc's `clock()` and the error names `clock_t`, not this.
    var clock: any RunClock = SystemClock()

    /// Directory reserved for the eMMC flow, fully separated from the DDR flow.
    static let root = "/userdata/az0x-emmc"
    static var work: String { "\(root)/work" }

    // MARK: - Locating the eMMC

    /// Finds the sysfs directory of the eMMC.
    func mmcDirectory() async -> String {
        let out = await adb.line(
            "for d in /sys/class/mmc_host/*/mmc*:*/; do "
          + "[ \"$(cat $d/type 2>/dev/null)\" = MMC ] && echo $d; done")
        return out.components(separatedBy: .newlines).first { !$0.isEmpty } ?? ""
    }

    /// Derives the block device node from the sysfs directory, avoiding a hard-coded /dev/mmcblk0.
    func blockDevice(_ dir: String) async -> String {
        let name = await adb.line("ls \(dir)block/ 2>/dev/null | head -1")
        return name.isEmpty ? "" : "/dev/\(name)"
    }

    /// Extracts the controller name from the sysfs directory.
    private func hostName(_ dir: String) -> String {
        let parts = dir.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "mmc_host"), i + 1 < parts.count else { return "" }
        return parts[i + 1]
    }

    // MARK: - E02 spec and health, record plus pass or fail

    /// The requirements table defines only two automatic checks
    func runE02() async -> ItemResult {
        var r = ItemResult(code: "E02")
        let dir = await mmcDirectory()
        guard !dir.isEmpty else {
            r.interrupted("未找到 eMMC（/sys/class/mmc_host 下无 type=MMC 的设备）")
            return r
        }

        // Device identity.
        for (field, label) in [("name", "型号"), ("manfid", "厂商 ID"), ("oemid", "OEM ID"),
                               ("serial", "序列号"), ("date", "生产日期"),
                               ("fwrev", "固件版本"), ("hwrev", "硬件版本")] {
            let v = await adb.line("cat \(dir)\(field) 2>/dev/null")
            if !v.isEmpty { r.measurements.append(.text(label, v)) }
        }

        let dev = await blockDevice(dir)
        guard !dev.isEmpty else {
            r.interrupted("无法从 \(dir) 推导块设备节点")
            return r
        }
        r.measurements.append(.text("块设备", dev))
        if let bytes = await adb.int("blockdev --getsize64 \(dev) 2>/dev/null"), bytes > 0 {
            // One physical quantity must use one unit throughout a report.
            r.measurements.append(.num("容量", Double(bytes / (1 << 20)), "MiB"))
            r.measurements.append(.num("容量（十进制）",
                (Double(bytes) / 1e9 * 100).rounded() / 100, "GB"))
        }

        // Bus negotiation result, read from the debugfs ios file.
        let host = hostName(dir)
        let iosRaw = await adb.line(
            "cat /sys/kernel/debug/\(host)/ios 2>/dev/null "
          + "|| cat /sys/kernel/debug/mmc_host/\(host)/ios 2>/dev/null")
        let ios = Self.parseIOS(iosRaw)
        for (key, label) in [("bus width", "总线位宽"), ("timing spec", "时序档位"),
                             ("clock", "总线时钟"), ("actual clock", "实际时钟"),
                             ("signal voltage", "信号电压"), ("driver type", "驱动强度"),
                             ("bus mode", "总线模式"), ("power mode", "供电模式")] {
            if let v = ios[key] { r.measurements.append(.text(label, Self.readableIOS(v))) }
        }

        // Other device attributes, recorded when present.
        for (field, label) in [("cmdq_en", "命令队列(CQ)"),
                               ("preferred_erase_size", "推荐擦除单元"),
                               ("rel_sectors", "可靠写扇区"),
                               ("raw_rpmb_size_mult", "RPMB 容量倍数"),
                               ("ocr", "OCR"), ("dsr", "DSR")] {
            let v = await adb.line("cat \(dir)\(field) 2>/dev/null")
            if !v.isEmpty { r.measurements.append(.text(label, v)) }
        }

        // Health registers, the two values with explicit criteria.
        let lifeRaw = await adb.line("cat \(dir)life_time 2>/dev/null")
        let eolRaw = await adb.line("cat \(dir)pre_eol_info 2>/dev/null")

        // life_time holds two values, TYPE_A and TYPE_B; the worse one decides.
        let lifeValues = lifeRaw.split(whereSeparator: \.isWhitespace)
            .compactMap { Int($0.replacingOccurrences(of: "0x", with: ""), radix: 16) }
        for (i, v) in lifeValues.enumerated() {
            let tag = String(UnicodeScalar(UInt8(65 + i)))
            r.measurements.append(.text("寿命消耗 TYPE_\(tag)", Self.lifeTimeLabel(v)))
        }
        let eol = Int(eolRaw.replacingOccurrences(of: "0x", with: ""), radix: 16)
        if let eol { r.measurements.append(.text("EOL 状态", Self.preEolLabel(eol))) }

        // Two lists, and the split is the whole point. Whether we could read the registers is about
        // this run; what the registers say is about the device. One list could not tell them apart,
        // so an unreadable debugfs used to condemn a healthy part.
        r.validity = [
            .isTrue("读到健康寄存器", !lifeValues.isEmpty && eol != nil,
                    expected: "life_time 与 pre_eol_info 均可读"),
            .isTrue("总线协商结果可读", !ios.isEmpty, expected: "debugfs ios 可读"),
        ]
        if let eol {
            r.criteria.append(Check(name: "pre_eol_info",
                                  actual: String(format: "0x%02X", eol),
                                  expected: "0x01（Normal）",
                                  passed: eol == 0x01))
        }
        if let worst = lifeValues.max() {
            r.criteria.append(Check(name: "寿命消耗等级",
                                  actual: String(format: "0x%02X", worst),
                                  expected: "< 0x0B（未超出寿命）",
                                  passed: worst < 0x0B))
        }

        r.conclude()
        r.evidence = [.log("cat /sys/kernel/debug/\(host)/ios",
                           iosRaw.isEmpty ? "（未读到）" : iosRaw)]
        return r
    }

    /// Reduces an ios value to its meaningful part.
    static func readableIOS(_ value: String) -> String {
        guard let open = value.firstIndex(of: "("),
              let close = value.lastIndex(of: ")"), open < close else { return value }
        let inner = value[value.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
        return inner.isEmpty ? value : inner
    }

    /// The debugfs ios file holds `key:\tvalue` lines.
    static func parseIOS(_ raw: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in raw.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty, !v.isEmpty { out[k] = v }
        }
        return out
    }

    /// Life-time consumption semantics from EXT_CSD in JEDEC eMMC 5.0.
    static func lifeTimeLabel(_ v: Int) -> String {
        switch v {
        case 0x0B: return "超出寿命(0x0B)"
        case 1...0x0A: return "\((v - 1) * 10)–\(v * 10)%"
        default: return String(format: "未知(0x%02X)", v)
        }
    }

    static func preEolLabel(_ v: Int) -> String {
        switch v {
        case 0x01: return "Normal"
        case 0x02: return "Warning（已用 80%）"
        case 0x03: return "Urgent"
        default:   return String(format: "未知(0x%02X)", v)
        }
    }
}
