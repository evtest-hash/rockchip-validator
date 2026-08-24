import Foundation
@testable import AZ0XCore

/// A maskrom tool that answers from a declared scenario instead of from a board.
///
/// Same discipline as `ScriptedBoardSession`: answers are declared, never computed, and an
/// unexpected request fails loudly rather than defaulting. The whole point of T01–T03 is what they
/// decide about a board, and that cannot be exercised against a real tool that needs a physical
/// board sitting in maskrom mode.
final class ScriptedMaskromTool: MaskromTool, @unchecked Sendable {

    /// One answer per `--flag`, shaped like the tool's real envelope.
    ///
    /// `ok` and `error` are top level in every mode, so they are supplied here rather than being
    /// spelled out in each scenario's dictionary — a fixture that forgets them describes a tool that
    /// does not exist, and the item reading them would look broken for the wrong reason.
    struct Answer {
        var json: [String: Any] = [:]
        var exitCode: Int32 = 0
        /// The tool's own verdict, top level in every mode.
        var ok: Bool = true
        /// v2.7's stable reason no verdict was produced. Non-nil means the tool exited 1.
        var errorCode: String?
        var errorMessage: String?
        var raw: String = ""
        var parseError: String?
    }

    var answers: [String: Answer] = [:]
    var enumerated: [DdrCli.Device] = [.init(id: "002-1.4-2207-350e-NA", pid: "0x350e")]

    private(set) var asked: [String] = []
    private(set) var unmatched: [String] = []

    init(_ answers: [String: Answer] = [:]) { self.answers = answers }

    func runJSON(_ flag: String, deviceID: String?,
                 timeout: TimeInterval) async -> DdrCli.JSONResult {
        asked.append(flag)
        guard let a = answers[flag] else {
            unmatched.append(flag)
            return DdrCli.JSONResult(json: [:], exitCode: 127, raw: "",
                                     parseError: "场景没有覆盖 \(flag)")
        }
        var json = a.json
        json["pass"] = a.ok
        if let code = a.errorCode { json["errorCode"] = code }
        if let message = a.errorMessage { json["errorMessage"] = message }
        return DdrCli.JSONResult(json: json, exitCode: a.exitCode,
                                 raw: a.raw, parseError: a.parseError)
    }

    func devices() async -> [DdrCli.Device] { enumerated }
}
