import Foundation

/// Where a finished board's two files land.
///
/// One place, used by the command line and the interface alike: a report produced either way has to
/// be the same document, and the surest way to keep that true is to have one function write it.
public enum RunStore {

    /// Writes the record and the report side by side, and returns the report.
    ///
    /// The record goes first. It is the run's durable form and the report is one rendering of it,
    /// not the other way round — so if only one of the two survives, it should be the one everything
    /// else can be rebuilt from.
    @discardableResult
    public static func write(_ run: Run, into dir: URL) -> URL? {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        if let data = try? encoder.encode(run) {
            try? data.write(to: dir.appendingPathComponent("run.json"))
        }

        // The name has to say model, flow, when and which board without the folder around it: a
        // report gets forwarded, screenshotted and pasted somewhere else.
        let stem = "\(run.batchID)-\(run.boardName)"
        let name = "\(stem)\(run.isPartial ? "-抽测记录" : "-初步报告").md"
        let url = dir.appendingPathComponent(name)
        guard (try? ReportRenderer.render(run).write(to: url, atomically: true, encoding: .utf8))
                != nil else { return nil }
        return url
    }

    /// Copies a finished report where the operator looks for things to send.
    ///
    /// The archive lives under Documents because that is where a record belongs; a report gets
    /// forwarded from the Downloads folder, so it is offered there too rather than asking someone
    /// to go and find it.
    public static func copyToDownloads(_ report: URL?) throws -> URL {
        guard let report else { throw CocoaError(.fileNoSuchFile) }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        let target = downloads.appendingPathComponent(report.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: report, to: target)
        return target
    }
}

/// What is plugged in right now.
///
/// A snapshot of the bus, and deliberately not a statement about availability: whether a board is
/// free is the caller's to know, and across processes nobody can know it.
public enum MaskromScan {

    public struct Board: Identifiable, Equatable {
        /// The tool's device id — how the maskrom domain is addressed.
        public let deviceID: String
        /// USB product id, lower-case, as the tool prints it.
        public let pid: String
        public var id: String { deviceID }
        /// Bus and port chain: the physical position, which is what an operator recognises.
        public var socket: String { DdrCli.socket(deviceID) }
        /// Whether this is a board of that model, as far as the USB id can say.
        public func matches(_ model: DeviceModel) -> Bool { pid == model.maskromPID }
    }

    public static func attached() async -> [Board] {
        guard let cli = DdrCli() else { return [] }
        return await cli.devices().map { Board(deviceID: $0.id, pid: $0.pid) }
    }

    /// Bundled tools this build is missing. Empty is the only workable answer.
    public static var missingTools: [String] { BundledTools.missingTools }

    /// Serials of boards that are booted and reachable over adb.
    ///
    /// The other domain. A sequence that starts in maskrom never needs this — it learns the serial
    /// from OTP — but one that runs only board items has to be told which already-flashed board it
    /// means, and the two domains share no identifier.
    public static func onlineSerials() async -> [String] {
        await Adb.onlineSerials()
    }
}
