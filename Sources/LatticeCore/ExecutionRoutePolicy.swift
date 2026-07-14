import Foundation

public enum ExecutionRoutePolicy {
    public static let qualifiedEngineIDs: Set<String> = ["codex", "opencode", "grok", "antigravity", "ollama", "apple"]
    public static let qualifiedHarnessIDs: Set<String> = ["codex", "opencode", "grok", "antigravity", "pi", "hermes", "lattice"]

    public static func compatibleHarnessIDs(for engineID: String) -> Set<String> {
        switch engineID {
        case "codex": ["codex", "pi"]
        case "opencode": ["opencode", "pi", "hermes"]
        case "grok": ["grok"]
        case "antigravity": ["antigravity"]
        case "ollama": ["lattice"]
        case "apple": ["lattice"]
        default: []
        }
    }

    public static func compatibleEngineIDs(for harnessID: String) -> Set<String> {
        Set(qualifiedEngineIDs.filter { compatibleHarnessIDs(for: $0).contains(harnessID) })
    }

    public static func defaultHarnessID(for engineID: String) -> String? {
        switch engineID {
        case "codex": "codex"
        case "opencode": "opencode"
        case "grok": "grok"
        case "antigravity": "antigravity"
        case "ollama", "apple": "lattice"
        default: nil
        }
    }

    public static func normalize(
        _ route: EngineHarnessSelection?,
        fallbackEngineID: String,
        fallbackHarnessID: String
    ) -> EngineHarnessSelection? {
        guard let route else { return nil }
        guard qualifiedEngineIDs.contains(route.engineID) else {
            return EngineHarnessSelection(engineID: fallbackEngineID, harnessID: fallbackHarnessID)
        }
        guard qualifiedHarnessIDs.contains(route.harnessID) else {
            return EngineHarnessSelection(engineID: route.engineID, harnessID: defaultHarnessID(for: route.engineID) ?? fallbackHarnessID)
        }
        guard compatibleHarnessIDs(for: route.engineID).contains(route.harnessID) else {
            return EngineHarnessSelection(engineID: route.engineID, harnessID: defaultHarnessID(for: route.engineID) ?? fallbackHarnessID)
        }
        return route
    }
}

public enum ExecutionRouteReadiness: Equatable, Hashable, Codable, Sendable {
    case loading
    case missingRuntime
    case authenticationRequired
    case validating
    case runnable
    case failed(String)

    public var isRunnable: Bool {
        if case .runnable = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case detail
    }

    private enum State: String, Codable {
        case loading
        case missingRuntime
        case authenticationRequired
        case validating
        case runnable
        case failed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(State.self, forKey: .state)
        switch state {
        case .loading: self = .loading
        case .missingRuntime: self = .missingRuntime
        case .authenticationRequired: self = .authenticationRequired
        case .validating: self = .validating
        case .runnable: self = .runnable
        case .failed:
            self = .failed(try container.decode(String.self, forKey: .detail))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .loading:
            try container.encode(State.loading, forKey: .state)
        case .missingRuntime:
            try container.encode(State.missingRuntime, forKey: .state)
        case .authenticationRequired:
            try container.encode(State.authenticationRequired, forKey: .state)
        case .validating:
            try container.encode(State.validating, forKey: .state)
        case .runnable:
            try container.encode(State.runnable, forKey: .state)
        case .failed(let detail):
            try container.encode(State.failed, forKey: .state)
            try container.encode(detail, forKey: .detail)
        }
    }
}

public struct ExecutionRouteCatalogEntry: Identifiable, Equatable, Codable, Sendable {
    public let route: ExecutionRoute
    public let title: String
    public let readiness: ExecutionRouteReadiness

    public init(
        route: ExecutionRoute,
        title: String,
        readiness: ExecutionRouteReadiness = .loading
    ) {
        self.route = route
        self.title = title
        self.readiness = readiness
    }

    public var id: String { route.id }
}

public struct ExecutionRouteCatalog: Equatable, Codable, Sendable {
    public let entries: [ExecutionRouteCatalogEntry]

    public init(entries: [ExecutionRouteCatalogEntry]) {
        self.entries = entries
    }

    public static var all: ExecutionRouteCatalog {
        ExecutionRouteResolver.catalog()
    }

    public func entries(for mode: ConversationMode) -> [ExecutionRouteCatalogEntry] {
        entries.filter { $0.route.mode == mode }
    }

    public func entry(for route: ExecutionRoute) -> ExecutionRouteCatalogEntry? {
        entries.first { $0.route == route }
    }
}

/// Maps user-facing mode/provider choices to declared Wave 1 execution routes.
/// Resolution is strict: unknown providers, missing models, and unsupported combinations return nil.
public enum ExecutionRouteResolver {
    private struct Template: Sendable {
        let mode: ConversationMode
        let providerID: String
        let runtimeID: String
        let title: String
        let modelRequired: Bool
    }

    private static let templates: [Template] = [
        Template(mode: .code, providerID: "codex", runtimeID: "pi", title: "Codex · Pi", modelRequired: true),
        Template(mode: .code, providerID: "opencode", runtimeID: "pi", title: "OpenCode · Pi", modelRequired: true),
        Template(mode: .code, providerID: "grok", runtimeID: "grok", title: "Grok ACP", modelRequired: true),
        Template(mode: .code, providerID: "antigravity", runtimeID: "antigravity", title: "Antigravity", modelRequired: true),
        Template(mode: .work, providerID: "codex", runtimeID: "hermes", title: "Codex · Hermes", modelRequired: true),
        Template(mode: .work, providerID: "grok", runtimeID: "hermes", title: "Grok · Hermes", modelRequired: true),
        Template(mode: .work, providerID: "opencode", runtimeID: "hermes", title: "OpenCode · Hermes", modelRequired: true),
        Template(mode: .local, providerID: "apple", runtimeID: "lattice", title: "Apple Intelligence", modelRequired: false),
        Template(mode: .local, providerID: "ollama", runtimeID: "lattice", title: "Ollama", modelRequired: true)
    ]

    public static func resolve(
        mode: ConversationMode,
        providerID: String,
        modelID: String? = nil
    ) -> ExecutionRoute? {
        guard let template = templates.first(where: {
            $0.mode == mode && $0.providerID == providerID
        }) else { return nil }

        let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if template.modelRequired {
            guard let model, !model.isEmpty else { return nil }
        } else if model != nil {
            return nil
        }

        return ExecutionRoute(
            mode: template.mode,
            providerID: template.providerID,
            modelID: model,
            runtimeID: template.runtimeID
        )
    }

    public static func resolve(mode: ConversationMode, backend: ChatBackend) -> ExecutionRoute? {
        switch backend {
        case .codex(let model): resolve(mode: mode, providerID: "codex", modelID: model)
        case .grok(let model): resolve(mode: mode, providerID: "grok", modelID: model)
        case .openCode(let model): resolve(mode: mode, providerID: "opencode", modelID: model)
        case .antigravity(let model): resolve(mode: mode, providerID: "antigravity", modelID: model)
        case .appleIntelligence: resolve(mode: mode, providerID: "apple")
        case .ollama(let model): resolve(mode: mode, providerID: "ollama", modelID: model)
        }
    }

    public static func catalog(
        readiness: ExecutionRouteReadiness = .loading
    ) -> ExecutionRouteCatalog {
        ExecutionRouteCatalog(entries: templates.map { template in
            ExecutionRouteCatalogEntry(
                route: ExecutionRoute(
                    mode: template.mode,
                    providerID: template.providerID,
                    modelID: nil,
                    runtimeID: template.runtimeID
                ),
                title: template.title,
                readiness: readiness
            )
        })
    }

    public static func isDeclared(_ route: ExecutionRoute) -> Bool {
        guard let template = templates.first(where: {
            $0.mode == route.mode && $0.providerID == route.providerID && $0.runtimeID == route.runtimeID
        }) else { return false }
        if template.modelRequired {
            return route.modelID?.isEmpty == false
        }
        return route.modelID == nil
    }

    /// Allows persisted routes that predate mode routing while keeping new resolution strict.
    public static func isLegacyCompatible(_ route: ExecutionRoute) -> Bool {
        guard !route.providerID.isEmpty, !route.runtimeID.isEmpty else { return false }
        switch route.providerID {
        case "codex":
            return route.mode == .code
                && ExecutionRoutePolicy.compatibleHarnessIDs(for: "codex").contains(route.runtimeID)
                && route.modelID?.isEmpty == false
        case "opencode":
            return route.mode == .code
                && ExecutionRoutePolicy.compatibleHarnessIDs(for: "opencode").contains(route.runtimeID)
                && route.modelID?.isEmpty == false
        case "grok":
            return route.mode == .code && route.runtimeID == "grok" && route.modelID?.isEmpty == false
        case "antigravity":
            return route.mode == .code && route.runtimeID == "antigravity" && route.modelID?.isEmpty == false
        case "apple":
            return route.mode == .local && route.runtimeID == "lattice" && route.modelID == nil
        case "ollama":
            return route.mode == .local && route.runtimeID == "lattice" && route.modelID?.isEmpty == false
        default:
            return false
        }
    }
}

public typealias RouteReadiness = ExecutionRouteReadiness
public typealias RouteCatalog = ExecutionRouteCatalog

public extension ExecutionRoutePolicy {
    static func resolve(
        mode: ConversationMode,
        providerID: String,
        modelID: String? = nil
    ) -> ExecutionRoute? {
        ExecutionRouteResolver.resolve(mode: mode, providerID: providerID, modelID: modelID)
    }

    static func catalog(readiness: ExecutionRouteReadiness = .loading) -> ExecutionRouteCatalog {
        ExecutionRouteResolver.catalog(readiness: readiness)
    }
}
