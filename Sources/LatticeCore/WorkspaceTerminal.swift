import Foundation

// MARK: - Models

public enum WorkspaceTerminalSessionState: String, Sendable, Equatable, Codable {
    case idle
    case running
    case stopping
    case exited
    case failed
}

public struct WorkspaceTerminalLine: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var text: String
    public var isError: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        isError: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.isError = isError
        self.createdAt = createdAt
    }
}

/// Durable presentation snapshot for one workspace-owned terminal session.
///
/// Terminals are keyed by worktree path, not chat session — they survive chat switches.
public struct WorkspaceTerminalSnapshot: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    /// Standardized workspace path used as the session identity.
    public var worktreePath: String
    public var state: WorkspaceTerminalSessionState
    public var lines: [WorkspaceTerminalLine]
    public var lastExitStatus: Int32?
    public var lastFailureSummary: String?
    public var createdAt: Date
    public var updatedAt: Date
    /// Bounded recent stdout/stderr retained for optional user-initiated context attach.
    public var lastOutputChunk: String

    public static let maximumRetainedLines = 2_000
    public static let maximumOutputChunkCharacters = 12_000

    public init(
        id: UUID = UUID(),
        worktreePath: String,
        state: WorkspaceTerminalSessionState = .idle,
        lines: [WorkspaceTerminalLine] = [],
        lastExitStatus: Int32? = nil,
        lastFailureSummary: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastOutputChunk: String = ""
    ) {
        self.id = id
        self.worktreePath = WorkspaceTerminalPolicy.standardizedPath(worktreePath)
        self.state = state
        self.lines = lines
        self.lastExitStatus = lastExitStatus
        self.lastFailureSummary = lastFailureSummary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastOutputChunk = lastOutputChunk
    }
}

// MARK: - Policy

public enum WorkspaceTerminalPolicy {
    public static let defaultShellCandidates = ["/bin/zsh", "/bin/bash", "/bin/sh"]
    public static let maximumCommandLength = 8_000

    public static func standardizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).standardizingPath
    }

    public static func sessionKey(forWorktreePath path: String) -> String {
        standardizedPath(path)
    }

    /// Product rule: terminal identity is worktree-scoped. Chat switches never clear a
    /// non-empty worktree terminal; UI rebinds to the selected worktree instead.
    public static func survivesSessionSwitch(terminalWorktreePath: String) -> Bool {
        !sessionKey(forWorktreePath: terminalWorktreePath).isEmpty
    }

    /// Legacy overload retained for call sites that pass previous/next workspace paths.
    /// Chat switch alone never drops worktree-owned terminal identity.
    public static func survivesSessionSwitch(
        terminalWorktreePath: String,
        previousSessionWorkspace: String?,
        nextSessionWorkspace: String?
    ) -> Bool {
        _ = previousSessionWorkspace
        _ = nextSessionWorkspace
        return survivesSessionSwitch(terminalWorktreePath: terminalWorktreePath)
    }

    public static func shouldRemapTerminal(
        terminalWorktreePath: String,
        selectedWorkspacePath: String?
    ) -> Bool {
        let terminalKey = sessionKey(forWorktreePath: terminalWorktreePath)
        let selectedKey = sessionKey(forWorktreePath: selectedWorkspacePath ?? "")
        return !selectedKey.isEmpty && terminalKey != selectedKey
    }

    public static func sanitizeCommand(_ command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maximumCommandLength {
            return String(trimmed.prefix(maximumCommandLength))
        }
        return trimmed
    }

    public static func appendLine(
        _ line: WorkspaceTerminalLine,
        to snapshot: inout WorkspaceTerminalSnapshot
    ) {
        snapshot.lines.append(line)
        if snapshot.lines.count > WorkspaceTerminalSnapshot.maximumRetainedLines {
            snapshot.lines.removeFirst(snapshot.lines.count - WorkspaceTerminalSnapshot.maximumRetainedLines)
        }
        var chunk = snapshot.lastOutputChunk
        if !chunk.isEmpty { chunk += "\n" }
        chunk += line.text
        if chunk.count > WorkspaceTerminalSnapshot.maximumOutputChunkCharacters {
            chunk = String(chunk.suffix(WorkspaceTerminalSnapshot.maximumOutputChunkCharacters))
        }
        snapshot.lastOutputChunk = chunk
        snapshot.updatedAt = Date()
    }

    /// User-initiated only: build a context attachment snippet from the last command output.
    public static func contextAttachmentText(from snapshot: WorkspaceTerminalSnapshot) -> String {
        let body = snapshot.lastOutputChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return "Terminal output is empty for \(snapshot.worktreePath)."
        }
        return """
        [Workspace terminal · \(snapshot.worktreePath)]
        \(body)
        """
    }

    public static func resolveShellExecutable(
        preferred: String? = nil,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        if let preferred, !preferred.isEmpty, fileExists(preferred) {
            return preferred
        }
        if let shell = ProcessInfo.processInfo.environment["SHELL"], fileExists(shell) {
            return shell
        }
        return defaultShellCandidates.first(where: fileExists)
    }

    /// Exit semantics for status chips: zero → success; non-zero → failed.
    public static func statusSemanticForExit(_ code: Int32?) -> String {
        guard let code else { return "exited" }
        return code == 0 ? "success" : "failed"
    }
}

// MARK: - Store (in-memory, workspace keyed)

/// Holds workspace-owned terminal snapshots. Process ownership stays in the app layer;
/// this type only models survival and selection policy.
public struct WorkspaceTerminalStore: Sendable, Equatable {
    public private(set) var snapshotsByWorktree: [String: WorkspaceTerminalSnapshot]

    public init(snapshotsByWorktree: [String: WorkspaceTerminalSnapshot] = [:]) {
        self.snapshotsByWorktree = snapshotsByWorktree
    }

    public func snapshot(forWorktreePath path: String) -> WorkspaceTerminalSnapshot? {
        let key = WorkspaceTerminalPolicy.sessionKey(forWorktreePath: path)
        guard !key.isEmpty else { return nil }
        return snapshotsByWorktree[key]
    }

    public mutating func ensureSnapshot(forWorktreePath path: String) -> WorkspaceTerminalSnapshot {
        let key = WorkspaceTerminalPolicy.sessionKey(forWorktreePath: path)
        if let existing = snapshotsByWorktree[key] { return existing }
        let created = WorkspaceTerminalSnapshot(worktreePath: key)
        if !key.isEmpty {
            snapshotsByWorktree[key] = created
        }
        return created
    }

    public mutating func update(_ snapshot: WorkspaceTerminalSnapshot) {
        let key = WorkspaceTerminalPolicy.sessionKey(forWorktreePath: snapshot.worktreePath)
        guard !key.isEmpty else { return }
        var copy = snapshot
        copy.worktreePath = key
        snapshotsByWorktree[key] = copy
    }

    public mutating func remove(forWorktreePath path: String) {
        let key = WorkspaceTerminalPolicy.sessionKey(forWorktreePath: path)
        snapshotsByWorktree[key] = nil
    }
}
