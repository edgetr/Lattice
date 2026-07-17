import CryptoKit
import Darwin
import Foundation

// MARK: - Domain

/// When a workspace checkpoint was taken relative to an agent run.
public enum WorkspaceCheckpointBoundary: String, Codable, Sendable, Equatable, CaseIterable {
    case beforeRun
    case afterRun
}

/// Capture outcome for a checkpoint record.
public enum WorkspaceCheckpointStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case captured
    case failed
}

/// Ownership identity that scopes Git refs and durable records.
public struct WorkspaceCheckpointOwnership: Codable, Sendable, Equatable, Hashable {
    public var worktreePath: String
    /// Stable identity for the worktree (canonical path + common Git dir fingerprint).
    public var worktreeIdentity: String
    public var sessionID: UUID
    public var runID: UUID

    public init(worktreePath: String, worktreeIdentity: String, sessionID: UUID, runID: UUID) {
        self.worktreePath = worktreePath
        self.worktreeIdentity = worktreeIdentity
        self.sessionID = sessionID
        self.runID = runID
    }
}

/// Metadata for an untracked path. Content bytes are never retained.
///
/// Regular-file `contentOID` is computed with `git hash-object` (no `-w`) so objects are
/// not written. Symlinks use a SHA-256 fingerprint of link text and are never followed.
/// Untracked file contents cannot be restored from this metadata alone.
public struct WorkspaceUntrackedFileMetadata: Codable, Sendable, Equatable, Hashable {
    public var path: String
    public var byteSize: Int64
    public var contentOID: String
    /// Symlinks are fingerprinted from their link text; Lattice never follows them.
    public var isSymbolicLink: Bool
    /// Always false: Lattice intentionally does not store untracked contents for restore.
    public var canRestoreContent: Bool
    public var modificationTime: Date?

    public init(
        path: String,
        byteSize: Int64,
        contentOID: String,
        isSymbolicLink: Bool = false,
        canRestoreContent: Bool = false,
        modificationTime: Date? = nil
    ) {
        self.path = path
        self.byteSize = byteSize
        self.contentOID = contentOID
        self.isSymbolicLink = isSymbolicLink
        self.canRestoreContent = false
        self.modificationTime = modificationTime
        _ = canRestoreContent
    }

    private enum CodingKeys: String, CodingKey {
        case path, byteSize, contentOID, isSymbolicLink, canRestoreContent, modificationTime
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        byteSize = try container.decode(Int64.self, forKey: .byteSize)
        contentOID = try container.decode(String.self, forKey: .contentOID)
        isSymbolicLink = try container.decodeIfPresent(Bool.self, forKey: .isSymbolicLink) ?? false
        canRestoreContent = false
        modificationTime = try container.decodeIfPresent(Date.self, forKey: .modificationTime)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(byteSize, forKey: .byteSize)
        try container.encode(contentOID, forKey: .contentOID)
        try container.encode(isSymbolicLink, forKey: .isSymbolicLink)
        try container.encode(false, forKey: .canRestoreContent)
        try container.encodeIfPresent(modificationTime, forKey: .modificationTime)
    }
}

/// Aggregate change counts for a checkpoint boundary.
public struct WorkspaceCheckpointChangeStats: Codable, Sendable, Equatable {
    public var filesChanged: Int
    public var additions: Int
    public var deletions: Int

    public init(filesChanged: Int = 0, additions: Int = 0, deletions: Int = 0) {
        self.filesChanged = filesChanged
        self.additions = additions
        self.deletions = deletions
    }
}

/// Durable record of a Git worktree snapshot owned by a session/run.
public struct WorkspaceCheckpoint: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var ownership: WorkspaceCheckpointOwnership
    public var boundary: WorkspaceCheckpointBoundary
    public var status: WorkspaceCheckpointStatus
    public var createdAt: Date
    /// `HEAD` commit when the checkpoint was taken (`nil` for empty/unborn repos).
    public var headCommitOID: String?
    /// Tree written from tracked working-tree state via alternate-index plumbing.
    public var treeOID: String?
    /// Commit created with `git commit-tree` for the snapshot tree.
    public var snapshotCommitOID: String?
    /// Lattice-namespaced ref pointing at `snapshotCommitOID`.
    public var refName: String?
    public var hasTrackedDirtiness: Bool
    public var hasIndexDirtiness: Bool
    public var untrackedFiles: [WorkspaceUntrackedFileMetadata]
    public var changeStats: WorkspaceCheckpointChangeStats
    public var failureSummary: String?

    public init(
        id: UUID = UUID(),
        ownership: WorkspaceCheckpointOwnership,
        boundary: WorkspaceCheckpointBoundary,
        status: WorkspaceCheckpointStatus,
        createdAt: Date = Date(),
        headCommitOID: String? = nil,
        treeOID: String? = nil,
        snapshotCommitOID: String? = nil,
        refName: String? = nil,
        hasTrackedDirtiness: Bool = false,
        hasIndexDirtiness: Bool = false,
        untrackedFiles: [WorkspaceUntrackedFileMetadata] = [],
        changeStats: WorkspaceCheckpointChangeStats = .init(),
        failureSummary: String? = nil
    ) {
        self.id = id
        self.ownership = ownership
        self.boundary = boundary
        self.status = status
        self.createdAt = createdAt
        self.headCommitOID = headCommitOID
        self.treeOID = treeOID
        self.snapshotCommitOID = snapshotCommitOID
        self.refName = refName
        self.hasTrackedDirtiness = hasTrackedDirtiness
        self.hasIndexDirtiness = hasIndexDirtiness
        self.untrackedFiles = untrackedFiles
        self.changeStats = changeStats
        self.failureSummary = failureSummary
    }

    private enum CodingKeys: String, CodingKey {
        case id, ownership, boundary, status, createdAt
        case headCommitOID, treeOID, snapshotCommitOID, refName
        case hasTrackedDirtiness, hasIndexDirtiness
        case untrackedFiles, changeStats, failureSummary
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        ownership = try container.decode(WorkspaceCheckpointOwnership.self, forKey: .ownership)
        boundary = try container.decode(WorkspaceCheckpointBoundary.self, forKey: .boundary)
        status = try container.decode(WorkspaceCheckpointStatus.self, forKey: .status)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .distantPast
        headCommitOID = try container.decodeIfPresent(String.self, forKey: .headCommitOID)
        treeOID = try container.decodeIfPresent(String.self, forKey: .treeOID)
        snapshotCommitOID = try container.decodeIfPresent(String.self, forKey: .snapshotCommitOID)
        refName = try container.decodeIfPresent(String.self, forKey: .refName)
        hasTrackedDirtiness = try container.decodeIfPresent(Bool.self, forKey: .hasTrackedDirtiness) ?? false
        hasIndexDirtiness = try container.decodeIfPresent(Bool.self, forKey: .hasIndexDirtiness) ?? false
        untrackedFiles = try container.decodeIfPresent([WorkspaceUntrackedFileMetadata].self, forKey: .untrackedFiles) ?? []
        changeStats = try container.decodeIfPresent(WorkspaceCheckpointChangeStats.self, forKey: .changeStats) ?? .init()
        failureSummary = try container.decodeIfPresent(String.self, forKey: .failureSummary)
    }
}

// MARK: - Review / follow-up notes

public enum WorkspaceReviewNoteKind: String, Codable, Sendable, Equatable, CaseIterable {
    case note
    case followUpPrompt
}

public struct WorkspaceReviewLineRange: Codable, Sendable, Equatable, Hashable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct WorkspaceReviewNote: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var checkpointID: UUID
    public var sessionID: UUID
    public var runID: UUID
    /// Repo-relative POSIX path (validated; never absolute / never escapes with `..`).
    public var path: String
    public var lineRange: WorkspaceReviewLineRange?
    public var hunkHeader: String?
    public var kind: WorkspaceReviewNoteKind
    public var body: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        checkpointID: UUID,
        sessionID: UUID,
        runID: UUID,
        path: String,
        lineRange: WorkspaceReviewLineRange? = nil,
        hunkHeader: String? = nil,
        kind: WorkspaceReviewNoteKind = .note,
        body: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.checkpointID = checkpointID
        self.sessionID = sessionID
        self.runID = runID
        self.path = path
        self.lineRange = lineRange
        self.hunkHeader = hunkHeader
        self.kind = kind
        self.body = body
        self.createdAt = createdAt
    }
}

// MARK: - Diff review model

public enum WorkspaceCheckpointFileStatus: String, Codable, Sendable, Equatable {
    case added
    case modified
    case deleted
    case renamed
    case copied
    case typeChanged
    case unknown
}

public enum WorkspaceCheckpointDiffLineKind: String, Codable, Sendable, Equatable {
    case context
    case addition
    case deletion
}

public struct WorkspaceCheckpointDiffLine: Codable, Sendable, Equatable {
    public var kind: WorkspaceCheckpointDiffLineKind
    public var text: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?

    public init(
        kind: WorkspaceCheckpointDiffLineKind,
        text: String,
        oldLineNumber: Int? = nil,
        newLineNumber: Int? = nil
    ) {
        self.kind = kind
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

public struct WorkspaceCheckpointHunk: Codable, Sendable, Equatable {
    public var header: String
    public var oldStart: Int
    public var oldCount: Int
    public var newStart: Int
    public var newCount: Int
    public var lines: [WorkspaceCheckpointDiffLine]

    public init(
        header: String,
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int,
        lines: [WorkspaceCheckpointDiffLine]
    ) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct WorkspaceCheckpointFileChange: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path + "|" + status.rawValue }
    public var path: String
    public var previousPath: String?
    public var status: WorkspaceCheckpointFileStatus
    /// True when the path is represented by privacy-preserving metadata only.
    public var isUntracked: Bool
    public var additions: Int
    public var deletions: Int
    public var hunks: [WorkspaceCheckpointHunk]

    public init(
        path: String,
        previousPath: String? = nil,
        status: WorkspaceCheckpointFileStatus,
        isUntracked: Bool = false,
        additions: Int,
        deletions: Int,
        hunks: [WorkspaceCheckpointHunk] = []
    ) {
        self.path = path
        self.previousPath = previousPath
        self.status = status
        self.isUntracked = isUntracked
        self.additions = additions
        self.deletions = deletions
        self.hunks = hunks
    }
}

public struct WorkspaceCheckpointChangeSet: Codable, Sendable, Equatable {
    public var beforeCheckpointID: UUID
    public var afterCheckpointID: UUID
    public var files: [WorkspaceCheckpointFileChange]
    public var stats: WorkspaceCheckpointChangeStats

    public init(
        beforeCheckpointID: UUID,
        afterCheckpointID: UUID,
        files: [WorkspaceCheckpointFileChange],
        stats: WorkspaceCheckpointChangeStats
    ) {
        self.beforeCheckpointID = beforeCheckpointID
        self.afterCheckpointID = afterCheckpointID
        self.files = files
        self.stats = stats
    }
}

// MARK: - Guarded revert

public enum WorkspaceCheckpointRevertOperationKind: String, Codable, Sendable, Equatable {
    case applyTrackedReversePatch
    case deleteRunCreatedUntracked
}

public struct WorkspaceCheckpointRevertOperation: Codable, Sendable, Equatable {
    public var kind: WorkspaceCheckpointRevertOperationKind
    public var path: String
    public var detail: String

    public init(kind: WorkspaceCheckpointRevertOperationKind, path: String, detail: String) {
        self.kind = kind
        self.path = path
        self.detail = detail
    }
}

/// Preview of a guarded revert. Confirmation must present the exact `confirmationToken`.
public struct WorkspaceCheckpointRevertPreview: Codable, Sendable, Equatable {
    public var beforeCheckpointID: UUID
    public var afterCheckpointID: UUID
    public var ownership: WorkspaceCheckpointOwnership
    public var targetPaths: [String]
    public var operations: [WorkspaceCheckpointRevertOperation]
    public var warnings: [String]
    /// Bound to immutable preview inputs; stale tokens are refused.
    public var confirmationToken: String
    public var inputFingerprint: String

    public init(
        beforeCheckpointID: UUID,
        afterCheckpointID: UUID,
        ownership: WorkspaceCheckpointOwnership,
        targetPaths: [String],
        operations: [WorkspaceCheckpointRevertOperation],
        warnings: [String],
        confirmationToken: String,
        inputFingerprint: String
    ) {
        self.beforeCheckpointID = beforeCheckpointID
        self.afterCheckpointID = afterCheckpointID
        self.ownership = ownership
        self.targetPaths = targetPaths
        self.operations = operations
        self.warnings = warnings
        self.confirmationToken = confirmationToken
        self.inputFingerprint = inputFingerprint
    }
}

public struct WorkspaceCheckpointRevertResult: Codable, Sendable, Equatable {
    public var beforeCheckpointID: UUID
    public var afterCheckpointID: UUID
    public var appliedOperations: [WorkspaceCheckpointRevertOperation]
    public var summary: String

    public init(
        beforeCheckpointID: UUID,
        afterCheckpointID: UUID,
        appliedOperations: [WorkspaceCheckpointRevertOperation],
        summary: String
    ) {
        self.beforeCheckpointID = beforeCheckpointID
        self.afterCheckpointID = afterCheckpointID
        self.appliedOperations = appliedOperations
        self.summary = summary
    }
}

// MARK: - Errors

public enum WorkspaceCheckpointError: Error, Sendable, Equatable {
    case gitExecutableUnavailable
    case notAGitWorktree(String)
    case subprocessFailed(operation: String, detail: String)
    case subprocessTimedOut(operation: String)
    case subprocessCancelled(operation: String)
    case captureFailed(String)
    case checkpointNotFound(UUID)
    case checkpointPairInvalid(String)
    case checkpointNotCaptured(UUID)
    case invalidRepoRelativePath(String)
    case invalidLineRange(start: Int, end: Int)
    case storeUnreadable(String)
    case storeWriteFailed(String)
    case revertPreviewRefused(String)
    case revertConfirmationInvalid
    case revertConfirmationStale
    case revertDivergence(String)
    case revertStagedChanges(paths: [String])
    case revertUntrackedNotRestorable(paths: [String])
    case revertApplyFailed(String)

    public var message: String {
        switch self {
        case .gitExecutableUnavailable:
            return "Git executable is not available on PATH."
        case .notAGitWorktree(let path):
            return "Path is not a Git worktree: \(path)"
        case .subprocessFailed(let operation, let detail):
            return "Git \(operation) failed: \(detail)"
        case .subprocessTimedOut(let operation):
            return "Git \(operation) timed out."
        case .subprocessCancelled(let operation):
            return "Git \(operation) was cancelled."
        case .captureFailed(let detail):
            return "Checkpoint capture failed: \(detail)"
        case .checkpointNotFound(let id):
            return "Checkpoint not found: \(id.uuidString)"
        case .checkpointPairInvalid(let detail):
            return "Checkpoint pair is invalid: \(detail)"
        case .checkpointNotCaptured(let id):
            return "Checkpoint \(id.uuidString) was not successfully captured."
        case .invalidRepoRelativePath(let path):
            return "Path must be repo-relative and stay inside the worktree: \(path)"
        case .invalidLineRange(let start, let end):
            return "Line range must be positive and ordered (start=\(start), end=\(end))."
        case .storeUnreadable(let detail):
            return "Checkpoint store could not be read: \(detail)"
        case .storeWriteFailed(let detail):
            return "Checkpoint store could not be written: \(detail)"
        case .revertPreviewRefused(let detail):
            return "Revert preview refused: \(detail)"
        case .revertConfirmationInvalid:
            return "Revert confirmation token is missing or malformed."
        case .revertConfirmationStale:
            return "Revert confirmation token does not match the current preview inputs."
        case .revertDivergence(let detail):
            return "Working tree diverged from the after-run checkpoint: \(detail)"
        case .revertStagedChanges(let paths):
            return "Staged changes exist on target paths and exact stage restoration is not implemented: \(paths.joined(separator: ", "))"
        case .revertUntrackedNotRestorable(let paths):
            return "Pre-existing untracked files changed and contents were not captured: \(paths.joined(separator: ", "))"
        case .revertApplyFailed(let detail):
            return "Revert apply failed: \(detail)"
        }
    }
}

// MARK: - Durable store (outside the repository)

/// Versioned JSON document persisted outside the Git worktree.
public struct WorkspaceCheckpointStoreDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 2

    public var version: Int
    public var checkpoints: [WorkspaceCheckpoint]
    public var notes: [WorkspaceReviewNote]

    public init(
        version: Int = currentVersion,
        checkpoints: [WorkspaceCheckpoint] = [],
        notes: [WorkspaceReviewNote] = []
    ) {
        self.version = version
        self.checkpoints = checkpoints
        self.notes = notes
    }
}

/// Injectable durable JSON store for checkpoints and review notes.
public struct WorkspaceCheckpointStore: Sendable {
    public static let storeID = "workspace-checkpoints"
    public static let storeName = "Workspace checkpoints"
    public static let defaultFileName = "workspace-checkpoints.json"

    public let fileURL: URL

    /// A bounded, cross-process lock for the store's read/modify/write cycle.
    ///
    /// The JSON file itself is replaced atomically, but atomic replacement alone
    /// does not serialize two callers that both read the same old document. The
    /// adjacent lock file is intentionally separate so replacing the JSON target
    /// never drops the lock held by another process.
    private static let lockTimeoutNanoseconds: UInt64 = 500_000_000
    private static let lockRetryMicroseconds: useconds_t = 5_000

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Default location under Lattice Application Support (never inside a project repo).
    public static func defaultStore(fileName: String = defaultFileName) -> WorkspaceCheckpointStore {
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        let safeFileName = normalizedDefaultStoreFileName(fileName)
        let root = LatticeApplicationSupport.productRootURL().standardizedFileURL
        let candidate = root.appendingPathComponent(safeFileName, isDirectory: false).standardizedFileURL
        let url = candidate.deletingLastPathComponent() == root
            ? candidate
            : root.appendingPathComponent(defaultFileName, isDirectory: false)
        return WorkspaceCheckpointStore(fileURL: url)
    }

    static func normalizedDefaultStoreFileName(_ fileName: String) -> String {
        isSafeBasename(fileName) ? fileName : defaultFileName
    }

    public func load() throws -> WorkspaceCheckpointStoreDocument {
        try withStoreLock { location in
            try loadUnlocked(from: location)
        }
    }

    private func loadUnlocked(from location: WorkspaceCheckpointStoreLocation) throws -> WorkspaceCheckpointStoreDocument {
        guard let data = try readStoreData(from: location) else {
            return WorkspaceCheckpointStoreDocument()
        }
        do {
            return try Self.decodeMigrating(data)
        } catch let error as WorkspaceCheckpointError {
            throw error
        } catch {
            throw WorkspaceCheckpointError.storeUnreadable(error.localizedDescription)
        }
    }

    public func save(_ document: WorkspaceCheckpointStoreDocument) throws {
        try withStoreLock(isWrite: true) { location in
            try saveUnlocked(document, to: location)
        }
    }

    private func saveUnlocked(
        _ document: WorkspaceCheckpointStoreDocument,
        to location: WorkspaceCheckpointStoreLocation
    ) throws {
        guard document.version <= WorkspaceCheckpointStoreDocument.currentVersion else {
            throw WorkspaceCheckpointError.storeWriteFailed(
                "Checkpoint store schema version \(document.version) is newer than supported version \(WorkspaceCheckpointStoreDocument.currentVersion)."
            )
        }
        var normalized = document
        normalized.version = WorkspaceCheckpointStoreDocument.currentVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(normalized)
        } catch {
            throw WorkspaceCheckpointError.storeWriteFailed(error.localizedDescription)
        }
        let limit = DurableStoreRecovery.maximumStoreByteCount
        guard data.count <= limit else {
            throw WorkspaceCheckpointError.storeWriteFailed(
                "Encoded checkpoint store exceeds the \(limit)-byte limit. Existing data was preserved."
            )
        }
        try publishStoreData(data, to: location)
    }

    public func upsert(_ checkpoint: WorkspaceCheckpoint) throws {
        try withStoreLock(isWrite: true) { location in
            var document = try loadUnlocked(from: location)
            if let index = document.checkpoints.firstIndex(where: { $0.id == checkpoint.id }) {
                document.checkpoints[index] = checkpoint
            } else {
                document.checkpoints.append(checkpoint)
            }
            try saveUnlocked(document, to: location)
        }
    }

    public func checkpoint(id: UUID) throws -> WorkspaceCheckpoint? {
        try load().checkpoints.first(where: { $0.id == id })
    }

    public func checkpoints(
        sessionID: UUID? = nil,
        runID: UUID? = nil,
        worktreeIdentity: String? = nil
    ) throws -> [WorkspaceCheckpoint] {
        try load().checkpoints.filter { checkpoint in
            if let sessionID, checkpoint.ownership.sessionID != sessionID { return false }
            if let runID, checkpoint.ownership.runID != runID { return false }
            if let worktreeIdentity, checkpoint.ownership.worktreeIdentity != worktreeIdentity { return false }
            return true
        }
    }

    public func appendNote(_ note: WorkspaceReviewNote) throws {
        try withStoreLock(isWrite: true) { location in
            var document = try loadUnlocked(from: location)
            guard !document.notes.contains(where: { $0.id == note.id }) else { return }
            document.notes.append(note)
            try saveUnlocked(document, to: location)
        }
    }

    private func withStoreLock<T>(
        isWrite: Bool = false,
        _ body: (WorkspaceCheckpointStoreLocation) throws -> T
    ) throws -> T {
        do {
            let location = try openStoreLocation()
            defer { _ = Darwin.close(location.parentDescriptor) }
            let lockFD = try openStoreLockFile(at: location)
            defer { _ = Darwin.close(lockFD) }

            var lockStatus = stat()
            guard fstat(lockFD, &lockStatus) == 0,
                  (lockStatus.st_mode & S_IFMT) == S_IFREG,
                  lockStatus.st_uid == geteuid() else {
                throw WorkspaceCheckpointStoreLockError("Checkpoint store lock is not a regular file owned by the current user.")
            }

            let started = DispatchTime.now().uptimeNanoseconds
            while true {
                if flock(lockFD, LOCK_EX | LOCK_NB) == 0 { break }
                let code = errno
                if code != EWOULDBLOCK && code != EAGAIN && code != EINTR {
                    throw WorkspaceCheckpointStoreLockError("Could not lock store (errno " + String(code) + ").")
                }
                let elapsed = DispatchTime.now().uptimeNanoseconds &- started
                guard elapsed < Self.lockTimeoutNanoseconds else {
                    throw WorkspaceCheckpointStoreLockError(
                        "Timed out after 0.5 seconds waiting for the checkpoint store lock."
                    )
                }
                usleep(Self.lockRetryMicroseconds)
            }
            defer { _ = flock(lockFD, LOCK_UN) }
            return try body(location)
        } catch let error as WorkspaceCheckpointError {
            throw error
        } catch let error as WorkspaceCheckpointStoreLockError {
            if isWrite {
                throw WorkspaceCheckpointError.storeWriteFailed(error.detail)
            }
            throw WorkspaceCheckpointError.storeUnreadable(error.detail)
        } catch {
            if isWrite {
                throw WorkspaceCheckpointError.storeWriteFailed(error.localizedDescription)
            }
            throw WorkspaceCheckpointError.storeUnreadable(error.localizedDescription)
        }
    }

    /// Opens the adjacent advisory lock without following symlinks.
    ///
    /// Creation is split from open so concurrent first writers never depend on a single
    /// `O_CREAT|O_NOFOLLOW` openat succeeding under contention. Darwin can surface ENOENT
    /// for that combined flag set when many callers race the first create.
    private func openStoreLockFile(at location: WorkspaceCheckpointStoreLocation) throws -> Int32 {
        let baseFlags = O_RDWR | O_CLOEXEC | O_NOFOLLOW
        var lockFD = Darwin.openat(location.parentDescriptor, location.lockName, baseFlags)
        if lockFD < 0, errno == ENOENT {
            lockFD = Darwin.openat(
                location.parentDescriptor,
                location.lockName,
                baseFlags | O_CREAT | O_EXCL,
                mode_t(0o600)
            )
        }
        if lockFD < 0, errno == EEXIST {
            lockFD = Darwin.openat(location.parentDescriptor, location.lockName, baseFlags)
        }
        // Bounded retry for create races: another writer may create then rename/replace
        // around the EXCL attempt, leaving a brief ENOENT/EEXIST window.
        if lockFD < 0, errno == ENOENT || errno == EEXIST {
            let started = DispatchTime.now().uptimeNanoseconds
            while lockFD < 0 {
                let elapsed = DispatchTime.now().uptimeNanoseconds &- started
                guard elapsed < Self.lockTimeoutNanoseconds else { break }
                usleep(Self.lockRetryMicroseconds)
                lockFD = Darwin.openat(location.parentDescriptor, location.lockName, baseFlags)
                if lockFD < 0, errno == ENOENT {
                    lockFD = Darwin.openat(
                        location.parentDescriptor,
                        location.lockName,
                        baseFlags | O_CREAT | O_EXCL,
                        mode_t(0o600)
                    )
                }
                if lockFD < 0, errno == EEXIST {
                    lockFD = Darwin.openat(location.parentDescriptor, location.lockName, baseFlags)
                }
            }
        }
        guard lockFD >= 0 else {
            throw WorkspaceCheckpointStoreLockError("Could not open lock file (errno " + String(errno) + ").")
        }
        return lockFD
    }

    private func openStoreLocation() throws -> WorkspaceCheckpointStoreLocation {
        let storeName = fileURL.lastPathComponent
        guard Self.isSafeBasename(storeName) else {
            throw WorkspaceCheckpointStoreLockError("Checkpoint store name must be one safe file basename.")
        }
        let parent = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceCheckpointStoreLockError("Could not create checkpoint store directory: \(error.localizedDescription)")
        }
        guard let canonicalPointer = realpath(parent.path, nil) else {
            throw WorkspaceCheckpointStoreLockError("Could not canonicalize checkpoint store directory (errno \(errno)).")
        }
        defer { free(canonicalPointer) }
        let canonicalParent = String(cString: canonicalPointer)
        let parentDescriptor = Darwin.open(
            canonicalParent,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard parentDescriptor >= 0 else {
            throw WorkspaceCheckpointStoreLockError("Could not open checkpoint store directory (errno \(errno)).")
        }
        var parentStatus = stat()
        guard fstat(parentDescriptor, &parentStatus) == 0,
              (parentStatus.st_mode & S_IFMT) == S_IFDIR else {
            _ = Darwin.close(parentDescriptor)
            throw WorkspaceCheckpointStoreLockError("Checkpoint store parent must be a directory.")
        }
        return WorkspaceCheckpointStoreLocation(
            parentDescriptor: parentDescriptor,
            storeName: storeName,
            lockName: "." + storeName + ".lock"
        )
    }

    private func readStoreData(from location: WorkspaceCheckpointStoreLocation) throws -> Data? {
        let descriptor = Darwin.openat(
            location.parentDescriptor,
            location.storeName,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw WorkspaceCheckpointError.storeUnreadable("Could not open checkpoint store (errno \(errno)).")
        }
        defer { _ = Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            throw WorkspaceCheckpointError.storeUnreadable("Checkpoint store must be a regular file.")
        }
        let limit = DurableStoreRecovery.maximumStoreByteCount
        if status.st_size > off_t(limit) {
            throw WorkspaceCheckpointError.storeUnreadable("Checkpoint store exceeds the \(limit)-byte limit.")
        }

        var data = Data()
        data.reserveCapacity(min(Int(status.st_size), limit))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw WorkspaceCheckpointError.storeUnreadable("Could not read checkpoint store (errno \(errno)).")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            if data.count > limit {
                throw WorkspaceCheckpointError.storeUnreadable("Checkpoint store exceeds the \(limit)-byte limit.")
            }
        }
        return data
    }

    private func publishStoreData(
        _ data: Data,
        to location: WorkspaceCheckpointStoreLocation
    ) throws {
        let temporaryName = "." + location.storeName + ".tmp-" + UUID().uuidString
        let temporaryDescriptor = Darwin.openat(
            location.parentDescriptor,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard temporaryDescriptor >= 0 else {
            throw WorkspaceCheckpointError.storeWriteFailed("Could not create checkpoint store temporary file (errno \(errno)).")
        }
        var published = false
        defer {
            _ = Darwin.close(temporaryDescriptor)
            if !published {
                _ = unlinkat(location.parentDescriptor, temporaryName, 0)
            }
        }

        var temporaryStatus = stat()
        guard fstat(temporaryDescriptor, &temporaryStatus) == 0,
              (temporaryStatus.st_mode & S_IFMT) == S_IFREG,
              temporaryStatus.st_uid == geteuid() else {
            throw WorkspaceCheckpointError.storeWriteFailed("Checkpoint store temporary file is unsafe.")
        }
        try writeStoreData(data, to: temporaryDescriptor)
        try synchronizeDescriptor(
            temporaryDescriptor,
            failure: "Could not synchronize checkpoint store temporary file"
        )
        try validatePublishTarget(location)
        guard renameat(
            location.parentDescriptor,
            temporaryName,
            location.parentDescriptor,
            location.storeName
        ) == 0 else {
            throw WorkspaceCheckpointError.storeWriteFailed("Could not publish checkpoint store (errno \(errno)).")
        }
        published = true
        try synchronizeDescriptor(
            location.parentDescriptor,
            failure: "Checkpoint store was published, but its directory could not be synchronized"
        )
    }

    private func validatePublishTarget(_ location: WorkspaceCheckpointStoreLocation) throws {
        var existingStatus = stat()
        if fstatat(
            location.parentDescriptor,
            location.storeName,
            &existingStatus,
            AT_SYMLINK_NOFOLLOW
        ) == 0 {
            guard (existingStatus.st_mode & S_IFMT) == S_IFREG else {
                throw WorkspaceCheckpointError.storeWriteFailed("Checkpoint store must be a regular file.")
            }
        } else if errno != ENOENT {
            throw WorkspaceCheckpointError.storeWriteFailed("Could not inspect checkpoint store (errno \(errno)).")
        }
    }

    private func writeStoreData(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw WorkspaceCheckpointError.storeWriteFailed("Could not write checkpoint store (errno \(errno)).")
                }
                guard result > 0 else {
                    throw WorkspaceCheckpointError.storeWriteFailed("Checkpoint store write made no progress.")
                }
                offset += result
            }
        }
    }

    private func synchronizeDescriptor(_ descriptor: Int32, failure: String) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw WorkspaceCheckpointError.storeWriteFailed(failure + " (errno " + String(errno) + ").")
        }
    }

    private static func isSafeBasename(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\0")
            // Leave room for adjacent lock and UUID-suffixed temporary names.
            && value.utf8.count <= 200
    }

    public func notes(
        checkpointID: UUID? = nil,
        sessionID: UUID? = nil,
        runID: UUID? = nil
    ) throws -> [WorkspaceReviewNote] {
        try load().notes.filter { note in
            if let checkpointID, note.checkpointID != checkpointID { return false }
            if let sessionID, note.sessionID != sessionID { return false }
            if let runID, note.runID != runID { return false }
            return true
        }
    }

    /// Decodes current or legacy v1-shaped documents (missing `notes` / newer fields).
    public static func decodeMigrating(_ data: Data) throws -> WorkspaceCheckpointStoreDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let parsedObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let rawVersion = parsedObject?["version"] {
            guard let version = rawVersion as? Int, version >= 1 else {
                throw WorkspaceCheckpointError.storeUnreadable("Checkpoint store schema version is malformed.")
            }
            guard version <= WorkspaceCheckpointStoreDocument.currentVersion else {
                throw WorkspaceCheckpointError.storeUnreadable(
                    "Checkpoint store schema version \(version) is newer than supported version \(WorkspaceCheckpointStoreDocument.currentVersion)."
                )
            }
        }

        if let modern = try? decoder.decode(WorkspaceCheckpointStoreDocument.self, from: data) {
            var document = modern
            if document.version < WorkspaceCheckpointStoreDocument.currentVersion {
                document.version = WorkspaceCheckpointStoreDocument.currentVersion
            }
            return document
        }

        // Legacy v1: object with `checkpoints` only, or a bare checkpoint array.
        if let object = parsedObject {
            let version = object["version"] as? Int ?? 1
            let checkpointData: Data
            if let checkpoints = object["checkpoints"] {
                checkpointData = try JSONSerialization.data(withJSONObject: checkpoints)
            } else {
                throw WorkspaceCheckpointError.storeUnreadable("Legacy store missing checkpoints array.")
            }
            let checkpoints = try decoder.decode([WorkspaceCheckpoint].self, from: checkpointData)
            var notes: [WorkspaceReviewNote] = []
            if let rawNotes = object["notes"] {
                do {
                    let notesData = try JSONSerialization.data(withJSONObject: rawNotes)
                    notes = try decoder.decode([WorkspaceReviewNote].self, from: notesData)
                } catch {
                    throw WorkspaceCheckpointError.storeUnreadable("Legacy checkpoint review notes are malformed.")
                }
            }
            return WorkspaceCheckpointStoreDocument(
                version: max(version, WorkspaceCheckpointStoreDocument.currentVersion),
                checkpoints: checkpoints,
                notes: notes
            )
        }

        if let checkpoints = try? decoder.decode([WorkspaceCheckpoint].self, from: data) {
            return WorkspaceCheckpointStoreDocument(
                version: WorkspaceCheckpointStoreDocument.currentVersion,
                checkpoints: checkpoints,
                notes: []
            )
        }

        throw WorkspaceCheckpointError.storeUnreadable("Unrecognized checkpoint store document.")
    }
}

private struct WorkspaceCheckpointStoreLocation {
    let parentDescriptor: Int32
    let storeName: String
    let lockName: String
}

private struct WorkspaceCheckpointStoreLockError: Error {
    let detail: String

    init(_ detail: String) {
        self.detail = detail
    }
}

// MARK: - Path / validation helpers

public enum WorkspaceCheckpointValidation {
    public static let maximumReviewNoteBytes = 32 * 1024
    /// Validates a repo-relative path suitable for notes and untracked metadata.
    public static func validateRepoRelativePath(_ raw: String) throws -> String {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw WorkspaceCheckpointError.invalidRepoRelativePath(raw)
        }
        guard !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !path.contains("\\"),
              !path.contains("\0") else {
            throw WorkspaceCheckpointError.invalidRepoRelativePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.contains(".."), !components.contains("") else {
            throw WorkspaceCheckpointError.invalidRepoRelativePath(path)
        }
        if components.contains(".") {
            // Allow "." only as a whole-path rejection; single-dot segments are odd but
            // normalize away for storage consistency.
        }
        let normalized = components.filter { $0 != "." }.joined(separator: "/")
        guard !normalized.isEmpty else {
            throw WorkspaceCheckpointError.invalidRepoRelativePath(path)
        }
        return normalized
    }

    public static func validateLineRange(_ range: WorkspaceReviewLineRange?) throws {
        guard let range else { return }
        guard range.start >= 1, range.end >= range.start else {
            throw WorkspaceCheckpointError.invalidLineRange(start: range.start, end: range.end)
        }
    }

    public static func validateReviewBody(_ raw: String) throws -> String {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.utf8.count <= maximumReviewNoteBytes else {
            throw WorkspaceCheckpointError.storeWriteFailed(
                "Review text must be between 1 byte and \(maximumReviewNoteBytes) bytes."
            )
        }
        return body
    }
}
