import Foundation

public enum ReasoningCapabilityPolicy {
    public static func options(
        for backend: ChatBackend,
        harnessID: String?,
        codexModels: [ProviderModel],
        grokModels: [ProviderModel],
        openCodeModels: [ProviderModel]
    ) -> [ReasoningOption] {
        switch backend {
        case .codex(let id):
            return codexModels.first(where: { $0.id == id })?.reasoningOptions ?? []
        case .grok:
            return []
        case .openCode(let id):
            guard effectiveHarnessID(for: backend, harnessID: harnessID) == "pi" else { return [] }
            return openCodeModels.first(where: { $0.id == id })?.reasoningOptions ?? []
        default:
            return []
        }
    }

    public static func defaultEffort(
        for backend: ChatBackend,
        harnessID: String?,
        codexModels: [ProviderModel],
        grokModels: [ProviderModel],
        openCodeModels: [ProviderModel]
    ) -> ReasoningEffort? {
        switch backend {
        case .codex(let id):
            return codexModels.first(where: { $0.id == id })?.defaultReasoningEffort
        case .grok:
            return nil
        case .openCode(let id):
            guard effectiveHarnessID(for: backend, harnessID: harnessID) == "pi" else { return nil }
            return openCodeModels.first(where: { $0.id == id })?.defaultReasoningEffort
        default:
            return nil
        }
    }

    private static func effectiveHarnessID(for backend: ChatBackend, harnessID: String?) -> String {
        if let harnessID { return harnessID }
        switch backend {
        case .codex: return "codex"
        case .grok: return "grok"
        case .openCode: return "opencode"
        case .appleIntelligence, .ollama: return "lattice"
        case .antigravity: return "antigravity"
        }
    }
}
