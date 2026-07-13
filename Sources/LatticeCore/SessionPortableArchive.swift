import Foundation
import CryptoKit
import CoreFoundation

// MARK: - Public surface

/// Versioned, privacy-safe portable chat export/import for healthy Lattice sessions.
///
/// Architecture: pure codec/validator/fingerprint layer. UI panels and session-list mutation
/// orchestration stay in the app target. Ordinary composer drafts are never exported.
public enum SessionPortableArchive {
    public static let formatID = "lattice.session.archive"
    public static let currentVersion = 1
    public static let jsonFileExtension = "lattice.json"
    public static let markdownFileExtension = "md"
    public static let jsonUTIDescription = "Lattice Session Archive"
    public static let markdownNotImportableBanner = "This is a human-readable Lattice Markdown export. It is **not** an importable archive. Use a `.lattice.json` file to import."

    // Bounds enforced before constructing a session.
    public static let maxArchiveBytes = 8 * 1024 * 1024
    public static let maxMessages = 5_000
    public static let maxActions = 2_000
    public static let maxAttachments = 200
    public static let maxQueuedFollowUps = 100
    public static let maxTitleLength = 500
    public static let maxStringLength = 200_000
    public static let maxDetailLength = 24_000
    public static let maxHarnessIDLength = 200
    public static let maxModelLength = 200
    public static let maxJSONNestingDepth = 32
    public static let maxJSONCollectionCount = 5_000
    public static let missingAttachmentScheme = "lattice-missing-attachment"

    public enum ExportFormat: String, CaseIterable, Sendable, Identifiable {
        case jsonArchive
        case markdown

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .jsonArchive: "Lattice JSON archive"
            case .markdown: "Readable Markdown"
            }
        }

        public var fileExtension: String {
            switch self {
            case .jsonArchive: SessionPortableArchive.jsonFileExtension
            case .markdown: SessionPortableArchive.markdownFileExtension
            }
        }

        public var contentTypeDescription: String {
            switch self {
            case .jsonArchive: SessionPortableArchive.jsonUTIDescription
            case .markdown: "Markdown Document"
            }
        }
    }

    public struct ExportOptions: Sendable, Equatable {
        /// Queued drafts/follow-ups are excluded by default; only included after explicit choice.
        public var includeQueuedFollowUps: Bool
        public var format: ExportFormat
        public var exportedAt: Date

        public init(
            includeQueuedFollowUps: Bool = false,
            format: ExportFormat = .jsonArchive,
            exportedAt: Date = .now
        ) {
            self.includeQueuedFollowUps = includeQueuedFollowUps
            self.format = format
            self.exportedAt = exportedAt
        }
    }

    public enum ArchiveError: Error, Equatable, Sendable, LocalizedError {
        case fileTooLarge(bytes: Int, limit: Int)
        case emptyFile
        case unreadableUTF8
        case invalidJSON
        case nestingTooDeep(depth: Int, limit: Int)
        case collectionTooLarge(count: Int, limit: Int)
        case unknownFormat(String)
        case unsupportedVersion(Int)
        case missingField(String)
        case invalidField(String)
        case stringTooLong(field: String, length: Int, limit: Int)
        case countExceeded(field: String, count: Int, limit: Int)
        case invalidDate(String)
        case invalidUUID(String)
        case invalidEnum(field: String, value: String)
        case duplicateID(field: String)
        case markdownNotImportable
        case unknownSensitiveField(String)
        case writeFailed(String)
        case pathDereferenceForbidden

        public var errorDescription: String? {
            switch self {
            case .fileTooLarge(let bytes, let limit):
                return "Archive is too large (\(bytes) bytes; limit \(limit))."
            case .emptyFile:
                return "Archive file is empty."
            case .unreadableUTF8:
                return "Archive is not valid UTF-8 text."
            case .invalidJSON:
                return "Archive JSON could not be parsed."
            case .nestingTooDeep(let depth, let limit):
                return "Archive JSON nests too deeply (\(depth); limit \(limit))."
            case .collectionTooLarge(let count, let limit):
                return "Archive contains a collection that is too large (\(count); limit \(limit))."
            case .unknownFormat(let value):
                return "Not a Lattice session archive (format “\(value)”)."
            case .unsupportedVersion(let version):
                return "Archive version \(version) is not supported by this Lattice build."
            case .missingField(let field):
                return "Archive is missing required field “\(field)”."
            case .invalidField(let field):
                return "Archive field “\(field)” is invalid."
            case .stringTooLong(let field, let length, let limit):
                return "Archive field “\(field)” is too long (\(length); limit \(limit))."
            case .countExceeded(let field, let count, let limit):
                return "Archive “\(field)” count exceeds the limit (\(count); max \(limit))."
            case .invalidDate(let field):
                return "Archive date “\(field)” is invalid."
            case .invalidUUID(let field):
                return "Archive identifier “\(field)” is not a valid UUID."
            case .invalidEnum(let field, let value):
                return "Archive field “\(field)” has an unsupported value “\(value)”."
            case .duplicateID(let field):
                return "Archive contains duplicate identifiers in “\(field)”."
            case .markdownNotImportable:
                return "Markdown exports cannot be imported. Choose a .lattice.json archive."
            case .unknownSensitiveField(let field):
                return "Archive contains disallowed field “\(field)”."
            case .writeFailed(let message):
                return message
            case .pathDereferenceForbidden:
                return "Import refuses to open or resolve attachment paths."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .markdownNotImportable:
                return "Export again as “Lattice JSON archive”, or pick a different file."
            case .unsupportedVersion:
                return "Update Lattice, or re-export from a compatible version."
            case .fileTooLarge:
                return "Export a smaller chat, or remove large action details before exporting."
            default:
                return "Existing chats were not changed. Fix the archive or choose another file."
            }
        }
    }
}

// MARK: - Portable document models

public struct PortableSessionDocument: Equatable, Sendable {
    public let format: String
    public let version: Int
    public let exportedAt: Date
    public let includeQueuedFollowUps: Bool
    public let chat: PortableChatPayload

    public init(
        format: String = SessionPortableArchive.formatID,
        version: Int = SessionPortableArchive.currentVersion,
        exportedAt: Date,
        includeQueuedFollowUps: Bool,
        chat: PortableChatPayload
    ) {
        self.format = format
        self.version = version
        self.exportedAt = exportedAt
        self.includeQueuedFollowUps = includeQueuedFollowUps
        self.chat = chat
    }
}

public struct PortableChatPayload: Equatable, Sendable {
    public var title: String
    public var isPinned: Bool
    public var lastUpdated: Date
    public var backendRoute: String
    public var backendModel: String?
    public var harnessID: String?
    public var harnessLabel: String?
    public var reasoningEffort: String?
    public var policy: String
    public var privacyMode: String
    public var messages: [PortableMessage]
    public var attachments: [PortableAttachment]
    public var actions: [PortableAction]
    public var queuedFollowUps: [PortableQueuedFollowUp]

    public init(
        title: String,
        isPinned: Bool,
        lastUpdated: Date,
        backendRoute: String,
        backendModel: String?,
        harnessID: String?,
        harnessLabel: String?,
        reasoningEffort: String?,
        policy: String,
        privacyMode: String,
        messages: [PortableMessage],
        attachments: [PortableAttachment],
        actions: [PortableAction],
        queuedFollowUps: [PortableQueuedFollowUp]
    ) {
        self.title = title
        self.isPinned = isPinned
        self.lastUpdated = lastUpdated
        self.backendRoute = backendRoute
        self.backendModel = backendModel
        self.harnessID = harnessID
        self.harnessLabel = harnessLabel
        self.reasoningEffort = reasoningEffort
        self.policy = policy
        self.privacyMode = privacyMode
        self.messages = messages
        self.attachments = attachments
        self.actions = actions
        self.queuedFollowUps = queuedFollowUps
    }
}

public struct PortableMessage: Equatable, Sendable {
    public var role: String
    public var text: String
    public var date: Date
    public var isPinned: Bool

    public init(role: String, text: String, date: Date, isPinned: Bool) {
        self.role = role
        self.text = text
        self.date = date
        self.isPinned = isPinned
    }
}

public struct PortableAttachment: Equatable, Sendable {
    public var name: String
    public var kind: String
    /// Always metadata-only. Paths are never restored as resolvable filesystem locations.
    public var availability: String

    public init(name: String, kind: String, availability: String = "metadata-only") {
        self.name = name
        self.kind = kind
        self.availability = availability
    }
}

public struct PortableAction: Equatable, Sendable {
    public var kind: String
    public var toolKind: String?
    public var title: String
    public var detail: String
    public var status: String
    public var workspaceScoped: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var messageIndex: Int?

    public init(
        kind: String,
        toolKind: String?,
        title: String,
        detail: String,
        status: String,
        workspaceScoped: Bool,
        createdAt: Date,
        updatedAt: Date,
        messageIndex: Int?
    ) {
        self.kind = kind
        self.toolKind = toolKind
        self.title = title
        self.detail = detail
        self.status = status
        self.workspaceScoped = workspaceScoped
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageIndex = messageIndex
    }
}

public struct PortableQueuedFollowUp: Equatable, Sendable {
    public var text: String
    public var date: Date

    public init(text: String, date: Date) {
        self.text = text
        self.date = date
    }
}

public struct SessionArchiveImportPreview: Equatable, Sendable {
    public let title: String
    public let routeLabel: String
    public let modelLabel: String
    public let harnessLabel: String?
    public let reasoningLabel: String?
    public let policy: String
    public let privacyMode: String
    public let messageCount: Int
    public let actionCount: Int
    public let attachmentCount: Int
    public let queuedFollowUpCount: Int
    public let includesQueuedFollowUps: Bool
    public let isPinned: Bool
    public let contentFingerprint: String
    public let isDuplicate: Bool
    public let duplicateSessionIDs: [UUID]
    public let summaryLines: [String]

    public init(
        title: String,
        routeLabel: String,
        modelLabel: String,
        harnessLabel: String?,
        reasoningLabel: String?,
        policy: String,
        privacyMode: String,
        messageCount: Int,
        actionCount: Int,
        attachmentCount: Int,
        queuedFollowUpCount: Int,
        includesQueuedFollowUps: Bool,
        isPinned: Bool,
        contentFingerprint: String,
        isDuplicate: Bool,
        duplicateSessionIDs: [UUID],
        summaryLines: [String]
    ) {
        self.title = title
        self.routeLabel = routeLabel
        self.modelLabel = modelLabel
        self.harnessLabel = harnessLabel
        self.reasoningLabel = reasoningLabel
        self.policy = policy
        self.privacyMode = privacyMode
        self.messageCount = messageCount
        self.actionCount = actionCount
        self.attachmentCount = attachmentCount
        self.queuedFollowUpCount = queuedFollowUpCount
        self.includesQueuedFollowUps = includesQueuedFollowUps
        self.isPinned = isPinned
        self.contentFingerprint = contentFingerprint
        self.isDuplicate = isDuplicate
        self.duplicateSessionIDs = duplicateSessionIDs
        self.summaryLines = summaryLines
    }
}

public struct SessionArchiveImportPlan: Equatable, Sendable {
    public let preview: SessionArchiveImportPreview
    public let session: LatticeSession
    public let document: PortableSessionDocument

    public init(preview: SessionArchiveImportPreview, session: LatticeSession, document: PortableSessionDocument) {
        self.preview = preview
        self.session = session
        self.document = document
    }
}

public struct SessionArchiveCommitResult: Equatable, Sendable {
    public let sessions: [LatticeSession]
    public let importedSessionID: UUID
    /// Import never auto-selects or starts the chat; selection is left unchanged unless callers opt in.
    public let selectedSessionID: UUID?

    public init(sessions: [LatticeSession], importedSessionID: UUID, selectedSessionID: UUID?) {
        self.sessions = sessions
        self.importedSessionID = importedSessionID
        self.selectedSessionID = selectedSessionID
    }
}

// MARK: - Export

public enum SessionPortableArchiveExporter {
    public static func makeDocument(
        from session: LatticeSession,
        options: SessionPortableArchive.ExportOptions = .init()
    ) -> PortableSessionDocument {
        var messageIndexByID: [UUID: Int] = [:]
        for (index, message) in session.messages.enumerated() {
            messageIndexByID[message.id] = index
        }
        let portableMessages = session.messages.map { message in
            PortableMessage(
                role: message.role.rawValue,
                text: message.text,
                date: message.date,
                isPinned: message.isPinned
            )
        }
        let portableAttachments = session.attachments.map { attachment in
            PortableAttachment(
                name: sanitizeAttachmentName(attachment.name),
                kind: attachment.isImage ? "image" : "file",
                availability: "metadata-only"
            )
        }
        let portableActions = session.actions.compactMap { action -> PortableAction? in
            // Only export user-visible summaries. Skip live running/waiting state entirely.
            guard action.status != .running, action.status != .waiting else { return nil }
            // Free-form provider titles/details may contain credentials or hidden reasoning. Portable
            // archives retain only a useful typed summary assembled from Lattice-owned enums.
            return PortableAction(
                kind: action.kind.rawValue,
                toolKind: action.toolKind?.rawValue,
                title: safeActionSummary(for: action),
                detail: "",
                status: portableStatus(for: action.status).rawValue,
                workspaceScoped: action.workspaceScoped,
                createdAt: action.createdAt,
                updatedAt: action.updatedAt,
                messageIndex: messageIndexByID[action.messageID]
            )
        }
        let queued: [PortableQueuedFollowUp]
        if options.includeQueuedFollowUps {
            queued = session.queuedFollowUps.map {
                PortableQueuedFollowUp(text: $0.text, date: $0.date)
            }
        } else {
            queued = []
        }

        let (route, model) = backendParts(session.backend)
        let chat = PortableChatPayload(
            title: session.title,
            isPinned: session.isPinned,
            lastUpdated: session.lastUpdated,
            backendRoute: route,
            backendModel: model,
            harnessID: session.harnessID,
            harnessLabel: session.backend.harnessName,
            reasoningEffort: session.reasoningEffort?.rawValue,
            policy: session.policy.rawValue,
            privacyMode: session.privacyMode.rawValue,
            messages: portableMessages,
            attachments: portableAttachments,
            actions: portableActions,
            queuedFollowUps: queued
        )
        return PortableSessionDocument(
            exportedAt: options.exportedAt,
            includeQueuedFollowUps: options.includeQueuedFollowUps,
            chat: chat
        )
    }

    public static func exportData(
        from session: LatticeSession,
        options: SessionPortableArchive.ExportOptions = .init()
    ) throws -> Data {
        switch options.format {
        case .jsonArchive:
            let document = makeDocument(from: session, options: options)
            let data = try encodeJSON(document)
            // An archive produced by Lattice must satisfy the same strict bounds it will enforce on import.
            _ = try SessionPortableArchiveImporter.prepareImport(data: data, existingSessions: [])
            return data
        case .markdown:
            let document = makeDocument(from: session, options: options)
            let validationData = try encodeJSON(document)
            _ = try SessionPortableArchiveImporter.prepareImport(data: validationData, existingSessions: [])
            let markdown = exportMarkdown(from: session, options: options)
            guard let data = markdown.data(using: .utf8) else {
                throw SessionPortableArchive.ArchiveError.writeFailed("Could not encode Markdown as UTF-8.")
            }
            if data.count > SessionPortableArchive.maxArchiveBytes {
                throw SessionPortableArchive.ArchiveError.fileTooLarge(
                    bytes: data.count,
                    limit: SessionPortableArchive.maxArchiveBytes
                )
            }
            return data
        }
    }

    public static func exportMarkdown(
        from session: LatticeSession,
        options: SessionPortableArchive.ExportOptions = .init()
    ) -> String {
        let document = makeDocument(from: session, options: options)
        var lines: [String] = []
        lines.append("# Lattice Chat Export")
        lines.append("")
        lines.append("> \(SessionPortableArchive.markdownNotImportableBanner)")
        lines.append(">")
        lines.append("> Ordinary unsent composer drafts are never included. Queued follow-ups are included only when explicitly chosen at export time.")
        lines.append("")
        lines.append("## \(document.chat.title)")
        lines.append("")
        lines.append("- **Route:** \(document.chat.harnessLabel ?? document.chat.backendRoute)")
        if let model = document.chat.backendModel, !model.isEmpty {
            lines.append("- **Model:** \(model)")
        }
        if let harness = document.chat.harnessID, !harness.isEmpty {
            lines.append("- **Harness:** \(harness)")
        }
        if let reasoning = document.chat.reasoningEffort {
            lines.append("- **Reasoning:** \(reasoning)")
        }
        lines.append("- **Policy:** \(document.chat.policy)")
        lines.append("- **Privacy:** \(document.chat.privacyMode)")
        lines.append("- **Pinned chat:** \(document.chat.isPinned ? "yes" : "no")")
        lines.append("- **Exported:** \(ISO8601DateFormatter.portable.string(from: document.exportedAt))")
        lines.append("")

        if document.chat.attachments.isEmpty {
            lines.append("## Attachments")
            lines.append("")
            lines.append("_None._")
            lines.append("")
        } else {
            lines.append("## Attachments (metadata only — file contents not embedded)")
            lines.append("")
            for attachment in document.chat.attachments {
                lines.append("- **\(attachment.name)** (`\(attachment.kind)`) — _not embedded; unavailable for transfer_")
            }
            lines.append("")
        }

        lines.append("## Transcript")
        lines.append("")
        if document.chat.messages.isEmpty {
            lines.append("_No messages._")
            lines.append("")
        } else {
            for message in document.chat.messages {
                let pin = message.isPinned ? " 📌" : ""
                let stamp = ISO8601DateFormatter.portable.string(from: message.date)
                lines.append("### \(message.role.capitalized)\(pin) · \(stamp)")
                lines.append("")
                lines.append(message.text.isEmpty ? "_Empty message._" : message.text)
                lines.append("")
            }
        }

        if !document.chat.actions.isEmpty {
            lines.append("## Action summaries (sanitized)")
            lines.append("")
            for action in document.chat.actions {
                lines.append("- **\(action.kind)** · \(action.status) · \(action.title)")
                if !action.detail.isEmpty {
                    lines.append("  - \(action.detail.replacingOccurrences(of: "\n", with: " "))")
                }
            }
            lines.append("")
        }

        if options.includeQueuedFollowUps {
            lines.append("## Queued follow-ups (explicitly included)")
            lines.append("")
            if document.chat.queuedFollowUps.isEmpty {
                lines.append("_None._")
            } else {
                for item in document.chat.queuedFollowUps {
                    let stamp = ISO8601DateFormatter.portable.string(from: item.date)
                    lines.append("- (\(stamp)) \(item.text)")
                }
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("Privacy: no provider thread IDs, secrets, hidden reasoning, attachment bytes, approval tokens, or running state are included.")
        return lines.joined(separator: "\n")
    }

    public static func suggestedFileName(for session: LatticeSession, format: SessionPortableArchive.ExportFormat) -> String {
        let base = session.title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let trimmed = base.isEmpty ? "lattice-chat" : String(base.prefix(48))
        return "\(trimmed).\(format.fileExtension)"
    }

    // MARK: private helpers

    private static func encodeJSON(_ document: PortableSessionDocument) throws -> Data {
        let object = jsonObject(from: document)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw SessionPortableArchive.ArchiveError.writeFailed("Archive JSON object is invalid.")
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func jsonObject(from document: PortableSessionDocument) -> [String: Any] {
        var chat: [String: Any] = [
            "title": document.chat.title,
            "isPinned": document.chat.isPinned,
            "lastUpdated": ISO8601DateFormatter.portable.string(from: document.chat.lastUpdated),
            "backendRoute": document.chat.backendRoute,
            "policy": document.chat.policy,
            "privacyMode": document.chat.privacyMode,
            "messages": document.chat.messages.map { message -> [String: Any] in
                [
                    "role": message.role,
                    "text": message.text,
                    "date": ISO8601DateFormatter.portable.string(from: message.date),
                    "isPinned": message.isPinned
                ]
            },
            "attachments": document.chat.attachments.map { attachment -> [String: Any] in
                [
                    "name": attachment.name,
                    "kind": attachment.kind,
                    "availability": attachment.availability
                ]
            },
            "actions": document.chat.actions.map { action -> [String: Any] in
                var item: [String: Any] = [
                    "kind": action.kind,
                    "title": action.title,
                    "detail": action.detail,
                    "status": action.status,
                    "workspaceScoped": action.workspaceScoped,
                    "createdAt": ISO8601DateFormatter.portable.string(from: action.createdAt),
                    "updatedAt": ISO8601DateFormatter.portable.string(from: action.updatedAt)
                ]
                if let toolKind = action.toolKind { item["toolKind"] = toolKind }
                if let messageIndex = action.messageIndex { item["messageIndex"] = messageIndex }
                return item
            },
            "queuedFollowUps": document.chat.queuedFollowUps.map { item -> [String: Any] in
                [
                    "text": item.text,
                    "date": ISO8601DateFormatter.portable.string(from: item.date)
                ]
            }
        ]
        if let model = document.chat.backendModel { chat["backendModel"] = model }
        if let harnessID = document.chat.harnessID { chat["harnessID"] = harnessID }
        if let harnessLabel = document.chat.harnessLabel { chat["harnessLabel"] = harnessLabel }
        if let reasoning = document.chat.reasoningEffort { chat["reasoningEffort"] = reasoning }

        return [
            "format": document.format,
            "version": document.version,
            "exportedAt": ISO8601DateFormatter.portable.string(from: document.exportedAt),
            "includeQueuedFollowUps": document.includeQueuedFollowUps,
            "chat": chat
        ]
    }

    private static func backendParts(_ backend: ChatBackend) -> (String, String?) {
        switch backend {
        case .codex(let model): ("codex", model)
        case .grok(let model): ("grok", model)
        case .openCode(let model): ("opencode", model)
        case .antigravity(let model): ("antigravity", model)
        case .appleIntelligence: ("appleIntelligence", nil)
        case .ollama(let model): ("ollama", model)
        }
    }

    private static func portableStatus(for status: SessionAction.Status) -> SessionAction.Status {
        switch status {
        case .running, .waiting:
            return .interrupted
        case .completed, .failed, .allowed, .denied, .cancelled, .interrupted:
            return status
        }
    }

    private static func safeActionSummary(for action: SessionAction) -> String {
        switch action.kind {
        case .tool:
            return action.toolKind.map { "\($0.rawValue.capitalized) tool action" } ?? "Tool action"
        case .approval:
            return "Approval decision"
        case .plan:
            return "Plan summary"
        case .reasoning:
            return "Reasoning summary"
        }
    }

    private static func sanitizeAttachmentName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = base
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned == "." || cleaned == ".." {
            return "attachment"
        }
        // Collapse path-like segments so archive never embeds traversal forms.
        return cleaned
            .split(whereSeparator: { $0 == "/" || $0 == "\\" })
            .map(String.init)
            .last
            .flatMap { $0.isEmpty ? nil : $0 } ?? "attachment"
    }

}

// MARK: - Fingerprint

public enum SessionPortableArchiveFingerprint {
    /// Deterministic privacy-safe hash of normalized portable content (no source IDs, no export timestamp).
    public static func contentFingerprint(for document: PortableSessionDocument) -> String {
        contentFingerprint(for: document.chat, includeQueuedFollowUps: document.includeQueuedFollowUps)
    }

    public static func contentFingerprint(for chat: PortableChatPayload, includeQueuedFollowUps: Bool) -> String {
        var lines: [String] = []
        lines.append("v1")
        lines.append(chat.title)
        lines.append(chat.isPinned ? "1" : "0")
        lines.append(ISO8601DateFormatter.portable.string(from: chat.lastUpdated))
        lines.append(chat.backendRoute)
        lines.append(chat.backendModel ?? "")
        lines.append(chat.harnessID ?? "")
        lines.append(chat.harnessLabel ?? "")
        lines.append(chat.reasoningEffort ?? "")
        lines.append(chat.policy)
        lines.append(chat.privacyMode)
        lines.append("messages:\(chat.messages.count)")
        for message in chat.messages {
            lines.append([
                message.role,
                message.isPinned ? "1" : "0",
                ISO8601DateFormatter.portable.string(from: message.date),
                message.text
            ].joined(separator: "\u{1f}"))
        }
        lines.append("attachments:\(chat.attachments.count)")
        for attachment in chat.attachments {
            lines.append([attachment.name, attachment.kind, attachment.availability].joined(separator: "\u{1f}"))
        }
        lines.append("actions:\(chat.actions.count)")
        for action in chat.actions {
            lines.append([
                action.kind,
                action.toolKind ?? "",
                action.title,
                action.detail,
                action.status,
                action.workspaceScoped ? "1" : "0",
                ISO8601DateFormatter.portable.string(from: action.createdAt),
                ISO8601DateFormatter.portable.string(from: action.updatedAt),
                action.messageIndex.map(String.init) ?? ""
            ].joined(separator: "\u{1f}"))
        }
        if includeQueuedFollowUps {
            lines.append("queued:\(chat.queuedFollowUps.count)")
            for item in chat.queuedFollowUps {
                lines.append([
                    ISO8601DateFormatter.portable.string(from: item.date),
                    item.text
                ].joined(separator: "\u{1f}"))
            }
        } else {
            lines.append("queued:0")
        }
        let payload = lines.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public static func matchingSessionIDs(
        fingerprint: String,
        document: PortableSessionDocument,
        in sessions: [LatticeSession]
    ) -> [UUID] {
        guard !fingerprint.isEmpty else { return [] }
        return sessions.compactMap { session in
            if session.portableArchiveFingerprint == fingerprint { return session.id }
            let normalized = SessionPortableArchiveExporter.makeDocument(
                from: session,
                options: .init(
                    includeQueuedFollowUps: document.includeQueuedFollowUps,
                    exportedAt: document.exportedAt
                )
            )
            return contentFingerprint(for: normalized) == fingerprint ? session.id : nil
        }
    }
}

// MARK: - Import validation + construction

public enum SessionPortableArchiveImporter {
    /// Validates archive bytes and builds a non-mutating import plan (new IDs, inert actions, missing attachments).
    public static func prepareImport(
        data: Data,
        existingSessions: [LatticeSession],
        now: Date = .now,
        idGenerator: () -> UUID = { UUID() }
    ) throws -> SessionArchiveImportPlan {
        try rejectOversized(data)
        if data.isEmpty { throw SessionPortableArchive.ArchiveError.emptyFile }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SessionPortableArchive.ArchiveError.unreadableUTF8
        }
        if looksLikeMarkdown(text) {
            throw SessionPortableArchive.ArchiveError.markdownNotImportable
        }

        let rootObject = try parseAndBoundJSON(data)
        try rejectSensitiveKeys(in: rootObject, path: "$")
        let document = try decodeDocument(from: rootObject)
        let fingerprint = SessionPortableArchiveFingerprint.contentFingerprint(for: document)
        let duplicates = SessionPortableArchiveFingerprint.matchingSessionIDs(
            fingerprint: fingerprint,
            document: document,
            in: existingSessions
        )
        var usedIDs = existingIdentitySet(existingSessions)
        let session = try materializeSession(
            from: document,
            fingerprint: fingerprint,
            now: now,
            usedIDs: &usedIDs,
            idGenerator: idGenerator
        )
        let preview = makePreview(document: document, session: session, fingerprint: fingerprint, duplicates: duplicates)
        return SessionArchiveImportPlan(preview: preview, session: session, document: document)
    }

    public static func prepareImport(
        fileURL: URL,
        existingSessions: [LatticeSession],
        now: Date = .now,
        idGenerator: () -> UUID = { UUID() },
        fileManager: FileManager = .default
    ) throws -> SessionArchiveImportPlan {
        // Size check before reading full contents when attributes are available.
        if let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
           let size = values.fileSize {
            if size > SessionPortableArchive.maxArchiveBytes {
                throw SessionPortableArchive.ArchiveError.fileTooLarge(
                    bytes: size,
                    limit: SessionPortableArchive.maxArchiveBytes
                )
            }
        }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            data = try handle.read(upToCount: SessionPortableArchive.maxArchiveBytes + 1) ?? Data()
        } catch {
            throw SessionPortableArchive.ArchiveError.writeFailed(
                "Could not read archive: \(error.localizedDescription)"
            )
        }
        // Never resolve attachment paths during import; only the user-selected archive file is read.
        _ = fileManager
        return try prepareImport(
            data: data,
            existingSessions: existingSessions,
            now: now,
            idGenerator: idGenerator
        )
    }

    /// Pure commit helper: inserts a new session without overwriting/merging any existing chat.
    /// Does not change selection and never starts a run.
    public static func commit(
        plan: SessionArchiveImportPlan,
        into existingSessions: [LatticeSession],
        selectedSessionID: UUID?
    ) -> SessionArchiveCommitResult {
        var next = existingSessions
        // Collision-safe: plan.session already carries freshly generated IDs.
        next.insert(plan.session, at: 0)
        return SessionArchiveCommitResult(
            sessions: next,
            importedSessionID: plan.session.id,
            selectedSessionID: selectedSessionID
        )
    }

    // MARK: decoding

    private static func rejectOversized(_ data: Data) throws {
        if data.count > SessionPortableArchive.maxArchiveBytes {
            throw SessionPortableArchive.ArchiveError.fileTooLarge(
                bytes: data.count,
                limit: SessionPortableArchive.maxArchiveBytes
            )
        }
    }

    private static func looksLikeMarkdown(_ text: String) -> Bool {
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400).lowercased()
        if head.hasPrefix("{") { return false }
        return head.contains("lattice chat export")
            || head.contains("not an importable archive")
            || head.contains(SessionPortableArchive.markdownNotImportableBanner.lowercased())
    }

    private static func parseAndBoundJSON(_ data: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw SessionPortableArchive.ArchiveError.invalidJSON
        }
        try validateJSONShape(object, depth: 1)
        guard let root = object as? [String: Any] else {
            throw SessionPortableArchive.ArchiveError.invalidJSON
        }
        return root
    }

    private static func validateJSONShape(_ value: Any, depth: Int) throws {
        if depth > SessionPortableArchive.maxJSONNestingDepth {
            throw SessionPortableArchive.ArchiveError.nestingTooDeep(
                depth: depth,
                limit: SessionPortableArchive.maxJSONNestingDepth
            )
        }
        if let dict = value as? [String: Any] {
            if dict.count > SessionPortableArchive.maxJSONCollectionCount {
                throw SessionPortableArchive.ArchiveError.collectionTooLarge(
                    count: dict.count,
                    limit: SessionPortableArchive.maxJSONCollectionCount
                )
            }
            for nested in dict.values {
                try validateJSONShape(nested, depth: depth + 1)
            }
        } else if let array = value as? [Any] {
            if array.count > SessionPortableArchive.maxJSONCollectionCount {
                throw SessionPortableArchive.ArchiveError.collectionTooLarge(
                    count: array.count,
                    limit: SessionPortableArchive.maxJSONCollectionCount
                )
            }
            for nested in array {
                try validateJSONShape(nested, depth: depth + 1)
            }
        } else if let string = value as? String {
            if string.count > SessionPortableArchive.maxStringLength {
                throw SessionPortableArchive.ArchiveError.stringTooLong(
                    field: "json",
                    length: string.count,
                    limit: SessionPortableArchive.maxStringLength
                )
            }
        }
    }

    private static let disallowedRootKeys: Set<String> = [
        "harnessThreadID", "providerThreadID", "providerSessionID", "threadID", "sessionToken",
        "apiKey", "api_key", "authorization", "secret", "secrets", "token", "tokens",
        "approvalToken", "approvalOptions", "approvalState", "pendingApproval",
        "isStreaming", "runningState", "rawProviderPayload", "chainOfThought", "hiddenReasoning",
        "draft", "composerDraft", "workspacePath", "workspaceContents", "attachmentBytes",
        "attachmentContents", "fileContents", "providerSecrets"
    ]

    private static let disallowedChatKeys: Set<String> = disallowedRootKeys.union([
        "id", "messageIDs", "actionIDs", "providerOwnedIDs"
    ])

    private static let allowedRootKeys: Set<String> = [
        "format", "version", "exportedAt", "includeQueuedFollowUps", "chat"
    ]

    private static let allowedChatKeys: Set<String> = [
        "title", "isPinned", "lastUpdated", "backendRoute", "backendModel", "harnessID", "harnessLabel",
        "reasoningEffort", "policy", "privacyMode", "messages", "attachments", "actions", "queuedFollowUps"
    ]

    private static let allowedMessageKeys: Set<String> = ["role", "text", "date", "isPinned"]
    private static let allowedAttachmentKeys: Set<String> = ["name", "kind", "availability"]
    private static let allowedActionKeys: Set<String> = [
        "kind", "toolKind", "title", "detail", "status", "workspaceScoped", "createdAt", "updatedAt", "messageIndex"
    ]
    private static let allowedQueuedKeys: Set<String> = ["text", "date"]

    private static func rejectSensitiveKeys(in root: [String: Any], path: String) throws {
        for key in root.keys {
            if disallowedRootKeys.contains(key) {
                throw SessionPortableArchive.ArchiveError.unknownSensitiveField(key)
            }
            if !allowedRootKeys.contains(key) {
                // Unknown future fields that are not sensitive-named are rejected for strictness.
                throw SessionPortableArchive.ArchiveError.unknownSensitiveField(key)
            }
        }
        guard let chat = root["chat"] as? [String: Any] else { return }
        for key in chat.keys {
            if disallowedChatKeys.contains(key) || !allowedChatKeys.contains(key) {
                throw SessionPortableArchive.ArchiveError.unknownSensitiveField(key)
            }
        }
        if let messages = chat["messages"] as? [[String: Any]] {
            for message in messages {
                for key in message.keys where !allowedMessageKeys.contains(key) {
                    throw SessionPortableArchive.ArchiveError.unknownSensitiveField(key)
                }
            }
        }
        if let attachments = chat["attachments"] as? [[String: Any]] {
            for attachment in attachments {
                for key in attachment.keys where !allowedAttachmentKeys.contains(key) {
                    throw SessionPortableArchive.ArchiveError.unknownSensitiveField(key)
                }
                if let pathValue = attachment["path"] as? String, !pathValue.isEmpty {
                    throw SessionPortableArchive.ArchiveError.unknownSensitiveField("path")
                }
            }
        }
        if let actions = chat["actions"] as? [[String: Any]] {
            for action in actions {
                for key in action.keys where !allowedActionKeys.contains(key) {
                    throw SessionPortableArchive.ArchiveError.unknownSensitiveField(key)
                }
            }
        }
        if let queued = chat["queuedFollowUps"] as? [[String: Any]] {
            for item in queued {
                for key in item.keys where !allowedQueuedKeys.contains(key) {
                    throw SessionPortableArchive.ArchiveError.unknownSensitiveField(key)
                }
            }
        }
        _ = path
    }

    private static func decodeDocument(from root: [String: Any]) throws -> PortableSessionDocument {
        guard let format = root["format"] as? String else {
            throw SessionPortableArchive.ArchiveError.missingField("format")
        }
        guard format == SessionPortableArchive.formatID else {
            throw SessionPortableArchive.ArchiveError.unknownFormat(format)
        }
        guard let version = strictInteger(root["version"]) else {
            throw SessionPortableArchive.ArchiveError.missingField("version")
        }
        guard version == SessionPortableArchive.currentVersion else {
            // Reject unknown future versions safely; only v1 is accepted.
            throw SessionPortableArchive.ArchiveError.unsupportedVersion(version)
        }
        let exportedAt = try parseDate(root["exportedAt"], field: "exportedAt") ?? .distantPast
        let includeQueued = try optionalBool(root["includeQueuedFollowUps"], field: "includeQueuedFollowUps") ?? false
        guard let chatObject = root["chat"] as? [String: Any] else {
            throw SessionPortableArchive.ArchiveError.missingField("chat")
        }
        let chat = try decodeChat(chatObject, includeQueuedFollowUps: includeQueued)
        return PortableSessionDocument(
            format: format,
            version: version,
            exportedAt: exportedAt,
            includeQueuedFollowUps: includeQueued,
            chat: chat
        )
    }

    private static func decodeChat(_ object: [String: Any], includeQueuedFollowUps: Bool) throws -> PortableChatPayload {
        let title = try requiredString(object["title"], field: "chat.title", limit: SessionPortableArchive.maxTitleLength)
        let isPinned = try optionalBool(object["isPinned"], field: "chat.isPinned") ?? false
        let lastUpdated = try parseDate(object["lastUpdated"], field: "chat.lastUpdated") ?? .distantPast
        let backendRoute = try requiredString(object["backendRoute"], field: "chat.backendRoute", limit: 64)
        try validateBackendRoute(backendRoute)
        let backendModel = try optionalString(object["backendModel"], field: "chat.backendModel", limit: SessionPortableArchive.maxModelLength)
        let harnessID = try optionalString(object["harnessID"], field: "chat.harnessID", limit: SessionPortableArchive.maxHarnessIDLength)
        let harnessLabel = try optionalString(object["harnessLabel"], field: "chat.harnessLabel", limit: 100)
        let reasoningEffort = try optionalString(object["reasoningEffort"], field: "chat.reasoningEffort", limit: 32)
        if let reasoningEffort {
            guard ReasoningEffort(rawValue: reasoningEffort) != nil else {
                throw SessionPortableArchive.ArchiveError.invalidEnum(field: "chat.reasoningEffort", value: reasoningEffort)
            }
        }
        let policy = try requiredString(object["policy"], field: "chat.policy", limit: 32)
        guard ExecutionPolicy(rawValue: policy) != nil else {
            throw SessionPortableArchive.ArchiveError.invalidEnum(field: "chat.policy", value: policy)
        }
        let privacyMode = try requiredString(object["privacyMode"], field: "chat.privacyMode", limit: 32)
        guard SessionPrivacyMode(rawValue: privacyMode) != nil else {
            throw SessionPortableArchive.ArchiveError.invalidEnum(field: "chat.privacyMode", value: privacyMode)
        }

        let messageObjects = try optionalArray(object["messages"], field: "chat.messages")
        if messageObjects.count > SessionPortableArchive.maxMessages {
            throw SessionPortableArchive.ArchiveError.countExceeded(
                field: "messages",
                count: messageObjects.count,
                limit: SessionPortableArchive.maxMessages
            )
        }
        var messages: [PortableMessage] = []
        messages.reserveCapacity(messageObjects.count)
        for (index, value) in messageObjects.enumerated() {
            guard let item = value as? [String: Any] else {
                throw SessionPortableArchive.ArchiveError.invalidField("messages[\(index)]")
            }
            messages.append(try decodeMessage(item, index: index))
        }

        let attachmentObjects = try optionalArray(object["attachments"], field: "chat.attachments")
        if attachmentObjects.count > SessionPortableArchive.maxAttachments {
            throw SessionPortableArchive.ArchiveError.countExceeded(
                field: "attachments",
                count: attachmentObjects.count,
                limit: SessionPortableArchive.maxAttachments
            )
        }
        var attachments: [PortableAttachment] = []
        for (index, value) in attachmentObjects.enumerated() {
            guard let item = value as? [String: Any] else {
                throw SessionPortableArchive.ArchiveError.invalidField("attachments[\(index)]")
            }
            attachments.append(try decodeAttachment(item, index: index))
        }

        let actionObjects = try optionalArray(object["actions"], field: "chat.actions")
        if actionObjects.count > SessionPortableArchive.maxActions {
            throw SessionPortableArchive.ArchiveError.countExceeded(
                field: "actions",
                count: actionObjects.count,
                limit: SessionPortableArchive.maxActions
            )
        }
        var actions: [PortableAction] = []
        for (index, value) in actionObjects.enumerated() {
            guard let item = value as? [String: Any] else {
                throw SessionPortableArchive.ArchiveError.invalidField("actions[\(index)]")
            }
            actions.append(try decodeAction(item, index: index, messageCount: messages.count))
        }

        var queued: [PortableQueuedFollowUp] = []
        let queuedObjects = try optionalArray(object["queuedFollowUps"], field: "chat.queuedFollowUps")
        if includeQueuedFollowUps {
            if queuedObjects.count > SessionPortableArchive.maxQueuedFollowUps {
                throw SessionPortableArchive.ArchiveError.countExceeded(
                    field: "queuedFollowUps",
                    count: queuedObjects.count,
                    limit: SessionPortableArchive.maxQueuedFollowUps
                )
            }
            for (index, value) in queuedObjects.enumerated() {
                guard let item = value as? [String: Any] else {
                    throw SessionPortableArchive.ArchiveError.invalidField("queuedFollowUps[\(index)]")
                }
                queued.append(try decodeQueued(item, index: index))
            }
        } else if !queuedObjects.isEmpty {
            throw SessionPortableArchive.ArchiveError.invalidField("chat.queuedFollowUps")
        }

        return PortableChatPayload(
            title: title,
            isPinned: isPinned,
            lastUpdated: lastUpdated,
            backendRoute: backendRoute,
            backendModel: backendModel,
            harnessID: harnessID,
            harnessLabel: harnessLabel,
            reasoningEffort: reasoningEffort,
            policy: policy,
            privacyMode: privacyMode,
            messages: messages,
            attachments: attachments,
            actions: actions,
            queuedFollowUps: queued
        )
    }

    private static func decodeMessage(_ object: [String: Any], index: Int) throws -> PortableMessage {
        let role = try requiredString(object["role"], field: "messages[\(index)].role", limit: 32)
        guard ChatMessage.Role(rawValue: role) != nil else {
            throw SessionPortableArchive.ArchiveError.invalidEnum(field: "messages[\(index)].role", value: role)
        }
        let text = try requiredString(object["text"], field: "messages[\(index)].text", limit: SessionPortableArchive.maxStringLength, allowEmpty: true)
        let date = try parseDate(object["date"], field: "messages[\(index)].date") ?? .distantPast
        let isPinned = try optionalBool(object["isPinned"], field: "messages[\(index)].isPinned") ?? false
        return PortableMessage(role: role, text: text, date: date, isPinned: isPinned)
    }

    private static func decodeAttachment(_ object: [String: Any], index: Int) throws -> PortableAttachment {
        // Refuse absolute / traversal / symlink-looking path fields if smuggled into name.
        if object["path"] != nil || object["url"] != nil || object["fileURL"] != nil || object["contents"] != nil || object["bytes"] != nil {
            throw SessionPortableArchive.ArchiveError.unknownSensitiveField("attachments[\(index)] path/contents")
        }
        let rawName = try requiredString(object["name"], field: "attachments[\(index)].name", limit: 500)
        let name = sanitizeImportedAttachmentName(rawName)
        let kind = try optionalString(object["kind"], field: "attachments[\(index)].kind", limit: 32) ?? "file"
        let availability = try optionalString(object["availability"], field: "attachments[\(index)].availability", limit: 64) ?? "metadata-only"
        guard kind == "file" || kind == "image" else {
            throw SessionPortableArchive.ArchiveError.invalidEnum(field: "attachments[\(index)].kind", value: kind)
        }
        guard availability == "metadata-only" else {
            throw SessionPortableArchive.ArchiveError.invalidEnum(field: "attachments[\(index)].availability", value: availability)
        }
        return PortableAttachment(name: name, kind: kind, availability: availability)
    }

    private static func decodeAction(_ object: [String: Any], index: Int, messageCount: Int) throws -> PortableAction {
        let kind = try requiredString(object["kind"], field: "actions[\(index)].kind", limit: 32)
        guard SessionAction.Kind(rawValue: kind) != nil else {
            throw SessionPortableArchive.ArchiveError.invalidEnum(field: "actions[\(index)].kind", value: kind)
        }
        let toolKind = try optionalString(object["toolKind"], field: "actions[\(index)].toolKind", limit: 32)
        if let toolKind, ToolRequest.Kind(rawValue: toolKind) == nil {
            throw SessionPortableArchive.ArchiveError.invalidEnum(field: "actions[\(index)].toolKind", value: toolKind)
        }
        let title = try requiredString(object["title"], field: "actions[\(index)].title", limit: SessionPortableArchive.maxTitleLength, allowEmpty: true)
        let detail = try requiredString(object["detail"], field: "actions[\(index)].detail", limit: SessionPortableArchive.maxDetailLength, allowEmpty: true)
        let statusRaw = try requiredString(object["status"], field: "actions[\(index)].status", limit: 32)
        guard let status = SessionAction.Status(rawValue: statusRaw) else {
            throw SessionPortableArchive.ArchiveError.invalidEnum(field: "actions[\(index)].status", value: statusRaw)
        }
        // Waiting/running must never be accepted as importable live state.
        if status == .running || status == .waiting {
            throw SessionPortableArchive.ArchiveError.invalidEnum(field: "actions[\(index)].status", value: statusRaw)
        }
        let workspaceScoped = try optionalBool(object["workspaceScoped"], field: "actions[\(index)].workspaceScoped") ?? false
        let createdAt = try parseDate(object["createdAt"], field: "actions[\(index)].createdAt") ?? .distantPast
        let updatedAt = try parseDate(object["updatedAt"], field: "actions[\(index)].updatedAt") ?? createdAt
        var messageIndex: Int?
        if let number = object["messageIndex"] as? Int {
            if number < 0 || number >= messageCount {
                throw SessionPortableArchive.ArchiveError.invalidField("actions[\(index)].messageIndex")
            }
            messageIndex = number
        } else if object["messageIndex"] != nil {
            throw SessionPortableArchive.ArchiveError.invalidField("actions[\(index)].messageIndex")
        }
        return PortableAction(
            kind: kind,
            toolKind: toolKind,
            title: title,
            detail: detail,
            status: status.rawValue,
            workspaceScoped: workspaceScoped,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messageIndex: messageIndex
        )
    }

    private static func decodeQueued(_ object: [String: Any], index: Int) throws -> PortableQueuedFollowUp {
        let text = try requiredString(object["text"], field: "queuedFollowUps[\(index)].text", limit: SessionPortableArchive.maxStringLength, allowEmpty: true)
        let date = try parseDate(object["date"], field: "queuedFollowUps[\(index)].date") ?? .distantPast
        return PortableQueuedFollowUp(text: text, date: date)
    }

    private static func materializeSession(
        from document: PortableSessionDocument,
        fingerprint: String,
        now: Date,
        usedIDs: inout Set<UUID>,
        idGenerator: () -> UUID
    ) throws -> LatticeSession {
        func freshID() -> UUID {
            for _ in 0..<32 {
                let candidate = idGenerator()
                if usedIDs.insert(candidate).inserted { return candidate }
            }
            while true {
                let candidate = UUID()
                if usedIDs.insert(candidate).inserted { return candidate }
            }
        }

        let chat = document.chat
        let backend = try backend(from: chat.backendRoute, model: chat.backendModel)
        let policy = ExecutionPolicy(rawValue: chat.policy) ?? .ask
        let privacy = SessionPrivacyMode(rawValue: chat.privacyMode) ?? .cloudAllowed
        let reasoning = chat.reasoningEffort.flatMap(ReasoningEffort.init(rawValue:))

        var messageIDMap: [Int: UUID] = [:]
        var messages: [ChatMessage] = []
        messages.reserveCapacity(chat.messages.count)
        for (index, portable) in chat.messages.enumerated() {
            let id = freshID()
            messageIDMap[index] = id
            let role = ChatMessage.Role(rawValue: portable.role) ?? .assistant
            messages.append(ChatMessage(id: id, role: role, text: portable.text, date: portable.date, isPinned: portable.isPinned))
        }

        // Attachment metadata only — never open/read/copy paths.
        let attachments: [ContextAttachment] = chat.attachments.map { portable in
            let name = sanitizeImportedAttachmentName(portable.name)
            let token = "\(SessionPortableArchive.missingAttachmentScheme):///\(name)"
            return ContextAttachment(id: freshID(), path: token, isMissing: true)
        }

        var actions: [SessionAction] = []
        actions.reserveCapacity(chat.actions.count)
        for portable in chat.actions {
            let kind = SessionAction.Kind(rawValue: portable.kind) ?? .tool
            let toolKind = portable.toolKind.flatMap(ToolRequest.Kind.init(rawValue:))
            let status = inertStatus(SessionAction.Status(rawValue: portable.status) ?? .completed)
            let messageID: UUID
            if let index = portable.messageIndex, let mapped = messageIDMap[index] {
                messageID = mapped
            } else if let first = messages.first?.id {
                messageID = first
            } else {
                messageID = freshID()
            }
            actions.append(
                SessionAction(
                    id: freshID(),
                    messageID: messageID,
                    kind: kind,
                    toolKind: toolKind,
                    title: portable.title,
                    detail: portable.detail,
                    status: status,
                    workspaceScoped: portable.workspaceScoped,
                    createdAt: portable.createdAt,
                    updatedAt: portable.updatedAt
                )
            )
        }

        let queued: [QueuedFollowUp]
        if document.includeQueuedFollowUps {
            queued = chat.queuedFollowUps.map {
                QueuedFollowUp(id: freshID(), text: $0.text, date: $0.date)
            }
        } else {
            queued = []
        }

        return LatticeSession(
            id: freshID(),
            title: chat.title,
            messages: messages,
            backend: backend,
            harnessID: chat.harnessID,
            reasoningEffort: reasoning,
            harnessThreadID: nil, // never restore provider thread IDs
            workspacePath: nil,   // not part of portable surface; avoids path leakage
            attachments: attachments,
            policy: policy,
            privacyMode: privacy,
            intent: nil,
            actions: actions,
            queuedFollowUps: queued,
            draft: "", // never import ordinary composer draft
            isPinned: chat.isPinned,
            isStreaming: false, // never restore running/streaming state
            lastUpdated: chat.lastUpdated == .distantPast ? now : chat.lastUpdated,
            portableArchiveFingerprint: fingerprint
        )
    }

    private static func makePreview(
        document: PortableSessionDocument,
        session: LatticeSession,
        fingerprint: String,
        duplicates: [UUID]
    ) -> SessionArchiveImportPreview {
        let routeLabel = document.chat.harnessLabel ?? document.chat.backendRoute
        let modelLabel = document.chat.backendModel ?? session.backend.displayName
        var lines: [String] = [
            "Title: \(document.chat.title)",
            "Route: \(routeLabel) · \(modelLabel)",
            "Messages: \(document.chat.messages.count)",
            "Actions: \(document.chat.actions.count)",
            "Attachments: \(document.chat.attachments.count) (metadata only; will show as missing)",
            "Policy: \(document.chat.policy)",
            "Privacy: \(document.chat.privacyMode)"
        ]
        if let reasoning = document.chat.reasoningEffort {
            lines.append("Reasoning: \(reasoning)")
        }
        if document.includeQueuedFollowUps {
            lines.append("Queued follow-ups: \(document.chat.queuedFollowUps.count) (included; not auto-sent)")
        } else {
            lines.append("Queued follow-ups: excluded")
        }
        if !duplicates.isEmpty {
            lines.append("Duplicate warning: a chat with the same portable content fingerprint already exists.")
        }
        lines.append("Import creates a new chat only. Nothing is overwritten or started automatically.")
        return SessionArchiveImportPreview(
            title: document.chat.title,
            routeLabel: routeLabel,
            modelLabel: modelLabel,
            harnessLabel: document.chat.harnessID ?? document.chat.harnessLabel,
            reasoningLabel: document.chat.reasoningEffort,
            policy: document.chat.policy,
            privacyMode: document.chat.privacyMode,
            messageCount: document.chat.messages.count,
            actionCount: document.chat.actions.count,
            attachmentCount: document.chat.attachments.count,
            queuedFollowUpCount: document.includeQueuedFollowUps ? document.chat.queuedFollowUps.count : 0,
            includesQueuedFollowUps: document.includeQueuedFollowUps,
            isPinned: document.chat.isPinned,
            contentFingerprint: fingerprint,
            isDuplicate: !duplicates.isEmpty,
            duplicateSessionIDs: duplicates,
            summaryLines: lines
        )
    }

    private static func backend(from route: String, model: String?) throws -> ChatBackend {
        let modelValue = model ?? ""
        switch route {
        case "codex": return .codex(model: modelValue)
        case "grok": return .grok(model: modelValue)
        case "opencode": return .openCode(model: modelValue)
        case "antigravity": return .antigravity(model: modelValue)
        case "appleIntelligence": return .appleIntelligence
        case "ollama": return .ollama(model: modelValue)
        default:
            throw SessionPortableArchive.ArchiveError.invalidEnum(field: "chat.backendRoute", value: route)
        }
    }

    private static func validateBackendRoute(_ route: String) throws {
        let allowed = ["codex", "grok", "opencode", "antigravity", "appleIntelligence", "ollama"]
        guard allowed.contains(route) else {
            throw SessionPortableArchive.ArchiveError.invalidEnum(field: "chat.backendRoute", value: route)
        }
    }

    private static func inertStatus(_ status: SessionAction.Status) -> SessionAction.Status {
        switch status {
        case .running, .waiting:
            return .interrupted
        case .completed, .failed, .allowed, .denied, .cancelled, .interrupted:
            return status
        }
    }

    private static func sanitizeImportedAttachmentName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(of: "\0", with: "")
        // Strip URL schemes and path components; refuse traversal.
        if let url = URL(string: name), let host = url.host, !host.isEmpty {
            name = url.lastPathComponent
        }
        name = name
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)
            .last ?? name
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." {
            return "attachment"
        }
        // Drop leading dots that could form hidden/relative forms.
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { return "attachment" }
        return String(name.prefix(200))
    }

    private static func requiredString(
        _ value: Any?,
        field: String,
        limit: Int,
        allowEmpty: Bool = false
    ) throws -> String {
        guard let string = value as? String else {
            throw SessionPortableArchive.ArchiveError.missingField(field)
        }
        if string.count > limit {
            throw SessionPortableArchive.ArchiveError.stringTooLong(field: field, length: string.count, limit: limit)
        }
        if !allowEmpty && string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw SessionPortableArchive.ArchiveError.invalidField(field)
        }
        return string
    }

    private static func optionalArray(_ value: Any?, field: String) throws -> [Any] {
        guard let value else { return [] }
        guard let array = value as? [Any] else {
            throw SessionPortableArchive.ArchiveError.invalidField(field)
        }
        return array
    }

    private static func optionalBool(_ value: Any?, field: String) throws -> Bool? {
        guard let value else { return nil }
        guard CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID(), let boolean = value as? Bool else {
            throw SessionPortableArchive.ArchiveError.invalidField(field)
        }
        return boolean
    }

    private static func strictInteger(_ value: Any?) -> Int? {
        guard let value else { return nil }
        guard CFGetTypeID(value as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        return value as? Int
    }

    private static func existingIdentitySet(_ sessions: [LatticeSession]) -> Set<UUID> {
        var ids = Set(sessions.map(\.id))
        for session in sessions {
            ids.formUnion(session.messages.map(\.id))
            ids.formUnion(session.attachments.map(\.id))
            ids.formUnion(session.actions.map(\.id))
            ids.formUnion(session.queuedFollowUps.map(\.id))
        }
        return ids
    }

    private static func optionalString(_ value: Any?, field: String, limit: Int) throws -> String? {
        guard let value else { return nil }
        guard let string = value as? String else {
            throw SessionPortableArchive.ArchiveError.invalidField(field)
        }
        if string.count > limit {
            throw SessionPortableArchive.ArchiveError.stringTooLong(field: field, length: string.count, limit: limit)
        }
        return string
    }

    private static func parseDate(_ value: Any?, field: String) throws -> Date? {
        guard let value else { return nil }
        if let string = value as? String {
            if let date = ISO8601DateFormatter.portable.date(from: string)
                ?? ISO8601DateFormatter.portableFractional.date(from: string) {
                return date
            }
            throw SessionPortableArchive.ArchiveError.invalidDate(field)
        }
        throw SessionPortableArchive.ArchiveError.invalidDate(field)
    }
}

// MARK: - Privacy proof helpers (tests / verify)

public enum SessionPortableArchivePrivacy {
    public static let forbiddenExportSubstrings = [
        "harnessThreadID",
        "providerThreadID",
        "providerSessionID",
        "apiKey",
        "api_key",
        "authorization",
        "chainOfThought",
        "hiddenReasoning",
        "approvalToken",
        "pendingApproval",
        "isStreaming",
        "attachmentBytes",
        "fileContents"
    ]

    public static func assertExportPrivacy(in data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return ["non-utf8"] }
        return forbiddenExportSubstrings.filter { text.contains($0) }
    }

    public static func containsProviderThreadID(in data: Data, threadID: String) -> Bool {
        guard !threadID.isEmpty, let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(threadID)
    }
}

// MARK: - Date helpers

private extension ISO8601DateFormatter {
    nonisolated(unsafe) static let portable: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    nonisolated(unsafe) static let portableFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
