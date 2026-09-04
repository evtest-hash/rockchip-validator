import Foundation

/// Location of the bundled tools and board-side scripts. Packaging: docs/decisions.md.
enum BundledTools {

    /// The Contents/Helpers directory inside the .app.
    static var helpersDirectory: URL? {
        // Normal case: the executable lives in Contents/MacOS, Helpers is its sibling.
        let exe = Bundle.main.bundleURL
        let inBundle = exe.appendingPathComponent("Contents/Helpers", isDirectory: true)
        if FileManager.default.fileExists(atPath: inBundle.path) { return inBundle }

        // During development (swift run, swift test) there is no bundle structure.
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            dir.deleteLastPathComponent()
            if dir.pathComponents.count <= 1 { break }
            let vendor = dir.appendingPathComponent("Vendor/bin", isDirectory: true)
            if FileManager.default.fileExists(atPath: vendor.path) { return vendor }
        }
        return nil
    }

    static func tool(_ name: String) -> String? {
        guard let dir = helpersDirectory else { return nil }
        let path = dir.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var ddrCli: String?   { tool("RockchipDDRTestUtilityCLI") }
    static var flashTool: String? { tool("rockchip-flash-tool-cli") }
    static var adb: String?      { tool("adb") }

    /// Versions of the bundled tools, generated from tools.lock by Packaging/fetch-tools.sh.
    /// Read once: the bundle cannot change while the application runs, and the record is now
    /// written after every completed item rather than once at the end of a run.
    static let toolVersions: [String] = readToolVersions()

    private static func readToolVersions() -> [String] {
        // In the shipped bundle the file lives in Resources rather than Helpers.
        let candidates = [Bundle.main.resourceURL, helpersDirectory]
            .compactMap { $0?.appendingPathComponent("tools.version") }
        guard let txt = candidates.lazy
            .compactMap({ try? String(contentsOf: $0, encoding: .utf8) }).first
        else { return [] }
        // Split on isNewline rather than on "\n".
        return txt.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A board-side script, bundled verbatim.
    static func payload(_ name: String) -> String? {
        guard let url = Bundle.module.url(forResource: "payloads/\(name)",
                                          withExtension: nil)
                ?? Bundle.module.url(forResource: name, withExtension: nil,
                                     subdirectory: "payloads")
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Which tools are missing.
    static var missingTools: [String] {
        [("adb", adb), ("rockchip-flash-tool-cli", flashTool),
         ("RockchipDDRTestUtilityCLI", ddrCli)]
            .filter { $0.1 == nil }.map(\.0)
    }
}
