import XCTest
@testable import ValidationCore

/// Reading a board's own name out of its device tree.
///
/// This had no test at all while it was a regex, `(AZ0\d[AB]?)`, which is a rule about how one
/// product line numbers its boards rather than about what this bench validates — it could not see
/// a board called anything else, and adding catalog entries would never have taught it to. Asking
/// the catalog for its declared aliases makes a board identifiable exactly when it is known.
final class BoardIdentityTests: XCTestCase {

    private func identity(model: String, compatible: String = "", serial: String = "s")
        -> BoardIdentity {
        BoardIdentity(model: model, compatible: compatible, uname: "board", serial: serial)
    }

    /// The shape a real board prints: mixed case across the two nodes, which is why the haystack
    /// is upper-cased before anything is compared.
    func testTheDeviceTreeNamesTheBoard() {
        XCTAssertEqual(identity(model: "Focalcrest AZ08", compatible: "rockchip,rk3576 az08").code,
                       "AZ08")
        XCTAssertEqual(identity(model: "az04b").code, "AZ04B")
        XCTAssertEqual(identity(model: "FOCALCREST AZ05 BOARD").code, "AZ05")
    }

    /// AZ04A must not answer for AZ04B, and neither may be reached by the bare AZ04 that is no
    /// board at all — the two codes differ by their last character and both contain the shorter one.
    func testTheLongerCodeIsNotShadowedByAShorterOne() {
        XCTAssertEqual(identity(model: "Focalcrest AZ04A").code, "AZ04A")
        XCTAssertEqual(identity(model: "Focalcrest AZ04B").code, "AZ04B")
        XCTAssertNil(identity(model: "Focalcrest AZ04").code, "AZ04 不是任何一块板")
    }

    /// A device tree naming two boards has told us nothing that can be acted on, so it is
    /// unidentifiable rather than resolved by picking one.
    func testTwoBoardsNamedIsUnidentifiable() {
        XCTAssertNil(identity(model: "AZ08", compatible: "az05").code)
    }

    func testABoardThisBuildDoesNotKnowIsUnidentifiable() {
        XCTAssertNil(identity(model: "Some Other Vendor Board").code)
        XCTAssertNil(identity(model: "").code)
    }

    /// The one case that answers differently than the regex did, pinned deliberately rather than
    /// left to be discovered. `AZ09` is not a board, so it is noise rather than a competing claim —
    /// the same reasoning `contradicts(chipVariant:)` already applies to an unknown OTP marking.
    /// The regex counted both tokens and called the pair a conflict.
    func testATokenNoBoardIsBuiltUnderIsNoise() {
        XCTAssertEqual(identity(model: "AZ08", compatible: "az09").code, "AZ08")
    }

    // MARK: - Checking it against what the operator chose

    func testTheCheckComparesTheReportedBoardWithTheSelectedOne() {
        XCTAssertEqual(BoardModel.az08.check(identity(model: "Focalcrest AZ08")), .matched)
        XCTAssertEqual(BoardModel.az08.check(identity(model: "Focalcrest AZ05")),
                       .mismatched(actual: "AZ05"))
        XCTAssertEqual(BoardModel.az08.check(identity(model: "no name here")), .unidentifiable)
    }

    /// The report's "device under test" row drops what it does not have rather than printing a gap.
    func testTheDisplayRowLeavesOutWhatIsMissing() {
        XCTAssertEqual(identity(model: "Focalcrest AZ08", serial: "34376b2c031e323e").display,
                       "AZ08 · Focalcrest AZ08 · 34376b2c031e323e")
        XCTAssertEqual(identity(model: "", serial: "").display, "")
    }
}
