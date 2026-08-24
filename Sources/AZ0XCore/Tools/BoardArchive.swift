import Foundation

/// Archival of the raw board-side logs.
enum BoardArchive {

    /// Files larger than this are retrieved through a board-side gzip stream.
    static let compressAboveBytes = 1_000_000

    /// Retrieval limit per file.
    static let perFileTimeout: TimeInterval = 300

    struct Entry: Equatable {
        let name: String
        let boardBytes: Int
        let localBytes: Int
        let compressed: Bool
        /// nil on success; otherwise the reason for failure.
        let failure: String?
    }

    struct Result {
        var entries: [Entry] = []
        /// The report uses this to decide whether to note an incomplete archive.
        var isComplete: Bool { entries.allSatisfy { $0.failure == nil } }
        var failures: [Entry] { entries.filter { $0.failure != nil } }
    }

    /// Retrieves a board-side test directory into `<run>/logs/<code>/`.
    @discardableResult
    static func capture(adb: any BoardSession, boardDirectory: String, code: String,
                        runFolder: URL, extraPaths: [String] = []) async -> Result {
        var out = Result()
        let dest = runFolder.appendingPathComponent("logs/\(code)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            return Result(entries: [Entry(name: code, boardBytes: 0, localBytes: 0,
                                          compressed: false,
                                          failure: "建目录失败：\(error.localizedDescription)")])
        }

        // One shell call returns names and byte counts together, avoiding a round trip per file.
        let listing = await adb.line(
            "for f in \(boardDirectory)/*; do [ -f \"$f\" ] && "
          + "printf '%s %s\\n' \"$(wc -c < \"$f\")\" \"$f\"; done")
        var files: [(bytes: Int, path: String)] = listing
            .components(separatedBy: .newlines)
            .compactMap { line in
                let p = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard p.count == 2, let n = Int(p[0]) else { return nil }
                return (n, p[1].trimmingCharacters(in: .whitespaces))
            }
        for extra in extraPaths {
            if let n = await adb.int("wc -c < \(extra) 2>/dev/null"), n > 0 {
                files.append((n, extra))
            }
        }
        guard !files.isEmpty else {
            return Result(entries: [Entry(name: code, boardBytes: 0, localBytes: 0,
                                          compressed: false, failure: "板端目录为空或读不到")])
        }

        for f in files {
            out.entries.append(await pull(adb: adb, file: f, into: dest))
        }
        writeManifest(out, code: code, boardDirectory: boardDirectory, to: dest)
        return out
    }

    private static func pull(adb: any BoardSession, file: (bytes: Int, path: String),
                             into dest: URL) async -> Entry {
        let name = (file.path as NSString).lastPathComponent
        let compress = file.bytes > compressAboveBytes
        let local = dest.appendingPathComponent(compress ? name + ".gz" : name)

        let ok: Bool
        if compress {
            // Board-side gzip streamed through exec-out, creating no temporary file on the board.
            ok = await adb.execOut("gzip -c \(file.path)", to: local, timeout: perFileTimeout)
        } else {
            ok = await adb.pull(file.path, to: local, timeout: perFileTimeout)
        }

        // Success requires bytes on disk.
        let got = (try? FileManager.default
            .attributesOfItem(atPath: local.path)[.size] as? Int).flatMap { $0 } ?? 0
        guard ok, got > 0 else {
            try? FileManager.default.removeItem(at: local)
            return Entry(name: name, boardBytes: file.bytes, localBytes: 0,
                         compressed: compress, failure: "取回失败或落地为空")
        }
        return Entry(name: compress ? name + ".gz" : name, boardBytes: file.bytes,
                     localBytes: got, compressed: compress, failure: nil)
    }

    /// Writes the manifest.
    private static func writeManifest(_ r: Result, code: String,
                                      boardDirectory: String, to dest: URL) {
        var lines = [
            "# \(code) 板端原始日志清单",
            "",
            "板端目录：\(boardDirectory)",
            "取回时间：\(stamp.string(from: Date()))",
            "",
            "| 文件 | 板端字节 | 本地字节 | 压缩 | 状态 |",
            "|---|---|---|---|---|",
        ]
        for e in r.entries {
            lines.append("| \(e.name) | \(e.boardBytes) | \(e.localBytes) "
                       + "| \(e.compressed ? "gzip" : "—") | \(e.failure ?? "完好") |")
        }
        if !r.isComplete {
            lines += ["", "⚠️ 本次归档不完整，见上表「状态」列。"]
        }
        lines += ["", "压缩文件用 `gunzip` 解开；解压后内容与板端原件逐字节一致。"]
        try? lines.joined(separator: "\n")
            .write(to: dest.appendingPathComponent("MANIFEST.md"),
                   atomically: true, encoding: .utf8)
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
