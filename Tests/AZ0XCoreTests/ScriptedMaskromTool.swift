import Foundation
@testable import AZ0XCore

/// A maskrom tool that answers from a declared scenario instead of from a board.
///
/// Same discipline as `ScriptedBoardSession`: answers are declared, never computed, and an
/// unexpected request fails loudly rather than defaulting. The whole point of T01–T03 is what they
/// decide about a board, and that cannot be exercised against a real tool that needs a physical
/// board sitting in maskrom mode.
final class ScriptedMaskromTool: MaskromTool, @unchecked Sendable {

    /// One answer per `--flag`. `exitCode` is the primary source, as it is for the real tool.
    struct Answer {
        var json: [String: Any] = [:]
        var exitCode: Int32 = 0
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
        return DdrCli.JSONResult(json: a.json, exitCode: a.exitCode,
                                 raw: a.raw, parseError: a.parseError)
    }

    func devices() async -> [DdrCli.Device] { enumerated }
}
