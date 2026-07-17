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

    /// Declared Wave-1 default runtimes (aligned with `RouteRuntimeMap` / catalog templates).
    /// Prefer `RouteRuntimeMap.defaultRuntimeID(mode:providerID:)` for mode-aware selection.
    public static func defaultHarnessID(for engineID: String) -> String? {
        // Code-mode declared defaults: codex/opencode → pi; others keep direct harness IDs.
        switch engineID {
        case "codex": RouteRuntimeMap.defaultRuntimeID(mode: .code, providerID: "codex") ?? "pi"
        case "opencode": RouteRuntimeMap.defaultRuntimeID(mode: .code, providerID: "opencode") ?? "pi"
        case "grok": RouteRuntimeMap.defaultRuntimeID(mode: .code, providerID: "grok") ?? "grok"
        case "antigravity": RouteRuntimeMap.defaultRuntimeID(mode: .code, providerID: "antigravity") ?? "antigravity"
        case "ollama", "apple": RouteRuntimeMap.defaultRuntimeID(mode: .local, providerID: engineID == "apple" ? "apple" : "ollama") ?? "lattice"
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
        Template(mode: .code, providerID: "codex", runtimeID: "pi", title: "Codex · Lattice Agent", modelRequired: true),
        Template(mode: .code, providerID: "opencode", runtimeID: "pi", title: "OpenCode · Lattice Agent", modelRequired: true),
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
        if PiFirstCodeRoutingPolicy.isDeclaredProviderFallback(route) {
            return true
        }
        guard let template = templates.first(where: {
            $0.mode == route.mode && $0.providerID == route.providerID && $0.runtimeID == route.runtimeID
        }) else { return false }
        guard route.fallbackFromRuntimeID == nil else { return false }
        if template.modelRequired {
            return route.modelID?.isEmpty == false
        }
        return route.modelID == nil
    }

    /// Allows persisted routes that predate mode routing while keeping new resolution strict.
    public static func isLegacyCompatible(_ route: ExecutionRoute) -> Bool {
        guard !route.providerID.isEmpty,
              !route.runtimeID.isEmpty,
              route.fallbackFromRuntimeID == nil else { return false }
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

/// The old OpenCode auth-file bridge exists only for a selected persisted
/// direct OpenCode route. New Pi/Hermes routes must never use it.
public enum LegacyOpenCodeBridgePolicy {
    public static func allows(_ route: ExecutionRoute) -> Bool {
        route.mode == .code
            && route.providerID == "opencode"
            && route.runtimeID == "opencode"
            && route.fallbackFromRuntimeID == nil
            && route.modelID?.isEmpty == false
            && !ExecutionRouteResolver.isDeclared(route)
    }
}

public struct PiFirstCodeRouteResolution: Equatable, Sendable {
    public let route: ExecutionRoute
    public let disclosure: String
    public let blockingReason: String?

    public init(route: ExecutionRoute, disclosure: String, blockingReason: String? = nil) {
        self.route = route
        self.disclosure = disclosure
        self.blockingReason = blockingReason
    }

    public var isRunnable: Bool { blockingReason == nil }
    public var usesProviderFallback: Bool { route.fallbackFromRuntimeID == "pi" }
}

/// Materializes Code routes before prompt admission. Lattice Agent (Pi) remains
/// preferred. A direct provider harness is selected only for an unlocked chat,
/// after Pi is conclusively unavailable, and when that exact route is runnable.
public enum PiFirstCodeRoutingPolicy {
    public static let preferredRuntimeID = "pi"

    /// Returns the declared Pi route represented by either a preferred route or
    /// a previously materialized provider fallback. This is intentionally
    /// limited to Code Codex/OpenCode routes; legacy direct routes stay legacy.
    public static func preferredRoute(for route: ExecutionRoute) -> ExecutionRoute? {
        guard route.mode == .code,
              route.providerID == "codex" || route.providerID == "opencode",
              let modelID = route.modelID,
              !modelID.isEmpty else { return nil }
        guard route.runtimeID == preferredRuntimeID || isDeclaredProviderFallback(route) else { return nil }
        return ExecutionRoute(
            mode: .code,
            providerID: route.providerID,
            modelID: modelID,
            runtimeID: preferredRuntimeID
        )
    }

    public static func fallbackRoute(for preferredRoute: ExecutionRoute) -> ExecutionRoute? {
        guard preferredRoute.mode == .code,
              preferredRoute.runtimeID == preferredRuntimeID,
              preferredRoute.fallbackFromRuntimeID == nil,
              let modelID = preferredRoute.modelID,
              !modelID.isEmpty,
              preferredRoute.providerID == "codex" || preferredRoute.providerID == "opencode" else {
            return nil
        }
        return ExecutionRoute(
            mode: .code,
            providerID: preferredRoute.providerID,
            modelID: modelID,
            runtimeID: preferredRoute.providerID,
            fallbackFromRuntimeID: preferredRuntimeID
        )
    }

    public static func isDeclaredProviderFallback(_ route: ExecutionRoute) -> Bool {
        route.mode == .code
            && route.fallbackFromRuntimeID == preferredRuntimeID
            && route.runtimeID == route.providerID
            && (route.providerID == "codex" || route.providerID == "opencode")
            && route.modelID?.isEmpty == false
    }

    public static func resolve(
        preferredRoute: ExecutionRoute,
        preferredReadiness: ExecutionRouteReadiness,
        directReadiness: ExecutionRouteReadiness,
        routeLocked: Bool
    ) -> PiFirstCodeRouteResolution {
        if preferredReadiness.isRunnable {
            return .init(route: preferredRoute, disclosure: "Lattice Agent · preferred Code runtime")
        }
        guard let fallback = fallbackRoute(for: preferredRoute) else {
            return .init(
                route: preferredRoute,
                disclosure: "Selected Code runtime",
                blockingReason: preferredReadiness.detail
            )
        }
        if routeLocked {
            return .init(
                route: preferredRoute,
                disclosure: "Lattice Agent · chat runtime locked",
                blockingReason: "This chat is locked to Lattice Agent. Restore that runtime or start a new chat to use a provider fallback."
            )
        }
        switch preferredReadiness {
        case .loading, .validating:
            return .init(
                route: preferredRoute,
                disclosure: "Lattice Agent · checking preferred runtime",
                blockingReason: preferredReadiness.detail
            )
        case .missingRuntime, .authenticationRequired, .failed:
            break
        case .runnable:
            return .init(route: preferredRoute, disclosure: "Lattice Agent · preferred Code runtime")
        }
        guard directReadiness.isRunnable else {
            return .init(
                route: preferredRoute,
                disclosure: "Lattice Agent unavailable · provider fallback unavailable",
                blockingReason: "Lattice Agent is unavailable, and the exact \(preferredRoute.providerID) provider route is not ready: \(directReadiness.detail)"
            )
        }
        return .init(route: fallback, disclosure: "Provider fallback · Lattice Agent unavailable")
    }
}

/// Single table for runtime identity derived from ExecutionRoute.
/// Prefer this over ad-hoc engine/harness parallel fields for readiness, cancel, and new writes.
public enum RouteRuntimeMap {
    /// Runtime used for cancel/permission/process ownership.
    public static func cancelTarget(for route: ExecutionRoute, legacyHarnessID: String? = nil) -> String {
        if ExecutionRouteResolver.isDeclared(route) {
            return route.runtimeID
        }
        let legacy = legacyHarnessID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !legacy.isEmpty { return legacy }
        return route.runtimeID
    }

    /// Runtime used for readiness probes and capability checks.
    public static func readinessRuntimeID(for route: ExecutionRoute) -> String {
        route.runtimeID
    }

    /// Declared default runtime for a mode/provider pair (no model).
    /// Matches `ExecutionRouteResolver` templates so catalog and new writes share one authority.
    public static func defaultRuntimeID(mode: ConversationMode, providerID: String) -> String? {
        ExecutionRouteResolver.catalog().entries
            .first { $0.route.mode == mode && $0.route.providerID == providerID }?
            .route.runtimeID
    }

    /// Preferred declared route for a backend under a conversation mode.
    public static func preferredRoute(mode: ConversationMode, backend: ChatBackend) -> ExecutionRoute? {
        ExecutionRouteResolver.resolve(mode: mode, backend: backend)
    }

    /// Mode-aware write authority: prefer declared routes; fall back to legacy identity.
    /// Use for new session construction and unlocked route mutation.
    public static func writeRoute(
        backend: ChatBackend,
        mode: ConversationMode? = nil,
        preferredRuntimeID: String? = nil
    ) -> ExecutionRoute {
        if let preferredRuntimeID {
            let trimmed = preferredRuntimeID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let base = ExecutionRoute.legacy(for: backend, harnessID: trimmed)
                if let mode {
                    return ExecutionRoute(
                        mode: mode,
                        providerID: base.providerID,
                        modelID: base.modelID,
                        runtimeID: trimmed
                    )
                }
                return base
            }
        }

        let candidates: [ConversationMode]
        if let mode {
            candidates = [mode]
        } else {
            switch backend {
            case .appleIntelligence, .ollama:
                candidates = [.local, .code, .work]
            default:
                candidates = [.code, .work, .local]
            }
        }

        for candidate in candidates {
            if let route = ExecutionRouteResolver.resolve(mode: candidate, backend: backend) {
                return route
            }
        }
        return ExecutionRoute.legacy(for: backend, harnessID: nil)
    }

    /// Backend projection for UI/compat derived from route identity.
    public static func backendProjection(for route: ExecutionRoute) -> ChatBackend? {
        switch (route.providerID, route.modelID) {
        case ("codex", let model?):
            return .codex(model: model)
        case ("grok", let model?):
            return .grok(model: model)
        case ("opencode", let model?):
            return .openCode(model: model)
        case ("antigravity", let model?):
            return .antigravity(model: model)
        case ("apple", nil):
            return .appleIntelligence
        case ("ollama", let model?):
            return .ollama(model: model)
        default:
            return nil
        }
    }

    /// Effective runtime for a session: executionRoute is sole authority.
    public static func effectiveRuntimeID(for session: LatticeSession) -> String {
        session.executionRoute.runtimeID
    }

    /// Provider id for scheduling / health, preferring declared route.
    public static func providerID(for session: LatticeSession) -> String {
        if ExecutionRouteResolver.isDeclared(session.executionRoute)
            || !session.executionRoute.providerID.isEmpty {
            return session.executionRoute.providerID
        }
        switch session.backend {
        case .codex: return "codex"
        case .grok: return "grok"
        case .openCode: return "opencode"
        case .antigravity: return "antigravity"
        case .appleIntelligence: return "apple"
        case .ollama: return "ollama"
        }
    }
}
