import Testing
@testable import LatticeCore

@Suite("Provider route safety")
struct ProviderRouteSafetyPolicyTests {
    @Test func providerRoutesRequireExplicitAcknowledgement() {
        for (engineID, harnessID) in [
            ("codex", "codex"),
            ("codex", "pi"),
            ("opencode", "opencode"),
            ("opencode", "hermes"),
            ("grok", "grok"),
            ("antigravity", "antigravity")
        ] {
            #expect(ProviderRouteSafetyPolicy.requiresAcknowledgement(engineID: engineID, harnessID: harnessID))
        }
    }

    @Test func localRoutesDoNotRequireAcknowledgement() {
        for (engineID, harnessID) in [("apple", "lattice"), ("ollama", "lattice")] {
            #expect(!ProviderRouteSafetyPolicy.requiresAcknowledgement(engineID: engineID, harnessID: harnessID))
        }
    }

    @Test func unknownOrIncompatibleNonLocalRouteFailsClosed() {
        #expect(ProviderRouteSafetyPolicy.requiresAcknowledgement(engineID: "unknown", harnessID: "unknown"))
        #expect(ProviderRouteSafetyPolicy.requiresAcknowledgement(engineID: "codex", harnessID: "lattice"))
    }

    @Test func routeKeysKeepProviderHarnessAcknowledgementsScoped() {
        #expect(ProviderRouteSafetyPolicy.routeKey(engineID: "codex", harnessID: "codex") == "codex:codex")
        #expect(ProviderRouteSafetyPolicy.routeKey(engineID: "codex", harnessID: "codex") != ProviderRouteSafetyPolicy.routeKey(engineID: "codex", harnessID: "pi"))
    }

    @Test func acknowledgementExplainsMissingBrokerBoundaryWithoutOverclaiming() {
        let detail = ProviderRouteSafetyPolicy.acknowledgementDetail(providerName: "Codex")
        #expect(detail.contains("do not cross Lattice's LocalToolBroker"))
        #expect(detail.contains("Workspace containment describes writes only"))
        #expect(detail.contains("does not add broker enforcement"))
    }
}
