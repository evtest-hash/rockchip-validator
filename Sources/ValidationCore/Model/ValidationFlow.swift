import Foundation

/// The two independent validation flows.
public enum ValidationFlow: String, CaseIterable, Identifiable, Codable {
    case ddr
    case emmc

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ddr:  return "DDR 验证"
        case .emmc: return "eMMC 验证"
        }
    }
}
