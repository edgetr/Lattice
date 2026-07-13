import Foundation

public struct BackendAvailabilitySnapshot: Hashable, Sendable {
    public let codexModels: [ProviderModel]
    public let grokModels: [ProviderModel]
    public let openCodeModels: [ProviderModel]
    public let antigravityModels: [ProviderModel]
    public let codexReady: Bool
    public let grokReady: Bool
    public let openCodeReady: Bool
    public let antigravityReady: Bool
    public let codexCatalogKnown: Bool
    public let grokCatalogKnown: Bool
    public let openCodeCatalogKnown: Bool
    public let appleIntelligenceReady: Bool
    public let ollamaModelNames: [String]
    public let codexInstalled: Bool

    public init(
        codexModels: [ProviderModel] = [],
        grokModels: [ProviderModel] = [],
        openCodeModels: [ProviderModel] = [],
        antigravityModels: [ProviderModel] = [],
        codexReady: Bool = true,
        grokReady: Bool = true,
        openCodeReady: Bool = true,
        antigravityReady: Bool = false,
        codexCatalogKnown: Bool = false,
        grokCatalogKnown: Bool = false,
        openCodeCatalogKnown: Bool = false,
        appleIntelligenceReady: Bool = false,
        ollamaModelNames: [String] = [],
        codexInstalled: Bool = false
    ) {
        self.codexModels = codexModels
        self.grokModels = grokModels
        self.openCodeModels = openCodeModels
        self.antigravityModels = antigravityModels
        self.codexReady = codexReady
        self.grokReady = grokReady
        self.openCodeReady = openCodeReady
        self.antigravityReady = antigravityReady
        self.codexCatalogKnown = codexCatalogKnown
        self.grokCatalogKnown = grokCatalogKnown
        self.openCodeCatalogKnown = openCodeCatalogKnown
        self.appleIntelligenceReady = appleIntelligenceReady
        self.ollamaModelNames = ollamaModelNames
        self.codexInstalled = codexInstalled
    }

    public var preferredBackend: ChatBackend {
        if codexReady, let model = codexModels.preferredModel {
            return .codex(model: model.id)
        }
        if grokReady, let model = grokModels.preferredModel {
            return .grok(model: model.id)
        }
        if openCodeReady, let model = openCodeModels.preferredModel {
            return .openCode(model: model.id)
        }
        if antigravityReady, let model = antigravityModels.preferredModel {
            return .antigravity(model: model.id)
        }
        if appleIntelligenceReady {
            return .appleIntelligence
        }
        if let localModel = ollamaModelNames.first {
            return .ollama(model: localModel)
        }
        return .ollama(model: "")
    }
}

public enum BackendAvailabilityPolicy {
    public static func normalize(_ backend: ChatBackend, using snapshot: BackendAvailabilitySnapshot) -> ChatBackend {
        switch backend {
        case .codex(let model):
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return backend }
            guard snapshot.codexReady else { return snapshot.preferredBackend }
            guard !snapshot.codexModels.isEmpty else { return snapshot.codexCatalogKnown ? snapshot.preferredBackend : backend }
            if snapshot.codexModels.contains(where: { $0.id == model }) { return backend }
            return snapshot.codexModels.preferredModel.map { .codex(model: $0.id) } ?? snapshot.preferredBackend

        case .grok(let model):
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return backend }
            guard snapshot.grokReady else { return snapshot.preferredBackend }
            guard !snapshot.grokModels.isEmpty else { return snapshot.grokCatalogKnown ? snapshot.preferredBackend : backend }
            if snapshot.grokModels.contains(where: { $0.id == model }) { return backend }
            return snapshot.grokModels.preferredModel.map { .grok(model: $0.id) } ?? snapshot.preferredBackend

        case .openCode(let model):
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return backend }
            guard snapshot.openCodeReady else { return snapshot.preferredBackend }
            guard !snapshot.openCodeModels.isEmpty else { return snapshot.openCodeCatalogKnown ? snapshot.preferredBackend : backend }
            if snapshot.openCodeModels.contains(where: { $0.id == model }) { return backend }
            return snapshot.openCodeModels.preferredModel.map { .openCode(model: $0.id) } ?? snapshot.preferredBackend

        case .antigravity(let model):
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return backend }
            guard snapshot.antigravityReady else { return snapshot.preferredBackend }
            guard !snapshot.antigravityModels.isEmpty else { return snapshot.preferredBackend }
            if snapshot.antigravityModels.contains(where: { $0.id == model }) { return backend }
            return snapshot.antigravityModels.preferredModel.map { .antigravity(model: $0.id) } ?? snapshot.preferredBackend

        case .appleIntelligence:
            return snapshot.appleIntelligenceReady ? backend : snapshot.preferredBackend

        case .ollama(let model):
            guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return backend }
            guard !snapshot.ollamaModelNames.isEmpty else { return backend }
            return snapshot.ollamaModelNames.contains(model) ? backend : snapshot.preferredBackend
        }
    }
}

private extension Array where Element == ProviderModel {
    var preferredModel: ProviderModel? {
        first(where: \.isDefault) ?? first
    }
}
