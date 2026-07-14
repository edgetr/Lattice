import Foundation

/// Chat-local resume state. This describes whether Lattice currently holds a
/// provider session handle without exposing or persisting that handle here.
public enum HarnessResumeState: String, Equatable, Sendable {
    case active
    case resumable
    case notEstablished
    case unsupported
    case unknown
}

/// Non-persisted, display-ready view of one active route and runtime.
///
/// Static enforcement claims come from `RouteCapability`; availability and
/// resume state must be supplied from current runtime discovery and chat state.
public struct HarnessCapabilitySnapshot: Equatable, Sendable {
    public let route: ExecutionRoute
    public let policy: ExecutionPolicy
    public let protocolTransport: RouteCapabilityDetail
    public let providerAvailability: RouteCapabilityDetail
    public let modelAvailability: RouteCapabilityDetail
    public let resumeState: HarnessResumeState
    public let resume: RouteCapabilityDetail
    public let sandboxOwner: RouteCapabilityDetail
    public let credentialBoundary: RouteCapabilityDetail
    public let routeCapability: RouteCapability

    public init(
        route: ExecutionRoute,
        policy: ExecutionPolicy,
        protocolTransport: RouteCapabilityDetail,
        providerAvailability: RouteCapabilityDetail,
        modelAvailability: RouteCapabilityDetail,
        resumeState: HarnessResumeState,
        resume: RouteCapabilityDetail,
        sandboxOwner: RouteCapabilityDetail,
        credentialBoundary: RouteCapabilityDetail,
        routeCapability: RouteCapability
    ) {
        self.route = route
        self.policy = policy
        self.protocolTransport = protocolTransport
        self.providerAvailability = providerAvailability
        self.modelAvailability = modelAvailability
        self.resumeState = resumeState
        self.resume = resume
        self.sandboxOwner = sandboxOwner
        self.credentialBoundary = credentialBoundary
        self.routeCapability = routeCapability
    }

    public static func resolve(
        route: ExecutionRoute,
        policy: ExecutionPolicy,
        readiness: RouteReadinessSnapshot?,
        hasProviderSession: Bool,
        isRunning: Bool,
        routeCredentialEnabled: Bool? = nil
    ) -> HarnessCapabilitySnapshot {
        let capability = RouteCapability.resolve(harnessID: route.runtimeID, policy: policy)
        let resume = resumeDetail(
            support: capability.providerSessionResume,
            hasProviderSession: hasProviderSession,
            isRunning: isRunning
        )
        return HarnessCapabilitySnapshot(
            route: route,
            policy: policy,
            protocolTransport: protocolTransport(for: route),
            providerAvailability: providerAvailability(from: readiness),
            modelAvailability: modelAvailability(from: readiness),
            resumeState: resume.0,
            resume: resume.1,
            sandboxOwner: sandboxOwner(for: capability),
            credentialBoundary: credentialBoundary(
                for: route,
                capability: capability,
                routeCredentialEnabled: routeCredentialEnabled
            ),
            routeCapability: capability
        )
    }

    private static func protocolTransport(for route: ExecutionRoute) -> RouteCapabilityDetail {
        let summary: String
        let detail: String
        switch route.runtimeID {
        case "codex":
            summary = "Codex app-server JSON-RPC · stdio"
            detail = "Lattice launches Codex app-server and exchanges newline-delimited JSON-RPC over the child process standard streams."
        case "grok", "opencode", "hermes":
            summary = "ACP JSON-RPC · stdio"
            detail = "Lattice exchanges Agent Client Protocol JSON-RPC messages with the provider runtime over child process standard streams."
        case "pi":
            summary = "Pi RPC events · stdio"
            detail = "Lattice exchanges newline-delimited Pi RPC commands and structured events over child process standard streams."
        case "antigravity":
            summary = "Provider CLI transcript · stdio"
            detail = "Lattice sends the prompt on standard input and receives transcript text from the non-interactive provider CLI; this is not a structured tool protocol."
        case "lattice" where route.providerID == "apple":
            summary = "Foundation Models · in process"
            detail = "Lattice streams text from Apple Foundation Models in process. This path has no delegated provider tool protocol."
        case "lattice" where route.providerID == "ollama":
            summary = "Ollama HTTP/NDJSON · loopback"
            detail = "Lattice streams NDJSON from the selected Ollama model over its loopback HTTP API. This path has no delegated provider tool protocol."
        default:
            return RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Protocol and transport unknown",
                detail: "Lattice has no verified protocol and transport description for runtime “\(route.runtimeID)”."
            )
        }
        return RouteCapabilityDetail(assurance: .present, summary: summary, detail: detail)
    }

    private static func providerAvailability(from readiness: RouteReadinessSnapshot?) -> RouteCapabilityDetail {
        guard let readiness else {
            return RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Provider availability unknown",
                detail: "This route has no current structured runtime discovery snapshot. Availability is not assumed."
            )
        }
        if readiness.readiness == .validating || readiness.readiness == .loading {
            return RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Checking provider",
                detail: "Runtime and authentication discovery is in progress."
            )
        }
        guard readiness.requirements.runtimePresent else {
            return RouteCapabilityDetail(
                assurance: .absent,
                summary: "Runtime unavailable",
                detail: "Runtime discovery did not find an available \(readiness.route.runtimeID) runtime."
            )
        }
        guard readiness.requirements.authenticationValidated else {
            return RouteCapabilityDetail(
                assurance: .absent,
                summary: "Authentication unavailable",
                detail: "The runtime is present, but provider authentication has not been validated for this route."
            )
        }
        return RouteCapabilityDetail(
            assurance: .present,
            summary: "Provider available",
            detail: "Current runtime discovery found the runtime and validated provider authentication for this route."
        )
    }

    private static func modelAvailability(from readiness: RouteReadinessSnapshot?) -> RouteCapabilityDetail {
        guard let readiness else {
            return RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Model availability unknown",
                detail: "This route has no current structured model discovery snapshot. Availability is not assumed."
            )
        }
        if readiness.readiness == .validating || readiness.readiness == .loading {
            return RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Checking model",
                detail: "Model discovery or validation is in progress."
            )
        }
        guard readiness.requirements.runtimePresent, readiness.requirements.authenticationValidated else {
            return RouteCapabilityDetail(
                assurance: .unknown,
                summary: "Model not yet verifiable",
                detail: "Lattice cannot validate the selected model until the runtime and provider authentication are available."
            )
        }
        guard readiness.requirements.modelValidated else {
            return RouteCapabilityDetail(
                assurance: .absent,
                summary: "Model unavailable",
                detail: "The selected model was not present in the current discovered catalog for this route."
            )
        }
        return RouteCapabilityDetail(
            assurance: .present,
            summary: "Model available",
            detail: "The selected model is present in the current discovered catalog for this route."
        )
    }

    private static func resumeDetail(
        support: RouteCapabilityDetail,
        hasProviderSession: Bool,
        isRunning: Bool
    ) -> (HarnessResumeState, RouteCapabilityDetail) {
        switch support.assurance {
        case .absent, .notApplicable:
            return (
                .unsupported,
                RouteCapabilityDetail(assurance: support.assurance, summary: "Resume unsupported", detail: support.detail)
            )
        case .unknown:
            return (
                .unknown,
                RouteCapabilityDetail(assurance: .unknown, summary: "Resume state unknown", detail: support.detail)
            )
        case .enforced, .present:
            if isRunning {
                let handleState = hasProviderSession
                    ? "Lattice currently holds the provider session handle for later resume."
                    : "No provider session handle has been received yet."
                return (
                    .active,
                    RouteCapabilityDetail(
                        assurance: .present,
                        summary: "Session active",
                        detail: "A turn is active. \(handleState) \(support.detail)"
                    )
                )
            }
            if hasProviderSession {
                return (
                    .resumable,
                    RouteCapabilityDetail(
                        assurance: .present,
                        summary: "Ready to resume",
                        detail: "Lattice currently holds a provider session handle. \(support.detail)"
                    )
                )
            }
            return (
                .notEstablished,
                RouteCapabilityDetail(
                    assurance: .present,
                    summary: "Supported · no session yet",
                    detail: "The runtime supports resume, but this chat does not currently hold a provider session handle. \(support.detail)"
                )
            )
        }
    }

    private static func sandboxOwner(for capability: RouteCapability) -> RouteCapabilityDetail {
        switch capability.writeContainmentKind {
        case .latticeMacOSWriteContainment:
            return RouteCapabilityDetail(
                assurance: .enforced,
                summary: "Lattice",
                detail: "Lattice owns the macOS sandbox-exec profile. It contains writes only; reads and network remain allowed."
            )
        case .providerConfiguredSandbox, .providerDeclaredSandbox, .readOnly:
            return RouteCapabilityDetail(
                assurance: .present,
                summary: "Provider",
                detail: "The provider owns this sandbox behavior. Lattice does not add or independently verify equivalent containment."
            )
        case .none:
            return RouteCapabilityDetail(
                assurance: .absent,
                summary: "No sandbox owner",
                detail: "No write-containment sandbox is claimed for this route."
            )
        case .notApplicable:
            return RouteCapabilityDetail(
                assurance: .notApplicable,
                summary: "Not applicable",
                detail: "This route has no delegated tool execution, so there is no tool sandbox owner."
            )
        }
    }

    private static func credentialBoundary(
        for route: ExecutionRoute,
        capability: RouteCapability,
        routeCredentialEnabled: Bool?
    ) -> RouteCapabilityDetail {
        guard OpenCodeCredentialPolicy.allowsKeychainCredential(for: route) else {
            return capability.credentialReadProtection
        }
        let state: String
        switch routeCredentialEnabled {
        case true: state = "enabled"
        case false: state = "disabled"
        case nil: state = "unknown"
        }
        return RouteCapabilityDetail(
            assurance: routeCredentialEnabled == true ? .present : (routeCredentialEnabled == false ? .absent : .unknown),
            summary: "Route key injection \(state)",
            detail: "For this OpenCode route, user-approved Keychain access is \(state). When enabled, Lattice injects only the route-specific key into the provider process environment. Provider-owned tools are not covered by LocalToolBroker credential denial, and the process may still read its own credential stores."
        )
    }
}
