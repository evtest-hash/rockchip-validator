import XCTest
@testable import AZ0XCore

/// The safety catch that keeps two benches off one board.
final class BenchRegistryTests: XCTestCase {

    func testABoardCanOnlyBeTakenOnce() async {
        let reg = BenchRegistry()
        let first = await reg.take("002-1.4-2207-350E-NA")
        let second = await reg.take("002-1.4-2207-350E-NA")

        XCTAssertTrue(first)
        XCTAssertFalse(second, "两个工位盯同一块板，对刷机项就是两个写入者")
    }

    func testReleasingMakesItAvailableAgain() async {
        let reg = BenchRegistry()
        _ = await reg.take("002-1.4")
        await reg.release("002-1.4")

        let again = await reg.take("002-1.4")
        XCTAssertTrue(again, "一块板判完，插座要立刻能进下一批")
    }

    func testDifferentBoardsDoNotBlockEachOther() async {
        let reg = BenchRegistry()
        let a = await reg.take("002-1.4")
        let b = await reg.take("002-1.5")
        let c = await reg.take("7413b4e0bbc37640")
        XCTAssertTrue(a && b && c)
    }

    /// The whole point of it being an actor: a batch takes its boards concurrently.
    func testConcurrentTakesOfOneBoardYieldExactlyOneWinner() async {
        let reg = BenchRegistry()
        let wins = await withTaskGroup(of: Bool.self) { group -> Int in
            for _ in 0..<64 { group.addTask { await reg.take("002-1.4") } }
            var n = 0
            for await ok in group where ok { n += 1 }
            return n
        }
        XCTAssertEqual(wins, 1)
    }
}
