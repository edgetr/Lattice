import Foundation

public enum ThreadActivityStatus: String, Equatable, Sendable {
    case idle
    case queued
    case running
    case waitingForApproval
    case failed
    case completed
    case cancelled

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .queued: "Queued"
        case .running: "Running"
        case .waitingForApproval: "Waiting for approval"
        case .failed: "Failed"
        case .completed: "Completed"
        case .cancelled: "Cancelled"
        }
    }

    public var canCancel: Bool {
        self == .running || self == .waitingForApproval
    }
}

public struct ThreadActivityLane: Equatable, Sendable {
    public var status: ThreadActivityStatus
    public var queuedCount: Int
    public var hasUnreadActivity: Bool
    public var requiresAttention: Bool
    public var failureMessage: String?

    public init(
        status: ThreadActivityStatus = .idle,
        queuedCount: Int = 0,
        hasUnreadActivity: Bool = false,
        requiresAttention: Bool = false,
        failureMessage: String? = nil
    ) {
        self.status = status
        self.queuedCount = max(0, queuedCount)
        self.hasUnreadActivity = hasUnreadActivity
        self.requiresAttention = requiresAttention
        self.failureMessage = failureMessage
    }
}

public enum ThreadActivityAction: Equatable, Sendable {
    case queued(Int)
    case started
    case approvalRequested
    case approvalResolved
    case completed
    case failed(String)
    case cancelled
    case attentionHandled
}

/// In-memory ownership for independent thread activity. Transcript persistence remains the
/// authority for durable messages/actions; this store owns only lightweight presentation state.
public struct ThreadActivityLaneStore: Equatable, Sendable {
    public private(set) var selectedSessionID: UUID?
    public private(set) var lanes: [UUID: ThreadActivityLane]

    public init(selectedSessionID: UUID? = nil, lanes: [UUID: ThreadActivityLane] = [:]) {
        self.selectedSessionID = selectedSessionID
        self.lanes = lanes
    }

    public func lane(for sessionID: UUID) -> ThreadActivityLane {
        lanes[sessionID] ?? ThreadActivityLane()
    }

    public mutating func select(_ sessionID: UUID?) {
        selectedSessionID = sessionID
        guard let sessionID, var lane = lanes[sessionID] else { return }
        lane.hasUnreadActivity = false
        lanes[sessionID] = lane
    }

    public mutating func remove(_ sessionID: UUID) {
        lanes[sessionID] = nil
        if selectedSessionID == sessionID { selectedSessionID = nil }
    }

    public mutating func apply(_ action: ThreadActivityAction, to sessionID: UUID) {
        var lane = lanes[sessionID] ?? ThreadActivityLane()
        let isSelected = selectedSessionID == sessionID

        switch action {
        case .queued(let count):
            lane.queuedCount = max(0, count)
            if lane.status == .idle || lane.status == .queued {
                lane.status = lane.queuedCount > 0 ? .queued : .idle
            }
        case .started:
            lane.status = .running
            lane.requiresAttention = false
            lane.failureMessage = nil
        case .approvalRequested:
            lane.status = .waitingForApproval
            lane.requiresAttention = true
            lane.hasUnreadActivity = !isSelected
        case .approvalResolved:
            lane.status = .running
            lane.requiresAttention = false
        case .completed:
            lane.status = lane.queuedCount > 0 ? .queued : .completed
            lane.requiresAttention = false
            lane.failureMessage = nil
            lane.hasUnreadActivity = !isSelected
        case .failed(let message):
            lane.status = .failed
            lane.requiresAttention = true
            lane.failureMessage = message
            lane.hasUnreadActivity = !isSelected
        case .cancelled:
            lane.status = .cancelled
            lane.requiresAttention = false
            lane.failureMessage = nil
            lane.hasUnreadActivity = !isSelected
        case .attentionHandled:
            if lane.status != .waitingForApproval { lane.requiresAttention = false }
            lane.hasUnreadActivity = false
        }

        lanes[sessionID] = lane
    }
}
