import Foundation

/// Runtime identities that Lattice owns for mode execution. Provider CLIs remain
/// separate legacy/direct routes and are not silently remapped to these runtimes.
public enum LatticeRuntimeID: String, CaseIterable, Codable, Hashable, Sendable {
    case pi
    case hermes

    public var displayName: String {
        switch self {
        case .pi: "Pi"
        case .hermes: "Hermes"
        }
    }

    public var executableName: String { rawValue }

    public var profileDirectoryName: String {
        switch self {
        case .pi: "HarnessRuntime/Pi"
        case .hermes: "HermesWork"
        }
    }
}

public enum RuntimeInstallPermission: String, CaseIterable, Codable, Hashable, Sendable {
    case network
    case executeRuntime
    case writeLatticeProfile
    case writeUserToolDirectory
    case readKeychainOpenCodeCredential
}

/// Trust boundary for a first-use pin. Neither value claims that Lattice
/// independently hashed a downloaded artifact or source checkout.
public enum RuntimePinTrust: String, Codable, Hashable, Sendable {
    case npmRegistryIntegrity
    case pinnedGitCommit
}

/// First-use setup metadata. Version pins are intentional. Hash is absent when
/// upstream does not publish a release artifact hash Lattice can verify honestly.
public struct RuntimeInstallDescriptor: Equatable, Hashable, Codable, Sendable, Identifiable {
    public let runtime: LatticeRuntimeID
    public let displayName: String
    public let source: String
    public let immutableVersion: String
    public let installReference: String
    public let pinTrust: RuntimePinTrust
    public let registryIntegrity: String?
    public let pinnedSourceCommit: String?
    public let estimatedSizeBytes: Int?
    public let permissions: Set<RuntimeInstallPermission>
    public let profileDirectory: String
    public let rollback: String
    public let uninstall: String

    public var id: String { runtime.rawValue }
    public var isVersionPinned: Bool { !immutableVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hasPublishedHash: Bool { false }
    public var verificationLabel: String {
        switch pinTrust {
        case .npmRegistryIntegrity:
            "npm registry integrity enforced; not independently hashed by Lattice."
        case .pinnedGitCommit:
            "Git commit pinned; source checkout not independently hashed by Lattice."
        }
    }

    public init(
        runtime: LatticeRuntimeID,
        displayName: String,
        source: String,
        immutableVersion: String,
        installReference: String,
        pinTrust: RuntimePinTrust,
        registryIntegrity: String? = nil,
        pinnedSourceCommit: String? = nil,
        estimatedSizeBytes: Int? = nil,
        permissions: Set<RuntimeInstallPermission>,
        profileDirectory: String,
        rollback: String,
        uninstall: String
    ) {
        self.runtime = runtime
        self.displayName = displayName
        self.source = source
        self.immutableVersion = immutableVersion
        self.installReference = installReference
        self.pinTrust = pinTrust
        self.registryIntegrity = registryIntegrity
        self.pinnedSourceCommit = pinnedSourceCommit
        self.estimatedSizeBytes = estimatedSizeBytes
        self.permissions = permissions
        self.profileDirectory = profileDirectory
        self.rollback = rollback
        self.uninstall = uninstall
    }

    public static let pi = RuntimeInstallDescriptor(
        runtime: .pi,
        displayName: "Pi",
        source: "https://github.com/earendil-works/pi/releases/tag/v0.80.6",
        immutableVersion: "0.80.6",
        installReference: "@earendil-works/pi-coding-agent@0.80.6",
        pinTrust: .npmRegistryIntegrity,
        registryIntegrity: "sha512-vcfD6tOk402isLl3Cm/qbn2O10TvgroMp1+/fEGM24ZdvETFCdOYv5VZ7m59EI5fPsjfSJh+CpQ5bhBrhfOg7g==",
        permissions: [.network, .executeRuntime, .writeLatticeProfile, .writeUserToolDirectory, .readKeychainOpenCodeCredential],
        profileDirectory: "HarnessRuntime/Pi",
        rollback: "Reinstall previously recorded exact package version, then revalidate Pi profile.",
        uninstall: "Remove exact Pi package and delete only Lattice-owned Pi profile after confirmation."
    )

    public static let hermes = RuntimeInstallDescriptor(
        runtime: .hermes,
        displayName: "Hermes",
        source: "https://github.com/NousResearch/hermes-agent/releases/tag/v2026.7.7.2",
        immutableVersion: "v2026.7.7.2",
        installReference: "git+https://github.com/NousResearch/hermes-agent.git@b7751df34688835a108e0d630f3495fc11f3df79",
        pinTrust: .pinnedGitCommit,
        pinnedSourceCommit: "b7751df34688835a108e0d630f3495fc11f3df79",
        permissions: [.network, .executeRuntime, .writeLatticeProfile, .writeUserToolDirectory, .readKeychainOpenCodeCredential],
        profileDirectory: "HermesWork",
        rollback: "Reinstall previously recorded exact Hermes source tag, then revalidate Hermes profile.",
        uninstall: "Remove exact Hermes tool and delete only Lattice-owned Hermes profile after confirmation."
    )

    public static func firstUse(for runtime: LatticeRuntimeID) -> Self {
        switch runtime {
        case .pi: .pi
        case .hermes: .hermes
        }
    }
}

public enum RuntimeLifecycleAction: String, Codable, Hashable, Sendable {
    case firstUseInstall
    case update
    case cancel
    case interruptUpdate
    case rollback
    case uninstall
}

public enum RuntimeLifecyclePhase: String, Codable, Hashable, Sendable {
    case idle
    case awaitingConfirmation
    case installing
    case updating
    case cancelling
    case updateInterrupted
    case rollbackAvailable
    case rollingBack
    case uninstalling
    case completed
    case cancelled
    case failed
}

public struct RuntimeLifecycleState: Equatable, Hashable, Codable, Sendable {
    public let runtime: LatticeRuntimeID
    public let phase: RuntimeLifecyclePhase
    public let detail: String?
    public let installedVersion: String?
    public let previousVersion: String?

    public init(
        runtime: LatticeRuntimeID,
        phase: RuntimeLifecyclePhase = .idle,
        detail: String? = nil,
        installedVersion: String? = nil,
        previousVersion: String? = nil
    ) {
        self.runtime = runtime
        self.phase = phase
        self.detail = detail
        self.installedVersion = installedVersion
        self.previousVersion = previousVersion
    }
}

public struct RuntimeConfirmationRequest: Equatable, Hashable, Codable, Sendable, Identifiable {
    public let runtime: LatticeRuntimeID
    public let action: RuntimeLifecycleAction
    public let descriptor: RuntimeInstallDescriptor

    public init(runtime: LatticeRuntimeID, action: RuntimeLifecycleAction, descriptor: RuntimeInstallDescriptor? = nil) {
        self.runtime = runtime
        self.action = action
        self.descriptor = descriptor ?? .firstUse(for: runtime)
    }

    public var id: String { runtime.rawValue + ":" + action.rawValue }
}

public struct RouteReadinessRequirements: Equatable, Hashable, Sendable {
    public let runtimePresent: Bool
    public let authenticationValidated: Bool
    public let modelValidated: Bool
    public let sandboxAvailable: Bool

    public init(
        runtimePresent: Bool,
        authenticationValidated: Bool,
        modelValidated: Bool,
        sandboxAvailable: Bool
    ) {
        self.runtimePresent = runtimePresent
        self.authenticationValidated = authenticationValidated
        self.modelValidated = modelValidated
        self.sandboxAvailable = sandboxAvailable
    }
}

public struct RouteReadinessSnapshot: Equatable, Hashable, Sendable {
    public let route: ExecutionRoute
    public let readiness: ExecutionRouteReadiness
    public let requirements: RouteReadinessRequirements

    public init(route: ExecutionRoute, readiness: ExecutionRouteReadiness, requirements: RouteReadinessRequirements) {
        self.route = route
        self.readiness = readiness
        self.requirements = requirements
    }
}

public enum RouteReadinessEvaluator {
    public static func evaluate(
        route: ExecutionRoute,
        requirements: RouteReadinessRequirements,
        validating: Bool = false
    ) -> RouteReadinessSnapshot {
        let readiness: ExecutionRouteReadiness
        if !requirements.runtimePresent {
            readiness = .missingRuntime
        } else if validating {
            readiness = .validating
        } else if !requirements.authenticationValidated {
            readiness = .authenticationRequired
        } else if !requirements.modelValidated {
            readiness = .failed("Selected model is not available for \(route.runtimeID).")
        } else if !requirements.sandboxAvailable {
            readiness = .failed("Required \(route.runtimeID) write-containment sandbox is unavailable.")
        } else {
            readiness = .runnable
        }
        return RouteReadinessSnapshot(route: route, readiness: readiness, requirements: requirements)
    }
}

public enum OpenCodeCredentialPolicy {
    public static let keychainAccount = "opencode-go-api-key"

    public static func allowsKeychainCredential(for route: ExecutionRoute) -> Bool {
        route.providerID == "opencode" && (route.runtimeID == "pi" || route.runtimeID == "hermes")
    }

    public static func environmentKey(for route: ExecutionRoute) -> String? {
        guard allowsKeychainCredential(for: route) else { return nil }
        if route.runtimeID == "pi" { return "OPENCODE_API_KEY" }
        guard let model = route.modelID else { return nil }
        if model.hasPrefix("opencode-go:") { return "OPENCODE_GO_API_KEY" }
        if model.hasPrefix("opencode-zen:") { return "OPENCODE_ZEN_API_KEY" }
        return nil
    }
}

public extension ExecutionRouteReadiness {
    var detail: String {
        switch self {
        case .loading: "Checking runtime readiness…"
        case .missingRuntime: "Runtime is not installed."
        case .authenticationRequired: "Authentication is required."
        case .validating: "Validating runtime, model, and sandbox…"
        case .runnable: "Ready"
        case .failed(let detail): detail
        }
    }
}
