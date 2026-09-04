import XCTest
@testable import ValidationCore

/// What a booted board says it is, as the report prints it.
///
/// There used to be a device-tree code extractor here — a regex, then a catalog lookup — whose
/// entire output was a prefix on this one row. It judged nothing: the `check` it offered had no
/// caller, and the code it derived was already in 被测型号 and in the batch id. What is left is the
/// board's own words, unmediated.
final class BoardIdentityTests: XCTestCase {

    /// Taken off a real Core3588E over adb, verbatim.
    func testTheRowIsWhatTheBoardSaysPlusTheSerialItAnswersTo() {
        let real = BoardIdentity(model: "Mixtile Core 3588E", serial: "9ea34627a8266cc2")
        XCTAssertEqual(real.display, "Mixtile Core 3588E · 9ea34627a8266cc2")
    }

    /// A board that cannot be read is not rendered as a gap or a separator with nothing round it.
    func testMissingHalvesAreDroppedRatherThanShownEmpty() {
        XCTAssertEqual(BoardIdentity(model: "", serial: "9ea34627a8266cc2").display,
                       "9ea34627a8266cc2")
        XCTAssertEqual(BoardIdentity(model: "Mixtile Core 3588E", serial: "").display,
                       "Mixtile Core 3588E")
        XCTAssertEqual(BoardIdentity(model: "", serial: "").display, "")
    }
}
