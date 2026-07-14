import Foundation

/// Input crossing the route-selection boundary. Execution ownership stays with app orchestration.
public struct ExecutionRequest: Equatable, Sendable {
    public let sessionID: UUID
    public let route: ExecutionRoute
    public let prompt: String

    public init(sessionID: UUID, route: ExecutionRoute, prompt: String) {
        self.sessionID = sessionID
        self.route = route
        self.prompt = prompt
    }
}

/// Wave 1 seam for future route execution. No provider/run implementation belongs here yet.
public protocol ExecutionCoordinator: Sendable {
    func execute(_ request: ExecutionRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(sessionID: UUID) async
}
