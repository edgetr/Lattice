import Foundation

// MARK: - Message timestamps

/// Localized timestamps and role/time accessibility labels for transcript rows.
public enum MessageTimestampPresentationPolicy: Sendable {
    public static func roleLabel(for role: ChatMessage.Role) -> String {
        switch role {
        case .user: "Your message"
        case .assistant: "Assistant message"
        case .system: "System message"
        }
    }

    /// Localized absolute timestamp suitable for a restrained caption under a bubble.
    public static func formattedTimestamp(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = false
        return formatter.string(from: date)
    }

    /// Combined accessible name for a message row's role and send time.
    public static func accessibilityMetadata(
        role: ChatMessage.Role,
        date: Date,
        isGenerating: Bool = false,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let rolePart = roleLabel(for: role)
        let timePart = formattedTimestamp(date, locale: locale, timeZone: timeZone)
        if isGenerating {
            return "\(rolePart), Generating response, \(timePart)"
        }
        return "\(rolePart), \(timePart)"
    }
}

// MARK: - Chat-route provenance

/// Restrained provider / model / harness labels derived from session route state
/// (never persisted onto individual messages).
public enum ChatRouteProvenancePresentationPolicy: Sendable {
    public struct Provenance: Equatable, Sendable {
        public let provider: String
        public let model: String
        public let harnessLabel: String?
        /// Single restrained caption line, e.g. `Codex · gpt-5 · Pi`.
        public let displayLine: String
        public let accessibilityLabel: String

        public init(provider: String, model: String, harnessLabel: String?, displayLine: String, accessibilityLabel: String) {
            self.provider = provider
            self.model = model
            self.harnessLabel = harnessLabel
            self.displayLine = displayLine
            self.accessibilityLabel = accessibilityLabel
        }
    }

    /// Default harness id aligned with session creation (presentation-only; not a routing authority).
    public static func defaultHarnessID(for backend: ChatBackend) -> String {
        switch backend {
        case .codex: "codex"
        case .grok: "grok"
        case .openCode: "opencode"
        case .antigravity: "antigravity"
        case .appleIntelligence, .ollama: "lattice"
        }
    }

    public static func resolvedHarnessID(sessionHarnessID: String?, backend: ChatBackend) -> String {
        if let sessionHarnessID {
            let trimmed = sessionHarnessID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return defaultHarnessID(for: backend)
    }

    public static func harnessDisplayName(for harnessID: String) -> String {
        switch harnessID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "codex": "Codex"
        case "grok": "Grok"
        case "opencode": "OpenCode"
        case "antigravity": "Antigravity"
        case "pi": "Pi"
        case "hermes": "Hermes"
        case "lattice": "Lattice"
        case let other where !other.isEmpty:
            other.split(separator: "-").map { part in
                part.prefix(1).uppercased() + part.dropFirst()
            }.joined(separator: "-")
        default:
            harnessID
        }
    }

    /// Builds restrained provenance from existing session backend + harness fields.
    public static func provenance(
        backend: ChatBackend,
        sessionHarnessID: String?
    ) -> Provenance {
        let provider = backend.harnessName
        let model = backend.displayName
        let harnessID = resolvedHarnessID(sessionHarnessID: sessionHarnessID, backend: backend)
        let harnessLabel = harnessDisplayName(for: harnessID)

        var parts: [String] = [provider]
        if !model.isEmpty, model.caseInsensitiveCompare(provider) != .orderedSame {
            parts.append(model)
        }
        // Include harness when it adds information (alternate harness or distinct label).
        if harnessLabel.caseInsensitiveCompare(provider) != .orderedSame {
            parts.append(harnessLabel)
        }

        let line = parts.joined(separator: " · ")
        var accessibility = "Route \(provider)"
        if !model.isEmpty { accessibility += ", model \(model)" }
        if harnessLabel.caseInsensitiveCompare(provider) != .orderedSame {
            accessibility += ", harness \(harnessLabel)"
        }
        return Provenance(
            provider: provider,
            model: model,
            harnessLabel: harnessLabel.caseInsensitiveCompare(provider) == .orderedSame ? nil : harnessLabel,
            displayLine: line,
            accessibilityLabel: accessibility
        )
    }
}

// MARK: - Fenced code blocks (display-only)

public enum MessageContentSegment: Equatable, Sendable {
    case text(String)
    /// `language` is the optional fence info string (may be empty).
    case codeBlock(language: String, code: String)
}

/// Display-only segmentation of message text into plain runs and fenced code blocks.
/// Does not mutate stored message text and does not interpret HTML.
public enum MessageContentPresentationPolicy: Sendable {
    /// Split raw message text into plain text and fenced code segments.
    /// Fence syntax: opening line ` ``` ` or ` ```lang `, closing line ` ``` `.
    public static func segments(from text: String) -> [MessageContentSegment] {
        guard !text.isEmpty else { return [] }

        var segments: [MessageContentSegment] = []
        var plainLines: [Substring] = []
        var codeLines: [Substring]? = nil
        var codeLanguage = ""

        func flushPlain() {
            guard !plainLines.isEmpty else { return }
            let joined = plainLines.joined(separator: "\n")
            if !joined.isEmpty {
                segments.append(.text(joined))
            }
            plainLines.removeAll(keepingCapacity: true)
        }

        func flushCode() {
            guard let lines = codeLines else { return }
            // Preserve interior newlines; drop a single trailing empty line from the closing fence boundary.
            let code = lines.joined(separator: "\n")
            segments.append(.codeBlock(language: codeLanguage, code: code))
            codeLines = nil
            codeLanguage = ""
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            if codeLines != nil {
                if isFenceLine(line) {
                    flushCode()
                } else {
                    codeLines?.append(line)
                }
                continue
            }

            if let language = fenceLanguage(line) {
                flushPlain()
                codeLines = []
                codeLanguage = language
            } else {
                plainLines.append(line)
            }
        }

        if codeLines != nil {
            // Unclosed fence: treat remainder as code (still monospaced, still copyable).
            flushCode()
        } else {
            flushPlain()
        }

        return segments.isEmpty ? [.text(text)] : segments
    }

    /// True when the text contains at least one fenced code block opening.
    public static func containsFencedCode(_ text: String) -> Bool {
        text.split(separator: "\n", omittingEmptySubsequences: false).contains { fenceLanguage($0) != nil }
    }

    // MARK: Fence detection

    /// Returns language info (possibly empty) when `line` is an opening/closing fence marker.
    /// Opening: optional language tag after ```; closing is detected separately via `isFenceLine`.
    private static func fenceLanguage(_ line: Substring) -> String? {
        let trimmed = trimFenceIndent(line)
        guard trimmed.hasPrefix("```") else { return nil }
        // Closing fences are only valid while already inside a block; for opening detection,
        // accept ``` or ```lang (no additional backticks mid-line required).
        let rest = trimmed.dropFirst(3)
        // A pure closing fence is still a fence opener when not inside a block (empty code block).
        if rest.isEmpty { return "" }
        // Reject lines that look like inline triple-backtick noise with trailing content after space-only lang.
        let language = String(rest).trimmingCharacters(in: .whitespaces)
        // Disallow spaces in language tokens beyond the info string itself; keep full info string.
        return language
    }

    private static func isFenceLine(_ line: Substring) -> Bool {
        let trimmed = trimFenceIndent(line)
        guard trimmed.hasPrefix("```") else { return false }
        let rest = trimmed.dropFirst(3)
        return rest.isEmpty || rest.allSatisfy({ $0 == "`" })
    }

    private static func trimFenceIndent(_ line: Substring) -> Substring {
        var index = line.startIndex
        var count = 0
        while index < line.endIndex, count < 3, line[index] == " " {
            count += 1
            index = line.index(after: index)
        }
        return line[index...]
    }
}

// MARK: - Error presentation

public struct ConversationErrorPresentation: Equatable, Sendable {
    public let headline: String
    public let detail: String?
    public let accessibilityLabel: String
    public let accessibilityValue: String?

    public init(headline: String, detail: String?, accessibilityLabel: String, accessibilityValue: String?) {
        self.headline = headline
        self.detail = detail
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityValue = accessibilityValue
    }
}

/// Splits free-form error strings into a concise headline and optional selectable detail.
/// Presentation only — does not invent retry affordances or mutate stored error state.
public enum ConversationErrorPresentationPolicy: Sendable {
    public static let maxHeadlineLength = 96

    public static func presentation(for rawMessage: String) -> ConversationErrorPresentation {
        let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ConversationErrorPresentation(
                headline: "Something went wrong",
                detail: nil,
                accessibilityLabel: "Error",
                accessibilityValue: "Something went wrong"
            )
        }

        let (headlineSource, detailSource) = splitHeadlineAndDetail(trimmed)
        let headline = condenseHeadline(headlineSource)
        let detail: String? = {
            guard let detailSource else { return nil }
            let cleaned = detailSource.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned.isEmpty ? nil : cleaned
        }()

        let accessibilityLabel = "Error"
        let accessibilityValue: String? = {
            if let detail, !detail.isEmpty {
                return "\(headline). \(detail)"
            }
            return headline
        }()

        return ConversationErrorPresentation(
            headline: headline,
            detail: detail,
            accessibilityLabel: accessibilityLabel,
            accessibilityValue: accessibilityValue
        )
    }

    // MARK: Private

    private static func splitHeadlineAndDetail(_ text: String) -> (String, String?) {
        // Prefer explicit multi-line errors: first line = headline, remainder = detail.
        if let newline = text.firstIndex(of: "\n") {
            let head = String(text[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(text[text.index(after: newline)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !head.isEmpty {
                return (head, tail.isEmpty ? nil : tail)
            }
        }

        // Short "Title: detail" forms common in route/provider errors.
        if let colon = text.range(of: ": ") {
            let head = String(text[..<colon.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let tail = String(text[colon.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if head.count >= 3, head.count <= 48, !tail.isEmpty, !head.contains(". ") {
                return (head, tail)
            }
        }

        // Long single-line: first sentence as headline when a clean boundary exists.
        if text.count > maxHeadlineLength {
            if let boundary = firstSentenceBoundary(in: text) {
                let head = String(text[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
                var tailStart = boundary
                if text[tailStart] == "." || text[tailStart] == "!" || text[tailStart] == "?" {
                    tailStart = text.index(after: tailStart)
                }
                let tail = String(text[tailStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !head.isEmpty {
                    return (head, tail.isEmpty ? nil : tail)
                }
            }
        }

        return (text, nil)
    }

    private static func condenseHeadline(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > maxHeadlineLength else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maxHeadlineLength - 1)
        var slice = String(collapsed[..<end])
        if let lastSpace = slice.lastIndex(of: " "), lastSpace > slice.startIndex {
            slice = String(slice[..<lastSpace])
        }
        return slice.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    private static func firstSentenceBoundary(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "." || ch == "!" || ch == "?" {
                let next = text.index(after: index)
                if next == text.endIndex { return index }
                if text[next].isWhitespace { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
