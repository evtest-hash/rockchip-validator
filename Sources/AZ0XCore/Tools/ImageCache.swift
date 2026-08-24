import Foundation

/// One download per image, however many benches ask for it at once. Benches of a round reach
/// their flashing item together and all want the same file.
actor ImageCache {
    static let shared = ImageCache()

    private var inFlight: [URL: Task<Void, Error>] = [:]
    private var observers: [URL: [UUID: ByteProgress]] = [:]

    /// Runs `download` for the first caller; later callers join it and see the same progress.
    func fetch(_ destination: URL,
               onProgress: ByteProgress?,
               download: @escaping (@escaping ByteProgress) async throws -> Void) async throws -> URL {
        let token = UUID()
        if let onProgress { observers[destination, default: [:]][token] = onProgress }
        defer { observers[destination]?[token] = nil }

        if let running = inFlight[destination] {
            try await running.value
            return destination
        }

        let task = Task {
            try await download { done, total in
                Task { await self.report(destination, done, total) }
            }
        }
        inFlight[destination] = task
        defer { inFlight[destination] = nil }
        try await task.value
        return destination
    }

    private func report(_ destination: URL, _ done: Int64, _ total: Int64?) {
        for report in (observers[destination] ?? [:]).values { report(done, total) }
    }
}
