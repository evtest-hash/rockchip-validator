import Foundation

/// The app's own build identity, stamped into the bundle by Packaging/build-app.sh.
/// Reading it is what lets a report be traced back to the build that produced it.
enum AppVersion {

    /// From `git describe --tags --always --dirty`, e.g. "0.2.0-9-g45528b9".
    static var short: String { plist("CFBundleShortVersionString") }

    /// The short commit hash, which maps a build back to a commit.
    static var commit: String { plist("CFBundleVersion") }

    /// Operator-facing form of this build.
    static var display: String { display(short: short, commit: commit) }

    /// Kept pure so the formatting is testable without a stamped bundle.
    /// An unstamped build says so rather than showing a made-up number: `swift build` and
    /// `swift test` products carry no Info.plist, and an invented version would be
    /// indistinguishable from a packaged one once it reached a report.
    static func display(short: String, commit: String) -> String {
        guard !short.isEmpty else { return "开发构建（未打版本号）" }
        // `git describe` already embeds the hash unless HEAD is exactly a tag.
        return commit.isEmpty || short.contains(commit) ? short : "\(short) (\(commit))"
    }

    private static func plist(_ key: String) -> String {
        (Bundle.main.infoDictionary?[key] as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}
