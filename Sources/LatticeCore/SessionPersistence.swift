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
    public static let searchIndexFileName = "sessions.search-index.json"

    public let fileURL: URL
    public let writeGate: DurableStoreWriteGate
    public let io: DurableStoreFileIO

    public var transcriptDirectoryURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent(Self.transcriptDirectoryName, isDirectory: true)
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
                }
                return .loaded(Self.restoreRuntimeState(sessions))
            } catch {
                return .failed(issue(for: error, path: transcriptPath(from: error) ?? transcriptDirectoryURL.path))
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

    public func save(_ sessions: [LatticeSession]) throws {
        try DurableStoreRecovery.enforceWritable(gate: writeGate, storeName: Self.storeName)
        try io.createDirectory(fileURL.deletingLastPathComponent())
        try io.createDirectory(transcriptDirectoryURL)

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
            if !searchIndex.containsValidEntry(for: stored) {
                var materialized = stored
                try materializeTranscript(in: &materialized)
                searchIndex.update(session: materialized)
            }
            stored.messages = []
            stored.isTranscriptLoaded = false
            storedSessions.append(stored)
        }

        // Derived index may be discarded and rebuilt; durable manifest is committed last.
        try io.writeDataAtomically(try encoder.encode(searchIndex), searchIndexURL)
        try io.writeDataAtomically(try encoder.encode(storedSessions), fileURL)
        removeOrphanedTranscripts(keeping: Set(storedSessions.compactMap { $0.transcriptStorage?.fileName }))
    }

    public static func restoreRuntimeState(_ sessions: [LatticeSession]) -> [LatticeSession] {
        sessions.map { session in
            var restored = session
            restored.isStreaming = false
            for index in restored.actions.indices where [.running, .waiting].contains(restored.actions[index].status) {
                restored.actions[index].status = .interrupted
                restored.actions[index].updatedAt = .now
            }
            return restored
        }.sorted { $0.lastUpdated > $1.lastUpdated }
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
        for url in urls where !fileNames.contains(url.lastPathComponent) {
            try? io.removeItem(url)
        }
    }

    public func issueForTranscriptError(_ error: Error) -> DurableStoreIssue {
        issue(for: error, path: transcriptPath(from: error) ?? transcriptDirectoryURL.path)
    }

    private func issue(for error: Error, path: String) -> DurableStoreIssue {
        let kind: DurableStoreIssueKind
        switch error as? SessionTranscriptStoreError {
        case .fingerprintMismatch,
             .countMismatch,
             .invalidReference:
            kind = .corrupt
        default:
            kind = .unreadable
        }
        return DurableStoreIssue(
            storeID: Self.storeID,
            storeName: Self.storeName,
            filePath: path,
            kind: kind,
            summary: "A durable chat transcript could not be loaded.",
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
