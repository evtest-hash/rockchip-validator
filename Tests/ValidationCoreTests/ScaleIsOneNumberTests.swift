import XCTest
@testable import ValidationCore

/// The amount an item is bounded by has one source, and everything that says it reads that source.
///
/// It did not. The row under the burn-in kept reading a compiled-in figure, so an operator who set
/// eight hours saw the item say eight and each of its three segments say twelve. Nothing failed; the
/// screen simply disagreed with itself, and it took someone looking at it to notice.
///
/// A test cannot look at a screen. What it can do is refuse to let a second copy of the number
/// exist — the label that drifted was one, and it turned out to have no callers at all.
final class ScaleIsOneNumberTests: XCTestCase {

    private var uiSources: [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RockchipValidator")
        return ((FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }) ?? []).filter { $0.pathExtension == "swift" }
    }

    /// Nothing the operator can see may be computed from the default. The default is only where the
    /// new-batch screen starts; what the run is *doing* comes from the run's own scale.
    func testTheInterfaceNeverShowsTheDefaultInsteadOfTheChosenAmount() throws {
        let sources = uiSources
        XCTAssertFalse(sources.isEmpty, "没找到界面源码，这条测试就没在检查任何东西")

        for url in sources {
            let text = try String(contentsOf: url, encoding: .utf8)
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            for constant in ["RunScale.default.burninSeconds", "RunScale.default.cycles",
                             "RunScale.default.emmcTargetN"] {
                XCTAssertFalse(text.contains(constant),
                               "\(url.lastPathComponent) 直接读了 \(constant)。"
                             + "界面要显示的是本次运行的量（app.scale），不是那个默认值 —— "
                             + "两者一旦分开写，屏幕就会自己和自己说不一致。")
            }
        }
    }

    /// The amounts a run carries describe that run and nothing else: no comparison, no target.
    func testTheScaleDescribesTheRunWithoutComparingIt() {
        var scale = RunScale.default
        scale.cycles = 5
        let ddr = TestItem.ddrItems

        let said = scale.summary(for: ddr, burninPhases: 3)
        XCTAssertTrue(said.contains("休眠唤醒 5 次") && said.contains("重启 5 次"), "\(said)")
        XCTAssertFalse(said.contains { $0.contains("3000") },
                       "不拿默认值作对照 —— 那就是被删掉的预设标准：\(said)")

        // An item that is not being run is not described.
        let withoutReboot = ddr.filter { $0.code != "T08" }
        XCTAssertFalse(scale.summary(for: withoutReboot, burninPhases: 3)
                            .contains { $0.hasPrefix("重启") })
    }

}
