import Foundation

public struct LazySessionLoad: Sendable {
    public var sessions: [LatticeSession]
    public var searchIndex: SessionSearchIndex
    public let usesLegacyMonolithicStore: Bool

    public init(sessions: [LatticeSession], searchIndex: SessionSearchIndex, usesLegacyMonolithicStore: Bool) {
        self.sessions = sessions
        self.searchIndex = searchIndex
        self.usesLegacyMonolithicStore = usesLegacyMonolithicStore
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
        switch DurableStoreRecovery.loadJSONArray(
            from: fileURL,
            as: LatticeSession.self,
            storeID: Self.storeID,
            storeName: Self.storeName,
            io: io
        ) {
        case .missing:
            return .missing
        case .failed(let issue):
            return .failed(issue)
        case .loaded(let decoded):
            let restored = Self.restoreRuntimeState(decoded)
            let usesLegacy = restored.contains { $0.transcriptStorage == nil }
            var index = loadSearchIndex() ?? SessionSearchIndex()
            index.retainValidEntries(for: restored)
            let needsIndexRepair = restored.contains { !index.containsValidEntry(for: $0) }
            do {
                for session in restored where !index.containsValidEntry(for: session) {
                    var materialized = session
                    try materializeTranscript(in: &materialized)
                    index.update(session: materialized)
                }
                // Index data is derived and contains hashes only. Repairing it must never mutate
                // the authoritative manifest/transcripts or turn an index write failure into data loss.
                if index.indexedSessionIDs != Set(restored.map(\.id)) {
                    return .failed(issue(
                        for: SessionTranscriptStoreError.indexRebuildIncomplete,
                        path: searchIndexURL.path
                    ))
                }
                if needsIndexRepair {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try? io.writeDataAtomically(encoder.encode(index), searchIndexURL)
                }
            } catch {
                return .failed(issue(for: error, path: transcriptPath(from: error) ?? transcriptDirectoryURL.path))
            }
            return .loaded(LazySessionLoad(
                sessions: restored,
                searchIndex: index,
                usesLegacyMonolithicStore: usesLegacy
            ))
        }
    }

    /// Evidence-rich compatibility load. This intentionally materializes every transcript for
    /// archive/tests/legacy callers; production AppState uses `loadLazyResult()`.
    public func loadResult() -> DurableStoreLoadResult<[LatticeSession]> {
        switch loadLazyResult() {
        case .missing:
            return .missing
        case .failed(let issue):
            return .failed(issue)
        case .loaded(let snapshot):
            var sessions = snapshot.sessions
            do {
                for index in sessions.indices {
                    try materializeTranscript(in: &sessions[index])
                    sessions[index].transcriptStorage = nil
                    try materializeArtifacts(in: &sessions[index])
                    sessions[index].artifactStorage = nil
                }
                return .loaded(Self.restoreRuntimeState(sessions))
            } catch {
                return .failed(issue(for: error, path: transcriptPath(from: error) ?? artifactPath(from: error) ?? transcriptDirectoryURL.path))
            }
        }
    }

    public func load() -> [LatticeSession] {
        if case .loaded(let sessions) = loadResult() { return sessions }
        return []
    }

    public func materializeTranscript(in session: inout LatticeSession) throws {
        guard !session.isTranscriptLoaded, let storage = session.transcriptStorage else { return }
        let expectedPrefix = session.id.uuidString.lowercased() + "-"
        guard storage.fileName == URL(fileURLWithPath: storage.fileName).lastPathComponent,
              storage.fileName.hasPrefix(expectedPrefix),
              storage.fileName.hasSuffix(".json") else {
            throw SessionTranscriptStoreError.invalidReference(storage.fileName)
        }
        let url = transcriptDirectoryURL.appendingPathComponent(storage.fileName)
        do {
            let data = try io.readDataUpTo(url, DurableStoreRecovery.maximumStoreByteCount)
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
        } catch {
            throw SessionTranscriptStoreError.unreadable(url.path, String(reflecting: error))
        }
    }

    /// Lazy materialization for the split artifact metadata store. Metadata only — never copies image bytes.
    public func materializeArtifacts(in session: inout LatticeSession) throws {
        guard !session.isArtifactsLoaded else { return }
        guard let storage = session.artifactStorage else {
            session.artifacts = []
            session.isArtifactsLoaded = true
            session.isArtifactsDirty = false
            return
        }
        let expectedPrefix = session.id.uuidString.lowercased() + "-"
        guard storage.fileName == URL(fileURLWithPath: storage.fileName).lastPathComponent,
              storage.fileName.hasPrefix(expectedPrefix),
              storage.fileName.hasSuffix(".json") else {
            throw SessionArtifactStoreError.invalidReference(storage.fileName)
        }
        let url = artifactDirectoryURL.appendingPathComponent(storage.fileName)
        do {
            let data = try io.readDataUpTo(url, DurableStoreRecovery.maximumStoreByteCount)
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
        } catch {
            throw SessionArtifactStoreError.unreadable(url.path, String(reflecting: error))
        }
    }

    /// Evidence-rich transcript + artifact metadata read used by asynchronous selection hydration.
    public func hydrationResult(for session: LatticeSession) -> TranscriptHydrationLoadResult {
        var materialized = session
        do {
            try materializeTranscript(in: &materialized)
            try materializeArtifacts(in: &materialized)
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
        try materializeTranscript(in: &session)
        try materializeArtifacts(in: &session)
    }

    public static func storageReference(sessionID: UUID, messages: [ChatMessage]) throws -> SessionTranscriptStorage {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(messages)
        let fingerprint = DurableStoreRecovery.contentFingerprint(for: data)
        return SessionTranscriptStorage(
            fileName: "\(sessionID.uuidString.lowercased())-\(fingerprint.prefix(16)).json",
            messageCount: messages.count,
            contentFingerprint: fingerprint,
            lastMessagePreview: Self.preview(from: messages.last?.text)
        )
    }

    public static func artifactStorageReference(sessionID: UUID, artifacts: [AssistantArtifact]) throws -> SessionArtifactStorage {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(artifacts)
        let fingerprint = DurableStoreRecovery.contentFingerprint(for: data)
        return SessionArtifactStorage(
            fileName: "\(sessionID.uuidString.lowercased())-\(fingerprint.prefix(16)).json",
            artifactCount: artifacts.count,
            contentFingerprint: fingerprint
        )
    }

    public func save(_ sessions: [LatticeSession]) throws {
        try DurableStoreRecovery.enforceWritable(gate: writeGate, storeName: Self.storeName)
        try io.createDirectory(fileURL.deletingLastPathComponent())
        try io.createDirectory(transcriptDirectoryURL)
        try io.createDirectory(artifactDirectoryURL)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var storedSessions: [LatticeSession] = []
        storedSessions.reserveCapacity(sessions.count)
        var searchIndex = loadSearchIndex() ?? SessionSearchIndex()
        searchIndex.retainValidEntries(for: sessions)

        for session in sessions {
            var stored = session
            if session.isTranscriptLoaded {
                let transcriptEncoder = JSONEncoder()
                transcriptEncoder.outputFormatting = [.sortedKeys]
                let data = try transcriptEncoder.encode(session.messages)
                let fingerprint = DurableStoreRecovery.contentFingerprint(for: data)
                let reference = SessionTranscriptStorage(
                    fileName: "\(session.id.uuidString.lowercased())-\(fingerprint.prefix(16)).json",
                    messageCount: session.messages.count,
                    contentFingerprint: fingerprint,
                    lastMessagePreview: Self.preview(from: session.messages.last?.text)
                )
                let fileName = reference.fileName
                let transcriptURL = transcriptDirectoryURL.appendingPathComponent(fileName)
                if !io.fileExists(transcriptURL.path) {
                    try io.writeDataAtomically(data, transcriptURL)
                }
                stored.transcriptStorage = reference
                searchIndex.update(session: session)
            } else if stored.transcriptStorage == nil {
                throw SessionTranscriptStoreError.unloadedWithoutReference(session.id)
            }
            if session.isArtifactsLoaded, !session.artifacts.isEmpty {
                let artifactEncoder = JSONEncoder()
                artifactEncoder.outputFormatting = [.sortedKeys]
                let data = try artifactEncoder.encode(session.artifacts)
                let fingerprint = DurableStoreRecovery.contentFingerprint(for: data)
                let reference = SessionArtifactStorage(
                    fileName: "\(session.id.uuidString.lowercased())-\(fingerprint.prefix(16)).json",
                    artifactCount: session.artifacts.count,
                    contentFingerprint: fingerprint
                )
                let artifactURL = artifactDirectoryURL.appendingPathComponent(reference.fileName)
                if !io.fileExists(artifactURL.path) {
                    try io.writeDataAtomically(data, artifactURL)
                }
                stored.artifactStorage = reference
            } else if session.isArtifactsLoaded {
                stored.artifactStorage = nil
            } else if stored.artifactStorage == nil, !session.artifacts.isEmpty {
                throw SessionArtifactStoreError.unloadedWithoutReference(session.id)
            }
            if !searchIndex.containsValidEntry(for: stored) {
                var materialized = stored
                try materializeTranscript(in: &materialized)
                searchIndex.update(session: materialized)
            }
            stored.messages = []
            stored.isTranscriptLoaded = false
            stored.artifacts = []
            stored.isArtifactsLoaded = false
            storedSessions.append(stored)
        }

        // Derived index may be discarded and rebuilt; durable manifest is committed last.
        try io.writeDataAtomically(try encoder.encode(searchIndex), searchIndexURL)
        try io.writeDataAtomically(try encoder.encode(storedSessions), fileURL)
        removeOrphanedTranscripts(keeping: Set(storedSessions.compactMap { $0.transcriptStorage?.fileName }))
        removeOrphanedArtifacts(keeping: Set(storedSessions.compactMap { $0.artifactStorage?.fileName }))
    }

    public static func restoreRuntimeState(_ sessions: [LatticeSession]) -> [LatticeSession] {
        // WorkRuntimeReconciliation fails closed for provider-bound live state without
        // reconstructing permission callbacks. User-owned pending tasks and terminal
        // artifacts/outcomes are preserved; restored approvals/questions are never live.
        sessions
            .map { WorkRuntimeReconciliation.reconcileSession($0) }
            .sorted { $0.lastUpdated > $1.lastUpdated }
    }

    private func loadSearchIndex() -> SessionSearchIndex? {
        guard io.fileExists(searchIndexURL.path),
              let data = try? io.readDataUpTo(searchIndexURL, DurableStoreRecovery.maximumStoreByteCount),
              let index = try? JSONDecoder().decode(SessionSearchIndex.self, from: data),
              index.version == SessionSearchIndex.schemaVersion else { return nil }
        return index
    }

    private static func preview(from text: String?) -> String? {
        guard let text else { return nil }
        let normalized = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(160))
    }

    private func removeOrphanedTranscripts(keeping fileNames: Set<String>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: transcriptDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.pathExtension == "json" && !fileNames.contains(url.lastPathComponent) {
            try? io.removeItem(url)
        }
    }

    /// Removes only artifact sidecars that are no longer referenced. Never deletes image files
    /// outside this directory — artifacts are metadata pointers only.
    private func removeOrphanedArtifacts(keeping fileNames: Set<String>) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: artifactDirectoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls where url.pathExtension == "json" && !fileNames.contains(url.lastPathComponent) {
            try? io.removeItem(url)
        }
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
            case .fingerprintMismatch, .countMismatch, .invalidReference:
                kind = .corrupt
            default:
                kind = .unreadable
            }
        } else if let artifactError = error as? SessionArtifactStoreError {
            switch artifactError {
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
        case .fingerprintMismatch(let path), .countMismatch(let path), .unreadable(let path, _):
            return path
        default:
            return nil
        }
    }

    private func artifactPath(from error: Error) -> String? {
        switch error as? SessionArtifactStoreError {
        case .fingerprintMismatch(let path), .countMismatch(let path), .unreadable(let path, _):
            return path
        default:
            return nil
        }
    }
}

public enum SessionTranscriptStoreError: Error, LocalizedError, Sendable {
    case fingerprintMismatch(String)
    case countMismatch(String)
    case unreadable(String, String)
    case unloadedWithoutReference(UUID)
    case indexRebuildIncomplete
    case invalidReference(String)

    public var errorDescription: String? {
        switch self {
        case .fingerprintMismatch(let path): "Transcript fingerprint does not match: \(path)"
        case .countMismatch(let path): "Transcript message count does not match: \(path)"
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
    case unreadable(String, String)
    case unloadedWithoutReference(UUID)
    case invalidReference(String)

    public var errorDescription: String? {
        switch self {
        case .fingerprintMismatch(let path): "Artifact metadata fingerprint does not match: \(path)"
        case .countMismatch(let path): "Artifact metadata count does not match: \(path)"
        case .unreadable(let path, let detail): "Artifact metadata is unreadable at \(path): \(detail)"
        case .unloadedWithoutReference(let id): "Session \(id) has unloaded artifacts without durable storage."
        case .invalidReference(let value): "Artifact storage reference is invalid: \(value)"
        }
    }
}
