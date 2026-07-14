import Foundation

/// Input crossing the route-selection boundary. Execution ownership stays with app orchestration.
public struct ExecutionRequest: Equatable, Sendable {
    public let sessionID: UUID
    public let route: ExecutionRoute
    public let prompt: String
    public let attachments: [ContextAttachment]

    public init(sessionID: UUID, route: ExecutionRoute, prompt: String, attachments: [ContextAttachment] = []) {
        self.sessionID = sessionID
        self.route = route
        self.prompt = prompt
        self.attachments = attachments
    }
}

/// Wave 1 seam for future route execution. No provider/run implementation belongs here yet.
public protocol ExecutionCoordinator: Sendable {
    func execute(_ request: ExecutionRequest) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(sessionID: UUID) async
}
