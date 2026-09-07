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
        let name = "\(stem)-报告.md"
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
        /// Whether this is a board on that silicon. A PID is a SoC fact and cannot say more —
        /// every board on one SoC shares it — so the parameter is the SoC, and the call sites read
        /// as the coarse filter this is rather than as a model filter.
        public func matches(_ soc: RockchipSoC) -> Bool { pid == soc.maskromPID }
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

// MARK: - Reading the archive back

public extension RunStore {

    /// One past run, read off the archive.
    struct Past: Identifiable {
        public let run: Run
        public let folder: URL
        public let reportURL: URL?
        public var id: String { folder.path }
    }

    /// One batch's worth of them: a batch folder holding a folder per board.
    struct PastBatch: Identifiable {
        public let batchID: String
        public let folder: URL
        public let runs: [Past]
        public var id: String { folder.path }
        /// When the earliest of its boards started.
        public var startedAt: Date? { runs.compactMap(\.run.startedAt).min() }
        public var model: BoardModel? { runs.first?.run.model }
        public var flow: ValidationFlow? { runs.first?.run.flow }
    }

    /// Past batches, newest first.
    ///
    /// A record this build cannot read is skipped without a word. The archive accumulates across
    /// versions of this program and across the generation before it, and a list that explained every
    /// unreadable folder would be mostly explanations. Nothing is written, renamed or removed here —
    /// clearing the archive is done in Finder.
    ///
    /// Ordered by folder date rather than by the timestamp in the batch id: sorting those
    /// lexically puts AZ04A ahead of AZ08 whatever the day, because the model comes first in the
    /// name. Read on demand, `limit` folders at a time — a bench doing twenty runs a day fills this
    /// directory with thousands of them, and none of that may be parsed to draw one screen.
    static func past(in root: URL = ArchiveRoot.default, limit: Int = 50) -> [PastBatch] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        return dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { $0.lastPathComponent != "images" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey])
                            .contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .compactMap { batch(at: $0.0) }
    }

    private static func batch(at folder: URL) -> PastBatch? {
        let fm = FileManager.default
        let boards = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles])) ?? []
        let runs = boards.compactMap { read(board: $0) }
        guard !runs.isEmpty else { return nil }
        return PastBatch(batchID: folder.lastPathComponent, folder: folder,
                         runs: runs.sorted { $0.run.boardName < $1.run.boardName })
    }

    private static func read(board folder: URL) -> Past? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("run.json")),
              let run = try? decoder.decode(Run.self, from: data),
              run.schemaVersion == Run.currentSchema
        else { return nil }
        let report = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?
            .first { $0.pathExtension == "md" }
        return Past(run: run, folder: folder, reportURL: report)
    }
}
