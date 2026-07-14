import Foundation

/// Durable metadata for an assistant-produced media artifact.
/// Records are path and metadata only — never image bytes or base64 payloads.
public struct AssistantArtifact: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case image
    }

    public enum Status: String, Codable, Sendable {
        case available
        case missing
    }

    public enum Origin: String, Codable, Sendable {
        case codexImageView
        case codexImageGeneration
        case structuredToolResult
    }

    public struct Provenance: Hashable, Codable, Sendable {
        public let provider: String
        public let origin: Origin
        /// Provider-stable event/item identity when available (not a free-form payload dump).
        public let eventID: String?

        public init(provider: String, origin: Origin, eventID: String? = nil) {
            self.provider = String(provider.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            self.origin = origin
            if let eventID {
                let trimmed = eventID.trimmingCharacters(in: .whitespacesAndNewlines)
                self.eventID = trimmed.isEmpty ? nil : String(trimmed.prefix(160))
            } else {
                self.eventID = nil
            }
        }
    }

    public let id: UUID
    public let messageID: UUID
    public let kind: Kind
    public var status: Status
    public let displayName: String
    public let mimeType: String
    public let byteCount: Int
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    /// Canonical absolute local path after validation. Never a URL scheme or data URI.
    public let canonicalPath: String
    public let provenance: Provenance
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        messageID: UUID,
        kind: Kind = .image,
        status: Status,
        displayName: String,
        mimeType: String,
        byteCount: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        canonicalPath: String,
        provenance: Provenance,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.messageID = messageID
        self.kind = kind
        self.status = status
        self.displayName = Self.safeDisplayName(displayName)
        self.mimeType = String(mimeType.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        self.byteCount = max(0, byteCount)
        self.pixelWidth = pixelWidth.flatMap { $0 > 0 ? $0 : nil }
        self.pixelHeight = pixelHeight.flatMap { $0 > 0 ? $0 : nil }
        self.canonicalPath = canonicalPath
        self.provenance = provenance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func rebound(to messageID: UUID) -> AssistantArtifact {
        AssistantArtifact(
            id: id,
            messageID: messageID,
            kind: kind,
            status: status,
            displayName: displayName,
            mimeType: mimeType,
            byteCount: byteCount,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            canonicalPath: canonicalPath,
            provenance: provenance,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func safeDisplayName(_ value: String) -> String {
        let oneLine = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let trimmed = oneLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "image" }
        return String(trimmed.prefix(180))
    }
}

/// Runtime observation emitted by a harness before the control plane binds `messageID`.
public struct AssistantArtifactObservation: Hashable, Sendable {
    public let id: UUID
    public let kind: AssistantArtifact.Kind
    public let status: AssistantArtifact.Status
    public let displayName: String
    public let mimeType: String
    public let byteCount: Int
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    public let canonicalPath: String
    public let provenance: AssistantArtifact.Provenance
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        kind: AssistantArtifact.Kind = .image,
        status: AssistantArtifact.Status,
        displayName: String,
        mimeType: String,
        byteCount: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        canonicalPath: String,
        provenance: AssistantArtifact.Provenance,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.displayName = displayName
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.canonicalPath = canonicalPath
        self.provenance = provenance
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func bound(to messageID: UUID) -> AssistantArtifact {
        AssistantArtifact(
            id: id,
            messageID: messageID,
            kind: kind,
            status: status,
            displayName: displayName,
            mimeType: mimeType,
            byteCount: byteCount,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            canonicalPath: canonicalPath,
            provenance: provenance,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}

/// Split-store pointer for per-session artifact metadata (paths and display fields only).
public struct SessionArtifactStorage: Hashable, Codable, Sendable {
    public let fileName: String
    public let artifactCount: Int
    public let contentFingerprint: String

    public init(fileName: String, artifactCount: Int, contentFingerprint: String) {
        self.fileName = fileName
        self.artifactCount = artifactCount
        self.contentFingerprint = contentFingerprint
    }
}

public enum AssistantArtifactTrail {
    /// Insert or replace a durable artifact record without silently dropping older output.
    /// Retention is owned by the session lifecycle (message deletion/branching), not this helper.
    public static func upsert(_ artifact: AssistantArtifact, in artifacts: inout [AssistantArtifact]) {
        if let index = artifacts.firstIndex(where: { $0.id == artifact.id }) {
            artifacts[index] = artifact
        } else {
            artifacts.append(artifact)
        }
    }

    public static func prune(in artifacts: inout [AssistantArtifact], keepingMessageIDs: Set<UUID>) {
        artifacts.removeAll { !keepingMessageIDs.contains($0.messageID) }
    }

    public static func artifacts(for messageID: UUID, in artifacts: [AssistantArtifact]) -> [AssistantArtifact] {
        artifacts.filter { $0.messageID == messageID }
    }
}
