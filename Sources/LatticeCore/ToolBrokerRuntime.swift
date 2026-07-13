import Foundation

public enum ToolAuditDecision: String, Codable, Hashable, Sendable {
    case allowed
    case approvalRequired
    case denied
    case executed
    case failed
}

public struct ToolAuditRecord: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let requestID: UUID
    public let requestKind: ToolRequest.Kind
    public let title: String
    public let detail: String
    public let workspaceScoped: Bool
    public let reversible: Bool
    public let policy: ExecutionPolicy
    public let decision: ToolAuditDecision
    public let reason: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        requestID: UUID,
        requestKind: ToolRequest.Kind,
        title: String,
        detail: String,
        workspaceScoped: Bool,
        reversible: Bool,
        policy: ExecutionPolicy,
        decision: ToolAuditDecision,
        reason: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.requestID = requestID
        self.requestKind = requestKind
        self.title = title
        self.detail = detail
        self.workspaceScoped = workspaceScoped
        self.reversible = reversible
        self.policy = policy
        self.decision = decision
        self.reason = reason
        self.createdAt = createdAt
    }
}

public enum ToolBrokerExecutionResult: Equatable, Sendable {
    case executed(AgentEvent)
    case requiresApproval(ApprovalRequest)
    case denied(String)
    case failed(String)
}

public enum ToolBrokerError: Error, Equatable, Sendable {
    case noHandler(kind: ToolRequest.Kind)
}

public actor LocalToolBroker: ToolBroker {
    public typealias ToolHandler = @Sendable (ToolRequest) async throws -> AgentEvent

    private let policyEngine: DeterministicPolicyEngine
    private let auditLimit: Int
    private var handlers: [ToolRequest.Kind: ToolHandler]
    private var auditRecords: [ToolAuditRecord] = []

    public init(
        policyEngine: DeterministicPolicyEngine = DeterministicPolicyEngine(),
        handlers: [ToolRequest.Kind: ToolHandler] = [:],
        auditLimit: Int = 500
    ) {
        self.policyEngine = policyEngine
        self.handlers = handlers
        self.auditLimit = max(1, auditLimit)
    }

    public func registerHandler(for kind: ToolRequest.Kind, handler: @escaping ToolHandler) {
        handlers[kind] = handler
    }

    public func auditSnapshot() -> [ToolAuditRecord] {
        auditRecords
    }

    public func authorize(_ request: ToolRequest, policy: ExecutionPolicy) async -> PolicyDecision {
        policyEngine.evaluate(request, under: policy)
    }

    public func execute(_ request: ToolRequest) async throws -> AgentEvent {
        guard let handler = handlers[request.kind] else {
            throw ToolBrokerError.noHandler(kind: request.kind)
        }
        return try await handler(request)
    }

    public func submit(_ request: ToolRequest, policy: ExecutionPolicy) async -> ToolBrokerExecutionResult {
        switch policyEngine.evaluate(request, under: policy) {
        case .allow(let reason):
            appendAudit(for: request, policy: policy, decision: .allowed, reason: reason)
            do {
                let event = try await execute(request)
                appendAudit(for: request, policy: policy, decision: .executed, reason: "Executed registered \(request.kind.rawValue) handler.")
                return .executed(event)
            } catch {
                let message = String(describing: error)
                appendAudit(for: request, policy: policy, decision: .failed, reason: message)
                return .failed(message)
            }
        case .requireApproval(let reason):
            appendAudit(for: request, policy: policy, decision: .approvalRequired, reason: reason)
            return .requiresApproval(Self.approvalRequest(for: request, policy: policy, reason: reason))
        case .deny(let reason):
            appendAudit(for: request, policy: policy, decision: .denied, reason: reason)
            return .denied(reason)
        }
    }

    private static func approvalRequest(for request: ToolRequest, policy: ExecutionPolicy, reason: String) -> ApprovalRequest {
        ApprovalRequest(
            id: request.id,
            title: request.title,
            detail: "\(request.detail)\n\n\(reason)",
            options: ApprovalOptionPolicy.visibleOptions([
                ApprovalOption(id: "allow_once", name: "Allow once", kind: "allow_once"),
                ApprovalOption(id: "allow_session", name: "Allow for session", kind: "allow_session"),
                ApprovalOption(id: "reject_once", name: "Deny", kind: "reject_once")
            ], under: policy),
            toolRequest: request
        )
    }

    private func appendAudit(for request: ToolRequest, policy: ExecutionPolicy, decision: ToolAuditDecision, reason: String) {
        auditRecords.append(ToolAuditRecord(
            requestID: request.id,
            requestKind: request.kind,
            title: request.title,
            detail: request.detail,
            workspaceScoped: request.workspaceScoped,
            reversible: request.reversible,
            policy: policy,
            decision: decision,
            reason: reason
        ))
        if auditRecords.count > auditLimit {
            auditRecords.removeFirst(auditRecords.count - auditLimit)
        }
    }
}
