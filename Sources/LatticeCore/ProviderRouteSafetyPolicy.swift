import Foundation

/// Provider-owned tool calls do not use LocalToolBroker's request/handler boundary.
/// Keep those routes explicit until a provider transport can hand every tool call to
/// the broker without weakening existing provider, workspace, or privacy controls.
public enum ProviderRouteSafetyPolicy {
    public static func requiresAcknowledgement(engineID: String, harnessID: String) -> Bool {
        // Only known local engines are exempt. Unknown/non-local engines fail
        // closed, even if a stale or future harness ID reaches this policy.
        engineID != "apple" && engineID != "ollama"
    }

    public static func routeKey(engineID: String, harnessID: String) -> String {
        "\(engineID):\(harnessID)"
    }

    public static func acknowledgementDetail(providerName: String) -> String {
        "\(providerName) owns tool execution on this route. Provider-owned calls do not cross Lattice's LocalToolBroker, so Lattice cannot inspect or authorize calls the provider does not report. Provider-native permissions and Lattice's policy, credential, workspace, and Local Only controls remain separate; this acknowledgement does not add broker enforcement. Workspace containment describes writes only—provider tools may still read outside the workspace or use the network."
    }
}
