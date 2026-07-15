import Foundation
import Testing
@testable import LatticeCore

@Suite("RouteRuntimeMap")
struct RouteRuntimeMapTests {
    @Test func declaredCodeCodexUsesPiRuntime() {
        let route = RouteRuntimeMap.writeRoute(backend: .codex(model: "gpt-5.5"), mode: .code)
        #expect(route == ExecutionRoute(mode: .code, providerID: "codex", modelID: "gpt-5.5", runtimeID: "pi"))
        #expect(RouteRuntimeMap.defaultRuntimeID(mode: .code, providerID: "codex") == "pi")
        #expect(RouteRuntimeMap.readinessRuntimeID(for: route) == "pi")
        #expect(RouteRuntimeMap.cancelTarget(for: route) == "pi")
    }

    @Test func declaredWorkOpenCodeUsesHermesRuntime() {
        let route = RouteRuntimeMap.writeRoute(
            backend: .openCode(model: "opencode-go:deepseek"),
            mode: .work
        )
        #expect(route.runtimeID == "hermes")
        #expect(route.providerID == "opencode")
        #expect(RouteRuntimeMap.backendProjection(for: route) == .openCode(model: "opencode-go:deepseek"))
    }

    @Test func localAppleUsesLatticeRuntime() {
        let route = RouteRuntimeMap.writeRoute(backend: .appleIntelligence, mode: .local)
        #expect(route == ExecutionRoute(mode: .local, providerID: "apple", modelID: nil, runtimeID: "lattice"))
        #expect(RouteRuntimeMap.backendProjection(for: route) == .appleIntelligence)
    }

    @Test func preferredRuntimeOverrideWinsForLegacyDirectRoutes() {
        let route = RouteRuntimeMap.writeRoute(
            backend: .codex(model: "gpt-5.5"),
            mode: .code,
            preferredRuntimeID: "codex"
        )
        #expect(route.runtimeID == "codex")
        #expect(route.mode == .code)
        #expect(RouteRuntimeMap.cancelTarget(for: route, legacyHarnessID: "pi") == "codex")
    }

    @Test func sessionEffectiveRuntimePrefersExecutionRoute() {
        let session = LatticeSession(
            title: "t",
            backend: .codex(model: "gpt-5.5"),
            executionRoute: ExecutionRoute(mode: .code, providerID: "codex", modelID: "gpt-5.5", runtimeID: "pi"),
            harnessID: "codex"
        )
        #expect(RouteRuntimeMap.effectiveRuntimeID(for: session) == "pi")
        #expect(RouteRuntimeMap.providerID(for: session) == "codex")
    }

    @Test func cancelFallsBackToLegacyWhenRouteNotDeclared() {
        let route = ExecutionRoute.legacy(for: .codex(model: "gpt-5.5"), harnessID: "codex")
        #expect(!ExecutionRouteResolver.isDeclared(route))
        #expect(RouteRuntimeMap.cancelTarget(for: route, legacyHarnessID: "codex") == "codex")
    }
}
