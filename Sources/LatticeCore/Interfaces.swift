import Foundation

// Lattice keeps only protocols that have real production conformances.
// Aspirational harness/engine interfaces were removed until a second
// implementation needs the abstraction (see code-quality remediation plan).

public protocol TaskRouter: Sendable {
    func recommend(for request: RecommendationRequest, catalog: [ExecutionTuple]) -> Recommendation?
}

public protocol ToolBroker: Sendable {
    func authorize(_ request: ToolRequest, policy: ExecutionPolicy) async -> PolicyDecision
    func execute(_ request: ToolRequest) async throws -> AgentEvent
}

public protocol PolicyEngine: Sendable {
    func evaluate(_ request: ToolRequest, under policy: ExecutionPolicy) -> PolicyDecision
}
