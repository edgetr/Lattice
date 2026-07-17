import Foundation
import Darwin

public enum SessionIndexWarningKind: String, Sendable, Equatable {
    case corrupt
    case unreadable
    case oversized
    case repairFailed
    case repairDeferred
    case staleManifest
}

public struct SessionIndexWarning: Sendable, Equatable {
    public let kind: SessionIndexWarningKind
    public let filePath: String
    public let details: String

    public init(kind: SessionIndexWarningKind, filePath: String, details: String) {
        self.kind = kind
        self.filePath = filePath
        self.details = details
    }
}

public struct LazySessionLoad: Sendable {
    public var sessions: [LatticeSession]
    public var searchIndex: SessionSearchIndex
    public let usesLegacyMonolithicStore: Bool
    public let indexWarning: SessionIndexWarning?

    public init(
        sessions: [LatticeSession],
        searchIndex: SessionSearchIndex,
        usesLegacyMonolithicStore: Bool,
        indexWarning: SessionIndexWarning? = nil
    ) {
        self.sessions = sessions
        self.searchIndex = searchIndex
        self.usesLegacyMonolithicStore = usesLegacyMonolithicStore
        self.indexWarning = indexWarning
    }
}

public struct SessionPersistenceLoadError: Error, LocalizedError, Sendable {
    public let issue: DurableStoreIssue

    public init(issue: DurableStoreIssue) {
        self.issue = issue
    }

    public var errorDescription: String? {
        issue.summary + " " + issue.technicalDetails
    }
}

public enum SessionPersistenceConflictError: Error, LocalizedError, Sendable, Equatable {
    case existingStoreRequiresLoad(path: String)
    case staleWriter(path: String)

    public var errorDescription: String? {
        switch self {
        case .existingStoreRequiresLoad(let path):
            "The session store already exists at \(path). Load it before saving."
        case .staleWriter(let path):
            "The session store changed since this writer observed it: \(path). Reload and retry."
        }
    }
}

public enum SessionPersistenceStorageError: Error, LocalizedError, Sendable, Equatable {
    case oversized(path: String, byteCount: Int, maximumByteCount: Int)

    public var errorDescription: String? {
        switch self {
        case .oversized(let path, let byteCount, let maximumByteCount):
            "The session payload at \(path) is \(byteCount) bytes; the limit is \(maximumByteCount) bytes."
        }
    }
}

private struct SessionStorePaths: Sendable {
    let root: URL
    let manifest: URL
    let searchIndex: URL
    let transcripts: URL
    let artifacts: URL
}

private enum SessionSidecarKind: Sendable {
    case transcript(messageCount: Int, fingerprint: String)
    case artifacts(artifactCount: Int, fingerprint: String)
}

private enum SessionPersistenceWritePublication: Sendable {
    case unknown
}

private enum SessionManifestRevision: Sendable, Equatable {
    case unobserved
    case missing
    case fingerprint(String)
}

private final class SessionManifestRevisionState: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: SessionManifestRevision = .unobserved

    func snapshot() -> SessionManifestRevision {
        lock.lock(); defer { lock.unlock() }
        return revision
    }

    func record(_ revision: SessionManifestRevision) {
        lock.lock()
        self.revision = revision
        lock.unlock()
    }
}

private enum SessionIndexLoadOutcome {
    case missing
    case loaded(SessionSearchIndex)
    case unavailable(SessionIndexWarning)
}

private struct SessionPersistenceWriteError: Error, LocalizedError, Sendable {
    let operation: String
    let publication: SessionPersistenceWritePublication
    let underlying: String

    var errorDescription: String? {
        "The " + operation + " write could not be confirmed: " + underlying
    }
}

public struct SessionPersistence: Sendable {
    public static let storeID = "sessions"
    public static let storeName = "Chat sessions"
    public static let fileName = "sessions.json"
    public static let transcriptDirectoryName = "session-transcripts"
    public static let artifactDirectoryName = "session-artifacts"
    public static let searchIndexFileName = "sessions.search-index.json"

    public let fileURL: URL
    public let writeGate: DurableStoreWriteGate
    public let io: DurableStoreFileIO
    private let revisionState: SessionManifestRevisionState

    public var transcriptDirectoryURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(Self.transcriptDirectoryName, isDirectory: true)
    }
    public var artifactDirectoryURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(Self.artifactDirectoryName, isDirectory: true)
    }
    public var searchIndexURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(Self.searchIndexFileName)
    }

    public init(
        fileURL: URL? = nil,
        writeGate: DurableStoreWriteGate = DurableStoreWriteGate(),
        io: DurableStoreFileIO = .default
    ) {
        self.writeGate = writeGate
        self.io = io
        self.revisionState = SessionManifestRevisionState()
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        if let overridePath = LatticeApplicationSupport.sessionStoreOverridePath() {
            self.fileURL = URL(fileURLWithPath: overridePath)
            return
        }
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        self.fileURL = LatticeApplicationSupport.productRootURL().appendingPathComponent(Self.fileName)
    }

    /// Loads session metadata and a privacy-safe derived index. Split-store transcripts stay on
    /// disk until `materializeTranscript` is called. Legacy stores remain readable and are split
    /// on the next normal save.
    public func loadLazyResult() -> DurableStoreLoadResult<LazySessionLoad> {
        writeGate.withExclusiveWrite {
            do {
                return try withProcessLock { paths in
                    loadLazyLocked(paths: paths)
                }
            } catch {
                return .failed(manifestIssue(for: error, path: fileURL.path))
            }
        }
    }

    /// Evidence-rich compatibility load. This intentionally materializes every transcript for
    /// archive/tests/legacy callers; production AppState uses `loadLazyResult()`.
    public func loadResult() -> DurableStoreLoadResult<[LatticeSession]> {
        writeGate.withExclusiveWrite {
            do {
                return try withProcessLock { paths in
                    switch loadLazyLocked(paths: paths) {
                    case .missing:
                        return .missing
                    case .failed(let issue):
                        return .failed(issue)
                    case .loaded(let snapshot):
                        var sessions = snapshot.sessions
                        do {
                            for index in sessions.indices {
                                try materializeTranscript(in: &sessions[index], paths: paths)
                                sessions[index].transcriptStorage = nil
                                try materializeArtifacts(in: &sessions[index], paths: paths)
                                sessions[index].artifactStorage = nil
                            }
                            return .loaded(Self.restoreRuntimeState(sessions))
                        } catch {
                            return .failed(issue(
                                for: error,
                                path: transcriptPath(from: error)
                                    ?? artifactPath(from: error)
                                    ?? paths.transcripts.path
                            ))
                        }
                    }
                }
            } catch {
                return .failed(manifestIssue(for: error, path: fileURL.path))
            }
        }
    }

    public func load() throws -> [LatticeSession] {
        switch loadResult() {
        case .missing:
            return []
        case .loaded(let sessions):
            return sessions
        case .failed(let issue):
            throw SessionPersistenceLoadError(issue: issue)
        }
    }

    public func materializeTranscript(in session: inout LatticeSession) throws {
        try withProcessLock { paths in
            try materializeTranscript(in: &session, paths: paths)
        }
    }

    /// Lazy materialization for the split artifact metadata store. Metadata only — never copies image bytes.
    public func materializeArtifacts(in session: inout LatticeSession) throws {
        try withProcessLock { paths in
            try materializeArtifacts(in: &session, paths: paths)
        }
    }

    /// Evidence-rich transcript + artifact metadata read used by asynchronous selection hydration.
    public func hydrationResult(for session: LatticeSession) -> TranscriptHydrationLoadResult {
        var materialized = session
        do {
            try materializeSessionContent(in: &materialized)
            return .loaded(TranscriptHydrationContent(
                messages: materialized.messages,
                artifacts: materialized.artifacts
            ))
        } catch {
            return .failed(issueForTranscriptError(error))
        }
    }

    /// Materialize transcript and artifact sidecars for selection hydration.
    public func materializeSessionContent(in session: inout LatticeSession) throws {
        try withProcessLock { paths in
            try materializeTranscript(in: &session, paths: paths)
            try materializeArtifacts(in: &session, paths: paths)
        }
    }

    private func loadLazyLocked(paths: SessionStorePaths) -> DurableStoreLoadResult<LazySessionLoad> {
        switch DurableStoreRecovery.loadJSONArray(
            from: paths.manifest,
            as: LatticeSession.self,
            storeID: Self.storeID,
            storeName: Self.storeName,
            io: io
        ) {
        case .missing:
            revisionState.record(.missing)
            return .missing
        case .failed(let issue):
            return .failed(issue)
        case .loaded(let decoded):
            let observedRevision: SessionManifestRevision
            do {
                observedRevision = try manifestRevision(at: paths.manifest)
            } catch {
                return .failed(manifestIssue(for: error, path: paths.manifest.path))
            }
            guard case .fingerprint = observedRevision else {
                return .failed(manifestIssue(
                    for: SessionPersistenceConflictError.staleWriter(path: paths.manifest.path),
                    path: paths.manifest.path
                ))
            }
            revisionState.record(observedRevision)

            let restored = Self.restoreRuntimeState(decoded)
            let usesLegacy = restored.contains { $0.transcriptStorage == nil }
            let indexOutcome = loadSearchIndex(paths: paths)
            var index: SessionSearchIndex
            let indexWasTrusted: Bool
            var unavailableIndexWarning: SessionIndexWarning?
            switch indexOutcome {
            case .loaded(let loaded):
                index = loaded
                indexWasTrusted = true
            case .missing:
                index = SessionSearchIndex()
                indexWasTrusted = false
            case .unavailable(let warning):
                index = SessionSearchIndex()
                indexWasTrusted = false
                unavailableIndexWarning = warning
            }
            index.retainValidEntries(for: restored)
            let needsIndexRepair = !indexWasTrusted
                || restored.contains { !index.containsValidEntry(for: $0) }

            do {
                for session in restored where !index.containsValidEntry(for: session) {
                    var materialized = session
                    try materializeTranscript(in: &materialized, paths: paths)
                    index.update(session: materialized)
                }
            } catch {
                return .failed(issue(
                    for: error,
                    path: transcriptPath(from: error) ?? paths.transcripts.path
                ))
            }

            guard index.indexedSessionIDs == Set(restored.map(\.id)) else {
                return conservativeLazyLoad(
                    sessions: restored,
                    usesLegacy: usesLegacy,
                    warning: SessionIndexWarning(
                        kind: .repairFailed,
                        filePath: paths.searchIndex.path,
                        details: "The rebuilt index did not cover every durable session."
                    )
                )
            }

            guard needsIndexRepair else {
                return .loaded(LazySessionLoad(
                    sessions: restored,
                    searchIndex: index,
                    usesLegacyMonolithicStore: usesLegacy
                ))
            }

            if LatticeStorePathSecurity.entryExistsWithoutFollowingSymlinks(at: paths.searchIndex),
               !LatticeStorePathSecurity.isRegularFileWithoutFollowingSymlinks(at: paths.searchIndex) {
                return conservativeLazyLoad(
                    sessions: restored,
                    usesLegacy: usesLegacy,
                    warning: unavailableIndexWarning ?? SessionIndexWarning(
                        kind: .unreadable,
                        filePath: paths.searchIndex.path,
                        details: "The derived index path is not a regular file."
                    )
                )
            }

            guard !writeGate.isBlocked else {
                return conservativeLazyLoad(
                    sessions: restored,
                    usesLegacy: usesLegacy,
                    warning: SessionIndexWarning(
                        kind: .repairDeferred,
                        filePath: paths.searchIndex.path,
                        details: "Index repair was deferred while durable-store recovery blocks writes."
                    )
                )
            }

            do {
                let currentRevision = try manifestRevision(at: paths.manifest)
                guard currentRevision == observedRevision else {
                    revisionState.record(currentRevision)
                    return conservativeLazyLoad(
                        sessions: restored,
                        usesLegacy: usesLegacy,
                        warning: SessionIndexWarning(
                            kind: .staleManifest,
                            filePath: paths.searchIndex.path,
                            details: "The session manifest changed while its derived index was rebuilding."
                        )
                    )
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try writeDataAtomicallyConfirmed(
                    encoder.encode(index),
                    to: paths.searchIndex,
                    operation: "session search index"
                )
                return .loaded(LazySessionLoad(
                    sessions: restored,
                    searchIndex: index,
                    usesLegacyMonolithicStore: usesLegacy
                ))
            } catch {
                return conservativeLazyLoad(
                    sessions: restored,
                    usesLegacy: usesLegacy,
                    warning: SessionIndexWarning(
                        kind: .repairFailed,
                        filePath: paths.searchIndex.path,
                        details: String(reflecting: error)
                    )
                )
            }
        }
    }

    private func conservativeLazyLoad(
        sessions: [LatticeSession],
        usesLegacy: Bool,
        warning: SessionIndexWarning
    ) -> DurableStoreLoadResult<LazySessionLoad> {
        .loaded(LazySessionLoad(
            sessions: sessions,
            searchIndex: SessionSearchIndex(),
            usesLegacyMonolithicStore: usesLegacy,
            indexWarning: warning
        ))
    }

    private func materializeTranscript(
        in session: inout LatticeSession,
        paths: SessionStorePaths
    ) throws {
        guard !session.isTranscriptLoaded, let storage = session.transcriptStorage else { return }
        try validateTranscriptReference(storage, sessionID: session.id)
        let url = paths.transcripts.appendingPathComponent(storage.fileName)
        do {
            try ensureSafeExistingRegularFile(at: url)
            let data = try io.readDataUpTo(url, DurableStoreRecovery.maximumStoreByteCount)
            try enforceSizeLimit(data, at: url)
            guard DurableStoreRecovery.contentFingerprint(for: data) == storage.contentFingerprint else {
                throw SessionTranscriptStoreError.fingerprintMismatch(url.path)
            }
            let messages = try JSONDecoder().decode([ChatMessage].self, from: data)
            guard messages.count == storage.messageCount else {
                throw SessionTranscriptStoreError.countMismatch(url.path)
            }
            session.messages = messages
            session.isTranscriptLoaded = true
            session.isTranscriptDirty = false
        } catch let error as SessionTranscriptStoreError {
            throw error
        } catch let error as SessionPersistenceStorageError {
            if case .oversized(_, let byteCount, let maximumByteCount) = error {
                throw SessionTranscriptStoreError.oversized(url.path, byteCount, maximumByteCount)
            }
            throw error
        } catch let error as LatticeStorePathError {
            if case .oversized = error {
                throw SessionTranscriptStoreError.oversized(
                    url.path,
                    DurableStoreRecovery.maximumStoreByteCount + 1,
                    DurableStoreRecovery.maximumStoreByteCount
                )
            }
            throw SessionTranscriptStoreError.unreadable(url.path, String(reflecting: error))
        } catch {
            throw SessionTranscriptStoreError.unreadable(url.path, String(reflecting: error))
        }
    }

    private func materializeArtifacts(
        in session: inout LatticeSession,
        paths: SessionStorePaths
    ) throws {
        guard !session.isArtifactsLoaded else { return }
        guard let storage = session.artifactStorage else {
            session.artifacts = []
            session.isArtifactsLoaded = true
            session.isArtifactsDirty = false
            return
        }
        try validateArtifactReference(storage, sessionID: session.id)
        let url = paths.artifacts.appendingPathComponent(storage.fileName)
        do {
            try ensureSafeExistingRegularFile(at: url)
            let data = try io.readDataUpTo(url, DurableStoreRecovery.maximumStoreByteCount)
            try enforceSizeLimit(data, at: url)
            guard DurableStoreRecovery.contentFingerprint(for: data) == storage.contentFingerprint else {
                throw SessionArtifactStoreError.fingerprintMismatch(url.path)
            }
            let artifacts = try JSONDecoder().decode([AssistantArtifact].self, from: data)
            guard artifacts.count == storage.artifactCount else {
                throw SessionArtifactStoreError.countMismatch(url.path)
            }
            session.artifacts = artifacts
            session.isArtifactsLoaded = true
            session.isArtifactsDirty = false
        } catch let error as SessionArtifactStoreError {
            throw error
        } catch let error as SessionPersistenceStorageError {
            if case .oversized(_, let byteCount, let maximumByteCount) = error {
                throw SessionArtifactStoreError.oversized(url.path, byteCount, maximumByteCount)
            }
            throw error
        } catch let error as LatticeStorePathError {
            if case .oversized = error {
                throw SessionArtifactStoreError.oversized(
                    url.path,
                    DurableStoreRecovery.maximumStoreByteCount + 1,
                    DurableStoreRecovery.maximumStoreByteCount
                )
            }
            throw SessionArtifactStoreError.unreadable(url.path, String(reflecting: error))
        } catch {
            throw SessionArtifactStoreError.unreadable(url.path, String(reflecting: error))
        }
    }

    public static func storageReference(sessionID: UUID, messages: [ChatMessage]) throws -> SessionTranscriptStorage {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(messages)
        guard data.count <= DurableStoreRecovery.maximumStoreByteCount else {
            throw SessionPersistenceStorageError.oversized(
                path: "transcript sidecar",
                byteCount: data.count,
                maximumByteCount: DurableStoreRecovery.maximumStoreByteCount
            )
        }
        let fingerprint = DurableStoreRecovery.contentFingerprint(for: data)
        return SessionTranscriptStorage(
            fileName: Self.sidecarFileName(sessionID: sessionID, fingerprint: fingerprint),
            messageCount: messages.count,
            contentFingerprint: fingerprint,
            lastMessagePreview: Self.preview(from: messages.last?.text)
        )
    }

    public static func artifactStorageReference(sessionID: UUID, artifacts: [AssistantArtifact]) throws -> SessionArtifactStorage {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(artifacts)
        guard data.count <= DurableStoreRecovery.maximumStoreByteCount else {
            throw SessionPersistenceStorageError.oversized(
                path: "artifact sidecar",
                byteCount: data.count,
                maximumByteCount: DurableStoreRecovery.maximumStoreByteCount
            )
        }
        let fingerprint = DurableStoreRecovery.contentFingerprint(for: data)
        return SessionArtifactStorage(
            fileName: Self.sidecarFileName(sessionID: sessionID, fingerprint: fingerprint),
            artifactCount: artifacts.count,
            contentFingerprint: fingerprint
        )
    }

    public func save(_ sessions: [LatticeSession]) throws {
        // Capture before waiting for the write gate. Concurrent calls through copied values
        // therefore carry the same optimistic revision; only the first may publish.
        let expectedRevision = revisionState.snapshot()
        try writeGate.withExclusiveWrite {
            try saveUnlocked(sessions, expectedRevision: expectedRevision)
        }
    }

    private func saveUnlocked(
        _ sessions: [LatticeSession],
        expectedRevision: SessionManifestRevision
    ) throws {
        try DurableStoreRecovery.enforceWritable(gate: writeGate, storeName: Self.storeName)
        try withProcessLock { paths in
            try io.createDirectory(paths.root)
            try validateSidecarDirectory(paths.transcripts, under: paths.root)
            try validateSidecarDirectory(paths.artifacts, under: paths.root)
            let currentRevision = try manifestRevision(at: paths.manifest)
            try validateExpectedRevision(
                expectedRevision,
                current: currentRevision,
                path: paths.manifest.path
            )

            // Sidecars are written before the derived index and manifest. If either later
            // commit fails, the previous manifest remains authoritative; remove only sidecars
            // created by this attempt so failed saves cannot accumulate unreachable files.
            var newlyCreatedSidecars = Set<URL>()
            var saveSucceeded = false
            var preserveSidecarsOnFailure = false
            defer {
                if !saveSucceeded && !preserveSidecarsOnFailure {
                    removeNewlyCreatedSidecars(newlyCreatedSidecars)
                }
            }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            var storedSessions: [LatticeSession] = []
            storedSessions.reserveCapacity(sessions.count)
            var searchIndex: SessionSearchIndex
            if case .loaded(let loadedIndex) = loadSearchIndex(paths: paths) {
                searchIndex = loadedIndex
            } else {
                searchIndex = SessionSearchIndex()
            }
            searchIndex.retainValidEntries(for: sessions)

            for session in sessions {
                var stored = session
                var validatedLazyTranscript: LatticeSession?
                if session.isTranscriptLoaded {
                    let transcriptEncoder = JSONEncoder()
                    transcriptEncoder.outputFormatting = [.sortedKeys]
                    let data = try transcriptEncoder.encode(session.messages)
                    let fingerprint = DurableStoreRecovery.contentFingerprint(for: data)
                    let reference = SessionTranscriptStorage(
                        fileName: Self.sidecarFileName(sessionID: session.id, fingerprint: fingerprint),
                        messageCount: session.messages.count,
                        contentFingerprint: fingerprint,
                        lastMessagePreview: Self.preview(from: session.messages.last?.text)
                    )
                    let transcriptURL = paths.transcripts.appendingPathComponent(reference.fileName)
                    try writeNewSidecarIfNeeded(
                        data,
                        to: transcriptURL,
                        kind: .transcript(messageCount: session.messages.count, fingerprint: fingerprint),
                        tracking: &newlyCreatedSidecars
                    )
                    stored.transcriptStorage = reference
                    searchIndex.update(session: session)
                } else {
                    guard stored.transcriptStorage != nil else {
                        throw SessionTranscriptStoreError.unloadedWithoutReference(session.id)
                    }
                    // Every lazy reference is proven against durable bytes before a manifest
                    // containing it may publish, even when the derived index claims validity.
                    var materialized = stored
                    try materializeTranscript(in: &materialized, paths: paths)
                    validatedLazyTranscript = materialized
                }

                if session.isArtifactsLoaded, !session.artifacts.isEmpty {
                    let artifactEncoder = JSONEncoder()
                    artifactEncoder.outputFormatting = [.sortedKeys]
                    let data = try artifactEncoder.encode(session.artifacts)
                    let fingerprint = DurableStoreRecovery.contentFingerprint(for: data)
                    let reference = SessionArtifactStorage(
                        fileName: Self.sidecarFileName(sessionID: session.id, fingerprint: fingerprint),
                        artifactCount: session.artifacts.count,
                        contentFingerprint: fingerprint
                    )
                    let artifactURL = paths.artifacts.appendingPathComponent(reference.fileName)
                    try writeNewSidecarIfNeeded(
                        data,
                        to: artifactURL,
                        kind: .artifacts(artifactCount: session.artifacts.count, fingerprint: fingerprint),
                        tracking: &newlyCreatedSidecars
                    )
                    stored.artifactStorage = reference
                } else if session.isArtifactsLoaded {
                    stored.artifactStorage = nil
                } else if let artifactStorage = stored.artifactStorage {
                    try validateArtifactReference(artifactStorage, sessionID: session.id)
                    var materialized = stored
                    try materializeArtifacts(in: &materialized, paths: paths)
                } else if !session.artifacts.isEmpty {
                    throw SessionArtifactStoreError.unloadedWithoutReference(session.id)
                }

                if !searchIndex.containsValidEntry(for: stored) {
                    if let materialized = validatedLazyTranscript {
                        searchIndex.update(session: materialized)
                    } else {
                        var materialized = stored
                        try materializeTranscript(in: &materialized, paths: paths)
                        searchIndex.update(session: materialized)
                    }
                }
                stored.messages = []
                stored.isTranscriptLoaded = false
                stored.artifacts = []
                stored.isArtifactsLoaded = false
                storedSessions.append(stored)
            }

            let indexData = try encoder.encode(searchIndex)
            let manifestData = try encoder.encode(storedSessions)
            try enforceSizeLimit(indexData, at: paths.searchIndex)
            try enforceSizeLimit(manifestData, at: paths.manifest)

            // Derived index may be discarded and rebuilt; durable manifest is committed last.
            try writeDataAtomicallyConfirmed(
                indexData,
                to: paths.searchIndex,
                operation: "session search index"
            )
            do {
                try writeDataAtomicallyConfirmed(
                    manifestData,
                    to: paths.manifest,
                    operation: "session manifest"
                )
            } catch let error as SessionPersistenceWriteError {
                // Every thrown mismatch is ambiguous. Retaining sidecars is safer than deleting
                // files that a published-but-unconfirmed manifest may reference.
                preserveSidecarsOnFailure = error.publication == .unknown
                throw error
            }
            revisionState.record(.fingerprint(DurableStoreRecovery.contentFingerprint(for: manifestData)))
            removeOrphanedTranscripts(
                keeping: Set(storedSessions.compactMap { $0.transcriptStorage?.fileName }),
                in: paths.transcripts
            )
            removeOrphanedArtifacts(
                keeping: Set(storedSessions.compactMap { $0.artifactStorage?.fileName }),
                in: paths.artifacts
            )
            saveSucceeded = true
        }
    }

    private func withProcessLock<T>(_ body: (SessionStorePaths) throws -> T) throws -> T {
        let paths = try resolvedStorePaths()
        // Resolve aliases before choosing the lock path so two callers addressing the same
        // manifest through a parent symlink still share one process lock. All save IO below
        // uses these canonical paths rather than the caller's alias.
        // The manifest override still shares the fixed index and sidecar directories, so every
        // session-store filename in one root must coordinate through the same lock.
        let lockURL = paths.root.appendingPathComponent(Self.fileName + ".lock")
        let lock = try SessionPersistenceProcessLock(
            rootURL: paths.root,
            fileName: lockURL.lastPathComponent
        )
        try lock.lockExclusive()
        defer { lock.unlock() }
        try lock.validateRootStillAddressed(at: paths.root)
        return try body(paths)
    }

    private func writeNewSidecarIfNeeded(
        _ data: Data,
        to url: URL,
        kind: SessionSidecarKind,
        tracking newlyCreatedSidecars: inout Set<URL>
    ) throws {
        try enforceSizeLimit(data, at: url)
        let existed = LatticeStorePathSecurity.entryExistsWithoutFollowingSymlinks(at: url)
        if existed, sidecarMatches(data: data, at: url, kind: kind) {
            return
        }
        if !existed {
            // Record the absent-before-write state before invoking injected I/O. This also
            // lets us clean up a test/disk implementation that creates the file then throws.
            newlyCreatedSidecars.insert(url)
        }
        try writeDataAtomicallyConfirmed(data, to: url, operation: "session sidecar")
    }

    private func sidecarMatches(data expected: Data, at url: URL, kind: SessionSidecarKind) -> Bool {
        guard (try? ensureSafeExistingRegularFile(at: url)) != nil,
              let actual = try? io.readDataUpTo(url, DurableStoreRecovery.maximumStoreByteCount),
              actual.count <= DurableStoreRecovery.maximumStoreByteCount,
              actual == expected else { return false }
        return validatesSidecar(actual, kind: kind)
    }

    private func validatesSidecar(_ data: Data, kind: SessionSidecarKind) -> Bool {
        switch kind {
        case .transcript(let messageCount, let fingerprint):
            guard DurableStoreRecovery.contentFingerprint(for: data) == fingerprint,
                  let messages = try? JSONDecoder().decode([ChatMessage].self, from: data) else {
                return false
            }
            return messages.count == messageCount
        case .artifacts(let artifactCount, let fingerprint):
            guard DurableStoreRecovery.contentFingerprint(for: data) == fingerprint,
                  let artifacts = try? JSONDecoder().decode([AssistantArtifact].self, from: data) else {
                return false
            }
            return artifacts.count == artifactCount
        }
    }

    private func validateTranscriptReference(
        _ storage: SessionTranscriptStorage,
        sessionID: UUID
    ) throws {
        guard Self.isLowercaseSHA256(storage.contentFingerprint),
              storage.fileName == Self.sidecarFileName(
                sessionID: sessionID,
                fingerprint: storage.contentFingerprint
              ) else {
            throw SessionTranscriptStoreError.invalidReference(storage.fileName)
        }
    }

    private func validateArtifactReference(
        _ storage: SessionArtifactStorage,
        sessionID: UUID
    ) throws {
        guard Self.isLowercaseSHA256(storage.contentFingerprint),
              storage.fileName == Self.sidecarFileName(
                sessionID: sessionID,
                fingerprint: storage.contentFingerprint
              ) else {
            throw SessionArtifactStoreError.invalidReference(storage.fileName)
        }
    }

    private static func sidecarFileName(sessionID: UUID, fingerprint: String) -> String {
        "\(sessionID.uuidString.lowercased())-\(fingerprint.prefix(16)).json"
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    private func writeDataAtomicallyConfirmed(_ data: Data, to url: URL, operation: String) throws {
        try enforceSizeLimit(data, at: url)
        do {
            try io.writeDataAtomically(data, url)
        } catch let error {
            if let pathError = error as? LatticeStorePathError,
               case .publishedButDurabilityUnconfirmed = pathError {
                throw SessionPersistenceWriteError(
                    operation: operation,
                    publication: .unknown,
                    underlying: String(reflecting: error)
                )
            }
            if let current = try? io.readDataUpTo(url, DurableStoreRecovery.maximumStoreByteCount),
               current == data {
                // Some filesystem adapters report an error after publishing. Exact-byte
                // confirmation makes that outcome a successful commit unless the adapter
                // explicitly reported that the published bytes were not durably synced.
                return
            }
            throw SessionPersistenceWriteError(
                operation: operation,
                publication: .unknown,
                underlying: String(reflecting: error)
            )
        }

        guard let current = try? io.readDataUpTo(url, DurableStoreRecovery.maximumStoreByteCount),
              current == data else {
            throw SessionPersistenceWriteError(
                operation: operation,
                publication: .unknown,
                underlying: "The published bytes did not match the intended payload."
            )
        }
    }

    private func removeNewlyCreatedSidecars(_ urls: Set<URL>) {
        for url in urls {
            try? LatticeStorePathSecurity.removeRegularFileWithoutFollowingSymlinks(at: url)
        }
    }

    private func enforceSizeLimit(_ data: Data, at url: URL) throws {
        guard data.count <= DurableStoreRecovery.maximumStoreByteCount else {
            throw SessionPersistenceStorageError.oversized(
                path: url.path,
                byteCount: data.count,
                maximumByteCount: DurableStoreRecovery.maximumStoreByteCount
            )
        }
    }

    private func manifestRevision(at url: URL) throws -> SessionManifestRevision {
        guard io.fileExists(url.path) else { return .missing }
        try ensureSafeExistingRegularFile(at: url)
        let data = try io.readDataUpTo(url, DurableStoreRecovery.maximumStoreByteCount)
        try enforceSizeLimit(data, at: url)
        return .fingerprint(DurableStoreRecovery.contentFingerprint(for: data))
    }

    private func validateExpectedRevision(
        _ expected: SessionManifestRevision,
        current: SessionManifestRevision,
        path: String
    ) throws {
        switch expected {
        case .unobserved:
            guard current == .missing else {
                throw SessionPersistenceConflictError.existingStoreRequiresLoad(path: path)
            }
        case .missing:
            guard current == .missing else {
                throw SessionPersistenceConflictError.staleWriter(path: path)
            }
        case .fingerprint:
            guard current == expected else {
                throw SessionPersistenceConflictError.staleWriter(path: path)
            }
        }
    }

    private func ensureSafeExistingRegularFile(at url: URL) throws {
        if LatticeStorePathSecurity.entryExistsWithoutFollowingSymlinks(at: url),
           !LatticeStorePathSecurity.isRegularFileWithoutFollowingSymlinks(at: url) {
            throw LatticeStorePathError.notRegularFile(url)
        }
    }

    private func resolvedStorePaths() throws -> SessionStorePaths {
        let root = try LatticeStorePathSecurity.canonicalDirectory(
            at: fileURL.deletingLastPathComponent()
        )
        let manifestName = fileURL.lastPathComponent
        guard !manifestName.isEmpty,
              manifestName == URL(fileURLWithPath: manifestName).lastPathComponent,
              manifestName != ".",
              manifestName != ".." else {
            throw LatticeStorePathError.invalidPath(fileURL)
        }
        if let manifest = try LatticeStorePathSecurity.existingEntry(named: manifestName, under: root),
           !LatticeStorePathSecurity.isRegularFileWithoutFollowingSymlinks(at: manifest) {
            throw LatticeStorePathError.notRegularFile(manifest)
        }

        let paths = SessionStorePaths(
            root: root,
            manifest: root.appendingPathComponent(manifestName),
            searchIndex: root.appendingPathComponent(Self.searchIndexFileName),
            transcripts: root.appendingPathComponent(Self.transcriptDirectoryName, isDirectory: true),
            artifacts: root.appendingPathComponent(Self.artifactDirectoryName, isDirectory: true)
        )
        // Validate pre-existing derived paths before any injected adapter can follow a
        // swapped symlink. Missing children are created by the adapter and revalidated below.
        try validateExistingDirectory(paths.transcripts, under: root)
        try validateExistingDirectory(paths.artifacts, under: root)
        return paths
    }

    private func validateExistingDirectory(_ url: URL, under root: URL) throws {
        _ = try LatticeStorePathSecurity.existingChildDirectory(
            named: url.lastPathComponent,
            under: root
        )
    }

    private func validateSidecarDirectory(_ url: URL, under root: URL) throws {
        try io.createDirectory(url)
        guard try LatticeStorePathSecurity.existingChildDirectory(
            named: url.lastPathComponent,
            under: root
        ) != nil else {
            throw LatticeStorePathError.notDirectory(url)
        }
    }

    public static func restoreRuntimeState(_ sessions: [LatticeSession]) -> [LatticeSession] {
        // WorkRuntimeReconciliation fails closed for provider-bound live state without
        // reconstructing permission callbacks. User-owned pending tasks and terminal
        // artifacts/outcomes are preserved; restored approvals/questions are never live.
        sessions
            .map { WorkRuntimeReconciliation.reconcileSession($0) }
            .sorted { $0.lastUpdated > $1.lastUpdated }
    }

    private func loadSearchIndex(paths: SessionStorePaths) -> SessionIndexLoadOutcome {
        guard io.fileExists(paths.searchIndex.path) else { return .missing }
        do {
            try ensureSafeExistingRegularFile(at: paths.searchIndex)
            let data = try io.readDataUpTo(
                paths.searchIndex,
                DurableStoreRecovery.maximumStoreByteCount
            )
            try enforceSizeLimit(data, at: paths.searchIndex)
            guard let index = try? JSONDecoder().decode(SessionSearchIndex.self, from: data),
                  index.hasValidIntegrity else {
                return .unavailable(SessionIndexWarning(
                    kind: .corrupt,
                    filePath: paths.searchIndex.path,
                    details: "The derived search index failed schema or checksum validation."
                ))
            }
            return .loaded(index)
        } catch let error as SessionPersistenceStorageError {
            return .unavailable(SessionIndexWarning(
                kind: .oversized,
                filePath: paths.searchIndex.path,
                details: error.localizedDescription
            ))
        } catch let error as LatticeStorePathError {
            let kind: SessionIndexWarningKind
            if case .oversized = error { kind = .oversized } else { kind = .unreadable }
            return .unavailable(SessionIndexWarning(
                kind: kind,
                filePath: paths.searchIndex.path,
                details: error.localizedDescription
            ))
        } catch {
            return .unavailable(SessionIndexWarning(
                kind: .unreadable,
                filePath: paths.searchIndex.path,
                details: String(reflecting: error)
            ))
        }
    }

    private static func preview(from text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(160))
    }

    private func removeOrphanedTranscripts(keeping fileNames: Set<String>, in directory: URL) {
        try? LatticeStorePathSecurity.removeRegularFilesWithoutFollowingSymlinks(
            in: directory,
            keeping: fileNames,
            matchingSuffix: ".json"
        )
    }

    /// Removes only artifact sidecars that are no longer referenced. Never deletes image files
    /// outside this directory — artifacts are metadata pointers only.
    private func removeOrphanedArtifacts(keeping fileNames: Set<String>, in directory: URL) {
        try? LatticeStorePathSecurity.removeRegularFilesWithoutFollowingSymlinks(
            in: directory,
            keeping: fileNames,
            matchingSuffix: ".json"
        )
    }

    private func manifestIssue(for error: Error, path: String) -> DurableStoreIssue {
        let kind: DurableStoreIssueKind
        if error is SessionPersistenceStorageError {
            kind = .oversized
        } else if let pathError = error as? LatticeStorePathError,
                  case .oversized = pathError {
            kind = .oversized
        } else {
            kind = .unreadable
        }
        let observation = DurableStoreRecovery.observation(of: URL(fileURLWithPath: path), io: io)
        return DurableStoreIssue(
            storeID: Self.storeID,
            storeName: Self.storeName,
            filePath: path,
            kind: kind,
            summary: "The durable session manifest could not be loaded safely.",
            technicalDetails: "Path: \(path)\nError: \(String(reflecting: error))",
            observedModificationDate: observation.modificationDate,
            observedFileSize: observation.fileSize,
            observedContentFingerprint: observation.fingerprint
        )
    }

    public func issueForTranscriptError(_ error: Error) -> DurableStoreIssue {
        if error is SessionArtifactStoreError {
            return issue(for: error, path: artifactPath(from: error) ?? artifactDirectoryURL.path)
        }
        return issue(for: error, path: transcriptPath(from: error) ?? transcriptDirectoryURL.path)
    }

    private func issue(for error: Error, path: String) -> DurableStoreIssue {
        let kind: DurableStoreIssueKind
        if let transcriptError = error as? SessionTranscriptStoreError {
            switch transcriptError {
            case .oversized:
                kind = .oversized
            case .fingerprintMismatch, .countMismatch, .invalidReference:
                kind = .corrupt
            default:
                kind = .unreadable
            }
        } else if let artifactError = error as? SessionArtifactStoreError {
            switch artifactError {
            case .oversized:
                kind = .oversized
            case .fingerprintMismatch, .countMismatch, .invalidReference:
                kind = .corrupt
            default:
                kind = .unreadable
            }
        } else {
            kind = .unreadable
        }
        let summary = error is SessionArtifactStoreError
            ? "A durable chat artifact metadata store could not be loaded."
            : "A durable chat transcript could not be loaded."
        return DurableStoreIssue(
            storeID: Self.storeID,
            storeName: Self.storeName,
            filePath: path,
            kind: kind,
            summary: summary,
            technicalDetails: "Path: \(path)\nError: \(String(reflecting: error))"
        )
    }

    private func transcriptPath(from error: Error) -> String? {
        switch error as? SessionTranscriptStoreError {
        case .fingerprintMismatch(let path),
             .countMismatch(let path),
             .unreadable(let path, _),
             .oversized(let path, _, _):
            return path
        default:
            return nil
        }
    }

    private func artifactPath(from error: Error) -> String? {
        switch error as? SessionArtifactStoreError {
        case .fingerprintMismatch(let path),
             .countMismatch(let path),
             .unreadable(let path, _),
             .oversized(let path, _, _):
            return path
        default:
            return nil
        }
    }
}

public enum SessionTranscriptStoreError: Error, LocalizedError, Sendable {
    case fingerprintMismatch(String)
    case countMismatch(String)
    case oversized(String, Int, Int)
    case unreadable(String, String)
    case unloadedWithoutReference(UUID)
    case indexRebuildIncomplete
    case invalidReference(String)

    public var errorDescription: String? {
        switch self {
        case .fingerprintMismatch(let path): "Transcript fingerprint does not match: \(path)"
        case .countMismatch(let path): "Transcript message count does not match: \(path)"
        case .oversized(let path, let count, let limit): "Transcript is \(count) bytes and exceeds the \(limit)-byte limit: \(path)"
        case .unreadable(let path, let detail): "Transcript is unreadable at \(path): \(detail)"
        case .unloadedWithoutReference(let id): "Session \(id) is unloaded without durable transcript storage."
        case .indexRebuildIncomplete: "The derived session search index could not be rebuilt completely."
        case .invalidReference(let value): "Transcript storage reference is invalid: \(value)"
        }
    }
}

public enum SessionArtifactStoreError: Error, LocalizedError, Sendable {
    case fingerprintMismatch(String)
    case countMismatch(String)
    case oversized(String, Int, Int)
    case unreadable(String, String)
    case unloadedWithoutReference(UUID)
    case invalidReference(String)

    public var errorDescription: String? {
        switch self {
        case .fingerprintMismatch(let path): "Artifact metadata fingerprint does not match: \(path)"
        case .countMismatch(let path): "Artifact metadata count does not match: \(path)"
        case .oversized(let path, let count, let limit): "Artifact metadata is \(count) bytes and exceeds the \(limit)-byte limit: \(path)"
        case .unreadable(let path, let detail): "Artifact metadata is unreadable at \(path): \(detail)"
        case .unloadedWithoutReference(let id): "Session \(id) has unloaded artifacts without durable storage."
        case .invalidReference(let value): "Artifact storage reference is invalid: \(value)"
        }
    }
}

/// Cross-instance/process serialization for a single manifest path. The lock file is only a
/// coordination primitive; it is never included in the session store or presented as content.
private final class SessionPersistenceProcessLock: @unchecked Sendable {
    // Saves are synchronous today; keep contention bounded so a stale/slow peer produces an
    // actionable failure instead of freezing the UI for several seconds.
    private static let timeout: TimeInterval = 0.5
    private static let retryNanoseconds: useconds_t = 5_000
    private let rootDescriptor: Int32
    private let descriptor: Int32
    private let path: String

    init(rootURL: URL, fileName: String) throws {
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/") else {
            throw SessionPersistenceLockError.unsafePath(
                rootURL.appendingPathComponent(fileName).path
            )
        }
        let rootDescriptor = try Self.openDirectoryWithoutFollowingSymlinks(at: rootURL)
        let lockURL = rootURL.appendingPathComponent(fileName)
        let descriptor = openat(
            rootDescriptor,
            fileName,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else {
            Darwin.close(rootDescriptor)
            throw SessionPersistenceLockError.openFailed(path: lockURL.path, code: errno)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1 else {
            Darwin.close(descriptor)
            Darwin.close(rootDescriptor)
            throw SessionPersistenceLockError.unsafePath(lockURL.path)
        }
        var addressedMetadata = stat()
        guard fstatat(rootDescriptor, fileName, &addressedMetadata, AT_SYMLINK_NOFOLLOW) == 0,
              addressedMetadata.st_dev == metadata.st_dev,
              addressedMetadata.st_ino == metadata.st_ino else {
            Darwin.close(descriptor)
            Darwin.close(rootDescriptor)
            throw SessionPersistenceLockError.unsafePath(lockURL.path)
        }
        self.rootDescriptor = rootDescriptor
        self.descriptor = descriptor
        self.path = lockURL.path
    }

    deinit {
        Darwin.close(descriptor)
        Darwin.close(rootDescriptor)
    }

    func lockExclusive() throws {
        let deadline = Date().addingTimeInterval(Self.timeout)
        while true {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                var descriptorMetadata = stat()
                var addressedMetadata = stat()
                guard fstat(descriptor, &descriptorMetadata) == 0,
                      fstatat(
                        rootDescriptor,
                        URL(fileURLWithPath: path).lastPathComponent,
                        &addressedMetadata,
                        AT_SYMLINK_NOFOLLOW
                      ) == 0,
                      addressedMetadata.st_dev == descriptorMetadata.st_dev,
                      addressedMetadata.st_ino == descriptorMetadata.st_ino else {
                    _ = flock(descriptor, LOCK_UN)
                    throw SessionPersistenceLockError.unsafePath(path)
                }
                return
            }
            let errorCode = errno
            guard errorCode == EWOULDBLOCK || errorCode == EAGAIN else {
                throw SessionPersistenceLockError.lockFailed(path: path, code: errorCode)
            }
            guard Date() < deadline else {
                throw SessionPersistenceLockError.timeout(path: path)
            }
            usleep(Self.retryNanoseconds)
        }
    }

    func unlock() {
        _ = flock(descriptor, LOCK_UN)
    }

    func validateRootStillAddressed(at rootURL: URL) throws {
        let currentDescriptor = try Self.openDirectoryWithoutFollowingSymlinks(at: rootURL)
        defer { Darwin.close(currentDescriptor) }
        var pinned = stat()
        var current = stat()
        guard fstat(rootDescriptor, &pinned) == 0,
              fstat(currentDescriptor, &current) == 0,
              pinned.st_dev == current.st_dev,
              pinned.st_ino == current.st_ino else {
            throw SessionPersistenceLockError.unsafePath(rootURL.path)
        }
    }

    private static func openDirectoryWithoutFollowingSymlinks(at url: URL) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw SessionPersistenceLockError.unsafePath(url.path)
        }
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw SessionPersistenceLockError.unsafePath(url.path)
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SessionPersistenceLockError.openFailed(path: "/", code: errno)
        }
        for component in components {
            let next = openat(
                descriptor,
                String(component),
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw SessionPersistenceLockError.openFailed(path: url.path, code: code)
            }
            Darwin.close(descriptor)
            descriptor = next
        }
        return descriptor
    }
}

private enum SessionPersistenceLockError: Error, LocalizedError, Sendable {
    case openFailed(path: String, code: Int32)
    case unsafePath(String)
    case lockFailed(path: String, code: Int32)
    case timeout(path: String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let path, let code): "Could not open the session lock at \(path) (POSIX \(code))."
        case .unsafePath(let path): "The session lock path is not a regular file owned by this user: \(path)."
        case .lockFailed(let path, let code): "Could not lock the session store at \(path) (POSIX \(code))."
        case .timeout(let path): "Timed out waiting for another session save to finish: \(path)."
        }
    }
}
