import Foundation

/// Category breakdown for local context estimates (OpenCode-style honesty).
/// Provider-reported totals stay separate and are never invented here.
public enum LatticeContextBudgetCategory: String, Sendable, Equatable, CaseIterable, Codable {
    case system
    case user
    case assistant
    case tool
    case attachment
    case draft
    case other

    public var displayName: String {
        switch self {
        case .system: "System"
        case .user: "User"
        case .assistant: "Assistant"
        case .tool: "Tool"
        case .attachment: "Attachments"
        case .draft: "Draft"
        case .other: "Other"
        }
    }
}

public struct LatticeContextBudgetCategorySlice: Sendable, Equatable, Hashable, Codable {
    public var category: LatticeContextBudgetCategory
    public var estimatedTokens: Int

    public init(category: LatticeContextBudgetCategory, estimatedTokens: Int) {
        self.category = category
        self.estimatedTokens = max(0, estimatedTokens)
    }
}

public struct LatticeContextBudgetBreakdown: Sendable, Equatable, Hashable {
    public var slices: [LatticeContextBudgetCategorySlice]
    /// Local estimate only — never a provider tokenizer truth claim.
    public var isEstimate: Bool
    /// Optional provider-reported total when the harness actually supplies one.
    public var providerReportedTotalTokens: Int?

    public init(
        slices: [LatticeContextBudgetCategorySlice],
        isEstimate: Bool = true,
        providerReportedTotalTokens: Int? = nil
    ) {
        self.slices = slices
        self.isEstimate = isEstimate
        self.providerReportedTotalTokens = providerReportedTotalTokens.flatMap { $0 > 0 ? $0 : nil }
    }

    public var estimatedTotal: Int {
        slices.reduce(0) { $0 + $1.estimatedTokens }
    }

    public func tokens(for category: LatticeContextBudgetCategory) -> Int {
        slices.first(where: { $0.category == category })?.estimatedTokens ?? 0
    }
}

public extension LatticeContextBudgetEstimator {
    /// Breaks a session estimate into role/tool/attachment/draft categories.
    /// All values are local estimates; label them as such in UI.
    static func breakdown(
        session: LatticeSession,
        draft: String = "",
        tokenLimit: Int? = nil
    ) -> LatticeContextBudgetBreakdown {
        var systemTokens = 0
        var userTokens = 0
        var assistantTokens = 0
        var toolTokens = 0
        let otherTokens = 0

        for message in session.messages {
            let tokens = estimateTokens(in: message.text)
            switch message.role {
            case .system: systemTokens += tokens
            case .user: userTokens += tokens
            case .assistant: assistantTokens += tokens
            }
        }

        // Action trail / tool summaries contribute lightly when present on the session.
        let actionText = session.actions
            .map { "\($0.title)\n\($0.detail)" }
            .joined(separator: "\n")
        toolTokens += estimateTokens(in: actionText) / 4

        let attachmentText = session.attachments
            .map { "attached path: \($0.name) \($0.path)" }
            .joined(separator: "\n")
        let attachmentTokens = estimateTokens(in: attachmentText) + session.attachments.count * 8
        let draftTokens = estimateTokens(in: draft)

        var slices: [LatticeContextBudgetCategorySlice] = [
            .init(category: .system, estimatedTokens: systemTokens),
            .init(category: .user, estimatedTokens: userTokens),
            .init(category: .assistant, estimatedTokens: assistantTokens),
            .init(category: .tool, estimatedTokens: toolTokens),
            .init(category: .attachment, estimatedTokens: attachmentTokens),
            .init(category: .draft, estimatedTokens: draftTokens),
            .init(category: .other, estimatedTokens: otherTokens)
        ]
        slices.removeAll { $0.estimatedTokens == 0 && $0.category != .user && $0.category != .assistant }

        // tokenLimit is accepted for API symmetry with estimate(); breakdown is independent of the cap.
        _ = tokenLimit

        return LatticeContextBudgetBreakdown(slices: slices, isEstimate: true, providerReportedTotalTokens: nil)
    }
}
