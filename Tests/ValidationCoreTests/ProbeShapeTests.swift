import XCTest
@testable import ValidationCore

/// rk-msch-probe prints two shapes, and the reading has to come out the same from both.
///
/// The bench fixture models the one a real AZ08 prints — the master table followed by LOAD / RD / WR
/// rows. The other shape has no LOAD line at all, and the parser sums the table's `total` column
/// instead. That path has no other test: it used to be what the fixture exercised, which meant the
/// real shape was the untested one.
final class ProbeShapeTests: XCTestCase {

    func testTheLoadShapeCarriesTheUtilisationThatTheTableDoesNot() {
        let p = ProbeOutput("""
            ====loop 1/2====
            ddr freq: 2112Mhz
            master bw(MB/s)   12164.00     0.00 12164.00
            ---ALL---
                   recorded LOAD: max 12164.00MB/s(61.20%)
                            LOAD:  12164.00MB/s(61.20%)
                              RD:   3164.00MB/s(15.90%)
                              WR:   9000.00MB/s(45.30%)
            """)

        XCTAssertEqual(p.peak?.loadMBps, 12164)
        XCTAssertEqual(p.peak?.loadPercent, 61.2, "报告里的峰值利用率就是这个数")
        XCTAssertEqual(p.peak?.freqMHz, 2112)
    }

    /// No LOAD line: the whole-board figure is the sum of the table's `total` rows, and there is no
    /// percentage to be had. Nothing may be invented to fill the gap — a missing reading stays
    /// missing, and T05's row simply does not carry 峰值利用率 on such a part.
    func testTheTableShapeReportsTheSameQuantityAndNoPercentage() {
        let p = ProbeOutput("""
            ====loop 1/2====
            ddr freq: 2112Mhz CH0:
                             master  bw(MB/s)
                               core  12164.00
                              total  12164.00
            """)

        XCTAssertEqual(p.peak?.loadMBps, 12164, "两种形状报的是同一个量")
        XCTAssertNil(p.peak?.loadPercent, "这种形状没有百分比，不能凑一个出来")
        XCTAssertNil(p.peak?.readMBps)
    }

    /// The peak is the highest round, not the last one.
    func testThePeakIsTheHighestRound() {
        let p = ProbeOutput("""
            ====loop 1/2====
            ddr freq: 2112Mhz
                            LOAD:  12164.00MB/s(61.20%)
            ====loop 2/2====
            ddr freq: 2112Mhz
                            LOAD:   9000.00MB/s(45.30%)
            """)

        XCTAssertEqual(p.peak?.loadMBps, 12164)
        XCTAssertEqual(p.peak?.index, 1)
    }
}
