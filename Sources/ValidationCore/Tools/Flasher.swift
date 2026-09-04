import Foundation

/// Getting a production image onto a board, named as a role.
///
/// The last dependency that was still a concrete type. It mattered because flashing is the one item
/// the rest of the sequence depends on, so with a real `FlashTool` the only way to exercise the
/// engine past T04 was to have a board, a network and a CI channel — which meant the sequence
/// logic, the part most worth testing, had no test at all.
protocol Flasher {
    /// The newest published image for this model, or nil when the channel has none.
    func latestImage(for model: BoardModel) async throws -> FlashTool.ImageMeta?
    /// Downloads it, verifying the digest when CI will tell us one.
    func fetch(_ meta: FlashTool.ImageMeta,
               onProgress: ByteProgress?) async throws -> FlashTool.FetchedImage
    /// Writes it to the board addressed by the tool's device id.
    func flash(_ image: URL, device: String, timeout: TimeInterval,
               onPercent: ((Int) -> Void)?) async -> ShellResult
}

extension FlashTool: Flasher {}

extension Flasher {
    /// Protocol requirements cannot carry defaults, so the call-site ergonomics live here.
    func flash(_ image: URL, device: String,
               onPercent: ((Int) -> Void)? = nil) async -> ShellResult {
        await flash(image, device: device, timeout: 1800, onPercent: onPercent)
    }
}
