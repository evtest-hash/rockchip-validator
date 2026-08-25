import XCTest
@testable import AZ0XCore

/// Folding a tool's in-place redraws down to what it actually said.
///
/// `memtester` writes a line and then rewrites its counter over itself. Twenty seconds of it comes
/// back as 24 KB holding 24 real lines and 11 847 backspaces — extrapolated to a twelve-hour phase,
/// tens of megabytes of terminal noise. Keeping that as evidence would mean the record grows with
/// how long the test ran rather than with what it found.
///
/// Done at extraction, never at render: what reaches the record is already what a person watching
/// the terminal would have seen.
final class NormalizeTests: XCTestCase {

    func testBackspacesLeaveOnlyWhatTheLineFinallySaid() {
        XCTAssertEqual(LongTest.normalize("Loop 1\u{8}\u{8}\u{8}\u{8}\u{8}\u{8}Loop 9"), "Loop 9")
    }

    func testCarriageReturnRewritesFromTheStart() {
        XCTAssertEqual(LongTest.normalize("testing  12%\rtesting 100%"), "testing 100%")
    }

    /// A shorter rewrite leaves the tail of the older text standing, exactly as a terminal does —
    /// which is why this belongs at extraction and not in a regex somewhere: the answer is what the
    /// screen showed, not what the last write said.
    func testAShorterRewriteDoesNotEraseWhatItDoesNotCover() {
        XCTAssertEqual(LongTest.normalize("Loop 100/500\rLoop 9"), "Loop 900/500")
    }

    func testOrdinaryTextIsUntouched() {
        let plain = "memtester version 4.5.1\npagesize is 4096\ngot 172MB"
        XCTAssertEqual(LongTest.normalize(plain), plain)
    }

    /// The point of the whole exercise, in the shape the real file has.
    func testARedrawHeavyLogCollapsesToItsRealLines() {
        var raw = "memtester version 4.5.1\n  Stuck Address       : "
        // Each redraw rubs out exactly what it wrote, which is what memtester does.
        for pct in stride(from: 0, through: 100, by: 1) {
            let field = "testing \(pct)%"
            raw += field + String(repeating: "\u{8}", count: field.count)
        }
        raw += "ok\n"

        let folded = LongTest.normalize(raw)

        XCTAssertEqual(folded.components(separatedBy: "\n").count, 2)
        XCTAssertTrue(folded.contains("ok"), folded)
        XCTAssertFalse(folded.contains("\u{8}"))
        XCTAssertLessThan(folded.count, raw.count / 3, "折叠后必须显著变小，否则这一步没有意义")
    }
}
