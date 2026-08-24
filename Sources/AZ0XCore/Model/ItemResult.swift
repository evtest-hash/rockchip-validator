import Foundation

/// A recorded measurement. Always recorded, never a judgement.
struct Measurement: Identifiable, Codable, Equatable {
    let name: String
    let value: Value
    var id: String { name }

    enum Value: Codable, Equatable {
        case number(Double, unit: String?)
        case text(String)

        /// Presentation text shared by the report and the interface.
        var display: String {
            switch self {
            case let .number(v, unit):
                let s = v == v.rounded() && abs(v) < 1e15
                    ? String(Int(v))
                    : String(format: "%g", v)
                return unit.map { "\(s) \($0)" } ?? s
            case let .text(t):
                return t
            }
        }
    }

    static func num(_ name: String, _ v: Double, _ unit: String? = nil) -> Measurement {
        Measurement(name: name, value: .number(v, unit: unit))
    }
    static func text(_ name: String, _ v: String) -> Measurement {
        Measurement(name: name, value: .text(v))
    }
}

/// One named check, in either of the two lists on `ItemResult`.
struct Check: Identifiable, Codable, Equatable {
    let name: String
    let actual: String
    /// Human-readable description of the expectation, for example "= 0" or "≥ 1".
    let expected: String
    let passed: Bool
    var id: String { name }

    /// How this check reads when it is the one that decided the item's conclusion.
    var sentence: String { "\(name)：实测 \(actual)，要求 \(expected)" }

    static func equals(_ name: String, _ actual: Int, _ want: Int) -> Check {
        Check(name: name, actual: String(actual), expected: "= \(want)", passed: actual == want)
    }
    static func isTrue(_ name: String, _ ok: Bool, expected: String) -> Check {
        Check(name: name, actual: ok ? "满足" : "不满足", expected: expected, passed: ok)
    }
    static func lessThan(_ name: String, _ actual: Int, _ limit: Int, unit: String = "") -> Check {
        Check(name: name, actual: "\(actual)\(unit)", expected: "< \(limit)\(unit)",
              passed: actual < limit)
    }
}

/// One piece of evidence in the report appendix.
struct Evidence: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case log, markdown }

    let title: String
    let body: String
    var kind: Kind = .log
    var id: String { title }

    static func log(_ title: String, _ body: String) -> Evidence {
        Evidence(title: title, body: body, kind: .log)
    }
    static func markdown(_ title: String, _ body: String) -> Evidence {
        Evidence(title: title, body: body, kind: .markdown)
    }
}

/// Everything one item produced.
struct ItemResult: Codable, Equatable {
    let code: String

    /// Did it run properly. nil means it has not run yet.
    var execution: Execution?
    /// What the criteria say about the material. nil unless `execution == .completed`.
    var verdict: Verdict?

    var measurements: [Measurement] = []

    /// Preconditions for this run being valid at all: did the test actually do its work, did our
    /// own tooling behave, is the evidence readable.
    ///
    /// A failing one makes the execution `.invalid` and **can never produce a verdict against the
    /// material** — the same split pytest draws between an error in setup and a failure in the test
    /// body. In the first iteration these shared one list with the criteria, so "memtester never
    /// looped" and "memtester found a bit error" both rendered as 不通过, and two thirds of the
    /// forty-five criteria were facts about our own execution wearing a verdict's clothes.
    var validity: [Check] = []

    /// Criteria about the material. Only these can produce `notPassed`.
    var criteria: [Check] = []

    var evidence: [Evidence] = []
    var startedAt: Date?
    var finishedAt: Date?

    /// Present only for the long-running items.
    var progress: LongTestProgress?

    init(code: String) { self.code = code }

    var duration: TimeInterval? {
        guard let s = startedAt, let f = finishedAt else { return nil }
        return f.timeIntervalSince(s)
    }

    /// Every check, in the order the report shows them.
    var allChecks: [Check] { validity + criteria }

    // MARK: - Settling

    /// Settles the two check lists into an execution status and a verdict.
    ///
    /// Validity is decided first and stops there: a run that was not valid gets no verdict at all,
    /// rather than a verdict computed from readings nobody should trust.
    mutating func conclude(_ execution: Execution = .completed) {
        self.execution = execution
        guard execution.isCompleted else { verdict = nil; return }

        if let bad = validity.first(where: { !$0.passed }) {
            self.execution = .invalid(bad.sentence)
            verdict = nil
            return
        }
        guard !criteria.isEmpty else { verdict = .noCriterion; return }
        verdict = criteria.first(where: { !$0.passed }).map { .notPassed($0.sentence) } ?? .passed
    }

    /// A precondition was not met, so it never started.
    mutating func notStarted(_ why: String) { conclude(.notStarted(why)) }
    /// It started and could not finish.
    mutating func interrupted(_ why: String) { conclude(.interrupted(why)) }
    /// It ran, but the run was not valid. Never a statement about the material.
    mutating func invalid(_ why: String) { conclude(.invalid(why)) }

    // MARK: - Reading the conclusion

    /// Whether this item says the material is defective. The one question that must never be
    /// answered by anything but a verdict.
    var condemnsMaterial: Bool {
        if case .notPassed = verdict { return true }
        return false
    }

    /// Short label for the report and the interface.
    ///
    /// `interrupted` and `invalid` share one label: the operator's next action is the same for both
    /// — nothing about the material was established — and which of the two it was belongs in the
    /// explanation, not in another status light.
    var label: String {
        guard let execution else { return "未开始" }
        switch execution {
        case .notStarted:            return "跳过"
        case .interrupted, .invalid: return "未得结果"
        case .completed:
            switch verdict {
            case .passed?:      return "通过"
            case .notPassed?:   return "失败"
            case .noCriterion?: return "仅记录"
            case nil:           return "未得结果"
            }
        }
    }

    /// The accompanying explanation, or nil when there is nothing to explain.
    var detail: String? {
        if let reason = execution?.reason { return reason }
        if case let .notPassed(why) = verdict { return why }
        return nil
    }
}
