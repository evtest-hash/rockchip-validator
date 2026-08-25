import Foundation

/// Progress of a time-consuming step inside an item. Interface state, never part of a conclusion.
struct StepProgress: Equatable {
    /// Downloads are measured in bytes, which gives a known denominator.
    enum Metric: Equatable { case bytes, percent }
    var metric: Metric = .bytes

    var code: String
    /// Step name, for example "下载镜像".
    var label: String
    /// `total` is nil when the total is unknown.
    var done: Int64
    var total: Int64?

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(done) / Double(total)))
    }

    /// How far along, in the step's own unit.
    ///
    /// Bytes are decimal MB, to match the image size published by CI. The percent case used to
    /// return an empty string, so flashing printed its label and nothing else — twenty-odd bare
    /// `刷入镜像` lines for a run that was in fact reporting progress the whole time.
    var valueText: String {
        switch metric {
        case .percent:
            return total == nil ? "…" : "\(done)%"
        case .bytes:
            func mb(_ b: Int64) -> String { String(format: "%.1f MB", Double(b) / 1_000_000) }
            guard let total else { return mb(done) }
            return "\(mb(done)) / \(mb(total))"
        }
    }
}

/// Progress of a long-running item, read from the board's own log rather than inferred.
struct LongTestProgress: Codable, Equatable {
    /// Metric and denominator. Each long item is bounded by what it is actually about.
    enum Scale: Codable, Equatable {
        /// T06: bounded by hours.
        case duration(TimeInterval)
        /// E05: bounded by bytes written.
        case written(doneMiB: Double, targetMiB: Double)
        /// T07 and T08: bounded by a count. Showing these against a clock would put the operator's
        /// attention on the wrong number and imply a finish time nobody promised.
        case count(done: Double, target: Double)
    }

    /// Plain description of the current stage.
    var phase: String
    /// Wall-clock seconds elapsed.
    var elapsed: TimeInterval
    var scale: Scale
    var logTail: String = ""

    var fraction: Double {
        switch scale {
        case let .duration(total):
            return total > 0 ? min(1, max(0, elapsed / total)) : 0
        case let .written(done, target), let .count(done, target):
            return target > 0 ? min(1, max(0, done / target)) : 0
        }
    }

    var progressText: String {
        switch scale {
        case let .duration(total):
            return "\(formatDuration(elapsed)) / \(formatDuration(total))"
        case let .written(done, target):
            return "已写入 \(Int(done)) MiB / \(Int(target)) MiB · 已跑 \(formatDuration(elapsed))"
        case let .count(done, target):
            return "\(Int(done)) / \(Int(target)) 次 · 已跑 \(formatDuration(elapsed))"
        }
    }
}

/// The most recent count read from a board, shared between the two progress callbacks of one item.
///
/// A reference so both closures see the same value: an offline line must keep showing the count
/// reached rather than starting again from zero, which reads as if the run had restarted.
final class LastCount: @unchecked Sendable {
    var value = 0
}

/// Timestamp as the operator reads it, in one place.
let operatorStamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

/// Duration as the operator reads it, worded as the report words it.
func formatDuration(_ t: TimeInterval) -> String {
    let total = Int(t.rounded())
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return "\(h) 小时 \(m) 分" }
    if m > 0 { return "\(m) 分 \(s) 秒" }
    return "\(s) 秒"
}
