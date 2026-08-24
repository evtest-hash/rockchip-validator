import Foundation

/// Result of running an external command.
struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval
    /// Whether the process was killed after the timeout.
    let timedOut: Bool
    /// Whether the process was killed because the task was cancelled.
    let cancelled: Bool
    /// The process exited but the pipes were not drained within the grace period.
    let outputTruncated: Bool

    /// Checks read the exit code rather than matching strings.
    var ok: Bool { exitCode == 0 && !timedOut && !cancelled }

    /// Raw tool output.
    var combined: String {
        stderr.isEmpty ? stdout : (stdout.isEmpty ? stderr : stdout + "\n" + stderr)
    }
}

/// Thread-safe output accumulator.
private final class OutputSink {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

/// Holds the running process so that the cancellation handler can kill it from another thread.
private final class ProcessBox {
    private let lock = NSLock()
    private var process: Process?
    private(set) var wasCancelled = false

    func adopt(_ p: Process) { lock.lock(); process = p; lock.unlock() }
    func clear() { lock.lock(); process = nil; lock.unlock() }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let p = process
        lock.unlock()
        guard let p, p.isRunning else { return }
        p.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
    }
}

/// Runner for external commands.
struct Shell {

    /// Grace period for draining the pipes after the process exits.
    private static let drainGrace: TimeInterval = 5

    /// Runs a command and waits for it to finish.
    static func run(_ executable: String,
                    _ arguments: [String] = [],
                    timeout: TimeInterval = 120,
                    environment: [String: String]? = nil,
                    stdin: String? = nil,
                    onOutput: ((String) -> Void)? = nil) async -> ShellResult {
        let box = ProcessBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Blocking waits happen on a background thread, leaving the interface responsive.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: runBlocking(
                        executable, arguments, timeout: timeout,
                        environment: environment, stdin: stdin, box: box,
                        onOutput: onOutput))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func runBlocking(_ executable: String,
                                    _ arguments: [String],
                                    timeout: TimeInterval,
                                    environment: [String: String]?,
                                    stdin: String?,
                                    box: ProcessBox,
                                    onOutput: ((String) -> Void)?) -> ShellResult {
        let started = Date()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let inPipe = stdin != nil ? Pipe() : nil
        if let inPipe { process.standardInput = inPipe }

        func failure(_ message: String) -> ShellResult {
            ShellResult(exitCode: -1, stdout: "", stderr: message,
                        duration: Date().timeIntervalSince(started),
                        timedOut: false, cancelled: box.wasCancelled,
                        outputTruncated: false)
        }

        do {
            try process.run()
            box.adopt(process)
            if let inPipe, let stdin {
                inPipe.fileHandleForWriting.write(Data(stdin.utf8))
                try? inPipe.fileHandleForWriting.close()
            }
        } catch {
            return failure("无法启动 \(executable)：\(error.localizedDescription)")
        }
        defer { box.clear() }

        // Drain both pipes concurrently to avoid deadlocking on a full buffer.
        let outSink = OutputSink(), errSink = OutputSink()
        let group = DispatchGroup()
        for (pipe, sink, stream) in [(outPipe, outSink, true), (errPipe, errSink, false)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = pipe.fileHandleForReading
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }         // EOF
                    sink.append(chunk)
                    // Only stdout is forwarded: progress appears there.
                    if stream, let onOutput { onOutput(String(decoding: chunk)) }
                }
                group.leave()
            }
        }

        // Timeout watchdog: terminate first, then kill if the process is still running.
        let timedOut = TimeoutFlag()
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            timedOut.set()
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

        process.waitUntilExit()
        deadline.cancel()

        // Draining waits only for the grace period.
        let truncated = group.wait(timeout: .now() + drainGrace) == .timedOut

        return ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: outSink.value),
            stderr: String(decoding: errSink.value),
            duration: Date().timeIntervalSince(started),
            timedOut: timedOut.isSet,
            cancelled: box.wasCancelled,
            outputTruncated: truncated)
    }
}

/// Cross-thread boolean flag.
private final class TimeoutFlag {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

extension String {
    /// Tool output is not guaranteed to be valid UTF-8, since a device may emit binary noise.
    init(decoding data: Data) {
        let raw = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        self = raw.normalizingNewlines()
    }

    /// Normalises CRLF and lone CR to LF.
    func normalizingNewlines() -> String {
        replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
