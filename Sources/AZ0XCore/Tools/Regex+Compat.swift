import Foundation

/// Regular-expression helpers.
enum RE {

    /// Capture group `group` of the first match.
    static func first(_ pattern: String, in text: String,
                      group: Int = 1, options: NSRegularExpression.Options = []) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              group < m.numberOfRanges, m.range(at: group).location != NSNotFound
        else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    /// Capture group `group` of every match.
    static func all(_ pattern: String, in text: String,
                    group: Int = 1, options: NSRegularExpression.Options = []) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { m in
                guard group < m.numberOfRanges, m.range(at: group).location != NSNotFound
                else { return nil }
                return ns.substring(with: m.range(at: group))
            }
    }

    static func firstInt(_ pattern: String, in text: String, group: Int = 1) -> Int? {
        first(pattern, in: text, group: group).flatMap { Int($0) }
    }
}
