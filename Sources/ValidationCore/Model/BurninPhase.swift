import Foundation

/// The three phases of the T06 burn-in test.
public enum BurninPhase: String, CaseIterable, Codable, Identifiable {
    /// Fixed maximum frequency with stressapptest.
    case fixedSat = "A"
    /// Fixed maximum frequency with memtester.
    case fixedMemtester = "B"
    /// Frequency scaling across all operating points with memtester.
    case scalingMemtester = "C"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fixedSat:          return "定频 · stressapptest"
        case .fixedMemtester:    return "定频 · memtester"
        case .scalingMemtester:  return "变频 · memtester"
        }
    }

    /// One-line description used in the report and the interface.
    public var detail: String {
        switch self {
        case .fixedSat:
            return "锁定最高频率，stressapptest 满载查位错"
        case .fixedMemtester:
            return "锁定最高频率，memtester 逐模式查位错"
        case .scalingMemtester:
            return "随机遍历全频点切频，同时 memtester 查位错"
        }
    }

    /// Orders phases A to C.
    public static func ordered(_ set: Set<BurninPhase>) -> [BurninPhase] {
        allCases.filter(set.contains)
    }

    /// Phase mask passed to the board-side script, for example "AC".
    public static func mask(_ set: Set<BurninPhase>) -> String {
        ordered(set).map(\.rawValue).joined()
    }

    /// Restores the set from the mask recorded on the board.
    public static func parseMask(_ mask: String) -> Set<BurninPhase> {
        Set(mask.compactMap { BurninPhase(rawValue: String($0)) })
    }
}
