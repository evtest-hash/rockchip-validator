import Foundation

/// Parser for `rk-msch-probe` output, where `-t N` prints N loop blocks.
///
/// The tool prints two shapes, chosen by SoC — both format strings live in the one binary.
/// Newer parts (RK3576, RK3588 …) print a `LOAD:` line carrying the whole board. RK3288 has
/// an older DDR monitor and prints a per-master table per channel instead, whose `total` row
/// is the credible figure: measured on an AZ05 it tracked the load (121 MB/s idle against
/// 2946 loaded) while that path's own `ddr load:` line did not (1075 idle against 5.9 TB/s
/// loaded). Its percentages are not read either — they are computed against a 16-bit bus and
/// come out over 100% on a 32-bit part. Utilisation is worked out from what T01 and T02
/// probed, which is where it always came from.
struct ProbeOutput {

    /// One loop block.
    struct Round {
        let index: Int
        /// The full text of the block.
        let text: String
        let freqMHz: Int?
        /// Bandwidth of this loop across the whole board.
        let loadMBps: Double?
        /// Only from the `LOAD:` shape; the other shape's percentages are not trustworthy.
        let loadPercent: Double?
        let readMBps: Double?
        let writeMBps: Double?
    }

    let rounds: [Round]
    /// The peak loop, compared by instantaneous LOAD.
    let peak: Round?

    init(_ raw: String) {
        // Split on the loop banners.
        var blocks: [String] = []
        var current: [String] = []
        var started = false
        for line in raw.components(separatedBy: .newlines) {
            if line.contains("loop ") && line.contains("=") && line.contains("/") {
                // A loop has two banner lines; split only at the first.
                if line.hasSuffix("=") && line.contains("====") {
                    if started { blocks.append(current.joined(separator: "\n")) }
                    current = [line]
                    started = true
                    continue
                }
            }
            if started { current.append(line) }
        }
        if started, !current.isEmpty { blocks.append(current.joined(separator: "\n")) }

        // Some versions print no banner for `-t 1`; treat the whole text as one block.
        if blocks.isEmpty, raw.contains("LOAD:") { blocks = [raw] }

        rounds = blocks.enumerated().map { idx, text in
            let load = Self.allColumn(#"^\s*LOAD:"#, in: text)
            // Fall back to the per-channel master tables, summed: the LOAD line is the whole
            // board on the parts that print it, so the two shapes report the same quantity.
            let masterTotal = load == nil ? Self.masterTotals(in: text) : nil
            return Round(index: idx + 1,
                  text: text,
                  freqMHz: RE.firstInt(#"ddr freq:\s*(\d+)\s*Mhz"#, in: text,
                                       group: 1),
                  loadMBps: load ?? masterTotal,
                  loadPercent: load == nil ? nil
                                           : Self.allColumnPercent(#"^\s*LOAD:"#, in: text),
                  readMBps: load == nil ? nil : Self.allColumn(#"^\s*RD:"#, in: text),
                  writeMBps: load == nil ? nil : Self.allColumn(#"^\s*WR:"#, in: text))
        }
        peak = rounds.filter { $0.loadMBps != nil }
                     .max { ($0.loadMBps ?? 0) < ($1.loadMBps ?? 0) }
    }

    /// Sum of every channel's `total` row, which is that shape's whole-board figure.
    /// nil rather than zero when no such row is present, so a missing reading stays missing.
    private static func masterTotals(in text: String) -> Double? {
        let totals = text.components(separatedBy: .newlines)
            .compactMap { RE.first(#"^\s*total\s+([\d.]+)"#, in: $0, group: 1) }
            .compactMap(Double.init)
        return totals.isEmpty ? nil : totals.reduce(0, +)
    }

    /// First value of a LOAD, RD or WR line, which is the ALL column.
    private static func allColumn(_ prefix: String, in text: String) -> Double? {
        guard let line = matchingLine(prefix, in: text) else { return nil }
        return RE.first(#"([\d.]+)MB/s"#, in: line).flatMap(Double.init)
    }

    private static func allColumnPercent(_ prefix: String, in text: String) -> Double? {
        guard let line = matchingLine(prefix, in: text) else { return nil }
        return RE.first(#"[\d.]+MB/s\(([\d.]+)%\)"#, in: line).flatMap(Double.init)
    }

    /// Finds the line starting with the given prefix.
    private static func matchingLine(_ prefix: String, in text: String) -> String? {
        text.components(separatedBy: .newlines).first { line in
            guard !line.contains("recorded") else { return false }
            return RE.first("(" + prefix + ")", in: line) != nil
        }
    }

    /// Plausibility check on the readings.
    var suspicions: [String] {
        var out: [String] = []
        // Only the LOAD shape carries RD and WR; the other one is checked by the constancy
        // test below alone.
        if let p = peak, let l = p.loadMBps, let rd = p.readMBps, let wr = p.writeMBps,
           abs(l - rd) < 0.01, abs(l - wr) < 0.01 {
            out.append("LOAD / RD / WR 三者完全相等（正常应为 LOAD ≈ RD + WR）")
        }
        let loads = rounds.compactMap(\.loadMBps)
        if loads.count >= 3, let f = loads.first,
           loads.allSatisfy({ abs($0 - f) < 0.01 }) {
            out.append("\(loads.count) 轮读数完全恒定")
        }
        return out
    }
}
