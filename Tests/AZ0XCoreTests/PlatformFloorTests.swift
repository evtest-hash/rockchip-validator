import XCTest
@testable import AZ0XCore

/// The lowest macOS this build runs on is stated twice and the two must agree.
///
/// `Package.swift` decides what the compiler will accept; `Packaging/Info.plist` decides what the
/// installer will allow. They disagreed — the manifest said 13, the bundle said 12 — so the app
/// claimed to run on a system where `Grid`, `NavigationSplitView` and `.defaultSize` do not exist.
/// It installs there and then does not work, and nothing in the build says a word about it.
///
/// Found by reading the two files side by side, which is not a thing anyone does twice.
final class PlatformFloorTests: XCTestCase {

    private var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTheBundleClaimsExactlyWhatTheManifestRequires() throws {
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"),
                                  encoding: .utf8)
        let plist = try String(contentsOf: root.appendingPathComponent("Packaging/Info.plist"),
                              encoding: .utf8)

        guard let declared = RE.first(#"\.macOS\(\.v(\d+)\)"#, in: manifest, group: 1) else {
            return XCTFail("Package.swift 里找不到 .macOS(.vNN)，这条测试就没在检查任何东西")
        }
        guard let claimed = RE.first(
            #"<key>LSMinimumSystemVersion</key>\s*<string>([^<]+)</string>"#,
            in: plist, group: 1) else {
            return XCTFail("Info.plist 里找不到 LSMinimumSystemVersion")
        }

        // Major versions: that is what the two forms have in common.
        XCTAssertEqual(claimed.split(separator: ".").first.map(String.init), declared,
                       "Package.swift 要 macOS \(declared)，而打出来的包声称能在 \(claimed) 上跑 —— "
                     + "低的那个装得上、起来就不对，而且没有任何东西会报错")
    }
}
