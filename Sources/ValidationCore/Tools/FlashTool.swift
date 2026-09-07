import CryptoKit
import Foundation

/// Wrapper around rockchip-flash-tool-cli, shared by T04 and E01.
struct FlashTool {

    /// A retrieved image, and whether it was proved to be the build the CI published.
    struct FetchedImage {
        let url: URL
        /// False when no published digest could be obtained. The image is still flashed — that is a
        /// deliberate availability trade-off, recorded in decisions.md — but the report must say so,
        /// or a run that flashed an unverified image reads exactly like one that flashed a verified
        /// one, and this bench's whole output is a document someone trusts.
        let digestVerified: Bool
    }

    struct ImageMeta {
        let asset: String        // file name
        let url: String
        let size: Int
        let date: String
        let board: String
        let tag: String
    }

    let executable: String
    /// Where images are kept: beside the reports, one directory per model, newest only.
    ///
    /// Not `/tmp` and not `~/Library/Caches`, which were both places the system is entitled to
    /// empty. It did: two of the three model directories on this bench held nothing but their own
    /// name, and the next run for those models would have paid 766 MB again for no reason anyone
    /// could see. A test redirects this.
    let cacheDirectory: URL
    /// Where the published digest of a build comes from; the default reads the public GitHub API.
    let digestSource: (ImageMeta) async -> String?
    /// Whether an image may be fetched from this URL. Injectable for the same reason as
    /// `digestSource`: a test has to serve a file locally. Production never passes this — the
    /// default is the strict check, so relaxing it takes a deliberate argument at a call site.
    let isFetchable: (URL) -> Bool

    static let indexURL = URL(string:
        "https://mixtile-rockchip.github.io/focalcrest-rockchip-linux-ci/snapshots/data.json")!

    init?(executable: String? = BundledTools.flashTool,
          cacheDirectory: URL = ArchiveRoot.default.appendingPathComponent("images",
                                                                            isDirectory: true),
          digestSource: @escaping (ImageMeta) async -> String? = { await publishedDigest(for: $0) },
          isFetchable: @escaping (URL) -> Bool = FlashTool.isTrustedImageHost) {
        guard let executable else { return nil }
        self.executable = executable
        self.cacheDirectory = cacheDirectory
        self.digestSource = digestSource
        self.isFetchable = isFetchable
    }

    // MARK: - Image retrieval

    /// Queries the latest image for a model, matching exactly on board and taking the latest date.
    func latestImage(for model: BoardModel) async throws -> ImageMeta? {
        var request = URLRequest(url: Self.indexURL)
        request.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        let candidates = list.compactMap { entry -> ImageMeta? in
            guard let board = entry.str("board"), model.answersTo(board),
                  let url = entry.str("url"), !url.isEmpty,
                  let asset = entry.str("asset")
            else { return nil }
            return ImageMeta(asset: asset, url: url,
                             size: entry.int("size") ?? -1,
                             date: entry.str("date") ?? "",
                             board: model.code,
                             tag: entry.str("tag") ?? "")
        }
        return candidates.sorted { $0.date > $1.date }.first
    }

    /// Downloads the image, reusing a cached file only when it is provably this build's.
    func fetch(_ meta: ImageMeta, onProgress: ByteProgress? = nil) async throws -> FetchedImage {
        let dest = try cachePath(meta)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let published = await digestSource(meta)
        if Self.isUsable(dest, expecting: meta.size), Self.passesDigest(dest, expecting: published) {
            // No progress is reported on a cache hit.
            keepOnly(dest)
            return FetchedImage(url: dest, digestVerified: published?.isEmpty == false)
        }
        guard !meta.url.isEmpty, let url = URL(string: meta.url), isFetchable(url) else {
            throw FlashError.badImageURL(meta.url)
        }
        // No single-flight here any more. Fetching happens once, before any board is opened, so
        // there is nothing to deduplicate — the actor that used to do it was deduplicating
        // something that should not have been happening several times.
        do {
            try await Downloader.download(from: url, to: dest, onProgress: onProgress)
        } catch let e as DownloadError {
            // Re-worded for the image context; the downloader knows nothing about images.
            if case let .httpStatus(code, u) = e { throw FlashError.httpStatus(code, u) }
            throw e
        }
        let file = dest
        guard Self.passesDigest(file, expecting: published) else {
            // Kept nowhere: a file that failed its digest would be reused as a cache hit next run.
            try? FileManager.default.removeItem(at: file)
            throw FlashError.digestMismatch(meta.asset)
        }
        keepOnly(file)
        return FetchedImage(url: file, digestVerified: published?.isEmpty == false)
    }

    // MARK: - Identifying one build

    /// Cache path of one build. A CI asset name carries the day, not the build, so several builds
    /// of one day share it; the tag is what tells them apart. See docs/decisions.md.
    ///
    /// Both halves come out of the CI index, which is a file on a Pages site — whoever can write it
    /// decides where an 800 MB download lands. `build` was already having its separators replaced,
    /// which says the hazard was seen, but `asset` went in untouched: an asset named
    /// `../../../../Library/LaunchAgents/x.plist` writes attacker-chosen bytes to a path that runs
    /// on the operator's next login, and it lands there *before* any digest is checked. Both halves
    /// are now reduced to safe components and the result is verified to be inside the cache.
    /// Where this model's image lives. One directory per model, and only the newest file in it.
    ///
    /// Keyed by model rather than by build: a bench flashes the current image and nothing else, so
    /// keeping a directory per build meant an unbounded pile of 766 MB files that only `/tmp` being
    /// swept ever cleaned up — by accident, and at the cost of re-downloading.
    func cachePath(_ meta: ImageMeta) throws -> URL {
        guard let board = SafePath.component(meta.board, maxLength: 64) else {
            throw FlashError.unsafeIndexEntry("型号", meta.board)
        }
        guard let asset = SafePath.component(meta.asset, maxLength: 128) else {
            throw FlashError.unsafeIndexEntry("镜像文件名", meta.asset)
        }
        let url = cacheDirectory
            .appendingPathComponent(board, isDirectory: true)
            .appendingPathComponent(asset)
        guard SafePath.isContained(url, in: cacheDirectory) else {
            throw FlashError.unsafeIndexEntry("镜像路径", meta.asset)
        }
        return url
    }

    /// Drops every other image this model had, once the new one is in hand.
    ///
    /// Only after a successful fetch: a download that failed its digest must not cost the image
    /// that was already there. An unverified new one does replace a verified old one — this batch
    /// is going to flash the new one either way, and one file per model is a rule that stays true
    /// without anybody maintaining it.
    private func keepOnly(_ image: URL) {
        let dir = image.deletingLastPathComponent()
        let others = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                   includingPropertiesForKeys: nil))
            ?? []
        for file in others where file.lastPathComponent != image.lastPathComponent {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Hosts an image may come from.
    ///
    /// The digest is looked up by parsing the URL as a GitHub release page, so an index entry
    /// pointing anywhere else silently yields no digest and the image is flashed unverified. That
    /// makes the host part of the integrity story, not just the transport: restricting it keeps the
    /// unverified path to genuine API failures instead of anything the index cares to name. ATS
    /// already refuses plain http, but this does not rely on that.
    static let trustedImageHosts: Set<String> = [
        "github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com",
        "mixtile-rockchip.github.io",
    ]

    static func isTrustedImageHost(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            return false
        }
        return trustedImageHosts.contains(host)
    }

    /// Whether a cached file may be flashed as is: a known expected size, matched exactly.
    static func isUsable(_ path: URL, expecting size: Int) -> Bool {
        guard size >= 0,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let have = attrs[.size] as? Int
        else { return false }
        return have == size
    }

    /// SHA-256 of a file, read in chunks so an 800 MB image never lands in memory whole.
    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of bytes already in memory.
    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a file is the one the CI published. An unknown digest passes: the API may be
    /// unreachable or rate-limited, and that disproves nothing about the file. Passing here is not
    /// the same as having been verified — `FetchedImage.digestVerified` carries that apart, so the
    /// report can state which of the two happened.
    static func passesDigest(_ path: URL, expecting expected: String?) -> Bool {
        guard let expected, !expected.isEmpty else { return true }
        guard let have = try? sha256(ofFileAt: path) else { return false }
        return have.caseInsensitiveCompare(expected) == .orderedSame
    }

    /// The public releases API for a release page URL. Unauthenticated on purpose: an operator's
    /// Mac has no token and no gh.
    static func releaseAPIURL(forReleasePage page: String) -> URL? {
        let pattern = #"^https://github\.com/([^/]+)/([^/]+)/releases/tag/(.+)$"#
        guard let owner = RE.first(pattern, in: page, group: 1),
              let repo = RE.first(pattern, in: page, group: 2),
              let tag = RE.first(pattern, in: page, group: 3)
        else { return nil }
        return URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/tags/\(tag)")
    }

    /// The digest the CI published for this build, or nil when the API cannot say.
    static func publishedDigest(for meta: ImageMeta, releasePage: String? = nil) async -> String? {
        let page = releasePage ?? releasePageURL(forAsset: meta.url)
        guard let api = releaseAPIURL(forReleasePage: page) else { return nil }
        // Asked once per batch, because the fetch itself happens once per batch. It used to be
        // memoised by an actor, which was deduplicating a lookup that should not have repeated.
        var request = URLRequest(url: api)
        // Short: a few kilobytes of JSON, and the download waits behind it.
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return sha256(inReleaseJSON: data, asset: meta.asset)
    }

    /// The release page an asset download URL belongs to: drop the file name, keep the tag.
    static func releasePageURL(forAsset asset: String) -> String {
        guard let cut = asset.range(of: "/", options: .backwards) else { return "" }
        return asset[..<cut.lowerBound]
            .replacingOccurrences(of: "/releases/download/", with: "/releases/tag/")
    }

    /// The sha256 of one asset in a releases-API response, whose `digest` reads `sha256:<hex>`.
    static func sha256(inReleaseJSON data: Data, asset: String) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = obj["assets"] as? [[String: Any]],
              let entry = assets.first(where: { $0.str("name") == asset }),
              let digest = entry.str("digest"), digest.hasPrefix("sha256:")
        else { return nil }
        return String(digest.dropFirst("sha256:".count))
    }

    // MARK: - Flashing

    /// Flashes the image into one named board; the tool never picks a board on its own.
    func flash(_ image: URL, device: String, timeout: TimeInterval = 1800,
               onPercent: ((Int) -> Void)? = nil) async -> ShellResult {
        let args = ["-device", device, image.path]
        guard let onPercent else {
            return await Shell.run(executable, args, timeout: timeout)
        }
        // Monotonic only: the tool redraws its progress line in place.
        let highest = HighWaterMark()
        return await Shell.run(executable, args, timeout: timeout) { chunk in
            guard let peak = Self.percent(in: chunk),
                  let bumped = highest.raise(to: peak) else { return }
            onPercent(bumped)
        }
    }

    /// The write percentage in one read of the tool's stdout, which is `Writing: 42% (n/m bytes)`
    /// redrawn in place. A read can hold several redraws, and the furthest along is the current
    /// one. Matching the opening bracket of the byte counts is what keeps a redraw split across
    /// two reads from being read as a smaller percentage; the split redraw is simply missed, and
    /// the next percentage the tool prints supersedes it.
    static func percent(in chunk: String) -> Int? {
        RE.all(#"Writing: (\d+)% \("#, in: chunk).compactMap(Int.init).max()
    }

    static func exitCodeMeaning(_ code: Int32) -> String {
        switch code {
        case 2: return "无设备"
        case 3: return "镜像不可读"
        case 5: return "loader 缺失"
        case 6: return "刷写失败"
        case 8: return "指定的板不在位"
        default: return "未知错误"
        }
    }
}

/// Monotonically increasing high-water mark.
private final class HighWaterMark {
    private let lock = NSLock()
    private var value = 0
    /// Raises the mark, returning nil if it did not move.
    func raise(to v: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard v > value else { return nil }
        value = v
        return v
    }
}

enum FlashError: LocalizedError {
    case badImageURL(String)
    case noImage(String)
    /// A non-2xx HTTP status.
    case httpStatus(Int, String)
    /// The file is not the build the CI published.
    case digestMismatch(String)
    /// A field in the CI index cannot safely name a file. Refused rather than sanitised, because a
    /// hostile index should fail loudly rather thanhalf-work.
    case unsafeIndexEntry(String, String)
    var errorDescription: String? {
        switch self {
        case .badImageURL:        return "镜像地址无效，无法下载"
        case let .noImage(m):     return "未找到 \(m) 的镜像"
        case let .httpStatus(c, _):
            return "镜像服务器无法提供该镜像（HTTP \(c)）"
        case .digestMismatch:
            return "镜像校验失败，文件已丢弃，请重试"
        case .unsafeIndexEntry:
            return "镜像索引数据有误，已拒绝下载"
        }
    }
}

