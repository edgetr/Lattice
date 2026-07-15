import Foundation

public struct ProviderEventDiagnostic: Hashable, Sendable {
    public let id: UUID
    public let provider: String
    public let eventType: String?
    public let reason: String
    public let fields: [String]

    public init(id: UUID = UUID(), provider: String, eventType: String? = nil, reason: String, fields: [String] = []) {
        self.id = id
        self.provider = String(provider.prefix(80))
        self.eventType = eventType.map { String($0.prefix(120)) }
        self.reason = String(reason.prefix(240))
        self.fields = Array(fields.sorted().prefix(32))
    }

    public var title: String { "\(provider) provider event not understood" }
    /// Metadata only. Never includes provider payload values.
    public var detail: String {
        var parts = [reason]
        if let eventType, !eventType.isEmpty { parts.append("Event: \(eventType)") }
        if !fields.isEmpty { parts.append("Fields: \(fields.joined(separator: ", "))") }
        return parts.joined(separator: " ")
    }
}

public struct HarnessActivityEvent: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case running
        case completed
        case failed
        case cancelled
        case degraded
        case unsupported
    }

    public let id: UUID
    public let provider: String
    public let title: String
    public let detail: String
    public let status: Status

    public init(id: UUID, provider: String, title: String, detail: String, status: Status) {
        self.id = id
        self.provider = String(provider.prefix(80))
        self.title = String(title.prefix(160))
        self.detail = String(detail.prefix(600))
        self.status = status
    }
}

public struct AgentPlanStep: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case pending
        case inProgress
        case completed
    }

    public let id: UUID
    public let title: String
    public let status: Status

    public init(id: UUID, title: String, status: Status) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public enum AgentEvent: Sendable, Equatable {
    case sessionStarted(UUID)
    case harnessSessionStarted(String)
    /// Provider rejected its persisted session; continuity is rebuilt only from visible transcript.
    case harnessSessionRecovery(String)
    case assistantDelta(String)
    case plan(id: UUID, title: String, explanation: String?, steps: [AgentPlanStep])
    case reasoningSummary(id: UUID, delta: String)
    case toolRequested(ToolRequest)
    case toolProgress(id: UUID, fraction: Double, detail: String)
    case permissionRequested(ApprovalRequest)
    /// Typed permission decision produced for a structured provider request.
    case permissionDecided(ProviderPermissionDecision)
    /// Observable provider-session lifecycle. This is ephemeral run state, not persisted provider state.
    case providerSessionLifecycle(ProviderSessionLifecycleEvent)
    /// Supplies the reason before the legacy terminal `cancelled` marker.
    case runCancelled(AgentCancellation)
    case metric(name: String, value: Double, unit: String)
    case harnessActivity(HarnessActivityEvent)
    case providerDiagnostic(ProviderEventDiagnostic)
    /// Typed assistant media artifact (metadata + authorized local path only; never bytes/base64).
    case artifact(AssistantArtifactObservation)
    /// Observable provider computer-use frame. Lattice does not mediate mouse/keyboard tools.
    case computerFrame(ComputerFrame)
    case completed
    case cancelled
    case failed(String)
}
