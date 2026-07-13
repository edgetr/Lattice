import Foundation

public struct LatticeContextBudgetEstimate: Hashable, Sendable {
    public enum Status: String, Sendable {
        case comfortable
        case tight
        case nearLimit
        case overLimit

        public var displayName: String {
            switch self {
            case .comfortable: "Comfortable"
            case .tight: "Tight"
            case .nearLimit: "Near limit"
            case .overLimit: "Over limit"
            }
        }
    }

    public let tokenLimit: Int
    public let transcriptTokens: Int
    public let draftTokens: Int
    public let attachmentTokens: Int

    public var estimatedTokens: Int { transcriptTokens + draftTokens + attachmentTokens }
    public var remainingTokens: Int { max(0, tokenLimit - estimatedTokens) }
    public var usageFraction: Double {
        guard tokenLimit > 0 else { return 0 }
        return min(1, Double(estimatedTokens) / Double(tokenLimit))
    }
    public var status: Status {
        guard tokenLimit > 0 else { return .comfortable }
        let fraction = Double(estimatedTokens) / Double(tokenLimit)
        if fraction > 1 { return .overLimit }
        if fraction >= 0.9 { return .nearLimit }
        if fraction >= 0.75 { return .tight }
        return .comfortable
    }

    public init(tokenLimit: Int, transcriptTokens: Int, draftTokens: Int, attachmentTokens: Int) {
        self.tokenLimit = max(1, tokenLimit)
        self.transcriptTokens = max(0, transcriptTokens)
        self.draftTokens = max(0, draftTokens)
        self.attachmentTokens = max(0, attachmentTokens)
    }
}

public enum LatticeContextBudgetEstimator {
    public static func defaultTokenLimit(for backend: ChatBackend) -> Int {
        switch backend {
        case .codex, .grok, .openCode:
            128_000
        case .appleIntelligence:
            32_000
        case .ollama:
            8_000
        case .antigravity:
            16_000
        }
    }

    public static func tokenLimit(
        for backend: ChatBackend,
        codexModels: [ProviderModel] = [],
        grokModels: [ProviderModel] = [],
        openCodeModels: [ProviderModel] = []
    ) -> Int {
        let catalogLimit: Int? = switch backend {
        case .codex(let model): contextWindow(for: model, in: codexModels)
        case .grok(let model): contextWindow(for: model, in: grokModels)
        case .openCode(let model): contextWindow(for: model, in: openCodeModels)
        case .appleIntelligence, .ollama, .antigravity: nil
        }
        return catalogLimit ?? defaultTokenLimit(for: backend)
    }

    private static func contextWindow(for id: String, in models: [ProviderModel]) -> Int? {
        models.first { $0.id == id }?.contextWindow.flatMap { $0 > 0 ? $0 : nil }
    }

    public static func estimate(session: LatticeSession, draft: String = "", tokenLimit: Int? = nil) -> LatticeContextBudgetEstimate {
        let limit = tokenLimit ?? defaultTokenLimit(for: session.backend)
        let transcript = session.messages.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n\n")
        let attachmentText = session.attachments.map { "attached path: \($0.name) \($0.path)" }.joined(separator: "\n")
        return LatticeContextBudgetEstimate(
            tokenLimit: max(1, limit),
            transcriptTokens: estimateTokens(in: transcript),
            draftTokens: estimateTokens(in: draft),
            attachmentTokens: estimateTokens(in: attachmentText) + session.attachments.count * 8
        )
    }

    public static func estimateBackendPayload(session: LatticeSession, submittedText: String, additionalContext: String = "", tokenLimit: Int? = nil) -> LatticeContextBudgetEstimate {
        let limit = tokenLimit ?? defaultTokenLimit(for: session.backend)
        var messages = session.messages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let backendText = submittedText + additionalContext
        if let index = messages.lastIndex(where: { $0.role == .user }) {
            messages[index].text = backendText
        } else {
            messages.append(.init(role: .user, text: backendText))
        }
        let payloadTranscript = messages.map { "\($0.role.rawValue): \($0.text)" }.joined(separator: "\n\n")
        return LatticeContextBudgetEstimate(
            tokenLimit: max(1, limit),
            transcriptTokens: estimateTokens(in: payloadTranscript),
            draftTokens: 0,
            attachmentTokens: 0
        )
    }

    public static func estimateTokens(in text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        return max(1, (trimmed.count + 3) / 4)
    }
}

public struct LatticeContextHandoffPlan: Hashable, Sendable {
    public let prompt: String
    public let estimate: LatticeContextBudgetEstimate
    public let usesVisibleTranscriptHandoff: Bool
    public let didCompact: Bool
    public let resetsHarnessSession: Bool
    public let statusDetail: String?
    public let deliveryIssue: String?

    public init(
        prompt: String,
        estimate: LatticeContextBudgetEstimate,
        usesVisibleTranscriptHandoff: Bool,
        didCompact: Bool,
        resetsHarnessSession: Bool,
        statusDetail: String? = nil,
        deliveryIssue: String? = nil
    ) {
        self.prompt = prompt
        self.estimate = estimate
        self.usesVisibleTranscriptHandoff = usesVisibleTranscriptHandoff
        self.didCompact = didCompact
        self.resetsHarnessSession = resetsHarnessSession
        self.statusDetail = statusDetail
        self.deliveryIssue = deliveryIssue
    }
}

public enum LatticeContextManagementMode: Hashable, Sendable {
    /// A first-party CLI owns its durable session and native context lifecycle.
    /// Lattice only reconstructs visible history when that provider session is unavailable.
    case providerManagedSession

    /// Lattice sends the canonical visible messages on every request and must bound them itself.
    case latticeManagedVisibleTranscript
}

public enum LatticeContextHandoffPlanner {
    public static let defaultCompactionThreshold = 0.85

    public static func plan(
        session: LatticeSession,
        submittedText: String,
        additionalContext: String = "",
        tokenLimit: Int? = nil,
        existingHarnessThreadID: String?,
        managementMode: LatticeContextManagementMode = .providerManagedSession,
        compactionThreshold: Double = defaultCompactionThreshold
    ) -> LatticeContextHandoffPlan {
        let limit = tokenLimit ?? LatticeContextBudgetEstimator.defaultTokenLimit(for: session.backend)
        let estimate = LatticeContextBudgetEstimator.estimateBackendPayload(session: session, submittedText: submittedText, additionalContext: additionalContext, tokenLimit: limit)
        let visibleMessages = canonicalVisibleMessages(from: session)
        let previousMessages = messagesBeforeCurrentUser(in: visibleMessages)
        let hasPriorTranscript = !previousMessages.isEmpty
        let isNearVisibleLimit = estimate.usageFraction >= compactionThreshold || estimate.status == .nearLimit || estimate.status == .overLimit
        let needsMissingSessionHandoff = managementMode == .providerManagedSession && existingHarnessThreadID == nil
        let needsLatticeCompaction = managementMode == .latticeManagedVisibleTranscript && isNearVisibleLimit
        let needsHandoff = hasPriorTranscript && (needsMissingSessionHandoff || needsLatticeCompaction)
        let shouldCompact = needsHandoff && isNearVisibleLimit
        let basePrompt = submittedText + additionalContext
        let basePromptTokens = LatticeContextBudgetEstimator.estimateTokens(in: basePrompt)
        let oversizedCurrentPayloadIssue = basePromptTokens >= limit
            ? "This request and its injected instructions need about \(basePromptTokens) tokens, which does not leave usable room in this model's \(limit)-token context window. Shorten the request or skill, remove attachments, or choose a model with a larger context window."
            : nil

        guard needsHandoff else {
            return .init(
                prompt: basePrompt,
                estimate: estimate,
                usesVisibleTranscriptHandoff: false,
                didCompact: false,
                resetsHarnessSession: false,
                deliveryIssue: oversizedCurrentPayloadIssue
            )
        }

        let mode = shouldCompact ? "compacted" : "full"
        let promptBuilder: (String) -> String = { transcript in
            """
            Lattice visible transcript handoff (\(mode)):
            The backend CLI session is being started from Lattice's canonical visible transcript. Do not assume hidden provider state, private reasoning, context caches, or prior tool state transferred.

            Previous visible transcript:
            \(transcript)

            Current user request:
            \(submittedText)
            \(additionalContext)
            """
        }
        let transcript: String
        if shouldCompact {
            let scaffoldTokens = LatticeContextBudgetEstimator.estimateTokens(in: promptBuilder(""))
            let reserveTokens = max(24, min(512, limit / 20))
            var candidateBudget = max(16, limit - scaffoldTokens - reserveTokens)
            var candidateTranscript = compactedTranscript(from: previousMessages, tokenBudget: candidateBudget)
            var candidatePrompt = promptBuilder(candidateTranscript)
            while LatticeContextBudgetEstimator.estimateTokens(in: candidatePrompt) >= limit && candidateBudget > 16 {
                candidateBudget = max(16, candidateBudget / 2)
                candidateTranscript = compactedTranscript(from: previousMessages, tokenBudget: candidateBudget)
                candidatePrompt = promptBuilder(candidateTranscript)
            }
            transcript = candidateTranscript
        } else {
            transcript = fullTranscript(from: previousMessages)
        }
        let prompt = promptBuilder(transcript)
        let resetsHarnessSession = managementMode == .providerManagedSession
        let detail = shouldCompact
            ? (resetsHarnessSession
                ? "Compacted the visible handoff because the provider session was unavailable."
                : "Compacted the visible transcript for this backend request.")
            : "Sent a visible transcript handoff because no provider session was available."
        let handoffTokens = LatticeContextBudgetEstimator.estimateTokens(in: prompt)
        let oversizedHandoffIssue: String? = if handoffTokens >= limit {
            shouldCompact
                ? "Lattice compacted the visible chat, but the resulting handoff still needs about \(handoffTokens) tokens for this model's \(limit)-token context window. Start a new chat, shorten the request or skill, remove attachments, or choose a larger-context model."
                : "Lattice prepared a visible transcript handoff, but it still needs about \(handoffTokens) tokens for this model's \(limit)-token context window. Start a new chat, shorten the request or skill, remove attachments, or choose a larger-context model."
        } else {
            nil
        }
        let deliveryIssue = oversizedCurrentPayloadIssue ?? oversizedHandoffIssue
        return .init(
            prompt: prompt,
            estimate: estimate,
            usesVisibleTranscriptHandoff: true,
            didCompact: shouldCompact,
            resetsHarnessSession: resetsHarnessSession,
            statusDetail: detail,
            deliveryIssue: deliveryIssue
        )
    }

    private static func canonicalVisibleMessages(from session: LatticeSession) -> [ChatMessage] {
        session.messages.filter { message in
            !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func messagesBeforeCurrentUser(in messages: [ChatMessage]) -> [ChatMessage] {
        guard let currentUserIndex = messages.lastIndex(where: { $0.role == .user }) else { return messages }
        return Array(messages[..<currentUserIndex])
    }

    private static func fullTranscript(from messages: [ChatMessage]) -> String {
        messages.map { "[\($0.role.rawValue.capitalized)] \(normalized($0.text))" }.joined(separator: "\n\n")
    }

    private static func compactedTranscript(from messages: [ChatMessage], tokenBudget: Int) -> String {
        guard !messages.isEmpty else { return "(No previous visible messages.)" }
        let recentCount = min(4, messages.count)
        let olderMessages = Array(messages.dropLast(recentCount))
        let recentMessages = Array(messages.suffix(recentCount))
        let transcriptCharacterBudget = max(64, tokenBudget * 4)
        let maxOlderCharacters = max(48, min(12_000, transcriptCharacterBudget / 3))
        let maxRecentCharacters = max(64, min(16_000, transcriptCharacterBudget - maxOlderCharacters))
        let tinyBudget = tokenBudget <= 48
        var remaining = maxOlderCharacters
        var lines: [String] = []
        if !olderMessages.isEmpty {
            lines.append("Older messages condensed by Lattice:")
            if tinyBudget {
                lines.append("- \(olderMessages.count) older message(s) omitted to fit this model's context window.")
            } else {
                for message in olderMessages {
                    guard remaining > 0 else { break }
                    let label = message.role.rawValue.capitalized
                    let snippet = prefix(normalized(message.text), maxCharacters: min(360, remaining))
                    remaining -= snippet.count
                    lines.append("- \(label): \(snippet)")
                }
                if olderMessages.count > lines.count - 1 {
                    lines.append("- \(olderMessages.count - (lines.count - 1)) older message(s) omitted after compaction budget was reached.")
                }
            }
            lines.append("")
        }
        lines.append("Most recent visible messages kept with larger excerpts:")
        let keptRecentMessages = tinyBudget ? Array(recentMessages.suffix(1)) : recentMessages
        let perRecentMessageLimit = max(tinyBudget ? 48 : 240, maxRecentCharacters / max(1, keptRecentMessages.count))
        lines.append(keptRecentMessages.map { "[\($0.role.rawValue.capitalized)] \(prefix(normalized($0.text), maxCharacters: perRecentMessageLimit))" }.joined(separator: "\n\n"))
        return lines.joined(separator: "\n")
    }

    private static func normalized(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func prefix(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        return String(text.prefix(max(0, maxCharacters))).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
