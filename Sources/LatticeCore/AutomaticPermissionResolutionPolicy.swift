import Foundation

public enum AutomaticPermissionResolution: Equatable, Sendable {
    case forward(optionID: String, allowed: Bool)
    case requestUser
    case denyFailClosed(reason: String)
}

public enum AutomaticPermissionResolutionPolicy {
    public static func resolve(
        decision: PolicyDecision?,
        policy: ExecutionPolicy,
        options: [ApprovalOption]
    ) -> AutomaticPermissionResolution {
        switch decision {
        case .deny(let reason):
            guard let option = options.first(where: { $0.kind == "reject_once" }) else {
                return .denyFailClosed(reason: reason)
            }
            return .forward(optionID: option.id, allowed: false)
        case .allow:
            guard let option = options.first(where: { $0.kind == "allow_once" }) else {
                return .requestUser
            }
            return .forward(optionID: option.id, allowed: true)
        case .requireApproval:
            return .requestUser
        case nil:
            // Without a tool-request classification, only YOLO may auto-allow.
            // Accept Edits still requires a classified allow decision.
            guard policy == .yolo,
                  let option = options.first(where: { $0.kind == "allow_once" }) else {
                return .requestUser
            }
            return .forward(optionID: option.id, allowed: true)
        }
    }
}
