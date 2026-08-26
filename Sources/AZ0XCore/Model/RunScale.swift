import Foundation

/// How much a run asks of a board: the durations and counts each long item is bounded by.
///
/// Recorded, not inferred. A run that ran T07 five times instead of three thousand has to be able
/// to say so in its own record, or the only trace of it is a number in an appendix and the document
/// on top says 初步报告 · 全部通过. That is what happened: an eMMC run at one twentieth of the
/// standard produced a report titled 初步报告, because 抽测 was decided from how many items were
/// cut and never from how far each one was cut short.
///
/// Shortened runs have a real purpose — there is not always time for the full sequence, and a quick
/// pass tells you whether anything is obviously wrong before committing days to it. That is exactly
/// why the report must name the scale: the value of a smoke check depends on nobody mistaking it
/// for the real thing.
public struct RunScale: Equatable, Codable {

    /// Seconds per burn-in phase (T06).
    public var burninSeconds: Int
    /// Cycles for T07 and T08.
    public var cycles: Int
    /// Equivalent full-device writes for E05.
    public var emmcTargetN: Int

    public init(burninSeconds: Int = Thresholds.longRunSeconds,
                cycles: Int = Thresholds.longRunCycles,
                emmcTargetN: Int = Thresholds.emmcTargetN) {
        self.burninSeconds = burninSeconds
        self.cycles = cycles
        self.emmcTargetN = emmcTargetN
    }

    /// The acceptance standard: what a run has to do for its verdicts to mean what they say.
    public static let standard = RunScale()

    /// Every selected item this run asks less of than the standard, worded for a person.
    ///
    /// Only selected items count: a sequence without T08 is not "short on reboots", it simply is not
    /// testing reboots, and the item list already says so.
    ///
    /// Asking *more* than the standard is not a shortfall. A run of five thousand cycles is stricter
    /// than the standard, not weaker than it, and its report reads normally with the actual figure
    /// recorded.
    public func shortfall(for items: [TestItem]) -> [String] {
        var out: [String] = []
        let codes = Set(items.map(\.code))
        if codes.contains("T06"), burninSeconds < Self.standard.burninSeconds {
            out.append("拷机每段 \(TestItem.hoursText(burninSeconds))"
                     + " / \(TestItem.hoursText(Self.standard.burninSeconds))")
        }
        if codes.contains("T07"), cycles < Self.standard.cycles {
            out.append("休眠唤醒 \(cycles) / \(Self.standard.cycles) 次")
        }
        if codes.contains("T08"), cycles < Self.standard.cycles {
            out.append("重启 \(cycles) / \(Self.standard.cycles) 次")
        }
        if codes.contains("E05"), emmcTargetN < Self.standard.emmcTargetN {
            out.append("eMMC 拷机 \(emmcTargetN) / \(Self.standard.emmcTargetN) 次全盘写")
        }
        return out
    }

    /// Whether this run asks less of the board than the standard does.
    public func isShortened(for items: [TestItem]) -> Bool { !shortfall(for: items).isEmpty }
}
