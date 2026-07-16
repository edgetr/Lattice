import Foundation

/// Codex app-server approvalPolicy + sandbox mapping for a Lattice execution policy.
///
/// This is the single truth source for both live Codex dispatch and capability disclosure.
/// Lattice does not re-enforce these settings through `LocalToolBroker` or `sandbox-exec`.
public struct CodexProviderExecutionRoute: Equatable, Sendable {
    public let approvalPolicy: String
    public let sandbox: String

    public init(approvalPolicy: String, sandbox: String) {
        self.approvalPolicy = approvalPolicy
        self.sandbox = sandbox
    }

    /// Maps Lattice policy to Codex provider knobs.
    /// - Ask: `on-request` approvals with `read-only` sandbox unless explicit workspace write is requested.
    /// - Smart: `on-request` approvals with `workspace-write`.
    /// - Accept Edits: `on-request` approvals with `workspace-write` (Lattice may auto-allow
    ///   workspace-scoped file writes/edits after a reported request without undo evidence;
    ///   bash/out-of-scope still surface).
    /// - YOLO: approvals `never` with `danger-full-access` (no provider sandbox containment).
    public static func resolve(policy: ExecutionPolicy, workspaceWrite: Bool = false) -> CodexProviderExecutionRoute {
        switch policy {
        case .ask:
            CodexProviderExecutionRoute(
                approvalPolicy: "on-request",
                sandbox: workspaceWrite ? "workspace-write" : "read-only"
            )
        case .smart, .acceptEdits:
            CodexProviderExecutionRoute(
                approvalPolicy: "on-request",
                sandbox: "workspace-write"
            )
        case .yolo:
            CodexProviderExecutionRoute(
                approvalPolicy: "never",
                sandbox: "danger-full-access"
            )
        }
    }
}
