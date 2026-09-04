import Foundation

/// Path components built from values this app did not choose.
///
/// Two kinds of string reach the filesystem from outside: identities the board reports about itself
/// (its OTP serial, its socket) and names the CI index supplies (the firmware asset). Neither is
/// validated at its source, and `URL.appendingPathComponent` does not normalise, so a `..` in one of
/// them walks out of the directory it was supposed to name. The threat model is not an attacker at
/// the bench — it is a defective or tampered board answering with a hostile string, and a CI index
/// whose write access is wider than this bench's.
///
/// Rejection, not repair: an unusable value returns nil rather than being stripped down to
/// something usable. Stripping would let two different serials collapse into one folder, which
/// silently mixes two boards' evidence — worse than refusing.
enum SafePath {

    /// Characters allowed in a component built from an outside value.
    ///
    /// Deliberately narrow: everything the real values contain (hex serials, `002-1.4` sockets,
    /// `image-raw-format-AZ08.img` assets) and nothing that means anything to a path.
    private static let allowed = Set("abcdefghijklmnopqrstuvwxyz"
                                   + "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                                   + "0123456789._-")

    /// One path component, or nil if the value cannot safely name anything.
    static func component(_ raw: String, maxLength: Int = 64) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength,
              trimmed != ".", trimmed != "..",
              trimmed.allSatisfy({ allowed.contains($0) })
        else { return nil }
        return trimmed
    }

    /// Whether `url` really resolves inside `root`, after `..` and symlinks are resolved.
    ///
    /// Defence in depth behind `component`: it catches a component this type failed to reject and
    /// anything a caller assembled by another route. Compared with a trailing separator so that a
    /// sibling directory sharing a prefix — `…/archive-evil` next to `…/archive` — is not accepted.
    static func isContained(_ url: URL, in root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard target != base else { return true }
        return target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }
}
