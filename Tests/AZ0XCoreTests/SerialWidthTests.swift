import XCTest
@testable import AZ0XCore

/// The serial read out of OTP is the name the booted board answers to on adb.
///
/// It is the only thing connecting the two device domains, and the two of them print it differently:
/// the tool without leading zeros, the firmware padded to sixteen hex digits. Measured on a real
/// AZ07 — OTP gave 883265bf7fee7c8, the board it flashed called itself 0883265bf7fee7c8 — so the run
/// spent its whole 180-second boot allowance waiting for a name nothing answers to and failed a
/// board that had flashed and booted correctly.
///
/// Every board validated before that one matched by luck: AZ08 7413b4e0bbc37640 and
/// AZ05 7f35c361c64395de both start with a non-zero nibble.
final class SerialWidthTests: XCTestCase {

    private func identity(serial: String, cpuid: String = "4d4242303832000000000000000f201e")
        -> DdrCli.Identity? {
        DdrCli.Identity(from: .init(json: ["cpuid": cpuid, "serial": serial, "chipVariant": "RK3566"],
                                    exitCode: 0, raw: "", parseError: nil))
    }

    func testAShortSerialIsPaddedToTheWidthTheBoardUses() {
        XCTAssertEqual(identity(serial: "883265bf7fee7c8")?.serial, "0883265bf7fee7c8",
                       "板端 adb 报的就是补零到 16 位的这个")
        XCTAssertEqual(identity(serial: "f")?.serial, "000000000000000f")
    }

    func testAFullWidthSerialIsUntouched() {
        for s in ["7413b4e0bbc37640", "7f35c361c64395de"] {
            XCTAssertEqual(identity(serial: s)?.serial, s, "已经 16 位的不动它")
        }
    }

    /// Padding is only right because the two strings are the same number. Anything that is not hex
    /// is not that number, and guessing at its width would be inventing an identity.
    func testAnythingThatIsNotShortHexIsLeftExactlyAsItCame() {
        XCTAssertEqual(identity(serial: "not-a-serial")?.serial, "not-a-serial")
        XCTAssertEqual(identity(serial: "0883265bf7fee7c8ff")?.serial, "0883265bf7fee7c8ff",
                       "比 16 位还长的也不动 —— 那不是我们该猜的东西")
    }

    /// The whole point of the padding: the sequence goes looking for the board under this name.
    func testTheRunAddressesTheBoardByThePaddedName() async {
        let tool = ScriptedMaskromTool([
            "--detect": .init(json: ["detect": ["pass": true, "cfg": "az07.cfg"],
                                     "cpuid": "4d4242303832000000000000000f201e",
                                     "serial": "883265bf7fee7c8"], exitCode: 0),
        ])
        tool.enumerated = [.init(id: "002-1.4-2207-350a-NA", pid: "0x350a")]
        var p = RunPlan(batchID: "AZ07-DDR", model: .az07, flow: .ddr,
                        items: TestItem.ddrItems.filter { $0.code == "T04" },
                        burninPhases: Set(BurninPhase.allCases),
                        deviceID: "002-1.4-2207-350a-NA")
        p.image = readyImage
        var askedFor: String?
        let v = Validator(plan: p, tool: tool,
                          boardSession: { askedFor = $0; return ScriptedBench.board() },
                          flashTool: ScriptedFlasher(), clock: SimClock())

        let run = await v.run { _ in }

        XCTAssertEqual(askedFor, "0883265bf7fee7c8", "去 adb 认领板子用的必须是补零后的名字")
        XCTAssertEqual(run.board.serial, "0883265bf7fee7c8", "报告里记的也是它")
        XCTAssertEqual(run.results["T04"]?.verdict, .passed,
                       String(describing: run.results["T04"]?.detail))
    }
}
