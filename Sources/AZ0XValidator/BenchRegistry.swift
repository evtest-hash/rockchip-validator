import Foundation

/// Which boards this window is already driving.
///
/// A safety catch, and only that. It lives here rather than in the core because it is part of
/// fanning out across boards, and fanning out is this side's job: the core runs one board. It answers one question — is something in this process already
/// working on this board — instantly, from memory, with no I/O, and therefore with no way to fail
/// for a reason that has nothing to do with the question. A file lock can fail on permissions, a
/// full disk, a sandbox; that would make it a new source of faults rather than a guard against one.
///
/// Normal operation never notices it. The interface offers only boards that are free, and a command
/// line names distinct ones, so it fires exactly when something has gone wrong: two benches aimed at
/// one board, which for a flashing item means two writers on the same part.
///
/// It coordinates nothing — nothing here queues, waits or retries. It says nothing across processes
/// either, and does not need to: the window is the only thing that validates material, and it is one
/// process.
public actor BenchRegistry {

        private var held: Set<String> = []

    /// Takes a board, or reports that something already has it.
    ///
    /// The key is whatever addresses the board for this run: the maskrom device id for a sequence
    /// that starts there, the adb serial for one that names an already-flashed board. Two runs that
    /// address the same board the same way collide, which is the case worth catching.
    func take(_ key: String) -> Bool {
        held.insert(key).inserted
    }

    /// Gives a board back. Must run on every path out of a bench, or a socket that is physically
    /// free stays unusable for the rest of the session — the same fault, one level up, that a
    /// twelve-hour wall clock used to cause on the board itself.
    func release(_ key: String) {
        held.remove(key)
    }

    var inUse: Set<String> { held }
}
