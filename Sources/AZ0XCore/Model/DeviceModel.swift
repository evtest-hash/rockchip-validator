import Foundation

/// AZ0X model to SoC, maskrom USB PID and rk-msch-probe chip name.
enum DeviceModel: String, CaseIterable, Identifiable, Codable {
    case az05  = "AZ05"
    case az07  = "AZ07"
    case az08  = "AZ08"
    case az04a = "AZ04A"
    case az04b = "AZ04B"

    var id: String { rawValue }

    var soc: String {
        switch self {
        case .az05:  return "RK3288"
        case .az07:  return "RK3566"
        case .az08:  return "RK3576"
        case .az04a: return "RK3588"
        case .az04b: return "RK3588S2"
        }
    }

    /// USB PID in maskrom mode, lower-case to match the tool's `--list` output.
    var maskromPID: String {
        switch self {
        case .az05:  return "0x320a"
        case .az07:  return "0x350a"
        case .az08:  return "0x350e"
        case .az04a, .az04b: return "0x350b"
        }
    }

    /// SoC variants this board type is built from. A model can span more than one — AZ08 is
    /// RK3576 and RK3576S alike — so membership is what the OTP variant is checked against,
    /// not equality with `soc`, which is only the family name shown in a picker.
    var acceptedVariants: Set<String> {
        switch self {
        case .az05:  return ["RK3288"]
        case .az07:  return ["RK3566"]
        case .az08:  return ["RK3576", "RK3576S"]
        case .az04a: return ["RK3588"]
        case .az04b: return ["RK3588S2"]
        }
    }

    private func accepts(_ variant: String) -> Bool {
        acceptedVariants.contains { $0.caseInsensitiveCompare(variant) == .orderedSame }
    }

    /// Which model a chip variant read from OTP names. The USB PID cannot separate AZ04A from
    /// AZ04B: both are 0x350b, and the cpuid is a per-chip serial rather than a model marking.
    static func named(byChipVariant variant: String) -> DeviceModel? {
        allCases.first { $0.accepts(variant) }
    }

    /// Whether a chip variant names a different model. A variant no model accepts (RK3588S,
    /// RK3288W, RK3568 …) contradicts nothing: stopping a legitimate board over a variant we
    /// have no information about is worse than not gating a board we do not build.
    func contradicts(chipVariant: String?) -> Bool {
        guard let chipVariant else { return false }
        if accepts(chipVariant) { return false }
        return Self.named(byChipVariant: chipVariant) != nil
    }

    /// Value for the `-c` argument of rk-msch-probe.
    var probeChip: String {
        switch self {
        case .az05:  return "rk3288"
        case .az07:  return "rk356x"
        case .az08:  return "rk3576"
        case .az04a, .az04b: return "rk3588"
        }
    }

    /// Bus width per channel, used only to compute the theoretical bandwidth for T05.
    /// nil means T02 has to supply it, or the theoretical figure is left out.
    var busBitsPerChannel: Int? {
        switch self {
        case .az05: return 32      // RK3288: two 32-bit channels
        case .az07: return 32
        case .az08: return 16
        default:    return nil     // T02 measures it; these have no fallback worth asserting
        }
    }

    /// Items requiring an unsupported capability never enter the sequence.
    func supports(_ capability: Capability) -> Bool {
        switch capability {
        case .eyescan: return self != .az05      // RK3288 has no DQ eye scan
        }
    }

    var displayName: String { "\(rawValue) · \(soc)" }
}

/// The two independent validation flows.
enum ValidationFlow: String, CaseIterable, Identifiable, Codable {
    case ddr
    case emmc

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ddr:  return "DDR 验证"
        case .emmc: return "eMMC 验证"
        }
    }

    /// Machine time of a long-run item, in seconds.
    static func setSeconds(_ code: String, burninPhases: Int) -> Int? {
        switch code {
        case "T06": return Thresholds.longRunSeconds * max(1, burninPhases)
        // T07 and T08 are bounded by a count, so their wall clock is not known in advance. The
        // cap is the honest figure: an upper bound on how long the bench will wait, not a promise.
        case "T07", "T08": return Thresholds.longRunPatienceSeconds
        default: return nil
        }
    }
}
