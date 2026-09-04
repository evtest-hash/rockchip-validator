import XCTest
@testable import ValidationCore

/// What the operator is told when an image cannot be had.
///
/// This is the one screen where a failure reaches them before any board is touched, and the text
/// used to be assembled out of three registers at once: 无法访问 CI 快照通道 (ours, internal),
/// a system error describing itself in English, and a second full stop after the first.
final class ImageFailureWordingTests: XCTestCase {

    private func message(whenChannelThrows error: Error) async -> String {
        let tool = ScriptedFlasher()
        tool.channelError = error
        do {
            _ = try await ImageSupply.prepare(model: .az08, using: tool)
            return "（没有失败）"
        } catch {
            return error.localizedDescription
        }
    }

    /// `URLError` speaks English about itself. In front of someone validating a board that is noise,
    /// and it is the most likely failure of the three.
    func testANetworkFailureIsSaidInTheOperatorsWords() async {
        let said = await message(whenChannelThrows: URLError(.notConnectedToInternet))

        XCTAssertEqual(said, "无法连接镜像服务器，请检查网络")
        XCTAssertFalse(said.contains("Internet"), "系统报错的原文不进界面：\(said)")
    }

    /// An error of ours passes through as itself rather than being flattened into a generic line.
    func testOurOwnFailuresKeepTheirOwnWording() async {
        let said = await message(whenChannelThrows: FlashError.httpStatus(404, "https://example/x"))

        XCTAssertTrue(said.contains("HTTP 404"), "状态码留着 —— 它短，而且是能报给人的东西：\(said)")
        XCTAssertFalse(said.contains("https://"), "地址不留 —— 读到它的人对它无能为力：\(said)")
    }

    /// Nothing unrecognised leaks its own description either.
    func testAnUnknownErrorStillGetsAChineseSentence() async {
        struct Odd: Error {}
        let said = await message(whenChannelThrows: Odd())

        XCTAssertEqual(said, "获取镜像时出错")
    }

    /// The three failures the operator can actually meet, each phrased as something to do.
    func testTheThreeStatedFailuresReadAsInstructions() {
        XCTAssertEqual(ImageSupply.Failure.toolMissing.errorDescription,
                       "应用安装不完整，缺少刷机组件，请重新安装")
        XCTAssertEqual(ImageSupply.Failure.noImage(.az08).errorDescription,
                       "未找到 AZ08 的镜像")
        for f in [ImageSupply.Failure.toolMissing, .noImage(.az08)] {
            XCTAssertFalse(f.errorDescription?.contains("CI") ?? true,
                           "CI 是我们的说法，不是操作员的：\(f.errorDescription ?? "")")
        }
    }
}
