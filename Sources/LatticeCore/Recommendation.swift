import Foundation

public struct RecommendationRequest: Sendable {
    public enum Task: String, Sendable { case chat, coding, reasoning, vision, toolUse }
    public let task: Task
    public let requiresLocal: Bool
    public let requiredContext: Int
    public let preferredCategory: String

    public init(task: Task, requiresLocal: Bool, requiredContext: Int, preferredCategory: String = "balanced") {
        self.task = task; self.requiresLocal = requiresLocal; self.requiredContext = requiredContext; self.preferredCategory = preferredCategory
    }
}

public struct ExecutionTuple: Identifiable, Sendable {
    public let id: String
    public let model: ModelDescriptor
    public let harness: HarnessProfile
    public let contextPolicy: String
    public let categories: Set<String>
    public init(id: String, model: ModelDescriptor, harness: HarnessProfile, contextPolicy: String, categories: Set<String>) {
        self.id = id; self.model = model; self.harness = harness; self.contextPolicy = contextPolicy; self.categories = categories
    }
}

public struct Recommendation: Sendable {
    public let configuration: ExecutionTuple
    public let explanation: String
}

public struct DeterministicTaskRouter: TaskRouter {
    public init() {}

    public func recommend(for request: RecommendationRequest, catalog: [ExecutionTuple]) -> Recommendation? {
        let candidates = catalog.filter {
            (!request.requiresLocal || $0.model.isLocal) &&
            $0.model.contextWindow >= request.requiredContext &&
            $0.model.fit != .unsupported && $0.model.fit != .risky
        }
        let ranked = candidates.sorted { lhs, rhs in
            score(lhs, request) > score(rhs, request)
        }
        guard let best = ranked.first else { return nil }
        let privacy = best.model.isLocal ? "keeps the session on this Mac" : "uses an optional remote provider"
        return Recommendation(
            configuration: best,
            explanation: "\(best.model.name) through \(best.harness.name) \(privacy), has a \(best.model.fit.rawValue) hardware fit, and supports the requested \(request.task.rawValue) workload."
        )
    }

    private func score(_ tuple: ExecutionTuple, _ request: RecommendationRequest) -> Int {
        var value = tuple.categories.contains(request.preferredCategory) ? 10 : 0
        value += tuple.model.capabilities.contains(request.task.rawValue) ? 8 : 0
        value += tuple.model.fit == .comfortable ? 4 : 1
        value += tuple.harness.isQualifiedForActions ? 2 : 0
        return value
    }
}
