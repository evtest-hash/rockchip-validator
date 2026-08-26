import Foundation

/// An image sitting on this machine, ready to be written to a board.
public struct PreparedImage: Equatable {
    public let url: URL
    /// What CI called it. Goes on the record, so a report says which build reached this board.
    public let asset: String
    /// Whether it was proved to be the published build. Flashing an unproved one is a deliberate
    /// trade-off — the digest API is rate-limited — but it must never be invisible.
    public let digestVerified: Bool

    public init(url: URL, asset: String, digestVerified: Bool) {
        self.url = url
        self.asset = asset
        self.digestVerified = digestVerified
    }
}

/// Getting the current image for a model onto this machine.
///
/// Separate from flashing, because they are separate jobs: this one asks CI what the current build
/// is and brings it here; T04 writes what it is handed onto one board. Binding them meant every
/// board asked CI independently and downloaded independently, which is why "several boards only
/// need one download" ever looked like a concurrency problem. It is not — it is one step that
/// happens before the boards do.
///
/// Two things follow from doing it once. Every board of a batch is flashed from the same build by
/// construction rather than by coincidence, and the machinery that used to deduplicate the download
/// and the digest lookup has nothing left to deduplicate.
public enum ImageSupply {

    public enum Failure: LocalizedError {
        case toolMissing
        case noImage(DeviceModel)
        case channel(String)

        public var errorDescription: String? {
            switch self {
            case .toolMissing:      return "刷机工具未随应用打包（rockchip-flash-tool-cli 缺失）"
            case let .noImage(m):   return "CI 快照通道没有 \(m.rawValue) 的镜像"
            case let .channel(why): return why
            }
        }
    }

    /// Finds the newest published image for a model and puts it where a run can flash it.
    ///
    /// Throws rather than returning an optional: every way this fails means the batch is not ready
    /// to start, and none of them says anything about any board.
    /// `onAsset` fires once CI has named the build, which is before a single byte moves. The two
    /// halves of this step look different to whoever is waiting: asking CI has no byte count to
    /// show, and the transfer has nothing to name until the asking is done.
    public static func prepare(model: DeviceModel,
                               onAsset: ((String) -> Void)? = nil,
                               onProgress: ByteProgress? = nil) async throws -> PreparedImage {
        guard let tool = FlashTool() else { throw Failure.toolMissing }
        return try await prepare(model: model, using: tool,
                                 onAsset: onAsset, onProgress: onProgress)
    }

    /// The injectable form, so the whole path is reachable without a network.
    static func prepare(model: DeviceModel, using tool: any Flasher,
                        onAsset: ((String) -> Void)? = nil,
                        onProgress: ByteProgress? = nil) async throws -> PreparedImage {
        let meta: FlashTool.ImageMeta?
        do { meta = try await tool.latestImage(for: model) }
        catch { throw Failure.channel("无法访问 CI 快照通道：\(error.localizedDescription)") }
        guard let meta else { throw Failure.noImage(model) }
        onAsset?(meta.asset)

        let fetched = try await tool.fetch(meta, onProgress: onProgress)
        return PreparedImage(url: fetched.url, asset: meta.asset,
                             digestVerified: fetched.digestVerified)
    }
}
