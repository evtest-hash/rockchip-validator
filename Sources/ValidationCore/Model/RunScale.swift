import Foundation

/// How much a run asks of a board: the durations and counts each long item is bounded by.
///
/// This is the run's own standard, not a reduction of some other one. Whatever was asked for when
/// the batch started is what the items are judged against — five cycles means the criterion is five
/// cycles, and surviving them is a real pass of a real, smaller run.
///
/// So the software holds no opinion about the right amount. `default` is where the new-batch screen
/// starts and nothing more. There used to be a `standard` here, and merely calling it that grew a
/// comparison (`shortfall`), a second report title (抽测记录), an orange warning before the run and
/// a sentence in the report declining to draw a conclusion nobody had asked it to draw.
///
/// What replaces all of it is plainer: the report states these amounts, always, in the same form
/// whether they are large or small. A pass of five cycles reads 休眠唤醒 5 次 and cannot be mistaken
/// for a pass of three thousand, because it says five.
///
/// Amounts are the operator's. The figures that decide whether an observation is good enough — how
/// long a board may be off the bus, how soon it must boot after flashing — are not, and live in
/// `Thresholds` where the screen cannot reach them.
public struct RunScale: Equatable, Codable {

    /// Seconds per burn-in phase (T06).
    public var burninSeconds: Int
    /// Cycles for T07 and T08.
    public var cycles: Int
    /// Equivalent full-device writes for E05.
    public var emmcTargetN: Int

    public init(burninSeconds: Int, cycles: Int, emmcTargetN: Int) {
        self.burninSeconds = burninSeconds
        self.cycles = cycles
        self.emmcTargetN = emmcTargetN
    }

    /// Where a new batch starts: a starting position, not a bar to clear.
    public static let `default` = RunScale(burninSeconds: 12 * 3_600,
                                           cycles: 3_000,
                                           emmcTargetN: 20)

    /// What this run asks of each long item it contains, worded for a person.
    ///
    /// Unconditional and free of comparison — 休眠唤醒 5 次, never 5 / 3000 次. Showing this only
    /// when the amounts were unusual would be the old presumed standard returning by the back door:
    /// the reader would learn to infer a target from the software's silence.
    public func summary(for items: [TestItem], burninPhases: Int) -> [String] {
        var out: [String] = []
        let codes = Set(items.map(\.code))
        if codes.contains("T06") {
            out.append("拷机 \(TestItem.durationText(burninSeconds))/段 × \(burninPhases) 段")
        }
        if codes.contains("T07") { out.append("休眠唤醒 \(cycles) 次") }
        if codes.contains("T08") { out.append("重启 \(cycles) 次") }
        if codes.contains("E05") { out.append("eMMC 拷机 \(emmcTargetN) 次全盘写") }
        return out
    }
}
