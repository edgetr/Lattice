import Foundation

public protocol InferenceEngine: Sendable {
    var identifier: String { get }
    func inspect() async throws -> [ModelDescriptor]
    func load(modelID: String) async throws
    func unload() async
    func generate(prompt: String) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel() async
}

public protocol ModelSource: Sendable {
    func discover() async throws -> [ModelDescriptor]
    func refresh() async throws
}

public protocol AgentHarness: Sendable {
    var profile: HarnessProfile { get }
    func authenticate() async throws
    func listModels() async throws -> [ModelDescriptor]
    func prompt(sessionID: String?, text: String) -> AsyncThrowingStream<AgentEvent, Error>
    func cancel(sessionID: String) async
}

public protocol HarnessTransport: Sendable {
    func connect() async throws
    func send(_ data: Data) async throws
    func events() -> AsyncThrowingStream<Data, Error>
    func disconnect() async
}

public protocol HarnessProcessSupervisor: Sendable {
    func executableStatus(for profile: HarnessProfile) async -> Bool
    func start(profile: HarnessProfile, workspace: URL) async throws
    func stop(profileID: String, workspace: URL) async
}

public protocol SessionOrchestrating: Sendable {
    func stream(prompt: String, sessionID: UUID) -> AsyncStream<AgentEvent>
    func cancel(sessionID: UUID) async
}

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

public protocol AutomationService: Sendable {
    func availableCapabilities() async -> Set<String>
    func perform(action: String, arguments: [String: String]) async throws
}
