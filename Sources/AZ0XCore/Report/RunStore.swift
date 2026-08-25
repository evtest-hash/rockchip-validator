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
}
