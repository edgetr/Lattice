import Foundation

/// Pure local-only / route / backend integrity checks used at gates and import.
/// Keeps privacy fail-closed logic out of App-only types so verify_core can exercise it.
public enum SessionLaunchIntegrity {
    public enum Rejection: Equatable, Sendable {
        case privacyBlocksCloudBackend
        case localOnlyNonLocalRoute
        case declaredRouteBackendMismatch
        case latticeRouteCloudBackend
    }

    public static func privacyAllows(backend: ChatBackend, privacyMode: SessionPrivacyMode) -> Bool {
        SessionPrivacyPolicy.allows(backend, in: privacyMode)
    }

    /// Returns a rejection when the session must not launch a provider run.
    public static func launchRejection(
        backend: ChatBackend,
        privacyMode: SessionPrivacyMode,
        route: ExecutionRoute
    ) -> Rejection? {
        guard SessionPrivacyPolicy.allows(backend, in: privacyMode) else {
            return .privacyBlocksCloudBackend
        }
        if privacyMode == .localOnly {
            if route.mode != .local || !backend.isLocal {
                return .localOnlyNonLocalRoute
            }
        }
        if route.mode == .local && !backend.isLocal {
            return .latticeRouteCloudBackend
        }
        if ExecutionRouteResolver.isDeclared(route),
           let projected = RouteRuntimeMap.backendProjection(for: route),
           projected.id != backend.id {
            return .declaredRouteBackendMismatch
        }
        return nil
    }

    public static func userMessage(for rejection: Rejection) -> String {
        switch rejection {
        case .privacyBlocksCloudBackend, .localOnlyNonLocalRoute, .latticeRouteCloudBackend:
            return SessionPrivacyPolicy.cloudBlockedMessage
        case .declaredRouteBackendMismatch:
            return "This chat's route and backend disagree. Start a new chat or pick a model again."
        }
    }

    /// Import-time integrity for privacy + backend + declared route triples.
    public static func importRejection(
        backend: ChatBackend,
        privacyMode: SessionPrivacyMode,
        route: ExecutionRoute?
    ) -> Rejection? {
        guard SessionPrivacyPolicy.allows(backend, in: privacyMode) else {
            return .privacyBlocksCloudBackend
        }
        if privacyMode == .localOnly, !backend.isLocal {
            return .privacyBlocksCloudBackend
        }
        guard let route else { return nil }
        if privacyMode == .localOnly, route.mode != .local {
            return .localOnlyNonLocalRoute
        }
        if route.mode == .local, !backend.isLocal {
            return .latticeRouteCloudBackend
        }
        if ExecutionRouteResolver.isDeclared(route),
           let projected = RouteRuntimeMap.backendProjection(for: route),
           projected.id != backend.id {
            return .declaredRouteBackendMismatch
        }
        return nil
    }
}
