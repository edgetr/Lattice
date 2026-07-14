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

public enum RuntimeArtifactVerification {
    public static func registryIntegrityMatches(reported: String, expected: String) -> Bool {
        let normalized = reported
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return !expected.isEmpty && normalized == expected
    }
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
        rollback: "Rollback requires previously recorded exact package and integrity metadata; otherwise Lattice fails closed.",
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
        rollback: "Rollback requires a previously recorded exact Hermes source commit; otherwise Lattice fails closed.",
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

/// User-facing runtime actions use ordinary verbs. Installation pins and
/// package mechanics remain available in confirmation details, not controls.
public enum RuntimeLifecyclePresentationPolicy {
    public static func actionTitle(
        for action: RuntimeLifecycleAction,
        installedVersion: String? = nil,
        targetVersion: String? = nil
    ) -> String {
        switch action {
        case .firstUseInstall:
            "Install"
        case .update:
            versionsMatch(installedVersion, targetVersion) ? "Repair" : "Update"
        case .uninstall:
            "Remove"
        case .rollback:
            "Restore Previous Version"
        case .cancel, .interruptUpdate:
            "Stop"
        }
    }

    private static func versionsMatch(_ installedVersion: String?, _ targetVersion: String?) -> Bool {
        guard let installedVersion, let targetVersion else { return false }
        let installed = installedVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = targetVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        return !installed.isEmpty && installed == target
    }
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

public enum RuntimeLifecycleTransition {
    public static func phaseAfterCancellation(from phase: RuntimeLifecyclePhase) -> RuntimeLifecyclePhase {
        phase == .updating ? .updateInterrupted : .cancelled
    }

    public static func rollbackPhase(previousVersion: String?) -> RuntimeLifecyclePhase {
        guard previousVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return .failed }
        return .rollingBack
    }
}

public enum RuntimeOwnershipPolicy {
    public static func canUninstall(_ runtime: LatticeRuntimeID, managedRuntimeIDs: Set<LatticeRuntimeID>) -> Bool {
        managedRuntimeIDs.contains(runtime)
    }

    /// Updating an external runtime does not transfer ownership to Lattice.
    /// Only a successful first-use installation creates removal authority.
    public static func shouldRecordOwnership(
        after action: RuntimeLifecycleAction,
        status: Int32,
        executableAvailable: Bool
    ) -> Bool {
        action == .firstUseInstall && status == 0 && executableAvailable
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

    public static func allowsKeychainCredential(
        for route: ExecutionRoute,
        enabledModes: Set<ConversationMode>
    ) -> Bool {
        allowsKeychainCredential(for: route) && enabledModes.contains(route.mode)
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
    /// Short, plain-language state used where a compact route label already
    /// identifies the mode. Avoids unexplained status glyphs in setup UI.
    var conciseStatus: String {
        switch self {
        case .loading, .validating: "checking"
        case .missingRuntime: "setup needed"
        case .authenticationRequired: "sign-in needed"
        case .runnable: "ready"
        case .failed: "unavailable"
        }
    }

    var detail: String {
        switch self {
        case .loading: "Checking availability…"
        case .missingRuntime: "Runtime is not installed."
        case .authenticationRequired: "Sign in required."
        case .validating: "Checking runtime, model, and write containment…"
        case .runnable: "Available"
        case .failed(let detail): detail
        }
    }
}

public enum HarnessReadinessAuthenticationAction: Equatable, Sendable {
    case signIn
    case configureCredential
    case enableCredential
    case validate
}

/// Typed continuation for provider-owned terminal authentication. User-facing
/// copy may change without changing whether the next safe action is sign-in or validation.
public enum HarnessReadinessAuthenticationPhase: String, Equatable, Codable, Sendable {
    case signInRequired
    case validationPending

    public var action: HarnessReadinessAuthenticationAction {
        switch self {
        case .signInRequired: .signIn
        case .validationPending: .validate
        }
    }

    public static func afterTerminalOpen(succeeded: Bool) -> Self {
        succeeded ? .validationPending : .signInRequired
    }

    public static func afterValidation() -> Self { .signInRequired }
}

public enum HarnessReadinessActionKind: Equatable, Sendable {
    case stateOnly
    case setupRuntime
    case signIn
    case configureCredential
    case enableCredential
    case validate
    case diagnostics
}

/// Resolves compact readiness into plain state copy or one precise recovery
/// action. Presentation supplies the operation while Core owns semantics.
public struct HarnessReadinessActionResolution: Equatable, Sendable {
    public let kind: HarnessReadinessActionKind
    public let title: String
    public let accessibilityLabel: String
    public let accessibilityHint: String
    public let isInteractive: Bool
    public let isEnabled: Bool

    public init(kind: HarnessReadinessActionKind, title: String, accessibilityLabel: String, accessibilityHint: String, isInteractive: Bool, isEnabled: Bool) {
        self.kind = kind
        self.title = title
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHint = accessibilityHint
        self.isInteractive = isInteractive
        self.isEnabled = isEnabled
    }
}

public enum HarnessReadinessActionPolicy: Sendable {
    public static func resolve(
        readiness: ExecutionRouteReadiness,
        modeName: String,
        runtimeName: String,
        authenticationAction: HarnessReadinessAuthenticationAction = .signIn,
        actionAvailable: Bool = true
    ) -> HarnessReadinessActionResolution {
        let mode = normalized(modeName, fallback: "Mode")
        let runtime = normalized(runtimeName, fallback: "runtime")

        switch readiness {
        case .runnable:
            return stateOnly(title: "\(mode) ready", label: "\(mode) mode through \(runtime), ready", hint: readiness.detail)
        case .loading, .validating:
            return stateOnly(title: "\(mode) checking", label: "\(mode) mode through \(runtime), checking", hint: readiness.detail)
        case .missingRuntime:
            return action(kind: .setupRuntime, title: "Set Up \(mode)", label: "Set up \(mode) mode through \(runtime)", hint: "Open the safe \(runtime) setup flow for \(mode) mode.", available: actionAvailable)
        case .authenticationRequired:
            let values: (HarnessReadinessActionKind, String, String)
            switch authenticationAction {
            case .signIn:
                values = (.signIn, "Sign In to \(mode)", "Start \(runtime) sign-in only after you activate this button.")
            case .configureCredential:
                values = (.configureCredential, "Set Up \(mode)", "Move to the credential setup required for \(mode) mode.")
            case .enableCredential:
                values = (.enableCredential, "Enable \(mode)", "Allow the saved credential to be used by \(mode) mode.")
            case .validate:
                values = (.validate, "Check \(mode)", "Check the current \(mode) setup through \(runtime).")
            }
            return action(kind: values.0, title: values.1, label: "\(values.1) through \(runtime)", hint: values.2, available: actionAvailable)
        case .failed(let detail):
            return action(kind: .diagnostics, title: "Diagnose \(mode)", label: "Diagnose \(mode) mode through \(runtime)", hint: "Run safe connection diagnostics. \(detail)", available: actionAvailable)
        }
    }

    private static func action(kind: HarnessReadinessActionKind, title: String, label: String, hint: String, available: Bool) -> HarnessReadinessActionResolution {
        HarnessReadinessActionResolution(
            kind: kind,
            title: title,
            accessibilityLabel: label,
            accessibilityHint: available ? hint : "Wait for the current connection action to finish.",
            isInteractive: true,
            isEnabled: available
        )
    }

    private static func stateOnly(title: String, label: String, hint: String) -> HarnessReadinessActionResolution {
        HarnessReadinessActionResolution(kind: .stateOnly, title: title, accessibilityLabel: label, accessibilityHint: hint, isInteractive: false, isEnabled: false)
    }

    private static func normalized(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
