import Foundation

public enum CLIVersionDisplayPolicy {
    public static func isUpdateAvailable(currentVersion: String?, latestVersion: String?) -> Bool {
        guard let current = normalizedVersion(currentVersion),
              let latest = normalizedVersion(latestVersion) else { return false }
        return compare(current, latest) == .orderedAscending
    }

    public static func updateActionTitle(_ base: String, currentVersion: String?, latestVersion: String?) -> String {
        guard let target = targetVersion(currentVersion: currentVersion, latestVersion: latestVersion) else { return base }
        return "\(base) (\(target))"
    }

    public static func releaseNotes(from rawText: String?) -> String? {
        guard let rawText else { return nil }
        let lines = rawText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let markerIndex = lines.firstIndex(where: {
            let normalized = $0.lowercased()
            return normalized.contains("release notes") || normalized.contains("changelog")
        }) else { return nil }

        let marker = lines[markerIndex]
        let markerSuffix: String? = {
            guard let separator = marker.firstIndex(where: { $0 == ":" || $0 == "-" || $0 == "—" }) else { return nil }
            let value = marker[marker.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }()
        let following = lines.dropFirst(markerIndex + 1)
            .prefix(8)
            .filter { !$0.isEmpty }
        let notes = ([markerSuffix].compactMap { $0 } + following)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return nil }
        return String(notes.prefix(800))
    }

    public static func targetVersion(currentVersion: String?, latestVersion: String?) -> String? {
        guard let latest = normalizedVersion(latestVersion) else { return nil }
        guard let current = normalizedVersion(currentVersion) else { return latest }
        return versionsEqual(current, latest) ? nil : latest
    }

    public static func normalizedVersion(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let pattern = #"(?i)\bv?(\d+(?:\.\d+)+(?:[-+][A-Z0-9._-]+)?)\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let matches = regex.matches(in: trimmed, range: range)
        guard let match = matches.last, match.numberOfRanges > 1, let swiftRange = Range(match.range(at: 1), in: trimmed) else { return nil }
        return String(trimmed[swiftRange])
    }

    private static func versionsEqual(_ left: String, _ right: String) -> Bool {
        left.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(right.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private static func compare(_ left: String, _ right: String) -> ComparisonResult {
        left.compare(right, options: [.numeric, .caseInsensitive])
    }
}
