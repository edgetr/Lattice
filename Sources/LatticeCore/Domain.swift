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
        return !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

public struct LatticeCommandPaletteItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let detail: String
    public let keywords: [String]
    public let isEnabled: Bool
    public let disabledReason: String?

    public init(id: String, title: String, detail: String = "", keywords: [String] = [], isEnabled: Bool = true, disabledReason: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.keywords = keywords
        self.isEnabled = isEnabled
        self.disabledReason = disabledReason
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

public enum AgentEvent: Sendable, Equatable {
    case sessionStarted(UUID)
    case harnessSessionStarted(String)
    case assistantDelta(String)
    case plan(id: UUID, title: String, steps: [String])
    case reasoningSummary(id: UUID, delta: String)
    case toolRequested(ToolRequest)
    case toolProgress(id: UUID, fraction: Double, detail: String)
    case permissionRequested(ApprovalRequest)
    case metric(name: String, value: Double, unit: String)
    case completed
    case cancelled
    case failed(String)
}

public struct ContextAttachment: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    /// Local absolute path for live attachments, or a non-resolvable display token for imported/missing ones.
    public let path: String
    /// When true, the attachment is metadata-only and must not be opened, read, or resolved on disk.
    public var isMissing: Bool
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
    public var isImage: Bool {
        ["png", "jpg", "jpeg", "heic", "webp", "gif"].contains(
            (name as NSString).pathExtension.lowercased()
        )
    }
    public init(id: UUID = UUID(), path: String, isMissing: Bool = false) {
        self.id = id
        self.path = path
        self.isMissing = isMissing
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, isMissing
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        path = try container.decode(String.self, forKey: .path)
        isMissing = try container.decodeIfPresent(Bool.self, forKey: .isMissing) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(path, forKey: .path)
        try container.encode(isMissing, forKey: .isMissing)
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

    public init(id: String, name: String, description: String = "", reasoningOptions: [ReasoningOption] = [], defaultReasoningEffort: ReasoningEffort? = nil, contextWindow: Int? = nil, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.description = description
        self.reasoningOptions = reasoningOptions
        self.defaultReasoningEffort = defaultReasoningEffort
        self.contextWindow = contextWindow.flatMap { $0 > 0 ? $0 : nil }
        self.isDefault = isDefault
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

public struct SessionAction: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case tool, approval, plan, reasoning }
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
        updatedAt: Date = .now
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
    }
}

public struct LatticeSession: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var title: String
    public var messages: [ChatMessage]
    public var backend: ChatBackend
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
        backend: ChatBackend,
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
        self.id = id; self.title = title; self.messages = messages; self.backend = backend
        self.harnessID = harnessID
        self.reasoningEffort = reasoningEffort
        self.harnessThreadID = harnessThreadID; self.workspacePath = workspacePath; self.attachments = attachments
        self.policy = policy; self.privacyMode = privacyMode; self.intent = intent; self.actions = actions; self.queuedFollowUps = queuedFollowUps
        self.draft = draft
        self.isPinned = isPinned; self.isStreaming = isStreaming; self.lastUpdated = lastUpdated
        self.portableArchiveFingerprint = portableArchiveFingerprint
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, messages, backend, harnessID, reasoningEffort, harnessThreadID, workspacePath, attachments, policy, privacyMode, intent, actions, queuedFollowUps, draft, isPinned, isStreaming, lastUpdated, portableArchiveFingerprint
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
        backend = try container.decode(ChatBackend.self, forKey: .backend)
        harnessID = try container.decodeIfPresent(String.self, forKey: .harnessID)
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
        try container.encode(backend, forKey: .backend)
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
