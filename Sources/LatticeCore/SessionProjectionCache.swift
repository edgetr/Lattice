import Foundation

/// Lightweight, transcript-free state used by high-frequency session navigation.
/// While a session is streaming, its ordering timestamp and preview stay fixed until the
/// terminal transition so token deltas do not rebuild or reorder the entire chat list.
public struct SessionListProjection: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: String
    public let workspacePath: String?
    public let isPinned: Bool
    public let lastUpdated: Date
    public let totalMessageCount: Int
    public let lastMessagePreview: String?
    public let routeMode: ConversationMode
    public let backendDisplayName: String
    public let isStreaming: Bool
    public let queuedCount: Int

    public init(session: LatticeSession) {
        id = session.id
        title = session.title
        workspacePath = session.workspacePath
        isPinned = session.isPinned
        lastUpdated = session.lastUpdated
        totalMessageCount = session.totalMessageCount
        lastMessagePreview = session.lastMessagePreview
        routeMode = session.executionRoute.mode
        backendDisplayName = session.backend.displayName
        isStreaming = session.isStreaming
        queuedCount = session.queuedFollowUps.count
    }

    fileprivate func preservingStreamingListIdentity(from previous: Self?) -> Self {
        guard isStreaming, previous?.isStreaming == true, let previous else { return self }
        return Self(
            id: id,
            title: title,
            workspacePath: workspacePath,
            isPinned: isPinned,
            lastUpdated: previous.lastUpdated,
            totalMessageCount: totalMessageCount,
            lastMessagePreview: previous.lastMessagePreview,
            routeMode: routeMode,
            backendDisplayName: backendDisplayName,
            isStreaming: isStreaming,
            queuedCount: queuedCount
        )
    }

    private init(
        id: UUID,
        title: String,
        workspacePath: String?,
        isPinned: Bool,
        lastUpdated: Date,
        totalMessageCount: Int,
        lastMessagePreview: String?,
        routeMode: ConversationMode,
        backendDisplayName: String,
        isStreaming: Bool,
        queuedCount: Int
    ) {
        self.id = id
        self.title = title
        self.workspacePath = workspacePath
        self.isPinned = isPinned
        self.lastUpdated = lastUpdated
        self.totalMessageCount = totalMessageCount
        self.lastMessagePreview = lastMessagePreview
        self.routeMode = routeMode
        self.backendDisplayName = backendDisplayName
        self.isStreaming = isStreaming
        self.queuedCount = queuedCount
    }
}

/// Retains row projections and their ordering across SwiftUI body evaluations. Refreshing with
/// unchanged row-visible metadata is a no-op, even when full session values are copied repeatedly.
public struct SessionProjectionCache: Sendable {
    private var projectionsByID: [UUID: SessionListProjection] = [:]
    private var orderedIDs: [UUID] = []
    public private(set) var rebuildCount = 0

    public init() {}

    @discardableResult
    public mutating func refresh(_ sessions: [LatticeSession]) -> [SessionListProjection] {
        var nextByID: [UUID: SessionListProjection] = [:]
        nextByID.reserveCapacity(sessions.count)
        for session in sessions {
            let projection = SessionListProjection(session: session)
                .preservingStreamingListIdentity(from: projectionsByID[session.id])
            nextByID[session.id] = projection
        }

        guard nextByID != projectionsByID else {
            return orderedIDs.compactMap { projectionsByID[$0] }
        }

        projectionsByID = nextByID
        orderedIDs = nextByID.values.sorted(by: Self.precedes).map(\.id)
        rebuildCount += 1
        return orderedIDs.compactMap { nextByID[$0] }
    }

    public mutating func orderedSessionIDs(for sessions: [LatticeSession]) -> [UUID] {
        refresh(sessions).map(\.id)
    }

    private static func precedes(_ lhs: SessionListProjection, _ rhs: SessionListProjection) -> Bool {
        if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
        if lhs.lastUpdated != rhs.lastUpdated { return lhs.lastUpdated > rhs.lastUpdated }
        let titleComparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if titleComparison != .orderedSame { return titleComparison == .orderedAscending }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
