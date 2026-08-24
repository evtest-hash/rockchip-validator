import Foundation

/// Wrapper around RockchipDDRTestUtilityCLI, used by T01 (spec).
struct DdrCli {

    /// A device enumerated in maskrom mode.
    struct Device {
        let id: String
        let pid: String        // lower-case, matching the tool's --list output
    }

    let executable: String

    init?(executable: String? = BundledTools.ddrCli) {
        guard let executable else { return nil }
        self.executable = executable
    }

    // MARK: - Enumeration

    /// Lists the currently enumerated Rockchip devices.
    ///
    /// From `--list --json`, which v2.7 answers with a structured `devices` array. It used to parse
    /// the human `--list` text for `id=` and `pid=` — a format meant for a person to read, and one
    /// nothing stops from being reworded.
    func devices() async -> [Device] {
        let r = await Shell.run(executable, ["--list", "--json"], timeout: 60)
        guard let data = r.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listed = obj["devices"] as? [[String: Any]]
        else { return [] }
        return listed.compactMap { entry in
            guard let id = entry.str("deviceID"), let pid = entry.str("pid") else { return nil }
            // Lower-cased to match `DeviceModel.maskromPID`, which is written that way.
            return Device(id: id, pid: pid.lowercased())
        }
    }

    /// Waits for one specific board to re-enumerate and stabilise before its next item runs.
    /// Addressed by the tool's device id, whose port chain survives re-enumeration; the USB
    /// address in it used to move between boards of one model.
    func waitEnumerated(deviceID: String,
                        settle: TimeInterval = 5,
                        timeout: TimeInterval = 20,
                        stableChecks: Int = 2) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
        let deadline = Date().addingTimeInterval(timeout)
        var same = 0
        while Date() < deadline {
            if await device(id: deviceID) != nil {
                same += 1
                if same >= stableChecks { return true }
            } else {
                same = 0
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        return false
    }

    /// Bus and port chain out of a device id, e.g. "002-1.4": the physical socket.
    static func socket(_ deviceID: String) -> String {
        deviceID.split(separator: "-").prefix(2).joined(separator: "-")
    }

    /// Chip identity read out of OTP: the cpuid, and the serial the board reports once booted.
    struct Identity {
        let cpuid: String
        let serial: String
        /// Model variant within the SoC family, nil on a tool or SoC that does not report it.
        let variant: String?
    }

    /// Reads the identity of one board while it is still in maskrom.
    func identity(deviceID: String) async -> Identity? {
        let jr = await runJSON("--detect", deviceID: deviceID, timeout: 120)
        // The tool puts these at the top level; the nested lookup is the older shape.
        let det = jr.json.dict("detect") ?? [:]
        func field(_ key: String) -> String? { det.str(key) ?? jr.json.str(key) }
        guard let cpuid = field("cpuid"), !cpuid.isEmpty,
              let serial = field("serial"), !serial.isEmpty
        else { return nil }
        return Identity(cpuid: cpuid, serial: serial, variant: field("chipVariant"))
    }

    // MARK: - Subcommands

    /// Result of one `--json` subcommand.
    struct JSONResult {
        let json: [String: Any]
        let exitCode: Int32
        /// The tool's raw stdout.
        let raw: String
        let parseError: String?
    }

    /// Runs one `--json` subcommand. `deviceID` must be supplied.
    func runJSON(_ flag: String,
                 deviceID: String?,
                 timeout: TimeInterval = 600) async -> JSONResult {
        var args = [flag, "--json"]
        if let deviceID, !deviceID.isEmpty {
            args += ["--device-id", deviceID]
        }
        let r = await Shell.run(executable, args, timeout: timeout)
        let raw = r.stdout
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let why = r.timedOut
                ? "工具超时（\(Int(timeout))s）未返回"
                : (r.stderr.isEmpty ? "输出不是合法 JSON" : r.stderr)
            return JSONResult(json: [:], exitCode: r.exitCode,
                              raw: r.combined, parseError: why)
        }
        return JSONResult(json: obj, exitCode: r.exitCode, raw: raw, parseError: nil)
    }
}

// MARK: - JSON accessors

extension Dictionary where Key == String, Value == Any {
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func str(_ key: String) -> String? {
        if let s = self[key] as? String { return s }
        if let n = self[key] as? NSNumber { return n.stringValue }
        return nil
    }
    func int(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber { return n.intValue }
        if let s = self[key] as? String { return Int(s) }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        if let b = self[key] as? Bool { return b }
        if let n = self[key] as? NSNumber { return n.boolValue }
        return nil
    }
    func array(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }
}
