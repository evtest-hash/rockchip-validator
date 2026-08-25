import Foundation

// Three independent facts per item, kept apart on purpose. Every mature test framework separates at
// least the first two, and the ones closest to this bench separate all three:
//
//   OpenHTF       PhaseOutcome (PASS/FAIL/SKIP/ERROR) × PhaseResult (CONTINUE/STOP/FAIL_AND_CONTINUE)
//   NI TestStand  Step.Result.Status                  × StepCausedSequenceFailure
//   pytest        outcome (passed/failed/skipped)      × when (setup/call/teardown)
//   JUnit XML     <failure>                           vs <error>
//   TAP           ok / not ok + Plan                  vs Bail out!
//   LAVA          test result                         vs job status (Complete/Incomplete)
//
// The first iteration used one enum for all three. That is why a record-only bandwidth reading with
// no criteria at all could end a thirty-six-hour run: the flow decision was a computed property of
// the verdict's class, so no item was able to say "I have no result — carry on".

/// Did this item run properly. Never a statement about the material.
enum Execution: Equatable, Codable {
    /// Ran to its own end. Only then can a verdict exist.
    case completed
    /// A precondition was not met, so it never started.
    case notStarted(String)
    /// Started and could not finish.
    case interrupted(String)
    /// Ran, but the run was not valid: the evidence cannot be read, the work was not actually done,
    /// or our own tooling misbehaved. pytest's setup-phase error; OpenHTF's PhaseOutcome.ERROR.
    ///
    /// Kept apart from `interrupted` because for a long item the difference is the whole run:
    /// here the board may well have done the work and only our reading of it failed, so what needs
    /// retrying is the reading.
    case invalid(String)

    var isCompleted: Bool { self == .completed }

    /// Why it did not run properly, or nil when it did.
    var reason: String? {
        switch self {
        case .completed: return nil
        case let .notStarted(m), let .interrupted(m), let .invalid(m): return m
        }
    }
}

/// What the implemented criteria say about the material. Exists only when execution completed.
enum Verdict: Equatable, Codable {
    case passed
    case notPassed(String)
    /// Measured, with no criterion implemented. The report states the values and says so; whoever
    /// reads it judges them. Four items are like this by design: T01, T05, E03, E06.
    case noCriterion
}

/// What the sequence does after an item.
enum Flow: Equatable {
    case cont
    case stop

    /// Defective material stops the run: there is no point spending another thirty-six hours on it.
    /// A problem on our own side stops the run only when the items that follow depend on this one —
    /// a firmware missing a diagnostic binary must not cost the operator the entire burn-in.
    static func after(_ r: ItemResult, item: TestItem) -> Flow {
        if case .notPassed = r.verdict { return .stop }
        guard let execution = r.execution else { return .cont }
        return execution.isCompleted || !item.gatesRest ? .cont : .stop
    }
}
