import Foundation
import Testing
@testable import LatticeCore

@Suite("Runtime readiness and setup")
struct RuntimeReadinessTests {
    private let route = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "opencode-go/model", runtimeID: "pi")

    @Test func confirmationIDUsesRuntimeAndActionValues() {
        let request = RuntimeConfirmationRequest(runtime: .pi, action: .firstUseInstall)
        #expect(request.id == "pi:firstUseInstall")
    }

    @Test func readinessRequiresEachIndependentRequirement() {
        let missing = RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: .init(runtimePresent: false, authenticationValidated: true, modelValidated: true, sandboxAvailable: true)
        )
        #expect(missing.readiness == .missingRuntime)

        let auth = RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: .init(runtimePresent: true, authenticationValidated: false, modelValidated: true, sandboxAvailable: true)
        )
        #expect(auth.readiness == .authenticationRequired)

        let validating = RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: .init(runtimePresent: true, authenticationValidated: true, modelValidated: true, sandboxAvailable: true),
            validating: true
        )
        #expect(validating.readiness == .validating)

        let noModel = RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: .init(runtimePresent: true, authenticationValidated: true, modelValidated: false, sandboxAvailable: true)
        )
        #expect(!noModel.readiness.isRunnable)
        #expect(noModel.readiness.detail.contains("model"))

        let noSandbox = RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: .init(runtimePresent: true, authenticationValidated: true, modelValidated: true, sandboxAvailable: false)
        )
        #expect(!noSandbox.readiness.isRunnable)
        #expect(noSandbox.readiness.detail.contains("sandbox"))

        let runnable = RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: .init(runtimePresent: true, authenticationValidated: true, modelValidated: true, sandboxAvailable: true)
        )
        #expect(runnable.readiness == .runnable)
    }

    @Test func setupDescriptorsPinVersionWithoutInventingHashOrSize() {
        let pi = RuntimeInstallDescriptor.pi
        #expect(pi.source.contains("earendil-works/pi/releases/tag/v0.80.6"))
        #expect(pi.immutableVersion == "0.80.6")
        #expect(pi.installReference.hasSuffix("@0.80.6"))
        #expect(pi.estimatedSizeBytes == nil)
        #expect(!pi.hasPublishedHash)
        #expect(pi.registryIntegrity == "sha512-vcfD6tOk402isLl3Cm/qbn2O10TvgroMp1+/fEGM24ZdvETFCdOYv5VZ7m59EI5fPsjfSJh+CpQ5bhBrhfOg7g==")
        #expect(pi.verificationLabel.contains("not independently hashed"))

        let hermes = RuntimeInstallDescriptor.hermes
        #expect(hermes.source.contains("NousResearch/hermes-agent/releases/tag/v2026.7.7.2"))
        #expect(hermes.immutableVersion == "v2026.7.7.2")
        #expect(hermes.installReference.hasSuffix("@b7751df34688835a108e0d630f3495fc11f3df79"))
        #expect(hermes.pinnedSourceCommit == "b7751df34688835a108e0d630f3495fc11f3df79")
        #expect(hermes.estimatedSizeBytes == nil)
        #expect(!hermes.hasPublishedHash)
    }

    @Test func OpenCodeKeychainCredentialIsLimitedToPiAndHermesAndUsesRuntimeEnvNames() {
        let pi = route
        let hermesGo = ExecutionRoute(mode: .work, providerID: "opencode", modelID: "opencode-go:model", runtimeID: "hermes")
        let hermesZen = ExecutionRoute(mode: .work, providerID: "opencode", modelID: "opencode-zen:model", runtimeID: "hermes")
        let direct = ExecutionRoute(mode: .code, providerID: "opencode", modelID: "opencode-go/model", runtimeID: "opencode")

        #expect(OpenCodeCredentialPolicy.allowsKeychainCredential(for: pi))
        #expect(OpenCodeCredentialPolicy.allowsKeychainCredential(for: hermesGo))
        #expect(OpenCodeCredentialPolicy.allowsKeychainCredential(for: hermesZen))
        #expect(!OpenCodeCredentialPolicy.allowsKeychainCredential(for: direct))
        #expect(OpenCodeCredentialPolicy.environmentKey(for: pi) == "OPENCODE_API_KEY")
        #expect(OpenCodeCredentialPolicy.environmentKey(for: hermesGo) == "OPENCODE_GO_API_KEY")
        #expect(OpenCodeCredentialPolicy.environmentKey(for: hermesZen) == "OPENCODE_ZEN_API_KEY")
        #expect(OpenCodeCredentialPolicy.environmentKey(for: direct) == nil)
    }
}
