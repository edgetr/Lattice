import Foundation

/// Secret-free launch cache used only to hydrate connection UI while live probes run.
/// It is never sufficient to make a route runnable or to authenticate a request.
public struct PersistedConnectionState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public struct Provider: Codable, Equatable, Sendable {
        public let installed: Bool
        public let authenticated: Bool
        public let catalogStatus: ProviderCatalogStatus
        public let runnableModelCount: Int

        public init(
            installed: Bool,
            authenticated: Bool,
            catalogStatus: ProviderCatalogStatus,
            runnableModelCount: Int
        ) {
            self.installed = installed
            self.authenticated = authenticated
            self.catalogStatus = catalogStatus
            self.runnableModelCount = max(0, runnableModelCount)
        }
    }

    public let schemaVersion: Int
    public let observedAt: Date
    public let providers: [String: Provider]
    /// Records only that a Keychain item was observed, never its value or metadata.
    public let openCodeCredentialRecorded: Bool

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        observedAt: Date,
        providers: [String: Provider],
        openCodeCredentialRecorded: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.observedAt = observedAt
        self.providers = providers
        self.openCodeCredentialRecorded = openCodeCredentialRecorded
    }
}

public enum PersistedConnectionHydration: Equatable, Sendable {
    case fresh(PersistedConnectionState)
    case stale(PersistedConnectionState)
    case rejected

    /// Cached state improves relaunch continuity but never grants readiness authority.
    public var canAuthorizeExecution: Bool { false }
}

public enum PersistedConnectionStatePolicy {
    public static let defaultMaximumAge: TimeInterval = 15 * 60

    public static func hydrate(
        _ data: Data,
        now: Date,
        maximumAge: TimeInterval = defaultMaximumAge
    ) -> PersistedConnectionHydration {
        guard maximumAge >= 0,
              let state = try? JSONDecoder().decode(PersistedConnectionState.self, from: data),
              state.schemaVersion == PersistedConnectionState.currentSchemaVersion,
              state.observedAt <= now else {
            return .rejected
        }
        return now.timeIntervalSince(state.observedAt) <= maximumAge ? .fresh(state) : .stale(state)
    }

    public static func encode(_ state: PersistedConnectionState) -> Data? {
        try? JSONEncoder().encode(state)
    }
}

public enum CredentialStoreAvailability: Equatable, Sendable {
    case present
    case missing
    case locked
    case denied
    case unavailable
}

public struct CredentialPresenceResolution: Equatable, Sendable {
    public let recorded: Bool
    public let shouldInvalidateConsent: Bool
    public let canReadSecret: Bool
}

public enum CredentialPresenceReconciler {
    /// Only an authoritative missing-item result means sign-out/removal. Locked,
    /// denied, and unavailable stores retain the prior secret-free presence bit
    /// while refusing to claim that secret bytes are readable.
    public static func resolve(
        _ availability: CredentialStoreAvailability,
        previouslyRecorded: Bool
    ) -> CredentialPresenceResolution {
        switch availability {
        case .present:
            CredentialPresenceResolution(recorded: true, shouldInvalidateConsent: false, canReadSecret: false)
        case .missing:
            CredentialPresenceResolution(recorded: false, shouldInvalidateConsent: true, canReadSecret: false)
        case .locked, .denied, .unavailable:
            CredentialPresenceResolution(recorded: previouslyRecorded, shouldInvalidateConsent: false, canReadSecret: false)
        }
    }
}

/// Resolves overlapping observations for every window sharing an AppState. A late
/// result from an older refresh can never replace a newer authentication/runtime view.
public struct ConnectionObservation<Value: Equatable & Sendable>: Equatable, Sendable {
    public let generation: UInt64
    public let value: Value

    public init(generation: UInt64, value: Value) {
        self.generation = generation
        self.value = value
    }

    public func accepting(_ candidate: Self) -> Self {
        candidate.generation >= generation ? candidate : self
    }
}
