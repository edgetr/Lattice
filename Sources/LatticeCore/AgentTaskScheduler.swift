import Foundation

public enum AgentTaskPriority: Int, CaseIterable, Codable, Comparable, Sendable {
    case low = 0
    case normal = 1
    case high = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .high: "High"
        case .normal: "Normal"
        case .low: "Low"
        }
    }
}

public enum AgentTaskRecoverySensitivity: String, Codable, Sendable {
    case ordinary
    case approvalSensitive
    case externallyConsequential
}

public struct AgentTaskResourceKey: Hashable, Codable, Sendable {
    public let workspaceID: String
    public let providerID: String
    public let routeID: String

    public init(workspaceID: String, providerID: String, routeID: String) {
        self.workspaceID = workspaceID
        self.providerID = providerID
        self.routeID = routeID
    }
}

public struct AgentTaskSchedulerLimits: Equatable, Codable, Sendable {
    public var global: Int
    public var perWorkspace: Int
    public var providerCaps: [String: Int]
    public var routeCaps: [String: Int]

    public init(
        global: Int = 4,
        perWorkspace: Int = 2,
        providerCaps: [String: Int] = [:],
        routeCaps: [String: Int] = [:]
    ) {
        self.global = max(1, global)
        self.perWorkspace = max(1, perWorkspace)
        self.providerCaps = providerCaps.mapValues { max(1, $0) }
        self.routeCaps = routeCaps.mapValues { max(1, $0) }
    }
}

public struct AgentTaskSchedulerRequest: Equatable, Codable, Sendable {
    public let id: UUID
    public let sessionID: UUID
    public let resources: AgentTaskResourceKey
    public var priority: AgentTaskPriority
    public let recoverySensitivity: AgentTaskRecoverySensitivity

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        resources: AgentTaskResourceKey,
        priority: AgentTaskPriority = .normal,
        recoverySensitivity: AgentTaskRecoverySensitivity = .ordinary
    ) {
        self.id = id
        self.sessionID = sessionID
        self.resources = resources
        self.priority = priority
        self.recoverySensitivity = recoverySensitivity
    }
}

public enum AgentTaskSchedulerState: String, Equatable, Codable, Sendable {
    case queued
    case running
    case waitingForApproval
    case recoveryHeld
}

public struct AgentTaskSchedulerSnapshot: Equatable, Sendable {
    public let request: AgentTaskSchedulerRequest
    public let state: AgentTaskSchedulerState
    public let queuePosition: Int?
    public let isApprovalResume: Bool
}

/// Secret-free queue metadata. It intentionally contains no prompt, transcript, credentials,
/// approval choice, or executable payload. Recovery always holds entries for explicit user action.
public struct PersistedAgentTaskQueue: Equatable, Codable, Sendable {
    public var version: Int
    public var entries: [AgentTaskSchedulerRequest]

    public init(version: Int = 1, entries: [AgentTaskSchedulerRequest]) {
        self.version = version
        self.entries = entries
    }
}

/// Deterministic admission controller. Callers own execution and feed terminal/approval transitions
/// back into the scheduler. Waiting approvals release capacity; resolving one must be re-admitted.
public struct AgentTaskScheduler: Sendable {
    private struct Entry: Sendable {
        var request: AgentTaskSchedulerRequest
        var state: AgentTaskSchedulerState
        var sequence: UInt64
        var waitingRounds: Int
        var isApprovalResume: Bool
        var holdsExecutionSlot: Bool
    }

    public private(set) var limits: AgentTaskSchedulerLimits
    public let fairnessInterval: Int
    private var entries: [UUID: Entry] = [:]
    private var nextSequence: UInt64 = 0

    public init(limits: AgentTaskSchedulerLimits = .init(), fairnessInterval: Int = 3) {
        self.limits = limits
        self.fairnessInterval = max(1, fairnessInterval)
    }

    public mutating func updateLimits(_ limits: AgentTaskSchedulerLimits) -> [UUID] {
        self.limits = limits
        return admitAvailable()
    }

    @discardableResult
    public mutating func submit(_ request: AgentTaskSchedulerRequest) -> [UUID] {
        guard entries[request.id] == nil else { return [] }
        entries[request.id] = Entry(
            request: request,
            state: .queued,
            sequence: nextSequence,
            waitingRounds: 0,
            isApprovalResume: false,
            holdsExecutionSlot: false
        )
        nextSequence &+= 1
        return admitAvailable()
    }

    @discardableResult
    public mutating func finish(_ id: UUID) -> [UUID] {
        entries[id] = nil
        return admitAvailable()
    }

    @discardableResult
    public mutating func cancel(_ id: UUID) -> [UUID] {
        entries[id] = nil
        return admitAvailable()
    }

    @discardableResult
    public mutating func waitForApproval(_ id: UUID, releasesExecutionSlot: Bool) -> [UUID] {
        guard var entry = entries[id], entry.state == .running else { return [] }
        entry.state = .waitingForApproval
        entry.isApprovalResume = false
        entry.holdsExecutionSlot = !releasesExecutionSlot
        entries[id] = entry
        return releasesExecutionSlot ? admitAvailable() : []
    }

    /// Returns task IDs newly admitted. The resolving task is present only when capacity was acquired.
    @discardableResult
    public mutating func resolveApproval(_ id: UUID) -> [UUID] {
        guard var entry = entries[id], entry.state == .waitingForApproval else { return [] }
        entry.state = .queued
        entry.isApprovalResume = true
        entry.holdsExecutionSlot = false
        entry.sequence = nextSequence
        entry.waitingRounds = 0
        nextSequence &+= 1
        entries[id] = entry
        return admitAvailable()
    }

    @discardableResult
    public mutating func reprioritize(_ id: UUID, to priority: AgentTaskPriority) -> [UUID] {
        guard var entry = entries[id] else { return [] }
        entry.request.priority = priority
        entries[id] = entry
        return admitAvailable()
    }

    public func snapshot(for id: UUID) -> AgentTaskSchedulerSnapshot? {
        guard let entry = entries[id] else { return nil }
        return AgentTaskSchedulerSnapshot(
            request: entry.request,
            state: entry.state,
            queuePosition: queueOrder().firstIndex(of: id).map { $0 + 1 },
            isApprovalResume: entry.isApprovalResume
        )
    }

    public var snapshots: [AgentTaskSchedulerSnapshot] {
        entries.values
            .sorted { $0.sequence < $1.sequence }
            .compactMap { snapshot(for: $0.request.id) }
    }

    public var persistedMetadata: PersistedAgentTaskQueue {
        PersistedAgentTaskQueue(entries: entries.values
            .filter { $0.state != .recoveryHeld }
            .sorted { $0.sequence < $1.sequence }
            .map(\.request))
    }

    /// No recovered entry is executable. In particular, approval-sensitive and externally
    /// consequential work can never be replayed without a fresh user submission/approval flow.
    public mutating func recover(_ persisted: PersistedAgentTaskQueue) {
        guard persisted.version == 1 else { return }
        for request in persisted.entries where entries[request.id] == nil {
            entries[request.id] = Entry(
                request: request,
                state: .recoveryHeld,
                sequence: nextSequence,
                waitingRounds: 0,
                isApprovalResume: false,
                holdsExecutionSlot: false
            )
            nextSequence &+= 1
        }
    }

    public mutating func discardRecovered(_ id: UUID) {
        guard entries[id]?.state == .recoveryHeld else { return }
        entries[id] = nil
    }

    private mutating func admitAvailable() -> [UUID] {
        var admitted: [UUID] = []
        var considered = Set<UUID>()
        while runningCount < limits.global {
            let order = queueOrder()
            guard let id = order.first(where: { !considered.contains($0) && canAdmit($0) }) else { break }
            guard var entry = entries[id] else { break }
            entry.state = .running
            entry.waitingRounds = 0
            entry.holdsExecutionSlot = true
            entries[id] = entry
            admitted.append(id)
            considered.insert(id)
        }
        if !admitted.isEmpty {
            for id in entries.keys {
                guard var entry = entries[id], entry.state == .queued else { continue }
                entry.waitingRounds += 1
                entries[id] = entry
            }
        }
        return admitted
    }

    private var runningEntries: [Entry] { entries.values.filter(\.holdsExecutionSlot) }
    private var runningCount: Int { runningEntries.count }

    private func canAdmit(_ id: UUID) -> Bool {
        guard let candidate = entries[id], candidate.state == .queued else { return false }
        let running = runningEntries
        let resources = candidate.request.resources
        if running.filter({ $0.request.resources.workspaceID == resources.workspaceID }).count >= limits.perWorkspace { return false }
        if let cap = limits.providerCaps[resources.providerID],
           running.filter({ $0.request.resources.providerID == resources.providerID }).count >= cap { return false }
        if let cap = limits.routeCaps[resources.routeID],
           running.filter({ $0.request.resources.routeID == resources.routeID }).count >= cap { return false }
        return true
    }

    private func queueOrder() -> [UUID] {
        entries.values
            .filter { $0.state == .queued }
            .sorted { lhs, rhs in
                let lhsRank = lhs.request.priority.rawValue + min(2, lhs.waitingRounds / fairnessInterval)
                let rhsRank = rhs.request.priority.rawValue + min(2, rhs.waitingRounds / fairnessInterval)
                if lhsRank != rhsRank { return lhsRank > rhsRank }
                return lhs.sequence < rhs.sequence
            }
            .map { $0.request.id }
    }
}
