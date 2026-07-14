import CryptoKit
import Foundation

public struct SessionSearchIndex: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        public let transcriptFingerprint: String
        public let metadataFingerprint: String
        public let gramHashes: [String]

        public init(transcriptFingerprint: String, metadataFingerprint: String, gramHashes: [String]) {
            self.transcriptFingerprint = transcriptFingerprint
            self.metadataFingerprint = metadataFingerprint
            self.gramHashes = gramHashes
        }
    }

    public var version: Int
    public var entries: [UUID: Entry]

    public init(version: Int = Self.schemaVersion, entries: [UUID: Entry] = [:]) {
        self.version = version
        self.entries = entries
    }

    public var indexedSessionIDs: Set<UUID> { Set(entries.keys) }

    /// Returns an indexed candidate set without decoding transcripts. Unindexed sessions are
    /// included so missing/corrupt derived index data can never hide a durable conversation.
    public func candidateSessionIDs(for query: String, allSessionIDs: Set<UUID>) -> Set<UUID> {
        let hashes = Self.queryGramHashes(query)
        guard !hashes.isEmpty else { return allSessionIDs }
        var result = allSessionIDs.subtracting(entries.keys)
        for (id, entry) in entries {
            let available = Set(entry.gramHashes)
            if hashes.isSubset(of: available) { result.insert(id) }
        }
        return result
    }

    public mutating func update(session: LatticeSession) {
        guard session.isTranscriptLoaded else { return }
        entries[session.id] = Entry(
            transcriptFingerprint: Self.fingerprint(messages: session.messages),
            metadataFingerprint: Self.metadataFingerprint(session),
            gramHashes: Self.gramHashes(for: Self.searchableText(session)).sorted()
        )
    }

    public mutating func retainValidEntries(for sessions: [LatticeSession]) {
        let byID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        entries = entries.filter { id, entry in
            guard let session = byID[id] else { return false }
            let transcriptMatches = session.isTranscriptLoaded
                || session.transcriptStorage?.contentFingerprint == entry.transcriptFingerprint
            return transcriptMatches && Self.metadataFingerprint(session) == entry.metadataFingerprint
        }
    }

    public func containsValidEntry(for session: LatticeSession) -> Bool {
        guard let entry = entries[session.id] else { return false }
        let transcriptMatches = session.isTranscriptLoaded
            ? entry.transcriptFingerprint == Self.fingerprint(messages: session.messages)
            : entry.transcriptFingerprint == session.transcriptStorage?.contentFingerprint
        return transcriptMatches && entry.metadataFingerprint == Self.metadataFingerprint(session)
    }

    public static func fingerprint(messages: [ChatMessage]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(messages)) ?? Data()
        return digest(data)
    }

    private static func metadataFingerprint(_ session: LatticeSession) -> String {
        var metadata = session
        metadata.messages = []
        metadata.transcriptStorage = nil
        metadata.isTranscriptLoaded = true
        // Artifact sidecars are independently content-addressed. Do not let the same
        // metadata appear different merely because its sidecar is loaded or lazy.
        metadata.artifacts = []
        metadata.artifactStorage = nil
        metadata.isArtifactsLoaded = true
        return digest((try? JSONEncoder().encode(metadata)) ?? Data())
    }

    private static func searchableText(_ session: LatticeSession) -> String {
        let messageText = session.messages.map { message in
            let pinTerms = message.isPinned ? "pinned pin favorite" : ""
            return "\(message.role.rawValue) \(message.text) \(pinTerms)"
        }.joined(separator: "\n")
        let followUpText = session.queuedFollowUps.map(\.text).joined(separator: "\n")
        let attachmentText = session.attachments.map { "\($0.name) \($0.path)" }.joined(separator: "\n")
        let actionText = session.actions.map { action in
            [action.kind.rawValue, action.toolKind?.rawValue ?? "", action.title, action.detail,
             action.status.rawValue, action.workspaceScoped ? "workspace" : "global"].joined(separator: " ")
        }.joined(separator: "\n")
        return [
            session.title, session.backend.displayName, session.backend.harnessName,
            session.harnessID ?? "", session.privacyMode.displayName,
            session.privacyMode == .localOnly
                ? "local-only local only private offline no cloud" : "cloud allowed remote provider",
            session.workspacePath ?? "", session.isPinned ? "pinned pin favorite" : "",
            messageText, followUpText, attachmentText, actionText
        ].joined(separator: "\n").lowercased()
    }

    private static func queryGramHashes(_ query: String) -> Set<String> {
        let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return Set(tokens.flatMap { rawGrams($0).map { digest(Data($0.utf8)) } })
    }

    private static func gramHashes(for text: String) -> Set<String> {
        Set(rawGrams(text).map { digest(Data($0.utf8)) })
    }

    /// One-, two-, and three-character grams preserve the existing substring search behavior,
    /// while hashes avoid writing a second plaintext copy of transcript content.
    private static func rawGrams(_ text: String) -> Set<String> {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        var grams: Set<String> = []
        for length in 1...3 where characters.count >= length {
            for start in 0...(characters.count - length) {
                grams.insert(String(characters[start..<(start + length)]))
            }
        }
        return grams
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public extension LatticeSession {
    /// Compatibility matcher for fully materialized sessions and tests. Production session-list
    /// filtering uses `SessionSearchIndex` so switching/searching does not decode every transcript.
    func matchesSearch(_ query: String) -> Bool {
        let tokens = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return true }
        let messageText = messages.map { message in
            "\(message.role.rawValue) \(message.text) \(message.isPinned ? "pinned pin favorite" : "")"
        }.joined(separator: "\n")
        let actionText = actions.map {
            "\($0.kind.rawValue) \($0.toolKind?.rawValue ?? "") \($0.title) \($0.detail) \($0.status.rawValue) \($0.workspaceScoped ? "workspace" : "global")"
        }.joined(separator: "\n")
        let text = [
            title, backend.displayName, backend.harnessName, harnessID ?? "", privacyMode.displayName,
            privacyMode == .localOnly ? "local-only local only private offline no cloud" : "cloud allowed remote provider",
            workspacePath ?? "", isPinned ? "pinned pin favorite" : "", messageText,
            queuedFollowUps.map(\.text).joined(separator: "\n"),
            attachments.map { "\($0.name) \($0.path)" }.joined(separator: "\n"), actionText
        ].joined(separator: "\n").lowercased()
        return tokens.allSatisfy(text.contains)
    }
}
