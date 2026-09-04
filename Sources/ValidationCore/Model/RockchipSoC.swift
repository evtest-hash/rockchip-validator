import Foundation

/// A Rockchip SoC, and the facts that follow from the silicon rather than from the board built on it.
///
/// Split out of the board catalog because these were being written once per board that used them.
/// `maskromPID` and `probeChip` had already collapsed into `case .az04a, .az04b:` branches, and a
/// merged branch is what a SoC-level fact looks like when it is stored per board — a third RK3588
/// board would have been the third copy of the same four values. `hasEyeScan` had gone further and
/// inverted: it read `self != .az05`, naming the one board that lacks the capability instead of the
/// silicon that lacks it.
public struct RockchipSoC: Hashable {

    /// Family name, as it appears in a picker and a report: "RK3588".
    public let family: String

    /// USB product id in maskrom mode, lower-case to match the tool's `--list` output.
    public let maskromPID: String

    /// Value for the `-c` argument of rk-msch-probe.
    public let probeChip: String

    /// Whether the DDR tool can scan DQ eye diagrams on this silicon. T03 requires it, and an item
    /// requiring a capability the SoC lacks never enters the sequence.
    public let hasEyeScan: Bool

    /// Bus width per channel, used only to compute the theoretical bandwidth for T05.
    /// nil means T02 has to supply it, or the theoretical figure is left out of the report.
    public let busBitsPerChannel: Int?
}

public extension RockchipSoC {

    static let rk3288 = RockchipSoC(family: "RK3288", maskromPID: "0x320a", probeChip: "rk3288",
                                    // No DQ eye scan on this one.
                                    hasEyeScan: false,
                                    // Two 32-bit channels.
                                    busBitsPerChannel: 32)

    static let rk3566 = RockchipSoC(family: "RK3566", maskromPID: "0x350a", probeChip: "rk356x",
                                    hasEyeScan: true, busBitsPerChannel: 32)

    static let rk3576 = RockchipSoC(family: "RK3576", maskromPID: "0x350e", probeChip: "rk3576",
                                    hasEyeScan: true, busBitsPerChannel: 16)

    /// One PID, 0x350b, for every board on this silicon — which is why the OTP marking is the only
    /// thing that separates them, and why `BoardModel.markings` exists.
    static let rk3588 = RockchipSoC(family: "RK3588", maskromPID: "0x350b", probeChip: "rk3588",
                                    hasEyeScan: true,
                                    // T02 measures it; there is no fallback here worth asserting.
                                    busBitsPerChannel: nil)
}
