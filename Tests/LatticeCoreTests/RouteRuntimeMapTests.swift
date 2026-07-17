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
        // Preferred override is not a declared catalog template (declared code/codex → pi),
        // so cancel falls back to the legacy harness id.
        #expect(!ExecutionRouteResolver.isDeclared(route))
        #expect(RouteRuntimeMap.cancelTarget(for: route, legacyHarnessID: "codex") == "codex")
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

    @Test func piFirstCodeRouteFallsBackOnlyBeforeRuntimeLock() {
        let preferred = ExecutionRoute(mode: .code, providerID: "codex", modelID: "gpt-5.6", runtimeID: "pi")
        let fallback = PiFirstCodeRoutingPolicy.resolve(
            preferredRoute: preferred,
            preferredReadiness: .missingRuntime,
            directReadiness: .runnable,
            routeLocked: false
        )
        #expect(fallback.isRunnable)
        #expect(fallback.usesProviderFallback)
        #expect(fallback.route.runtimeID == "codex")
        #expect(fallback.route.fallbackFromRuntimeID == "pi")
        #expect(ExecutionRouteResolver.isDeclared(fallback.route))
        #expect(RouteRuntimeMap.cancelTarget(for: fallback.route) == "codex")

        let locked = PiFirstCodeRoutingPolicy.resolve(
            preferredRoute: preferred,
            preferredReadiness: .missingRuntime,
            directReadiness: .runnable,
            routeLocked: true
        )
        #expect(!locked.isRunnable)
        #expect(locked.route == preferred)
    }

    @Test func piFirstWaitsForPreferredReadinessAndRequiresDirectReadiness() {
        let preferred = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "opencode-go/model", runtimeID: "pi")
        let checking = PiFirstCodeRoutingPolicy.resolve(
            preferredRoute: preferred,
            preferredReadiness: .validating,
            directReadiness: .runnable,
            routeLocked: false
        )
        #expect(!checking.isRunnable)
        #expect(!checking.usesProviderFallback)

        let unavailable = PiFirstCodeRoutingPolicy.resolve(
            preferredRoute: preferred,
            preferredReadiness: .failed("Pi unavailable"),
            directReadiness: .authenticationRequired,
            routeLocked: false
        )
        #expect(!unavailable.isRunnable)
        #expect(unavailable.route == preferred)
    }

    @Test func providerFallbackDoesNotUseLegacyOpenCodeCredentialBridge() {
        let preferred = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "opencode-go/model", runtimeID: "pi")
        let fallback = PiFirstCodeRoutingPolicy.fallbackRoute(for: preferred)
        #expect(fallback != nil)
        #expect(fallback.map(LegacyOpenCodeBridgePolicy.allows) == false)
        let legacy = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "legacy", runtimeID: "opencode")
        #expect(LegacyOpenCodeBridgePolicy.allows(legacy))
    }

    @Test func markedFallbackCanRestorePreferredPiOnlyBeforeLock() {
        let fallback = ExecutionRoute(
            mode: .code,
            providerID: "opencode",
            modelID: "opencode-go/model",
            runtimeID: "opencode",
            fallbackFromRuntimeID: "pi"
        )
        #expect(PiFirstCodeRoutingPolicy.preferredRoute(for: fallback)?.runtimeID == "pi")
        #expect(PiFirstCodeRoutingPolicy.preferredRoute(for: fallback)?.fallbackFromRuntimeID == nil)
        let legacy = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "legacy", runtimeID: "opencode")
        #expect(PiFirstCodeRoutingPolicy.preferredRoute(for: legacy) == nil)
    }

    @Test func malformedProviderFallbackIsNotDeclared() {
        let malformed = ExecutionRoute(
            mode: .code,
            providerID: "codex",
            modelID: "gpt-5.6",
            runtimeID: "codex",
            fallbackFromRuntimeID: "hermes"
        )
        #expect(!PiFirstCodeRoutingPolicy.isDeclaredProviderFallback(malformed))
        #expect(!ExecutionRouteResolver.isDeclared(malformed))
    }

    @Test func fallbackProvenanceRoundTripsDurably() throws {
        let route = ExecutionRoute(
            mode: .code,
            providerID: "codex",
            modelID: "gpt-5.6",
            runtimeID: "codex",
            fallbackFromRuntimeID: "pi"
        )
        let data = try JSONEncoder().encode(route)
        #expect(try JSONDecoder().decode(ExecutionRoute.self, from: data) == route)
        #expect(route.id != ExecutionRoute(mode: .code, providerID: "codex", modelID: "gpt-5.6", runtimeID: "codex").id)
    }
}
