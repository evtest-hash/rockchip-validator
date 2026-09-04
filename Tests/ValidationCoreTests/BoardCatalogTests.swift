import XCTest
@testable import ValidationCore

/// The catalog, and what splitting it out was supposed to buy: a SoC fact is written once.
///
/// `maskromPID` and `probeChip` used to live in per-board `switch`es that had already merged their
/// RK3588 branches, and every new board on known silicon was another chance to mistype one of four
/// constants.
final class BoardCatalogTests: XCTestCase {

    // MARK: - Every entry is usable

    func testEveryEntryCarriesWhatTheBenchWillAskItFor() {
        for board in BoardModel.catalog {
            XCTAssertFalse(board.code.isEmpty)
            XCTAssertFalse(board.name.isEmpty, "\(board.code) 没有可读的名字")
            XCTAssertFalse(board.soc.family.isEmpty, "\(board.code) 的 SoC 没有家族名")
            XCTAssertFalse(board.soc.probeChip.isEmpty, "\(board.code) 缺 rk-msch-probe 的 -c 取值")
            XCTAssertNotNil(RE.first(#"^(0x[0-9a-f]{4})$"#, in: board.soc.maskromPID),
                            "\(board.code) 的 maskrom PID 必须是小写十六进制，"
                          + "工具的 --list 就是那么打印的：\(board.soc.maskromPID)")
            XCTAssertFalse(board.chip.isEmpty, "\(board.code) 没有可显示的芯片名")
            XCTAssertFalse(board.deviceTreeAliases.isEmpty, "\(board.code) 认不出自己的设备树")
            for alias in board.deviceTreeAliases {
                XCTAssertEqual(alias, alias.uppercased(),
                               "\(board.code) 的别名 \(alias) 不是大写；比对前文本已被 uppercased")
            }
        }
    }

    /// The code is the identity — equality, hashing, the archive path and the wire format all rest
    /// on it, and two entries sharing one would break all four at once.
    func testCodesAreUnique() {
        let codes = BoardModel.catalog.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count, "型号 code 有重复：\(codes)")
    }

    /// The split's whole point, asserted rather than described: two boards on one SoC read the same
    /// four constants from one place.
    func testTwoBoardsOnOneSoCShareItsFacts() {
        XCTAssertEqual(BoardModel.az04a.soc, BoardModel.az04b.soc)
        XCTAssertEqual(BoardModel.az04a.soc.maskromPID, "0x350b")
        XCTAssertEqual(BoardModel.az04b.soc.maskromPID, "0x350b")
        XCTAssertEqual(BoardModel.az04a.soc.probeChip, BoardModel.az04b.soc.probeChip)
    }

    // MARK: - What the operator reads

    /// `chip` defaults to the SoC family, and AZ04B is the row that stops it being a synonym for
    /// one: it is built from RK3588S2 and its report has always said so.
    func testTheChipNameShownIsWhatItAlwaysWas() {
        XCTAssertEqual(BoardModel.az05.chip,  "RK3288")
        XCTAssertEqual(BoardModel.az07.chip,  "RK3566")
        XCTAssertEqual(BoardModel.az08.chip,  "RK3576")
        XCTAssertEqual(BoardModel.az04a.chip, "RK3588")
        XCTAssertEqual(BoardModel.az04b.chip, "RK3588S2")   // the one written out
        XCTAssertEqual(BoardModel.az08.displayName, "AZ08 · RK3576")
        XCTAssertEqual(BoardModel.az04b.displayName, "AZ04B · RK3588S2")
    }

    // MARK: - Capabilities follow the silicon

    func testEyeScanIsAPropertyOfTheChipNotOfOneBoard() {
        XCTAssertFalse(BoardModel.az05.supports(.eyescan), "RK3288 没有 DQ 眼图")
        for board in BoardModel.catalog where board.soc.family != "RK3288" {
            XCTAssertTrue(board.supports(.eyescan), "\(board.code) 应当支持眼图")
        }
        XCTAssertFalse(TestItem.items(for: .ddr, model: .az05).contains { $0.code == "T03" },
                       "不支持的项根本不该进序列")
        XCTAssertTrue(TestItem.items(for: .ddr, model: .az08).contains { $0.code == "T03" })
    }

    // MARK: - The wire format

    private func encoded(_ run: Run) throws -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return String(data: try e.encode(run), encoding: .utf8)!
    }

    private func sample(model: BoardModel = .az08) -> Run {
        Run(schemaVersion: Run.currentSchema, runID: "r", batchID: "b",
            model: model, flow: .ddr,
            board: .init(serial: "s", cpuid: nil, chipVariant: nil,
                         socket: "002-1.4", reported: nil, uptimeAtBind: 0),
            burninPhases: BurninPhase.allCases, scale: .default,
            items: [], results: [:], startedAt: nil, finishedAt: nil,
            stoppedAt: nil, toolVersions: [], appVersion: "1.0.0")
    }

    /// The record stores the code and nothing else, exactly as the enum's raw value did. A run.json
    /// written before this type existed has to keep reading, and the only way to promise that is to
    /// promise the bytes have not moved.
    func testAModelIsStoredAsItsCodeAlone() throws {
        let text = try encoded(sample())
        XCTAssertTrue(text.contains("\"model\":\"AZ08\""), text)
    }

    func testEveryCatalogEntryRoundTrips() throws {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        for board in BoardModel.catalog {
            let text = try encoded(sample(model: board))
            let back = try d.decode(Run.self, from: Data(text.utf8))
            XCTAssertEqual(back.model, board)
        }
    }

    /// A code this build does not know throws rather than decoding to a placeholder. `RunStore.past`
    /// skips an unreadable record without a word, and that is where a run from a future build with a
    /// board we have never heard of has to land — rendering it against the wrong board would be
    /// worse than leaving it off the list.
    func testARecordNamingAnUnknownBoardIsRefused() throws {
        let text = try encoded(sample()).replacingOccurrences(of: "\"model\":\"AZ08\"",
                                                              with: "\"model\":\"AZ99\"")
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        XCTAssertThrowsError(try d.decode(Run.self, from: Data(text.utf8)))
    }
}
