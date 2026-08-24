import Foundation
import CryptoKit

/// The real link: adb against a board over USB. Access constraints: docs/decisions.md.
struct Adb: BoardSession {

    /// adb server port.
    static let serverPort = 5037

    /// Environment for adb: the inherited environment with the server port fixed.
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["ANDROID_ADB_SERVER_PORT"] = String(serverPort)
        return env
    }()

    let executable: String
    /// Serial of the target device.
    let serial: String

    init?(executable: String? = BundledTools.adb, serial: String) {
        guard let executable else { return nil }
        self.executable = executable
        self.serial = serial
    }

    // MARK: - Device discovery

    /// Serials of online devices, meaning state == device.
    static func onlineSerials(executable: String? = BundledTools.adb) async -> [String] {
        guard let executable else { return [] }
        let r = await Shell.run(executable, ["devices"], timeout: 30,
                                environment: Adb.environment)
        return r.stdout.components(separatedBy: .newlines)
            .dropFirst()                                  // "List of devices attached"
            .compactMap { line in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2, parts[1] == "device" else { return nil }
                return String(parts[0])
            }
    }

    /// Waits for a device to come online and returns its serial.
    static func waitForDevice(timeout: TimeInterval = 180,
                             excluding: Set<String> = [],
                             executable: String? = BundledTools.adb) async -> String? {
        let began = Monotonic.now
        while !Monotonic.elapsed(since: began, exceeds: timeout) {
            let fresh = await onlineSerials(executable: executable)
                .filter { !excluding.contains($0) }
            if let s = fresh.first { return s }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return nil
    }

    var isOnline: Bool {
        get async {
            await Self.onlineSerials(executable: executable).contains(serial)
        }
    }

    // MARK: - Execution

    /// Runs one command on the board. The only primitive; `sh`, `line` and `int` derive from it.
    func shell(_ command: String, timeout: TimeInterval) async -> ShellResult {
        await Shell.run(executable, ["-s", serial, "shell", command], timeout: timeout,
                        environment: Adb.environment)
    }

    /// Writes text to a path on the board, used to push the board-side payload.
    func writeFile(_ content: String, to path: String, timeout: TimeInterval) async -> Bool {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("az0x-payload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? content.write(to: tmp, atomically: true, encoding: .utf8)) != nil
        else { return false }

        let push = await Shell.run(executable, ["-s", serial, "push", tmp.path, path],
                                   timeout: timeout,
                                   environment: Adb.environment)
        guard push.ok else { return false }

        let remote = await line("md5sum \(path) 2>/dev/null | awk '{print $1}'")
        guard let localData = try? Data(contentsOf: tmp) else { return false }
        return remote.isEmpty || remote.lowercased() == Self.md5Hex(localData)
    }

    /// Supplementary hint when no device is found.
    static func noDeviceHint(executable: String? = BundledTools.adb) async -> String {
        guard let executable else { return "" }
        let r = await Shell.run(executable, ["devices", "-l"], timeout: 30,
                                environment: environment)
        // Each line is `<serial> <state> usb:...`; only a state other than device needs explaining.
        let odd = r.stdout.components(separatedBy: .newlines)
            .dropFirst()
            .compactMap { line -> String? in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2, parts[1] != "device" else { return nil }
                return "\(parts[0]) 状态为 \(parts[1])"
            }
        guard !odd.isEmpty else { return "" }
        return "adb 检出了设备但状态不可用：" + odd.joined(separator: "、")
             + "。unauthorized 需在板子上确认授权，offline 或 no permissions 请重插 USB。"
    }

    /// Pulls a file from the board.
    func pull(_ boardPath: String, to local: URL, timeout: TimeInterval) async -> Bool {
        await Shell.run(executable, ["-s", serial, "pull", boardPath, local.path],
                        timeout: timeout, environment: Adb.environment).ok
    }

    /// Runs a command on the board and writes its raw stdout bytes to a local file.
    func execOut(_ command: String, to local: URL, timeout: TimeInterval) async -> Bool {
        guard let out = FileHandle(forWritingAtPath: local.path) ?? {
            FileManager.default.createFile(atPath: local.path, contents: nil)
            return FileHandle(forWritingAtPath: local.path)
        }() else { return false }
        defer { try? out.close() }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["-s", serial, "exec-out", command]
        p.environment = Adb.environment
        p.standardOutput = out
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return false }

        // The same watchdog as Shell.run: no step may block the run indefinitely.
        let deadline = DispatchWorkItem {
            guard p.isRunning else { return }
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                p.waitUntilExit()
                c.resume()
            }
        }
        deadline.cancel()
        _ = try? err.fileHandleForReading.readToEnd()
        return p.terminationStatus == 0
    }

    /// Computes an md5, used only to verify a pushed file.
    private static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Whether a command failed because the tool does not exist.
    static func isCommandMissing(_ r: ShellResult) -> Bool {
        r.exitCode == 127
            || r.combined.contains("not found")
            || r.combined.contains("No such file or directory")
    }
}
