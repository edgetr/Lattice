import Foundation

public enum ExecutionPolicy: String, CaseIterable, Codable, Sendable {
    case ask = "Ask"
    case smart = "Smart"
    case yolo = "YOLO"
}

public enum SessionPrivacyMode: String, CaseIterable, Codable, Sendable {
    case cloudAllowed
    case localOnly

    public var displayName: String {
        switch self {
        case .cloudAllowed: "Cloud allowed"
        case .localOnly: "Local only"
        }
    }
}

public enum MorphingControlState: Equatable, Sendable {
    case compact
    case expanded
    case context
    case progress(Double)
    case approval
    case success
    case failure(String)
}

public struct ModelDescriptor: Identifiable, Hashable, Codable, Sendable {
    public enum Engine: String, Codable, Sendable { case mlx, llamaCPP, remote, unavailable }
    public enum Fit: String, Codable, Sendable { case comfortable, tight, risky, unsupported, unknown }

    public let id: String
    public let name: String
    public let provider: String
    public let engine: Engine
    public let quantization: String
    public let contextWindow: Int
    public let capabilities: Set<String>
    public let fit: Fit
    public let isLocal: Bool

    public init(id: String, name: String, provider: String, engine: Engine, quantization: String, contextWindow: Int, capabilities: Set<String>, fit: Fit, isLocal: Bool) {
        self.id = id; self.name = name; self.provider = provider; self.engine = engine
        self.quantization = quantization; self.contextWindow = contextWindow
        self.capabilities = capabilities; self.fit = fit; self.isLocal = isLocal
    }
}

public struct HarnessProfile: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let executable: String?
    public let protocolName: String
    public let supportsTools: Bool
    public let isQualifiedForActions: Bool

    public init(id: String, name: String, executable: String?, protocolName: String, supportsTools: Bool, isQualifiedForActions: Bool) {
        self.id = id; self.name = name; self.executable = executable; self.protocolName = protocolName
        self.supportsTools = supportsTools; self.isQualifiedForActions = isQualifiedForActions
    }
}

public struct ChatMessage: Identifiable, Hashable, Codable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, system }
    public let id: UUID
    public let role: Role
    public var text: String
    public let date: Date
    public var isPinned: Bool

    public init(id: UUID = UUID(), role: Role, text: String, date: Date = .now, isPinned: Bool = false) {
        self.id = id; self.role = role; self.text = text; self.date = date; self.isPinned = isPinned
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, date, isPinned
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        date = try container.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(date, forKey: .date)
        try container.encode(isPinned, forKey: .isPinned)
    }
}

public struct QueuedFollowUp: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var text: String
    public let date: Date

    public init(id: UUID = UUID(), text: String, date: Date = .now) {
        self.id = id
        self.text = text
        self.date = date
    }
}

public enum LatticeContinuationPolicy {
    public static let prompt = "Continue from where you left off."

    public static func canContinue(_ session: LatticeSession) -> Bool {
        guard !session.isStreaming,
              let message = session.messages.last,
              message.role == .assistant else { return false }
        let hasText = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasArtifact = session.isArtifactsLoaded && session.artifacts.contains { $0.messageID == message.id }
        return hasText || hasArtifact
    }
}

public enum LatticeSessionIntent: String, Codable, Sendable {
    case selfEdit
}

public enum LatticeSelfEditCommand {
    public static let name = "/self-edit"

    public static func prompt(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == name || trimmed.hasPrefix("\(name) ") || trimmed.hasPrefix("\(name)\t") else { return nil }
        return String(trimmed.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct LatticeAppCommand: Identifiable, Hashable, Sendable {
    public let id: String
    public let invocation: String
    public let title: String
    public let detail: String
    public let replacementText: String?

    public init(id: String, invocation: String, title: String, detail: String, replacementText: String? = nil) {
        self.id = id
        self.invocation = invocation
        self.title = title
        self.detail = detail
        self.replacementText = replacementText
    }
}

public enum LatticeAppCommandCatalog {
    public static let selfEdit = LatticeAppCommand(
        id: "self-edit",
        invocation: LatticeSelfEditCommand.name,
        title: "Edit Lattice",
        detail: "Create a user-owned extension"
    )

    public static let all: [LatticeAppCommand] = [selfEdit]

    public static func uniqueByInvocation(_ commands: [LatticeAppCommand]) -> [LatticeAppCommand] {
        var seen = Set<String>()
        var unique: [LatticeAppCommand] = []
        for command in commands {
            let key = command.invocation.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            unique.append(command)
        }
        return unique
    }

    public static func suggestions(for draft: String, commands: [LatticeAppCommand] = all) -> [LatticeAppCommand] {
        let leadingTrimmed = String(draft.drop(while: \.isWhitespace))
        guard leadingTrimmed.hasPrefix("/") else { return [] }
        let commandToken = leadingTrimmed.dropFirst()
        guard !commandToken.contains(where: \.isWhitespace) else { return [] }
        let query = String(commandToken)
        let uniqueCommands = uniqueByInvocation(commands)
        guard !query.isEmpty else { return uniqueCommands }
        return uniqueCommands.filter { command in
            let token = String(command.invocation.dropFirst())
            return token.localizedCaseInsensitiveContains(query)
        }
    }

    public static func completion(for draft: String, commands: [LatticeAppCommand] = all) -> LatticeAppCommand? {
        let matches = suggestions(for: draft, commands: commands)
        return matches.count == 1 ? matches[0] : nil
    }
}

/// Keeps slash-command discovery useful without allowing a large catalog to
/// consume the conversation viewport. Results remain scrollable, not truncated.
public enum CommandSuggestionLayoutPolicy {
    public static let maximumVisibleRows = 7
    public static let estimatedRowHeight = 54.0

    public static func height(resultCount: Int) -> Double {
        guard resultCount > 0 else { return 0 }
        return Double(min(resultCount, maximumVisibleRows)) * estimatedRowHeight
    }
}

public struct LatticeCommandPaletteItem: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case command
        case chat(UUID)
    }

    public let id: String
    public let title: String
    public let detail: String
    public let keywords: [String]
    public let isEnabled: Bool
    public let disabledReason: String?
    public let kind: Kind
    public let chatState: LatticeCommandPaletteChatState?

    public init(
        id: String,
        title: String,
        detail: String = "",
        keywords: [String] = [],
        isEnabled: Bool = true,
        disabledReason: String? = nil,
        kind: Kind = .command,
        chatState: LatticeCommandPaletteChatState? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
        self.kind = kind
        self.chatState = chatState
    }
}

public struct LatticeCommandPaletteChatState: Hashable, Sendable {
    public let activityStatus: ThreadActivityStatus
    public let queuedCount: Int
    public let hasUnreadActivity: Bool
    public let requiresAttention: Bool
    public let isCurrent: Bool

    public init(
        activityStatus: ThreadActivityStatus,
        queuedCount: Int = 0,
        hasUnreadActivity: Bool = false,
        requiresAttention: Bool = false,
        isCurrent: Bool = false
    ) {
        self.activityStatus = activityStatus
        self.queuedCount = max(0, queuedCount)
        self.hasUnreadActivity = hasUnreadActivity
        self.requiresAttention = requiresAttention
        self.isCurrent = isCurrent
    }
}

public enum LatticeCommandPaletteMatcher {
    public static func filtered(_ items: [LatticeCommandPaletteItem], query: String) -> [LatticeCommandPaletteItem] {
        let tokens = query
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return items }
        return items.filter { item in
            let searchable = ([item.title, item.detail] + item.keywords).joined(separator: " ").lowercased()
            return tokens.allSatisfy { searchable.contains($0) }
        }
    }

    public static func firstEnabled(in items: [LatticeCommandPaletteItem], query: String) -> LatticeCommandPaletteItem? {
        filtered(items, query: query).first(where: \.isEnabled)
    }
}

/// Shared mouse/keyboard selection policy for the command palette.
public enum LatticeCommandPaletteSelection: Sendable {
    /// Prefer the current enabled selection; otherwise select the first enabled item (or `nil` when none).
    public static func clampedSelection(selectedID: String?, in items: [LatticeCommandPaletteItem]) -> String? {
        if let selectedID, items.contains(where: { $0.id == selectedID && $0.isEnabled }) {
            return selectedID
        }
        return items.first(where: \.isEnabled)?.id
    }

    /// Hover adopts an enabled row as the shared selection.
    /// Returns `nil` for missing/disabled rows so callers leave selection unchanged (mouse exit must not clear).
    public static func selectionAfterHover(hoveredID: String, in items: [LatticeCommandPaletteItem]) -> String? {
        guard items.contains(where: { $0.id == hoveredID && $0.isEnabled }) else { return nil }
        return hoveredID
    }

    /// Move the selection by `delta` among enabled visible rows, continuing from the current shared selection.
    public static func movedSelection(selectedID: String?, in items: [LatticeCommandPaletteItem], delta: Int) -> String? {
        let enabledItems = items.filter(\.isEnabled)
        guard !enabledItems.isEmpty else { return nil }
        guard delta != 0 else { return clampedSelection(selectedID: selectedID, in: enabledItems) }
        let currentIndex = selectedID.flatMap { id in enabledItems.firstIndex(where: { $0.id == id }) } ?? -1
        let nextIndex: Int
        if currentIndex < 0 {
            nextIndex = delta > 0 ? 0 : enabledItems.count - 1
        } else {
            nextIndex = min(max(currentIndex + delta, 0), enabledItems.count - 1)
        }
        return enabledItems[nextIndex].id
    }

    /// Return/click only execute enabled selections.
    public static func executableSelection(selectedID: String?, in items: [LatticeCommandPaletteItem]) -> LatticeCommandPaletteItem? {
        guard let selectedID else { return nil }
        return items.first(where: { $0.id == selectedID && $0.isEnabled })
    }
}

public struct ProviderEventDiagnostic: Hashable, Sendable {
    public let id: UUID
    public let provider: String
    public let eventType: String?
    public let reason: String
    public let fields: [String]

    public init(id: UUID = UUID(), provider: String, eventType: String? = nil, reason: String, fields: [String] = []) {
        self.id = id
        self.provider = String(provider.prefix(80))
        self.eventType = eventType.map { String($0.prefix(120)) }
        self.reason = String(reason.prefix(240))
        self.fields = Array(fields.sorted().prefix(32))
    }

    public var title: String { "\(provider) provider event not understood" }
    /// Metadata only. Never includes provider payload values.
    public var detail: String {
        var parts = [reason]
        if let eventType, !eventType.isEmpty { parts.append("Event: \(eventType)") }
        if !fields.isEmpty { parts.append("Fields: \(fields.joined(separator: ", "))") }
        return parts.joined(separator: " ")
    }
}

public struct HarnessActivityEvent: Hashable, Sendable {
    public enum Status: String, Hashable, Sendable {
        case running
        case completed
        case failed
        case cancelled
        case degraded
        case unsupported
    }

    public let id: UUID
    public let provider: String
    public let title: String
    public let detail: String
    public let status: Status

    public init(id: UUID, provider: String, title: String, detail: String, status: Status) {
        self.id = id
        self.provider = String(provider.prefix(80))
        self.title = String(title.prefix(160))
        self.detail = String(detail.prefix(600))
        self.status = status
    }
}

public struct AgentPlanStep: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case pending
        case inProgress
        case completed
    }

    public let id: UUID
    public let title: String
    public let status: Status

    public init(id: UUID, title: String, status: Status) {
        self.id = id
        self.title = title
        self.status = status
    }
}

public enum AgentEvent: Sendable, Equatable {
    case sessionStarted(UUID)
    case harnessSessionStarted(String)
    /// Provider rejected its persisted session; continuity is rebuilt only from visible transcript.
    case harnessSessionRecovery(String)
    case assistantDelta(String)
    case plan(id: UUID, title: String, explanation: String?, steps: [AgentPlanStep])
    case reasoningSummary(id: UUID, delta: String)
    case toolRequested(ToolRequest)
    case toolProgress(id: UUID, fraction: Double, detail: String)
    case permissionRequested(ApprovalRequest)
    /// Typed permission decision produced for a structured provider request.
    case permissionDecided(ProviderPermissionDecision)
    /// Observable provider-session lifecycle. This is ephemeral run state, not persisted provider state.
    case providerSessionLifecycle(ProviderSessionLifecycleEvent)
    /// Supplies the reason before the legacy terminal `cancelled` marker.
    case runCancelled(AgentCancellation)
    case metric(name: String, value: Double, unit: String)
    case harnessActivity(HarnessActivityEvent)
    case providerDiagnostic(ProviderEventDiagnostic)
    /// Typed assistant media artifact (metadata + authorized local path only; never bytes/base64).
    case artifact(AssistantArtifactObservation)
    case completed
    case cancelled
    case failed(String)
}

/// Typed multimodal attachment role for context inputs.
public enum ContextAttachmentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case image
    case file
}

/// How an attachment entered Lattice. Legacy/imported values preserve pre-metadata archives.
public enum ContextAttachmentSource: String, Codable, Sendable, Hashable, CaseIterable {
    case picker
    case drop
    case paste
    case screenshot
    /// Constructed or decoded without explicit provenance (pre-metadata archives / legacy callers).
    case legacy
    /// Portable-archive or other import token that must not be resolved on disk.
    case imported
}

/// Pixel size when image metadata can be read without decoding full pixel buffers.
public struct ContextAttachmentPixelDimensions: Hashable, Codable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
    }

    public var longestEdge: Int { max(width, height) }
}

public struct ContextAttachment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    /// Local absolute path for live attachments, or a non-resolvable display token for imported/missing ones.
    public let path: String
    /// When true, the attachment is metadata-only and must not be opened, read, or resolved on disk.
    public var isMissing: Bool
    /// Image vs ordinary file classification. Prefer inspected type evidence over extension alone.
    public var kind: ContextAttachmentKind
    /// UTType-like identifier when known (for example `public.png`). Never carries file bytes.
    public var contentTypeIdentifier: String?
    /// MIME type when known (for example `image/png`). Never carries file bytes.
    public var mimeType: String?
    /// Byte length when safely obtainable from filesystem metadata.
    public var byteCount: Int64?
    /// Image pixel dimensions when safely obtainable from bounded image metadata.
    public var pixelDimensions: ContextAttachmentPixelDimensions?
    /// Provenance of how this attachment entered the session.
    public var source: ContextAttachmentSource

    public var name: String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "attachment" }
        if trimmed.contains("://") {
            return URL(string: trimmed)?.lastPathComponent.isEmpty == false
                ? (URL(string: trimmed)?.lastPathComponent ?? "attachment")
                : "attachment"
        }
        return URL(fileURLWithPath: trimmed).lastPathComponent
    }

    /// True when the typed kind is image. Legacy archives derive kind from extension at decode time.
    public var isImage: Bool { kind == .image }

    /// Legacy-compatible initializer retained for existing callers.
    /// Classifies kind from the path extension only and records `source` as `.legacy`.
    public init(id: UUID = UUID(), path: String, isMissing: Bool = false) {
        self.init(
            id: id,
            path: path,
            isMissing: isMissing,
            kind: ContextAttachmentTypeMap.kind(forPathExtension: ContextAttachmentTypeMap.pathExtension(of: path)),
            contentTypeIdentifier: nil,
            mimeType: nil,
            byteCount: nil,
            pixelDimensions: nil,
            source: .legacy
        )
    }

    public init(
        id: UUID = UUID(),
        path: String,
        isMissing: Bool = false,
        kind: ContextAttachmentKind,
        contentTypeIdentifier: String? = nil,
        mimeType: String? = nil,
        byteCount: Int64? = nil,
        pixelDimensions: ContextAttachmentPixelDimensions? = nil,
        source: ContextAttachmentSource
    ) {
        self.id = id
        self.path = path
        self.isMissing = isMissing
        self.kind = kind
        self.contentTypeIdentifier = Self.normalizedOptional(contentTypeIdentifier)
        self.mimeType = Self.normalizedOptional(mimeType)
        self.byteCount = byteCount.flatMap { $0 >= 0 ? $0 : nil }
        self.pixelDimensions = pixelDimensions
        self.source = source
    }

    /// Builds an attachment from a local URL using bounded metadata inspection only.
    public static func inspecting(
        url: URL,
        source: ContextAttachmentSource,
        id: UUID = UUID(),
        inspector: any ContextAttachmentInspecting = FileContextAttachmentInspector()
    ) -> ContextAttachment {
        inspecting(path: url.path, source: source, id: id, inspector: inspector)
    }

    /// Builds an attachment from a path using bounded metadata inspection only.
    public static func inspecting(
        path: String,
        source: ContextAttachmentSource,
        id: UUID = UUID(),
        inspector: any ContextAttachmentInspecting = FileContextAttachmentInspector()
    ) -> ContextAttachment {
        let classification = ContextAttachmentClassifier.classify(
            path: path,
            evidence: inspector.inspect(path: path)
        )
        return ContextAttachment(
            id: id,
            path: path,
            isMissing: classification.isMissing,
            kind: classification.kind,
            contentTypeIdentifier: classification.contentTypeIdentifier,
            mimeType: classification.mimeType,
            byteCount: classification.byteCount,
            pixelDimensions: classification.pixelDimensions,
            source: source
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, isMissing
        case kind, contentTypeIdentifier, mimeType, byteCount, pixelDimensions, source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        isMissing = try container.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false
        kind = try container.decodeIfPresent(ContextAttachmentKind.self, forKey: .kind)
            ?? ContextAttachmentTypeMap.kind(forPathExtension: ContextAttachmentTypeMap.pathExtension(of: path))
        contentTypeIdentifier = Self.normalizedOptional(
            try container.decodeIfPresent(String.self, forKey: .contentTypeIdentifier)
        )
        mimeType = Self.normalizedOptional(
            try container.decodeIfPresent(String.self, forKey: .mimeType)
        )
        byteCount = try container.decodeIfPresent(Int64.self, forKey: .byteCount).flatMap { $0 >= 0 ? $0 : nil }
        pixelDimensions = try container.decodeIfPresent(ContextAttachmentPixelDimensions.self, forKey: .pixelDimensions)
        source = try container.decodeIfPresent(ContextAttachmentSource.self, forKey: .source) ?? .legacy
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(isMissing, forKey: .isMissing)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(contentTypeIdentifier, forKey: .contentTypeIdentifier)
        try container.encodeIfPresent(mimeType, forKey: .mimeType)
        try container.encodeIfPresent(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(pixelDimensions, forKey: .pixelDimensions)
        try container.encode(source, forKey: .source)
        // Intentionally never encode file bytes or base64 payloads.
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum ReasoningEffort: String, CaseIterable, Codable, Sendable, Identifiable {
    case none, minimal, low, medium, high, xhigh, max, thinking

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .none: "None"
        case .minimal: "Minimal"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra High"
        case .max: "Max"
        case .thinking: "Thinking"
        }
    }
}

public struct ReasoningOption: Identifiable, Hashable, Codable, Sendable {
    public let effort: ReasoningEffort
    public let description: String
    public var id: ReasoningEffort { effort }

    public init(effort: ReasoningEffort, description: String = "") {
        self.effort = effort
        self.description = description
    }
}

public struct ProviderModel: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let reasoningOptions: [ReasoningOption]
    public let defaultReasoningEffort: ReasoningEffort?
    public let contextWindow: Int?
    public let isDefault: Bool
    /// Nil means the runtime did not advertise input modalities; never infer support from model name.
    public let inputModalities: Set<ModelInputModality>?

    public init(id: String, name: String, description: String = "", reasoningOptions: [ReasoningOption] = [], defaultReasoningEffort: ReasoningEffort? = nil, contextWindow: Int? = nil, isDefault: Bool = false, inputModalities: Set<ModelInputModality>? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.reasoningOptions = reasoningOptions
        self.defaultReasoningEffort = defaultReasoningEffort
        self.contextWindow = contextWindow.flatMap { $0 > 0 ? $0 : nil }
        self.isDefault = isDefault
        self.inputModalities = inputModalities
    }
}

public enum ProviderModelMetadata {
    public static func contextWindow(from object: [String: Any]) -> Int? {
        for key in ["contextWindow", "context_window", "contextLength", "context_length", "maxContextWindow", "max_context_window", "maxContextLength", "max_context_length", "modelContextWindow", "model_context_window"] {
            if let value = positiveInteger(object[key]) { return value }
        }
        for containerKey in ["limit", "limits", "metadata"] {
            if let nested = object[containerKey] as? [String: Any] {
                for key in ["context", "contextWindow", "context_window", "contextLength", "context_length"] {
                    if let value = positiveInteger(nested[key]) { return value }
                }
            }
        }
        return nil
    }

    private static func positiveInteger(_ value: Any?) -> Int? {
        switch value {
        case let number as Int where number > 0:
            return number
        case let number as NSNumber where number.intValue > 0:
            return number.intValue
        case let string as String:
            let normalized = string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "_", with: "")
            let multiplier: Int
            let numeric: Substring
            if normalized.hasSuffix("k") {
                multiplier = 1_000
                numeric = normalized.dropLast()
            } else if normalized.hasSuffix("m") {
                multiplier = 1_000_000
                numeric = normalized.dropLast()
            } else {
                multiplier = 1
                numeric = Substring(normalized)
            }
            guard let base = Double(numeric), base > 0 else { return nil }
            return Int(base * Double(multiplier))
        default:
            return nil
        }
    }
}

public struct UsageWindow: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let usedPercent: Int
    public let resetsAt: Date?
    public var remainingPercent: Int { max(0, 100 - usedPercent) }

    public init(id: String, name: String, usedPercent: Int, resetsAt: Date?) {
        self.id = id; self.name = name; self.usedPercent = usedPercent; self.resetsAt = resetsAt
    }
}

public struct ProviderUsage: Hashable, Codable, Sendable {
    public let windows: [UsageWindow]
    public let creditsBalance: String?
    public init(windows: [UsageWindow], creditsBalance: String? = nil) {
        self.windows = windows; self.creditsBalance = creditsBalance
    }
}

public struct CLIUpdateInfo: Hashable, Codable, Sendable {
    public let currentVersion: String?
    public let latestVersion: String?
    public let updateAvailable: Bool?
    public let releaseNotes: String?
    public let detail: String?

    public init(currentVersion: String? = nil, latestVersion: String? = nil, updateAvailable: Bool? = nil, releaseNotes: String? = nil, detail: String? = nil) {
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.updateAvailable = updateAvailable
        self.releaseNotes = releaseNotes
        self.detail = detail
    }

    public var statusText: String {
        if updateAvailable == true, let latestVersion { return "Update available · \(latestVersion)" }
        if updateAvailable == true { return "Update available" }
        if updateAvailable == false { return "Up to date" }
        return detail ?? ""
    }
}

public enum ConversationMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case code
    case work
    case local

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .code: "Code"
        case .work: "Work"
        case .local: "Local"
        }
    }
}

public enum ChatBackend: Hashable, Codable, Sendable, Identifiable {
    case codex(model: String)
    case grok(model: String)
    case openCode(model: String)
    case antigravity(model: String)
    case appleIntelligence
    case ollama(model: String)

    public var id: String {
        switch self {
        case .codex(let model): "codex:\(model)"
        case .grok(let model): "grok:\(model)"
        case .openCode(let model): "opencode:\(model)"
        case .antigravity(let model): "antigravity:\(model)"
        case .appleIntelligence: "apple-intelligence"
        case .ollama(let model): "ollama:\(model)"
        }
    }
    public var displayName: String {
        switch self {
        case .codex(let model), .grok(let model), .openCode(let model), .antigravity(let model), .ollama(let model): model
        case .appleIntelligence: "Apple Intelligence"
        }
    }
    public var harnessName: String {
        switch self {
        case .codex: "Codex"
        case .grok: "Grok"
        case .openCode: "OpenCode"
        case .antigravity: "Antigravity"
        case .appleIntelligence: "On-device"
        case .ollama: "Local"
        }
    }

    public var isLocal: Bool {
        switch self {
        case .appleIntelligence, .ollama:
            true
        case .codex, .grok, .openCode, .antigravity:
            false
        }
    }
}

/// Stable persisted identity for execution. Runtime ID names harness/client boundary,
/// while provider and model IDs preserve user selection.
public struct ExecutionRoute: Hashable, Codable, Sendable, Identifiable {
    public let mode: ConversationMode
    public let providerID: String
    public let modelID: String?
    public let runtimeID: String

    public init(
        mode: ConversationMode,
        providerID: String,
        modelID: String? = nil,
        runtimeID: String
    ) {
        self.mode = mode
        self.providerID = providerID
        self.modelID = modelID
        self.runtimeID = runtimeID
    }

    /// Compatibility spelling for callers that still call runtimes harnesses.
    public var harnessID: String { runtimeID }

    public var id: String {
        [mode.rawValue, providerID, modelID ?? "", runtimeID].joined(separator: "\u{1f}")
    }

    /// Reconstruct old persisted sessions without remapping direct provider routes.
    public static func legacy(for backend: ChatBackend, harnessID: String?) -> ExecutionRoute {
        let runtime = { (fallback: String) in
            let value = harnessID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? fallback : value
        }

        switch backend {
        case .codex(let model):
            return ExecutionRoute(mode: .code, providerID: "codex", modelID: model, runtimeID: runtime("codex"))
        case .grok(let model):
            return ExecutionRoute(mode: .code, providerID: "grok", modelID: model, runtimeID: runtime("grok"))
        case .openCode(let model):
            return ExecutionRoute(mode: .code, providerID: "opencode", modelID: model, runtimeID: runtime("opencode"))
        case .antigravity(let model):
            return ExecutionRoute(mode: .code, providerID: "antigravity", modelID: model, runtimeID: runtime("antigravity"))
        case .appleIntelligence:
            return ExecutionRoute(mode: .local, providerID: "apple", modelID: nil, runtimeID: runtime("lattice"))
        case .ollama(let model):
            return ExecutionRoute(mode: .local, providerID: "ollama", modelID: model, runtimeID: runtime("lattice"))
        }
    }
}

public struct EngineHarnessSelection: Hashable, Codable, Sendable {
    public var engineID: String
    public var harnessID: String

    public init(engineID: String, harnessID: String) {
        self.engineID = engineID
        self.harnessID = harnessID
    }
}

public struct ToolRequest: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case read, write, command, network, automation, credential, destructive, unknown }
    public let id: UUID
    public let kind: Kind
    public let title: String
    public let detail: String
    public let workspaceScoped: Bool
    public let reversible: Bool

    public init(id: UUID = UUID(), kind: Kind, title: String, detail: String, workspaceScoped: Bool, reversible: Bool) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail
        self.workspaceScoped = workspaceScoped; self.reversible = reversible
    }
}

public struct ApprovalOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: String

    public init(id: String, name: String, kind: String) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var isAllow: Bool { kind.hasPrefix("allow_") }
    public var isReject: Bool { kind.hasPrefix("reject_") }
}

public struct ApprovalRequest: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let title: String
    public let detail: String
    public let options: [ApprovalOption]
    public let toolRequest: ToolRequest?
    public init(id: UUID = UUID(), title: String, detail: String, options: [ApprovalOption] = [], toolRequest: ToolRequest? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.options = options
        self.toolRequest = toolRequest
    }
}

/// Durable, privacy-bounded evidence for a permission decision.
/// Provider payloads, prompts, tokens, and raw option IDs are intentionally excluded.
public struct ApprovalProvenance: Hashable, Codable, Sendable {
    public enum Actor: String, Codable, Sendable { case user, automatic }
    public enum Outcome: String, Codable, Sendable { case pending, forwarded, stale, timedOut, cancelled, failed }
    public enum ProviderAcknowledgement: String, Codable, Sendable {
        case pending, acceptedByHarness, rejectedByHarness, timedOut, cancelled, unavailable
    }

    public let harnessID: String
    public let providerName: String
    public let requestID: UUID
    public let requestedOptionKinds: [String]
    public let toolKind: ToolRequest.Kind?
    public let workspaceScoped: Bool
    public let policy: ExecutionPolicy
    public let policyReason: String
    public var actor: Actor
    public var selectedOptionKind: String?
    public var outcome: Outcome
    public var providerAcknowledgement: ProviderAcknowledgement
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        harnessID: String,
        providerName: String,
        requestID: UUID,
        requestedOptionKinds: [String],
        toolKind: ToolRequest.Kind?,
        workspaceScoped: Bool,
        policy: ExecutionPolicy,
        policyReason: String,
        actor: Actor,
        selectedOptionKind: String? = nil,
        outcome: Outcome = .pending,
        providerAcknowledgement: ProviderAcknowledgement = .pending,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.harnessID = Self.safe(harnessID, limit: 64)
        self.providerName = Self.safe(providerName, limit: 96)
        self.requestID = requestID
        self.requestedOptionKinds = Array(requestedOptionKinds.prefix(16)).map { Self.safe($0, limit: 64) }
        self.toolKind = toolKind
        self.workspaceScoped = workspaceScoped
        self.policy = policy
        self.policyReason = Self.safe(policyReason, limit: 240)
        self.actor = actor
        self.selectedOptionKind = selectedOptionKind.map { Self.safe($0, limit: 64) }
        self.outcome = outcome
        self.providerAcknowledgement = providerAcknowledgement
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private static func safe(_ value: String, limit: Int) -> String {
        let oneLine = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(oneLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

/// Privacy-bounded structured Work-mode semantics attached to a durable `SessionAction`.
/// Title/detail stay on the host action (or origin message); this payload only carries typed
/// structure needed for projection, jump origins, and restore reconciliation.
public struct SessionWorkSemantics: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case planStep
        case taskStep
        case question
        case approval
        case artifact
        case outcome
    }

    /// Provider-bound rows require live runtime IDs before they are actionable.
    /// User-owned rows may be marked/confirmed without reconstructing a provider callback.
    public enum Ownership: String, Codable, Sendable {
        case providerBound
        case userOwned
    }

    public enum TaskMark: String, Codable, Sendable {
        case unchecked
        case checked
        case confirmed
    }

    public enum OutcomeKind: String, Codable, Sendable {
        case succeeded
        case failed
        case cancelled
        case partial
    }

    public let kind: Kind
    public let ownership: Ownership
    /// Bounded machine key within a plan (not free-form prose).
    public let stepKey: String?
    /// User mark for user-owned task steps only. Never used for provider-bound permissions.
    public var taskMark: TaskMark?
    /// Explicit deliverable locator for artifact rows only. Never derived from `action.detail`.
    public let artifactLocator: String?
    public let outcomeKind: OutcomeKind?
    /// Jump target when different from the host action's `messageID`.
    public let originMessageID: UUID?
    /// Jump target when this row was derived from another durable action.
    public let originActionID: UUID?
    /// Durable link to the user message that answered or resolved this request.
    public var resolutionMessageID: UUID?

    public init(
        kind: Kind,
        ownership: Ownership,
        stepKey: String? = nil,
        taskMark: TaskMark? = nil,
        artifactLocator: String? = nil,
        outcomeKind: OutcomeKind? = nil,
        originMessageID: UUID? = nil,
        originActionID: UUID? = nil,
        resolutionMessageID: UUID? = nil
    ) {
        self.kind = kind
        self.ownership = ownership
        self.stepKey = stepKey.map { Self.safe($0, limit: 64) }
        self.taskMark = taskMark
        // Artifact locators are explicit product data, still bounded and single-line.
        self.artifactLocator = kind == .artifact
            ? artifactLocator.map { Self.safe($0, limit: 512) }
            : nil
        self.outcomeKind = kind == .outcome ? outcomeKind : nil
        self.originMessageID = originMessageID
        self.originActionID = originActionID
        self.resolutionMessageID = resolutionMessageID
    }

    /// True when restore must keep this row pending instead of treating it as a live provider wait.
    public var isPendingUserOwnedTask: Bool {
        ownership == .userOwned && (kind == .taskStep || kind == .planStep)
    }

    /// True when this row is provider-dependent live work that cannot be reconstructed from disk alone.
    public var isProviderDependentLiveState: Bool {
        switch kind {
        case .approval, .question:
            return true
        case .planStep, .taskStep, .artifact, .outcome:
            return ownership == .providerBound
        }
    }

    private static func safe(_ value: String, limit: Int) -> String {
        let oneLine = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        return String(oneLine.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
}

public struct SessionAction: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case tool, approval, plan, reasoning, harness, diagnostic }
    public enum Status: String, Codable, Sendable { case running, waiting, completed, failed, allowed, denied, cancelled, interrupted }

    public let id: UUID
    public let messageID: UUID
    public let kind: Kind
    public let toolKind: ToolRequest.Kind?
    public let title: String
    public var detail: String
    public var status: Status
    public let workspaceScoped: Bool
    public let createdAt: Date
    public var updatedAt: Date
    public var approvalProvenance: ApprovalProvenance?
    /// Optional Work-mode structured payload. Absent in legacy JSON; never required for decode.
    public var work: SessionWorkSemantics?

    public init(
        id: UUID = UUID(),
        messageID: UUID,
        kind: Kind,
        toolKind: ToolRequest.Kind? = nil,
        title: String,
        detail: String,
        status: Status,
        workspaceScoped: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        approvalProvenance: ApprovalProvenance? = nil,
        work: SessionWorkSemantics? = nil
    ) {
        self.id = id
        self.messageID = messageID
        self.kind = kind
        self.toolKind = toolKind
        self.title = title
        self.detail = detail
        self.status = status
        self.workspaceScoped = workspaceScoped
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.approvalProvenance = approvalProvenance
        self.work = work
    }

    private enum CodingKeys: String, CodingKey {
        case id, messageID, kind, toolKind, title, detail, status, workspaceScoped, createdAt, updatedAt, approvalProvenance, work
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        messageID = try container.decode(UUID.self, forKey: .messageID)
        kind = try container.decode(Kind.self, forKey: .kind)
        toolKind = try container.decodeIfPresent(ToolRequest.Kind.self, forKey: .toolKind)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decode(String.self, forKey: .detail)
        status = try container.decode(Status.self, forKey: .status)
        workspaceScoped = try container.decodeIfPresent(Bool.self, forKey: .workspaceScoped) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        approvalProvenance = try container.decodeIfPresent(ApprovalProvenance.self, forKey: .approvalProvenance)
        work = try container.decodeIfPresent(SessionWorkSemantics.self, forKey: .work)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(messageID, forKey: .messageID)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(toolKind, forKey: .toolKind)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        try container.encode(status, forKey: .status)
        try container.encode(workspaceScoped, forKey: .workspaceScoped)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(approvalProvenance, forKey: .approvalProvenance)
        try container.encodeIfPresent(work, forKey: .work)
    }
}

public struct SessionTranscriptStorage: Hashable, Codable, Sendable {
    public let fileName: String
    public let messageCount: Int
    public let contentFingerprint: String
    public let lastMessagePreview: String?

    public init(fileName: String, messageCount: Int, contentFingerprint: String, lastMessagePreview: String? = nil) {
        self.fileName = fileName
        self.messageCount = messageCount
        self.contentFingerprint = contentFingerprint
        self.lastMessagePreview = lastMessagePreview
    }
}

public struct LatticeSession: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var messages: [ChatMessage] {
        didSet {
            if isTranscriptLoaded { isTranscriptDirty = true }
        }
    }
    /// Durable pointer used by the split transcript store. `messages` remains the canonical
    /// in-memory transcript whenever `isTranscriptLoaded` is true.
    public var transcriptStorage: SessionTranscriptStorage?
    /// Runtime-only materialization state. It is intentionally excluded from Codable so a
    /// metadata decode never mistakes an empty placeholder for a user-deleted transcript.
    public var isTranscriptLoaded: Bool
    /// Runtime-only mutation marker used to avoid hashing or saving clean transcripts on switch.
    public var isTranscriptDirty: Bool
    /// Durable assistant media artifacts (metadata only). Stored in a split sidecar when present.
    public var artifacts: [AssistantArtifact] {
        didSet {
            if isArtifactsLoaded { isArtifactsDirty = true }
        }
    }
    /// Durable pointer used by the split artifact metadata store.
    public var artifactStorage: SessionArtifactStorage?
    /// Runtime-only materialization state for artifact metadata.
    public var isArtifactsLoaded: Bool
    /// Runtime-only mutation marker for artifact metadata.
    public var isArtifactsDirty: Bool
    public var backend: ChatBackend
    /// New route authority. `backend` and `harnessID` remain for legacy decoding and UI migration.
    public var executionRoute: ExecutionRoute
    public var harnessID: String?
    public var reasoningEffort: ReasoningEffort?
    public var harnessThreadID: String?
    public var workspacePath: String?
    public var attachments: [ContextAttachment]
    public var policy: ExecutionPolicy
    public var privacyMode: SessionPrivacyMode
    public var intent: LatticeSessionIntent?
    public var actions: [SessionAction]
    public var queuedFollowUps: [QueuedFollowUp]
    /// Unsent ordinary composer text for this chat. Never stores transient message-edit text.
    public var draft: String
    public var isPinned: Bool
    public var isStreaming: Bool
    public var lastUpdated: Date
    /// Privacy-safe fingerprint of imported portable archive content (duplicate detection only).
    public var portableArchiveFingerprint: String?

    public init(
        id: UUID = UUID(),
        title: String,
        messages: [ChatMessage] = [],
        transcriptStorage: SessionTranscriptStorage? = nil,
        isTranscriptLoaded: Bool = true,
        isTranscriptDirty: Bool = false,
        artifacts: [AssistantArtifact] = [],
        artifactStorage: SessionArtifactStorage? = nil,
        isArtifactsLoaded: Bool = true,
        isArtifactsDirty: Bool = false,
        backend: ChatBackend,
        executionRoute: ExecutionRoute? = nil,
        harnessID: String? = nil,
        reasoningEffort: ReasoningEffort? = nil,
        harnessThreadID: String? = nil,
        workspacePath: String? = nil,
        attachments: [ContextAttachment] = [],
        policy: ExecutionPolicy = .ask,
        privacyMode: SessionPrivacyMode = .cloudAllowed,
        intent: LatticeSessionIntent? = nil,
        actions: [SessionAction] = [],
        queuedFollowUps: [QueuedFollowUp] = [],
        draft: String = "",
        isPinned: Bool = false,
        isStreaming: Bool = false,
        lastUpdated: Date = .now,
        portableArchiveFingerprint: String? = nil
    ) {
        self.id = id; self.title = title; self.messages = messages
        self.transcriptStorage = transcriptStorage; self.isTranscriptLoaded = isTranscriptLoaded
        self.isTranscriptDirty = isTranscriptDirty
        self.artifacts = artifacts
        self.artifactStorage = artifactStorage
        self.isArtifactsLoaded = isArtifactsLoaded
        self.isArtifactsDirty = isArtifactsDirty
        self.backend = backend
        self.executionRoute = executionRoute ?? ExecutionRoute.legacy(for: backend, harnessID: harnessID)
        self.harnessID = harnessID
        self.reasoningEffort = reasoningEffort
        self.harnessThreadID = harnessThreadID; self.workspacePath = workspacePath; self.attachments = attachments
        self.policy = policy; self.privacyMode = privacyMode; self.intent = intent; self.actions = actions; self.queuedFollowUps = queuedFollowUps
        self.draft = draft
        self.isPinned = isPinned; self.isStreaming = isStreaming; self.lastUpdated = lastUpdated
        self.portableArchiveFingerprint = portableArchiveFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, transcriptStorage, artifacts, artifactStorage, backend, executionRoute, harnessID, reasoningEffort, harnessThreadID, workspacePath, attachments, policy, privacyMode, intent, actions, queuedFollowUps, draft, isPinned, isStreaming, lastUpdated, portableArchiveFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        transcriptStorage = try container.decodeIfPresent(SessionTranscriptStorage.self, forKey: .transcriptStorage)
        isTranscriptLoaded = transcriptStorage == nil
        isTranscriptDirty = false
        // Prefer split artifact store. Inline `artifacts` is accepted only for transitional
        // payloads; legacy manifests without either field hydrate as empty/loaded.
        let decodedArtifactStorage = try container.decodeIfPresent(SessionArtifactStorage.self, forKey: .artifactStorage)
        let inlineArtifacts = try container.decodeIfPresent([AssistantArtifact].self, forKey: .artifacts) ?? []
        artifactStorage = decodedArtifactStorage
        if decodedArtifactStorage != nil {
            artifacts = []
            isArtifactsLoaded = false
        } else {
            artifacts = inlineArtifacts
            isArtifactsLoaded = true
        }
        isArtifactsDirty = false
        backend = try container.decode(ChatBackend.self, forKey: .backend)
        harnessID = try container.decodeIfPresent(String.self, forKey: .harnessID)
        executionRoute = try container.decodeIfPresent(ExecutionRoute.self, forKey: .executionRoute)
            ?? ExecutionRoute.legacy(for: backend, harnessID: harnessID)
        reasoningEffort = try container.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)
        harnessThreadID = try container.decodeIfPresent(String.self, forKey: .harnessThreadID)
        workspacePath = try container.decodeIfPresent(String.self, forKey: .workspacePath)
        attachments = try container.decodeIfPresent([ContextAttachment].self, forKey: .attachments) ?? []
        policy = try container.decodeIfPresent(ExecutionPolicy.self, forKey: .policy) ?? .ask
        privacyMode = try container.decodeIfPresent(SessionPrivacyMode.self, forKey: .privacyMode) ?? .cloudAllowed
        intent = try container.decodeIfPresent(LatticeSessionIntent.self, forKey: .intent)
        actions = try container.decodeIfPresent([SessionAction].self, forKey: .actions) ?? []
        queuedFollowUps = try container.decodeIfPresent([QueuedFollowUp].self, forKey: .queuedFollowUps) ?? []
        draft = try container.decodeIfPresent(String.self, forKey: .draft) ?? ""
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? .distantPast
        portableArchiveFingerprint = try container.decodeIfPresent(String.self, forKey: .portableArchiveFingerprint)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(messages, forKey: .messages)
        try container.encodeIfPresent(transcriptStorage, forKey: .transcriptStorage)
        // Prefer split store reference. Inline artifacts only when loaded without a split reference
        // (tests/legacy transitional encoding); production save clears them after writing the sidecar.
        if let artifactStorage {
            try container.encode(artifactStorage, forKey: .artifactStorage)
        } else if !artifacts.isEmpty {
            try container.encode(artifacts, forKey: .artifacts)
        }
        try container.encode(backend, forKey: .backend)
        try container.encode(executionRoute, forKey: .executionRoute)
        try container.encodeIfPresent(harnessID, forKey: .harnessID)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(harnessThreadID, forKey: .harnessThreadID)
        try container.encodeIfPresent(workspacePath, forKey: .workspacePath)
        try container.encode(attachments, forKey: .attachments)
        try container.encode(policy, forKey: .policy)
        try container.encode(privacyMode, forKey: .privacyMode)
        try container.encodeIfPresent(intent, forKey: .intent)
        try container.encode(actions, forKey: .actions)
        try container.encode(queuedFollowUps, forKey: .queuedFollowUps)
        try container.encode(draft, forKey: .draft)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encode(lastUpdated, forKey: .lastUpdated)
        try container.encodeIfPresent(portableArchiveFingerprint, forKey: .portableArchiveFingerprint)
    }
}

public extension LatticeSession {
    var totalMessageCount: Int {
        isTranscriptLoaded ? messages.count : transcriptStorage?.messageCount ?? messages.count
    }

    var lastMessagePreview: String? {
        isTranscriptLoaded ? messages.last?.text : transcriptStorage?.lastMessagePreview
    }
}
