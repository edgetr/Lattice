import Foundation

public enum PolicyDecision: Equatable, Sendable {
    case allow(reason: String)
    case requireApproval(reason: String)
    case deny(reason: String)
}

public enum ApprovalOptionPolicy {
    public static func visibleOptions(_ options: [ApprovalOption], under policy: ExecutionPolicy) -> [ApprovalOption] {
        options.filter { option in
            isVisible(option, under: policy)
        }
    }

    public static func isVisible(_ option: ApprovalOption, under policy: ExecutionPolicy) -> Bool {
        if option.isReject { return option.kind == "reject_once" }
        guard option.isAllow else { return false }
        switch policy {
        case .ask: return option.kind == "allow_once"
        case .smart: return option.kind == "allow_once" || option.kind == "allow_session"
        case .yolo: return true
        }
    }
}

public struct DeterministicPolicyEngine: PolicyEngine {
    public init() {}

    public func evaluate(_ request: ToolRequest, under policy: ExecutionPolicy) -> PolicyDecision {
        if request.kind == .credential {
            return .deny(reason: "Credential access remains outside Lattice's delegated boundary.")
        }
        if policy == .yolo {
            return .allow(reason: "Explicit YOLO mode; operating-system boundaries still apply.")
        }
        if request.kind == .unknown {
            return .requireApproval(reason: "Unknown tool capabilities require confirmation.")
        }
        if !request.workspaceScoped {
            return .requireApproval(reason: "The action crosses the selected workspace boundary.")
        }
        if request.kind == .read {
            return .allow(reason: "Workspace-scoped reads are allowed.")
        }
        if policy == .smart && request.reversible && request.kind == .write {
            return .allow(reason: "Smart mode allows reversible workspace-scoped edits.")
        }
        return .requireApproval(reason: "Material changes require confirmation in \(policy.rawValue) mode.")
    }
}
