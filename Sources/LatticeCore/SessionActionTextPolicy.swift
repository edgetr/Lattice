import Foundation

/// Sanitization boundary for text that may enter durable session action records.
///
/// Provider payloads can contain commands, headers, URLs, and diagnostic output.
/// Action records are user-visible and persisted, so they get bounded, redacted
/// summaries rather than raw provider text.
public enum SessionActionTextPolicy {
    public static let maximumInputCharacterCount = 16_384
    public static let maximumTitleUTF8ByteCount = 512
    public static let maximumDetailUTF8ByteCount = 4_096
    /// Fixed replacement used whenever the input cannot be inspected safely.
    /// Keeping this marker short also makes it safe for title/detail byte caps.
    public static let oversizedInputMarker = "[REDACTED]"

    private static let redactionPatterns: [(NSRegularExpression, String)] = {
        let sources: [(String, String)] = [
            (#"(?i)(([\"']?)authorization\2\s*[:=]\s*)([\"']?)(?!(?:(?:bearer|basic)\s+)?\[REDACTED\])((?:bearer|basic)\s+)?[^\"'\s,;\}\]\[]+\3"#, "$1$3$4[REDACTED]$3"),
            (#"(?i)\b(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1[REDACTED]"),
            (#"(?im)(^|[\r\n])([ \t]*(?:cookie|set-cookie)[ \t]*:[ \t]*)[^\r\n]*"#, "$1$2[REDACTED]"),
            (#"(?im)(^|[\r\n])([ \t]*(?:api[_-]?key|secret[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|password|passwd|secret|token|session[_-]?id|thread[_-]?id|provider[_-]?session[_-]?id|harness[_-]?thread[_-]?id|credential[_-]?id|credentials?)[ \t]*:[ \t]*)[^\r\n]*"#, "$1$2[REDACTED]"),
            (#"([A-Z][A-Z0-9_]*(?:API_KEY|SECRET(?:_ACCESS)?_KEY|BOT_TOKEN|ACCESS_TOKEN|REFRESH_TOKEN|ID_TOKEN|AUTH_TOKEN|PRIVATE_KEY|CLIENT_SECRET|PASSWORD|PASSWD|CREDENTIALS?|SESSION_ID|THREAD_ID|PROVIDER_SESSION_ID|HARNESS_THREAD_ID)\s*=\s*)(?:\\\"(?:\\(?!\")|[^\"\\])*\\\"|\\'(?:\\(?!')|[^'\\])*\\'|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\"'\\\s,;\{\}\[\]]+)"#, "$1[REDACTED]"),
            (#"(?i)(([\"']?)(?:api[_-]?key|secret[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|password|passwd|secret|token|cookie|session[_-]?id|thread[_-]?id|provider[_-]?session[_-]?id|harness[_-]?thread[_-]?id|credential[_-]?id)\2\s*[:=]\s*)\\\"(?:\\(?!\")|[^\"\\])*\\\""#, "$1[REDACTED]"),
            (#"(?i)(([\"']?)(?:api[_-]?key|secret[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|password|passwd|secret|token|cookie|session[_-]?id|thread[_-]?id|provider[_-]?session[_-]?id|harness[_-]?thread[_-]?id|credential[_-]?id)\2\s*[:=]\s*)\\'(?:\\(?!')|[^'\\])*\\'"#, "$1[REDACTED]"),
            (#"(?i)(([\"']?)(?:api[_-]?key|secret[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|password|passwd|secret|token|cookie|session[_-]?id|thread[_-]?id|provider[_-]?session[_-]?id|harness[_-]?thread[_-]?id|credential[_-]?id)\2\s*[:=]\s*)\"(?:\\.|[^\"\\])*\""#, "$1\"[REDACTED]\""),
            (#"(?i)(([\"']?)(?:api[_-]?key|secret[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|password|passwd|secret|token|cookie|session[_-]?id|thread[_-]?id|provider[_-]?session[_-]?id|harness[_-]?thread[_-]?id|credential[_-]?id)\2\s*[:=]\s*)'(?:\\.|[^'\\])*'"#, "$1'[REDACTED]'"),
            (#"(?i)(([\"']?)(?:api[_-]?key|secret[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|password|passwd|secret|token|cookie|session[_-]?id|thread[_-]?id|provider[_-]?session[_-]?id|harness[_-]?thread[_-]?id|credential[_-]?id)\2\s*[:=]\s*)(?![\"'\\]|\[REDACTED\])[^\"'\\\s,;\{\}\[\]&]+"#, "$1[REDACTED]"),
            (#"(?i)(--(?:api[_-]?key|token|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret|password|session[_-]?id|thread[_-]?id|provider[_-]?session[_-]?id|harness[_-]?thread[_-]?id)(?:\s+|=))(?:\\\"(?:\\(?!\")|[^\"\\])*\\\"|\\'(?:\\(?!')|[^'\\])*\\'|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\"'\\\s,;\{\}\[\]]+)"#, "$1[REDACTED]"),
            (#"(?i)([?&](?:api[_-]?key|token|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret|password|credential|session[_-]?id|thread[_-]?id|provider[_-]?session[_-]?id|harness[_-]?thread[_-]?id)=)[^&\"'\\\s\{\}\[\]]+"#, "$1[REDACTED]"),
            (#"(?i)\b(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{8,}|gh[pors]_[A-Za-z0-9_]{8,}|github_pat_[A-Za-z0-9_]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|AIza[0-9A-Za-z_-]{12,}|AKIA[0-9A-Z]{16}|npm_[A-Za-z0-9]{8,}|hf_[A-Za-z0-9]{8,}|gsk_[A-Za-z0-9_-]{8,}|xai-[A-Za-z0-9_-]{8,})\b"#, "[REDACTED]"),
            (#"(?i)\bcredential[_-]?id\s*[:=]?\s*[A-Za-z0-9][A-Za-z0-9._-]{7,}\b"#, "[REDACTED]"),
            (#"(?i)\b(?:sess(?:ion)?|cred(?:ential)?)[_-][A-Za-z0-9][A-Za-z0-9._-]{7,}\b"#, "[REDACTED]")
        ]
        return sources.compactMap { source, replacement in
            guard let expression = try? NSRegularExpression(pattern: source) else { return nil }
            return (expression, replacement)
        }
    }()

    private static let residualAssignmentPatterns: [NSRegularExpression] = {
        let sensitiveNames = "(?:authorization|cookie|set-cookie|api[_-]?key|secret[_-]?key|access[_-]?key|access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|password|passwd|secret|token|session[_-]?id|thread[_-]?id|provider[_-]?session[_-]?id|harness[_-]?thread[_-]?id|credential[_-]?id|credentials?)"
        let sources = [
            #"(?i)(?:\\?[\"']?)"# + sensitiveNames + #"(?:\\?[\"']?)\s*[:=]\s*"#,
            #"(?i)"# + sensitiveNames + #"(?:\\?\[[^\]\r\n]*\\?\])+\s*[:=]\s*"#,
            #"(?i)\b[A-Z][A-Z0-9_]*(?:API_KEY|SECRET(?:_ACCESS)?_KEY|BOT_TOKEN|ACCESS_TOKEN|REFRESH_TOKEN|ID_TOKEN|AUTH_TOKEN|PRIVATE_KEY|CLIENT_SECRET|PASSWORD|PASSWD|CREDENTIALS?|SESSION_ID|THREAD_ID|PROVIDER_SESSION_ID|HARNESS_THREAD_ID)\s*=\s*"#,
            #"(?i)--(?:api[_-]?key|token|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret|password|session[_-]?id|thread[_-]?id|provider[_-]?session[_-]?id|harness[_-]?thread[_-]?id)(?:\s+|=)"#
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static let queryKeyPattern = try? NSRegularExpression(
        pattern: #"[?&;]([^?&;=\s]+)="#
    )
    private static let unicodeEscapePattern = try? NSRegularExpression(
        pattern: #"\\+u([0-9A-Fa-f]{4})"#
    )

    /// Sanitizes action title. Title gets smaller bound than detail.
    public static func title(_ text: String) -> String {
        sanitize(text, maximumOutputUTF8Bytes: maximumTitleUTF8ByteCount)
    }

    /// Sanitizes action detail using durable detail bound.
    public static func detail(_ text: String) -> String {
        sanitize(text, maximumOutputUTF8Bytes: maximumDetailUTF8ByteCount)
    }

    /// General-purpose redaction for bounded provider/CLI summaries.
    public static func sanitize(
        _ text: String,
        maximumInputCharacters: Int = SessionActionTextPolicy.maximumInputCharacterCount,
        maximumOutputUTF8Bytes: Int = SessionActionTextPolicy.maximumDetailUTF8ByteCount
    ) -> String {
        guard maximumOutputUTF8Bytes > 0 else { return "" }
        guard maximumInputCharacters > 0, text.count <= maximumInputCharacters else {
            return truncateUTF8(oversizedInputMarker, to: maximumOutputUTF8Bytes)
        }
        if containsEncodedSensitiveSyntax(in: text) {
            return truncateUTF8(oversizedInputMarker, to: maximumOutputUTF8Bytes)
        }
        var sanitized = text
        for (expression, replacement) in redactionPatterns {
            let range = NSRange(sanitized.startIndex..<sanitized.endIndex, in: sanitized)
            sanitized = expression.stringByReplacingMatches(in: sanitized, range: range, withTemplate: replacement)
        }

        // Remove terminal controls and line delimiters. Durable action details are
        // summaries, not a raw terminal stream, so controls must not affect layout.
        sanitized = sanitized.unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if containsUnresolvedSensitiveAssignment(in: sanitized) {
            return truncateUTF8(oversizedInputMarker, to: maximumOutputUTF8Bytes)
        }
        return truncateUTF8(sanitized, to: maximumOutputUTF8Bytes)
    }

    /// Conservative second pass. Regex redaction intentionally handles common
    /// forms, but malformed/embedded escaped payloads must fail closed rather
    /// than risk persisting a suffix that was outside a line-oriented match.
    private static func containsUnresolvedSensitiveAssignment(in value: String) -> Bool {
        let source = value as NSString
        for expression in residualAssignmentPatterns {
            let searchRange = NSRange(location: 0, length: source.length)
            for match in expression.matches(in: value, range: searchRange) {
                let assignment = source.substring(with: match.range)
                let isCookieAssignment = assignment.lowercased().contains("cookie")
                let allowsWhitespaceTerminator = assignment.contains("=")
                    || assignment.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("--")
                let remainder = source.substring(from: NSMaxRange(match.range))
                guard let first = remainder.first(where: { !$0.isWhitespace }) else { return true }
                let remainderStart = remainder.index(remainder.firstIndex(of: first)!, offsetBy: 0)
                let trimmed = String(remainder[remainderStart...])
                let lowercasedTrimmed = trimmed.lowercased()
                if lowercasedTrimmed.hasPrefix("bearer ") || lowercasedTrimmed.hasPrefix("basic ") {
                    let schemeLength = lowercasedTrimmed.hasPrefix("bearer ") ? 7 : 6
                    let afterScheme = String(trimmed.dropFirst(schemeLength))
                    if afterScheme.hasPrefix(oversizedInputMarker),
                       isSafeUnquotedSuffix(
                           String(afterScheme.dropFirst(oversizedInputMarker.count)),
                           allowsWhitespace: false
                       ) {
                        continue
                    }
                }
                if trimmed.hasPrefix(oversizedInputMarker) {
                    let suffix = String(trimmed.dropFirst(oversizedInputMarker.count))
                    if isCookieAssignment {
                        if isSafeEmbeddedCookieSuffix(suffix) { continue }
                        return true
                    }
                    if isSafeUnquotedSuffix(suffix, allowsWhitespace: allowsWhitespaceTerminator) {
                        continue
                    }
                }
                if let opening = trimmed.first, opening == "\"" || opening == "'" {
                    let inner = String(trimmed.dropFirst())
                    if isSafeQuotedValue(inner, closing: String(opening)) { continue }
                }
                if trimmed.hasPrefix(#"\""#) || trimmed.hasPrefix(#"\'"#) {
                    let inner = String(trimmed.dropFirst(2))
                    let closing = trimmed.hasPrefix(#"\""#) ? #"\""# : #"\'"#
                    if isSafeQuotedValue(inner, closing: closing) { continue }
                }
                return true
            }
        }
        return false
    }

    private static func isSafeUnquotedSuffix(_ suffix: String, allowsWhitespace: Bool) -> Bool {
        guard let first = suffix.first else { return true }
        if first == "\"" || first == "'" {
            return isSafeQuotedSuffix(suffix, closing: String(first))
        }
        // Backslash-escaped quotes may be content inside an enclosing string;
        // they are never proof that the sensitive value itself ended.
        if suffix.hasPrefix(#"\""#) || suffix.hasPrefix(#"\'"#) { return false }
        guard allowsWhitespace, first.isWhitespace else { return false }
        return isRecognizableFollowingField(String(suffix.drop(while: { $0.isWhitespace })))
    }

    /// A Cookie header can contain arbitrarily many semicolon/comma/ampersand
    /// separated values. Once a Cookie value is embedded in another string, the
    /// marker is safe only when the enclosing string actually ends.
    private static func isSafeEmbeddedCookieSuffix(_ suffix: String) -> Bool {
        guard let first = suffix.first else { return true }
        if first == "\"" || first == "'" {
            return isSafeQuotedSuffix(suffix, closing: String(first))
        }
        if suffix.hasPrefix(#"\""#) || suffix.hasPrefix(#"\'"#) { return false }
        return false
    }

    private static func containsEncodedSensitiveSyntax(in value: String) -> Bool {
        if containsSensitivePercentEncodedQueryKey(in: value) { return true }

        if let unicodeDecoded = decodeUnicodeEscapesForInspection(in: value),
           unicodeDecoded != value,
           containsUnresolvedSensitiveAssignment(in: unicodeDecoded) {
            return true
        }

        guard value.range(of: #"\\u[0-9A-Fa-f]{4}"#, options: .regularExpression) != nil,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return false
        }
        return containsSensitiveJSONKey(in: object)
    }

    private static func containsSensitivePercentEncodedQueryKey(in value: String) -> Bool {
        guard let queryKeyPattern else { return false }
        let source = value as NSString
        let range = NSRange(location: 0, length: source.length)
        for match in queryKeyPattern.matches(in: value, range: range) {
            guard match.numberOfRanges > 1 else { continue }
            let rawKey = source.substring(with: match.range(at: 1))
            guard rawKey.contains("%") else { continue }
            guard let decodedKey = fullyPercentDecoded(rawKey) else {
                // A malformed encoded key is ambiguous and must not reach the
                // durable log merely because another component decoded cleanly.
                return true
            }
            let normalized = decodedKey.lowercased().filter { $0.isLetter || $0.isNumber }
            if sensitiveJSONKeyNames.contains(normalized) { return true }
        }
        return false
    }

    private static func fullyPercentDecoded(_ value: String) -> String? {
        var current = value
        // Input is already bounded. Every successful encoded pass strictly
        // shortens the string, so this loop terminates without an arbitrary
        // nesting cap that an attacker could exceed by one layer.
        while current.contains("%") {
            guard let next = current.removingPercentEncoding, next != current else { return nil }
            current = next
        }
        return current
    }

    private static func decodeUnicodeEscapesForInspection(in value: String) -> String? {
        guard let unicodeEscapePattern else { return nil }
        let mutable = NSMutableString(string: value)
        let range = NSRange(location: 0, length: mutable.length)
        let matches = unicodeEscapePattern.matches(in: value, range: range)
        guard !matches.isEmpty else { return value }
        for match in matches.reversed() {
            guard match.numberOfRanges > 1,
                  let scalarValue = UInt32(mutable.substring(with: match.range(at: 1)), radix: 16),
                  let scalar = UnicodeScalar(scalarValue) else { return nil }
            mutable.replaceCharacters(in: match.range, with: String(scalar))
        }
        return mutable as String
    }

    private static func containsSensitiveJSONKey(in object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                if sensitiveJSONKeyNames.contains(normalized) { return true }
                if containsSensitiveJSONKey(in: value) { return true }
            }
        } else if let values = object as? [Any] {
            return values.contains(where: containsSensitiveJSONKey)
        }
        return false
    }

    private static let sensitiveJSONKeyNames: Set<String> = [
        "authorization", "cookie", "setcookie", "apikey", "secretkey",
        "accesskey", "accesstoken", "refreshtoken", "idtoken", "authtoken",
        "clientsecret", "privatekey", "password", "passwd", "secret", "token",
        "sessionid", "threadid", "providersessionid", "harnessthreadid",
        "credentialid", "credentials", "csrf", "csrftoken", "databaseurl"
    ]

    private static func isSafeQuotedSuffix(_ suffix: String, closing: String) -> Bool {
        guard suffix.hasPrefix(closing) else { return false }
        let remainder = String(suffix.dropFirst(closing.count))
        guard let first = remainder.first else { return true }
        if isSafeStructuralDelimiter(first) { return true }
        guard first.isWhitespace else { return false }
        return isRecognizableFollowingField(String(remainder.drop(while: { $0.isWhitespace })))
    }

    private static func isSafeQuotedValue(_ value: String, closing: String) -> Bool {
        if value.hasPrefix(oversizedInputMarker) {
            return isSafeQuotedSuffix(
                String(value.dropFirst(oversizedInputMarker.count)),
                closing: closing
            )
        }
        let lowercased = value.lowercased()
        for scheme in ["bearer ", "basic "] where lowercased.hasPrefix(scheme) {
            let afterScheme = String(value.dropFirst(scheme.count))
            guard afterScheme.hasPrefix(oversizedInputMarker) else { return false }
            return isSafeQuotedSuffix(
                String(afterScheme.dropFirst(oversizedInputMarker.count)),
                closing: closing
            )
        }
        return false
    }

    private static func isRecognizableFollowingField(_ nextText: String) -> Bool {
        guard let nextFirst = nextText.first else { return true }
        if nextFirst == "{" || nextFirst == "[" { return true }
        if nextText.hasPrefix("--") || nextText.hasPrefix("http://") || nextText.hasPrefix("https://") {
            return true
        }
        return nextText.range(
            of: #"^[A-Za-z_][A-Za-z0-9_-]*\s*="#,
            options: .regularExpression
        ) != nil
    }

    private static func isSafeStructuralDelimiter(_ character: Character) -> Bool {
        ",;:&?}]})".contains(character)
    }

    private static func truncateUTF8(_ value: String, to byteLimit: Int) -> String {
        guard value.utf8.count > byteLimit else { return value }
        var result = ""
        var consumed = 0
        for scalar in value.unicodeScalars {
            let byteCount = String(scalar).utf8.count
            guard consumed + byteCount <= byteLimit else { break }
            result.unicodeScalars.append(scalar)
            consumed += byteCount
        }
        return result
    }
}
