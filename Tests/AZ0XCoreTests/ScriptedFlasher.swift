import Foundation
@testable import AZ0XCore

/// Flashing that writes nothing, so the sequence past T04 is reachable without a board or a network.
final class ScriptedFlasher: Flasher, @unchecked Sendable {

    var meta: FlashTool.ImageMeta? = .init(asset: "image-raw-format-AZ08.img",
                                           url: "https://example.invalid/x.img",
                                           size: 346_451_968, date: "20260824",
                                           board: "AZ08", tag: "snapshot-1")
    var digestVerified = true
    var exitCode: Int32 = 0
    /// Set to have the channel itself fail, which is our side and never the material's.
    var channelError: Error?

    private(set) var flashed: [String] = []

    func latestImage(for model: DeviceModel) async throws -> FlashTool.ImageMeta? {
        if let channelError { throw channelError }
        return meta
    }

    func fetch(_ meta: FlashTool.ImageMeta,
               onProgress: ByteProgress?) async throws -> FlashTool.FetchedImage {
        onProgress?(Int64(meta.size), Int64(meta.size))
        // A path that exists, so the item's size lookup behaves as it does in production.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("az0x-scripted-image.img")
        try? Data(count: 1024).write(to: url)
        return FlashTool.FetchedImage(url: url, digestVerified: digestVerified)
    }

    func flash(_ image: URL, device: String, timeout: TimeInterval,
               onPercent: ((Int) -> Void)?) async -> ShellResult {
        flashed.append(device)
        onPercent?(100)
        return ShellResult(exitCode: exitCode, stdout: "", stderr: "", duration: 92.4,
                           timedOut: false, cancelled: false, outputTruncated: false)
    }
}

/// An image already on this machine, the way a caller hands one to a run now that fetching is a
/// step of its own.
///
/// A real file, because the flashing item reads its size to report the average write rate — a
/// fixture pointing at a path that does not exist silently loses that measurement.
var readyImage: PreparedImage {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("az0x-test-image.img")
    if !FileManager.default.fileExists(atPath: url.path) {
        try? Data(count: 803_100_000 / 1000).write(to: url)
    }
    return PreparedImage(url: url, asset: "image-raw-format-AZ08.img", digestVerified: true)
}
