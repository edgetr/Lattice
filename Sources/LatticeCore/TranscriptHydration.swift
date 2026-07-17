import Foundation

public struct TranscriptHydrationRequest: Hashable, Sendable {
    /// Unique identity for this exact hydration attempt. Storage references may repeat
    /// across A→B→A selection cycles and therefore cannot identify a generation.
    public let requestID: UUID
    public let sessionID: UUID
    public let storage: SessionTranscriptStorage?
    public let artifactStorage: SessionArtifactStorage?

    public init(
        requestID: UUID = UUID(),
        sessionID: UUID,
        storage: SessionTranscriptStorage?,
        artifactStorage: SessionArtifactStorage? = nil
    ) {
        self.requestID = requestID
        self.sessionID = sessionID
        self.storage = storage
        self.artifactStorage = artifactStorage
    }
}

public struct TranscriptHydrationContent: Sendable, Equatable {
    public let messages: [ChatMessage]
    public let artifacts: [AssistantArtifact]

    public init(messages: [ChatMessage], artifacts: [AssistantArtifact] = []) {
        self.messages = messages
        self.artifacts = artifacts
    }
}

public enum TranscriptHydrationLoadResult: Sendable {
    case loaded(TranscriptHydrationContent)
    case failed(DurableStoreIssue)
    case cancelled

    /// Compatibility constructor for transcript-only loaders.
    public static func loaded(_ messages: [ChatMessage]) -> TranscriptHydrationLoadResult {
        .loaded(TranscriptHydrationContent(messages: messages, artifacts: []))
    }
}

public enum TranscriptHydrationOutcome: Sendable {
    case loaded(TranscriptHydrationRequest, TranscriptHydrationContent)
    case failed(TranscriptHydrationRequest, DurableStoreIssue)
    case cancelled(TranscriptHydrationRequest)
}

public enum TranscriptHydrationApplyPolicy: Sendable {
    public static func shouldApply(
        request: TranscriptHydrationRequest,
        activeRequest: TranscriptHydrationRequest,
        selectedSessionID: UUID?,
        currentSession: LatticeSession
    ) -> Bool {
        guard activeRequest == request,
              selectedSessionID == request.sessionID,
              currentSession.id == request.sessionID,
              currentSession.transcriptStorage == request.storage else { return false }
        let canApplyTranscript = !currentSession.isTranscriptLoaded
            && !currentSession.isTranscriptDirty
            && currentSession.messages.isEmpty
        let canApplyArtifacts = currentSession.artifactStorage == request.artifactStorage
            && !currentSession.isArtifactsLoaded
            && !currentSession.isArtifactsDirty
            && currentSession.artifacts.isEmpty
        return canApplyTranscript || canApplyArtifacts
    }
}

/// Serializes selection hydration requests without performing file I/O on the caller's executor.
/// Every new request invalidates and cancels the previous generation, so a late A/B result cannot
/// become visible after the user has selected C.
public actor TranscriptHydrationCoordinator {
    public typealias Loader = @Sendable () async -> TranscriptHydrationLoadResult

    private var generation: UInt64 = 0
    private var activeTask: Task<TranscriptHydrationLoadResult, Never>?
    private var activeRequest: TranscriptHydrationRequest?

    public init() {}

    public func hydrate(
        _ request: TranscriptHydrationRequest,
        loader: @escaping Loader
    ) async -> TranscriptHydrationOutcome {
        generation &+= 1
        let requestGeneration = generation
        activeTask?.cancel()

        guard !Task.isCancelled else { return .cancelled(request) }
        let task = Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return TranscriptHydrationLoadResult.cancelled }
            let result = await loader()
            guard !Task.isCancelled else { return TranscriptHydrationLoadResult.cancelled }
            return result
        }
        activeTask = task
        activeRequest = request
        let result = await task.value

        guard requestGeneration == generation, !Task.isCancelled else {
            return .cancelled(request)
        }
        activeTask = nil
        activeRequest = nil
        switch result {
        case .loaded(let content):
            return .loaded(request, content)
        case .failed(let issue):
            return .failed(request, issue)
        case .cancelled:
            return .cancelled(request)
        }
    }

    public func cancel() {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        activeRequest = nil
    }

    /// Cancels only the named selection. A delayed cancellation task from A therefore cannot
    /// cancel a newer C request that has already entered the coordinator.
    public func cancel(_ request: TranscriptHydrationRequest) {
        guard activeRequest == request else { return }
        cancel()
    }
}

/// Access-order bookkeeping for clean, materialized transcripts. Dirty and running sessions are
/// protected by the caller and therefore are not considered disposable cache entries.
public struct TranscriptHydrationLRU: Sendable {
    public let maximumCount: Int
    private var accessOrder: [UUID] = []

    public init(maximumCount: Int) {
        self.maximumCount = max(1, maximumCount)
    }

    public var count: Int { accessOrder.count }
    public var orderedSessionIDs: [UUID] { accessOrder }

    public mutating func recordAccess(_ sessionID: UUID) {
        accessOrder.removeAll { $0 == sessionID }
        accessOrder.append(sessionID)
    }

    public func evictionCandidates(protectedIDs: Set<UUID> = []) -> [UUID] {
        let excess = max(0, accessOrder.count - maximumCount)
        guard excess > 0 else { return [] }
        return Array(accessOrder.lazy.filter { !protectedIDs.contains($0) }.prefix(excess))
    }

    public mutating func remove(_ sessionID: UUID) {
        accessOrder.removeAll { $0 == sessionID }
    }

    public mutating func removeAll() {
        accessOrder.removeAll(keepingCapacity: true)
    }
}

/// Drops only clean, sidecar-backed content. State flags are flipped before
/// clearing arrays so property observers cannot turn cache eviction into edits.
public enum TranscriptHydrationEvictionPolicy {
    @discardableResult
    public static func evictCleanContent(in session: inout LatticeSession) -> Bool {
        guard session.transcriptStorage != nil,
              session.isTranscriptLoaded,
              !session.isTranscriptDirty else { return false }

        session.isTranscriptLoaded = false
        session.messages = []
        session.isTranscriptDirty = false

        if session.artifactStorage != nil,
           session.isArtifactsLoaded,
           !session.isArtifactsDirty {
            session.isArtifactsLoaded = false
            session.artifacts = []
            session.isArtifactsDirty = false
        }
        return true
    }
}
