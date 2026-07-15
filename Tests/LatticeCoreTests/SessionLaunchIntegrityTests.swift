import Foundation
import Testing
@testable import LatticeCore

@Suite("SessionLaunchIntegrity")
struct SessionLaunchIntegrityTests {
    @Test func localOnlyRejectsCloudBackend() {
        #expect(
            SessionLaunchIntegrity.launchRejection(
                backend: .codex(model: "gpt-5.5"),
                privacyMode: .localOnly,
                route: ExecutionRoute(mode: .local, providerID: "apple", runtimeID: "lattice")
            ) == .privacyBlocksCloudBackend
        )
    }

    @Test func localOnlyRejectsNonLocalRoute() {
        #expect(
            SessionLaunchIntegrity.launchRejection(
                backend: .appleIntelligence,
                privacyMode: .localOnly,
                route: ExecutionRoute(mode: .code, providerID: "apple", runtimeID: "lattice")
            ) == .localOnlyNonLocalRoute
        )
    }

    @Test func latticeRouteRejectsCloudBackend() {
        #expect(
            SessionLaunchIntegrity.launchRejection(
                backend: .codex(model: "gpt-5.5"),
                privacyMode: .cloudAllowed,
                route: ExecutionRoute(mode: .local, providerID: "apple", runtimeID: "lattice")
            ) == .latticeRouteCloudBackend
        )
    }

    @Test func declaredRouteBackendMismatch() {
        let route = ExecutionRoute(mode: .code, providerID: "codex", modelID: "gpt-5.5", runtimeID: "pi")
        #expect(
            SessionLaunchIntegrity.launchRejection(
                backend: .grok(model: "grok-4"),
                privacyMode: .cloudAllowed,
                route: route
            ) == .declaredRouteBackendMismatch
        )
        #expect(
            SessionLaunchIntegrity.importRejection(
                backend: .openCode(model: "other"),
                privacyMode: .cloudAllowed,
                route: route
            ) == .declaredRouteBackendMismatch
        )
    }

    @Test func matchingLocalAllows() {
        #expect(
            SessionLaunchIntegrity.launchRejection(
                backend: .appleIntelligence,
                privacyMode: .localOnly,
                route: ExecutionRoute(mode: .local, providerID: "apple", runtimeID: "lattice")
            ) == nil
        )
    }

    @Test func v1ImportRejectsLocalOnlyCloudBackend() {
        #expect(
            SessionLaunchIntegrity.importRejection(
                backend: .codex(model: "gpt-5.5"),
                privacyMode: .localOnly,
                route: ExecutionRoute.legacy(for: .codex(model: "gpt-5.5"), harnessID: "codex")
            ) == .privacyBlocksCloudBackend
        )
    }
}
