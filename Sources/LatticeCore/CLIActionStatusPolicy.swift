import Foundation

public enum CLIActionStatusPolicy {
    private static let maximumFailureDetailLength = 140
    private static let maximumSanitizationInputLength = 4_096
    private static let redactionPatterns: [(String, String)] = [
        (#"(?i)\b(authorization\s*[:=]\s*(?:bearer\s+)?)[^\s,;\}\]]+"#, "$1[REDACTED]"),
        (#"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1[REDACTED]"),
        (#"(?i)\b((?:api[_-]?key|secret[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|password|passwd|secret|token|cookie)\s*[:=]\s*)[^\s,;\}\]]+"#, "$1[REDACTED]"),
        (#"(?i)([?&](?:api[_-]?key|token|access[_-]?token|refresh[_-]?token)=)[^&\s]+"#, "$1[REDACTED]"),
        (#"(?i)\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{8,}|gh[pors]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|AIza[0-9A-Za-z_-]{12,}|AKIA[0-9A-Z]{16}|npm_[A-Za-z0-9]{8,}|hf_[A-Za-z0-9]{8,}|gsk_[A-Za-z0-9_-]{8,}|xai-[A-Za-z0-9_-]{8,})\b"#, "[REDACTED]"),
        (#"(?i)\b(?:session|credential)[_-]?id\s*[:=]?\s*[A-Za-z0-9][A-Za-z0-9._-]{7,}\b"#, "[REDACTED]"),
        (#"(?i)\b(?:sess(?:ion)?|cred(?:ential)?)[_-][A-Za-z0-9][A-Za-z0-9._-]{7,}\b"#, "[REDACTED]")
    ]
    public static func signInMessage(
        providerName: String,
        commandSucceeded: Bool,
        readyAfterRefresh: Bool
    ) -> String {
        if readyAfterRefresh { return "" }
        if !commandSucceeded { return "Sign in failed for \(providerName)." }
        return "Sign in finished, but Lattice could not verify a runnable \(providerName) connection."
    }

    public static func messageIndicatesProblem(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("failed")
            || normalized.contains("could not verify")
            || normalized.contains("not on path")
            || normalized.contains("stayed on")
            || normalized.contains("incomplete")
            || normalized.contains("unavailable")
    }

    public static func installMessage(
        executableName: String,
        status: Int32,
        output: Data,
        executableAvailableAfterRefresh: Bool
    ) -> String {
        guard status == 0 else {
            return failureMessage(prefix: "Install failed", output: output)
        }
        if executableAvailableAfterRefresh { return "" }
        return "\(executableName) installed, but it is not on PATH yet."
    }

    public static func updateMessage(
        status: Int32,
        output: Data,
        beforeVersion: String?,
        afterVersion: String?
    ) -> String {
        guard status == 0 else {
            return failureMessage(prefix: "Update failed", output: output)
        }
        if outputLooksUpToDate(output) {
            return ""
        }
        switch (beforeVersion, afterVersion) {
        case let (before?, after?):
            if before != after { return "" }
            return "Active CLI stayed on \(after)."
        case (nil, _?):
            return ""
        case (_?, nil), (nil, nil):
            return "Update finished, but Lattice could not verify the active CLI version."
        }
    }

    public static func outputLooksUpToDate(_ data: Data) -> Bool {
        let output = String(decoding: data, as: UTF8.self).lowercased()
        return output.contains("up to date")
            || output.contains("up-to-date")
            || output.contains("already installed")
            || output.contains("already up-to-date")
            || output.contains("already at the latest")
    }

    public static func failureMessage(prefix: String, output: Data) -> String {
        let text = String(decoding: output, as: UTF8.self)
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last { !$0.isEmpty }
            ?? "No error details."
        return "\(prefix): \(String(sanitizeFailureDetail(String(text.prefix(maximumSanitizationInputLength))).prefix(maximumFailureDetailLength)))"
    }

    public static func redactedDetail(_ text: String, limit: Int = 600) -> String {
        String(sanitizeFailureDetail(String(text.prefix(maximumSanitizationInputLength))).prefix(max(0, limit)))
    }

    private static func sanitizeFailureDetail(_ text: String) -> String {
        var sanitized = text
        for (patternSource, replacement) in redactionPatterns {
            guard let pattern = try? NSRegularExpression(pattern: patternSource) else { continue }
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = pattern.stringByReplacingMatches(in: sanitized, range: range, withTemplate: replacement)
        }
        return sanitized.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
