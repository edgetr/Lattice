import CryptoKit
import Foundation

// MARK: - Service

/// Git-backed workspace checkpoint capture, review diff, notes, and guarded revert.
///
/// Snapshots use a temporary alternate index (`git add -u`, `write-tree`, `commit-tree`,
/// `update-ref`) under a Lattice-specific ref namespace. Untracked contents are never
/// written into Git objects or the durable store. Revert is preview-gated and uses
/// binary reverse patches with `git apply --check` / `git apply`.
public struct WorkspaceCheckpointService: Sendable {
    public var store: WorkspaceCheckpointStore
    public var gitExecutableURL: URL?
    public var deadline: TimeInterval
    public var maximumOutputBytes: Int

    public init(
        store: WorkspaceCheckpointStore,
        gitExecutableURL: URL? = nil,
        deadline: TimeInterval = 30,
        maximumOutputBytes: Int = BoundedSubprocessRequest.defaultMaximumOutputBytes
    ) {
        self.store = store
        self.gitExecutableURL = gitExecutableURL
        self.deadline = deadline
        self.maximumOutputBytes = maximumOutputBytes
    }

    // MARK: Capture

    /// Captures tracked working-tree state for the given ownership and boundary.
    @discardableResult
    public func capture(
        worktreeURL: URL,
        sessionID: UUID,
        runID: UUID,
        boundary: WorkspaceCheckpointBoundary
    ) async throws -> WorkspaceCheckpoint {
        let git = try resolveGit()
        let context = try await resolveWorktreeContext(git: git, worktreeURL: worktreeURL)
        let ownership = WorkspaceCheckpointOwnership(
            worktreePath: context.toplevelPath,
            worktreeIdentity: context.worktreeIdentity,
            sessionID: sessionID,
            runID: runID
        )
        let checkpointID = UUID()
        let createdAt = Date()

        do {
            let headOID = try await readHeadCommit(git: git, context: context)
            let trackedDirty = try await hasTrackedDirtiness(git: git, context: context)
            let indexDirty = try await hasIndexDirtiness(git: git, context: context)
            let untracked = try await collectUntrackedMetadata(git: git, context: context)
            let snapshot = try await writeTrackedSnapshot(
                git: git,
                context: context,
                headOID: headOID,
                ownership: ownership,
                boundary: boundary,
                checkpointID: checkpointID
            )
            let headTree: String?
            if let headOID {
                headTree = try await treeForCommit(git: git, context: context, commit: headOID)
            } else {
                headTree = nil
            }
            let stats = try await changeStats(
                git: git,
                context: context,
                fromTree: headTree,
                toTree: snapshot.treeOID
            )

            let checkpoint = WorkspaceCheckpoint(
                id: checkpointID,
                ownership: ownership,
                boundary: boundary,
                status: .captured,
                createdAt: createdAt,
                headCommitOID: headOID,
                treeOID: snapshot.treeOID,
                snapshotCommitOID: snapshot.commitOID,
                refName: snapshot.refName,
                hasTrackedDirtiness: trackedDirty,
                hasIndexDirtiness: indexDirty,
                untrackedFiles: untracked,
                changeStats: stats,
                failureSummary: nil
            )
            try store.upsert(checkpoint)
            return checkpoint
        } catch let error as WorkspaceCheckpointError {
            let failed = WorkspaceCheckpoint(
                id: checkpointID,
                ownership: ownership,
                boundary: boundary,
                status: .failed,
                createdAt: createdAt,
                failureSummary: error.message
            )
            try? store.upsert(failed)
            throw error
        } catch {
            let failed = WorkspaceCheckpoint(
                id: checkpointID,
                ownership: ownership,
                boundary: boundary,
                status: .failed,
                createdAt: createdAt,
                failureSummary: error.localizedDescription
            )
            try? store.upsert(failed)
            throw WorkspaceCheckpointError.captureFailed(error.localizedDescription)
        }
    }

    // MARK: Diff

    /// Computes per-file changes (with hunks) between a before/after checkpoint pair.
    public func changes(
        beforeCheckpointID: UUID,
        afterCheckpointID: UUID
    ) async throws -> WorkspaceCheckpointChangeSet {
        let before = try requireCaptured(id: beforeCheckpointID)
        let after = try requireCaptured(id: afterCheckpointID)
        try validatePair(before: before, after: after)

        guard let beforeTree = before.treeOID, let afterTree = after.treeOID else {
            throw WorkspaceCheckpointError.checkpointPairInvalid("Missing tree OIDs on checkpoint pair.")
        }

        let git = try resolveGit()
        let context = try await resolveWorktreeContext(
            git: git,
            worktreeURL: URL(fileURLWithPath: after.ownership.worktreePath, isDirectory: true)
        )
        guard context.worktreeIdentity == after.ownership.worktreeIdentity else {
            throw WorkspaceCheckpointError.checkpointPairInvalid(
                "Worktree identity no longer matches the after-run checkpoint ownership."
            )
        }

        let files = try await diffFilesWithHunks(
            git: git,
            context: context,
            fromTree: beforeTree,
            toTree: afterTree
        )
        let untrackedFiles = Self.untrackedChanges(before: before, after: after)
        let allFiles = (files + untrackedFiles).sorted { $0.path < $1.path }
        let stats = WorkspaceCheckpointChangeStats(
            filesChanged: allFiles.count,
            additions: allFiles.reduce(0) { $0 + $1.additions },
            deletions: allFiles.reduce(0) { $0 + $1.deletions }
        )
        return WorkspaceCheckpointChangeSet(
            beforeCheckpointID: before.id,
            afterCheckpointID: after.id,
            files: allFiles,
            stats: stats
        )
    }

    // MARK: Review notes

    @discardableResult
    public func addReviewNote(
        checkpointID: UUID,
        path: String,
        body: String,
        kind: WorkspaceReviewNoteKind = .note,
        lineRange: WorkspaceReviewLineRange? = nil,
        hunkHeader: String? = nil
    ) throws -> WorkspaceReviewNote {
        let checkpoint = try requireCheckpoint(id: checkpointID)
        let normalizedPath = try WorkspaceCheckpointValidation.validateRepoRelativePath(path)
        try WorkspaceCheckpointValidation.validateLineRange(lineRange)
        let validatedBody = try WorkspaceCheckpointValidation.validateReviewBody(body)
        let note = WorkspaceReviewNote(
            checkpointID: checkpoint.id,
            sessionID: checkpoint.ownership.sessionID,
            runID: checkpoint.ownership.runID,
            path: normalizedPath,
            lineRange: lineRange,
            hunkHeader: hunkHeader,
            kind: kind,
            body: validatedBody
        )
        try store.appendNote(note)
        return note
    }

    public func reviewNotes(
        checkpointID: UUID? = nil,
        sessionID: UUID? = nil,
        runID: UUID? = nil
    ) throws -> [WorkspaceReviewNote] {
        try store.notes(checkpointID: checkpointID, sessionID: sessionID, runID: runID)
    }

    // MARK: Guarded revert

    /// Builds a revert preview from an after-run checkpoint back to its paired before-run checkpoint.
    public func previewRevert(afterCheckpointID: UUID) async throws -> WorkspaceCheckpointRevertPreview {
        let after = try requireCaptured(id: afterCheckpointID)
        guard after.boundary == .afterRun else {
            throw WorkspaceCheckpointError.checkpointPairInvalid(
                "Revert requires an after-run checkpoint."
            )
        }
        let before = try pairedBeforeCheckpoint(for: after)
        return try await buildRevertPreview(before: before, after: after)
    }

    /// Applies a previously previewed revert using the confirmation token from that preview.
    public func confirmRevert(
        afterCheckpointID: UUID,
        confirmationToken: String
    ) async throws -> WorkspaceCheckpointRevertResult {
        let token = confirmationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw WorkspaceCheckpointError.revertConfirmationInvalid
        }

        let after = try requireCaptured(id: afterCheckpointID)
        let before = try pairedBeforeCheckpoint(for: after)
        let preview = try await buildRevertPreview(before: before, after: after)
        guard preview.confirmationToken == token else {
            throw WorkspaceCheckpointError.revertConfirmationStale
        }

        let git = try resolveGit()
        let context = try await resolveWorktreeContext(
            git: git,
            worktreeURL: URL(fileURLWithPath: after.ownership.worktreePath, isDirectory: true)
        )
        guard context.worktreeIdentity == after.ownership.worktreeIdentity else {
            throw WorkspaceCheckpointError.revertDivergence("Worktree identity changed since capture.")
        }

        try await assertNoStagedTargetChanges(
            git: git,
            context: context,
            targetPaths: preview.targetPaths
        )
        try await assertWorkingTreeMatchesAfter(
            git: git,
            context: context,
            after: after,
            targetPaths: preview.targetPaths.filter { path in
                preview.operations.contains {
                    $0.kind == .applyTrackedReversePatch && $0.path == path
                }
            }
        )
        try await assertUntrackedDeleteStillMatches(
            git: git,
            context: context,
            after: after,
            operations: preview.operations
        )

        // Recompute the binary reverse patch and apply under check-then-apply.
        if let beforeTree = before.treeOID, let afterTree = after.treeOID, beforeTree != afterTree {
            let patch = try await runGitData(
                git: git,
                context: context,
                arguments: ["diff", "--binary", afterTree, beforeTree],
                operation: "diff --binary"
            )
            if !patch.isEmpty {
                _ = try await runGitCommand(
                    git: git,
                    context: context,
                    arguments: ["apply", "--check", "--whitespace=nowarn"],
                    operation: "apply --check",
                    stdinData: patch
                )
                _ = try await runGitCommand(
                    git: git,
                    context: context,
                    arguments: ["apply", "--whitespace=nowarn"],
                    operation: "apply",
                    stdinData: patch
                )
            }
        }

        var applied: [WorkspaceCheckpointRevertOperation] = []
        for operation in preview.operations where operation.kind == .deleteRunCreatedUntracked {
            let url = URL(fileURLWithPath: context.toplevelPath, isDirectory: true)
                .appendingPathComponent(operation.path)
            // Re-verify OID immediately before delete.
            if Self.pathExistsWithoutFollowingSymlink(url) {
                guard let metadata = after.untrackedFiles.first(where: { $0.path == operation.path }) else {
                    throw WorkspaceCheckpointError.revertDivergence("Missing untracked metadata for \(operation.path).")
                }
                let fingerprint = try await untrackedFingerprint(
                    git: git,
                    context: context,
                    path: operation.path,
                    isSymbolicLink: metadata.isSymbolicLink
                )
                guard fingerprint == metadata.contentOID else {
                    throw WorkspaceCheckpointError.revertDivergence(
                        "Untracked file \(operation.path) changed before delete."
                    )
                }
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    throw WorkspaceCheckpointError.revertApplyFailed(
                        "Failed to delete untracked file \(operation.path): \(error.localizedDescription)"
                    )
                }
            }
            applied.append(operation)
        }
        for operation in preview.operations where operation.kind == .applyTrackedReversePatch {
            applied.append(operation)
        }

        return WorkspaceCheckpointRevertResult(
            beforeCheckpointID: before.id,
            afterCheckpointID: after.id,
            appliedOperations: applied,
            summary: "Reverted run \(after.ownership.runID.uuidString) from after-run checkpoint to before-run checkpoint."
        )
    }

    // MARK: Internals — worktree / git

    private struct WorktreeContext: Sendable {
        var toplevelPath: String
        var gitCommonDir: String
        var worktreeIdentity: String
    }

    private struct SnapshotWrite: Sendable {
        var treeOID: String
        var commitOID: String
        var refName: String
    }

    private func resolveGit() throws -> URL {
        if let gitExecutableURL {
            return gitExecutableURL
        }
        if let discovered = ExecutableDiscovery.locate("git") {
            return discovered
        }
        throw WorkspaceCheckpointError.gitExecutableUnavailable
    }

    private func resolveWorktreeContext(git: URL, worktreeURL: URL) async throws -> WorktreeContext {
        let path = worktreeURL.resolvingSymlinksInPath().standardizedFileURL.path
        let toplevel = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: path, isDirectory: true),
            arguments: ["rev-parse", "--show-toplevel"],
            operation: "rev-parse --show-toplevel"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toplevel.isEmpty else {
            throw WorkspaceCheckpointError.notAGitWorktree(path)
        }
        let commonDirRaw = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: toplevel, isDirectory: true),
            arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            operation: "rev-parse --git-common-dir"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let commonDir = URL(fileURLWithPath: commonDirRaw).resolvingSymlinksInPath().standardizedFileURL.path
        let identity = Self.worktreeIdentity(toplevel: toplevel, gitCommonDir: commonDir)
        return WorktreeContext(
            toplevelPath: toplevel,
            gitCommonDir: commonDir,
            worktreeIdentity: identity
        )
    }

    static func worktreeIdentity(toplevel: String, gitCommonDir: String) -> String {
        let payload = "toplevel=\(toplevel)\ncommon=\(gitCommonDir)\n"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func latticeRefName(
        ownership: WorkspaceCheckpointOwnership,
        boundary: WorkspaceCheckpointBoundary,
        checkpointID: UUID
    ) -> String {
        // refs/lattice/checkpoints/<worktreeIdentity>/<session>/<run>/<boundary>/<checkpoint>
        let session = ownership.sessionID.uuidString.lowercased()
        let run = ownership.runID.uuidString.lowercased()
        let checkpoint = checkpointID.uuidString.lowercased()
        return "refs/lattice/checkpoints/\(ownership.worktreeIdentity)/\(session)/\(run)/\(boundary.rawValue)/\(checkpoint)"
    }

    private func readHeadCommit(git: URL, context: WorktreeContext) async throws -> String? {
        let result = await BoundedSubprocess.run(
            BoundedSubprocessRequest(
                executableURL: git,
                arguments: ["rev-parse", "-q", "--verify", "HEAD"],
                currentDirectoryURL: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
                deadline: deadline,
                maximumOutputBytes: maximumOutputBytes
            )
        )
        if result.outcome == .exited {
            if result.exitStatus == 0 {
                let oid = string(from: result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                return oid.isEmpty ? nil : oid
            }
            // `rev-parse -q --verify HEAD` returns 1 for an unborn HEAD.
            if result.exitStatus == 1 { return nil }
        }
        try throwSubprocessFailure(operation: "rev-parse HEAD", result: result)
        return nil
    }

    private func hasTrackedDirtiness(git: URL, context: WorktreeContext) async throws -> Bool {
        let result = await BoundedSubprocess.run(
            BoundedSubprocessRequest(
                executableURL: git,
                arguments: ["diff-files", "--quiet"],
                currentDirectoryURL: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
                deadline: deadline,
                maximumOutputBytes: maximumOutputBytes
            )
        )
        if result.outcome == .exited {
            // 0 = clean, 1 = dirty
            if result.exitStatus == 0 { return false }
            if result.exitStatus == 1 { return true }
            try throwSubprocessFailure(operation: "diff-files", result: result)
            return false
        }
        try throwSubprocessFailure(operation: "diff-files", result: result)
        return false
    }

    private func hasIndexDirtiness(git: URL, context: WorktreeContext) async throws -> Bool {
        // Compare index to HEAD when HEAD exists; otherwise any index entry is dirty.
        let head = try await readHeadCommit(git: git, context: context)
        let arguments: [String]
        if let head {
            arguments = ["diff-index", "--quiet", "--cached", head]
        } else {
            arguments = ["diff-index", "--quiet", "--cached", "4b825dc642cb6eb9a060e54bf8d69288fbee4904"]
        }
        let result = await BoundedSubprocess.run(
            BoundedSubprocessRequest(
                executableURL: git,
                arguments: arguments,
                currentDirectoryURL: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
                deadline: deadline,
                maximumOutputBytes: maximumOutputBytes
            )
        )
        if result.outcome == .exited {
            if result.exitStatus == 0 { return false }
            if result.exitStatus == 1 { return true }
            try throwSubprocessFailure(operation: "diff-index --cached", result: result)
            return false
        }
        // Empty tree may fail on exotic setups; fall back to ls-files.
        if head == nil {
            let listed = try await runGitString(
                git: git,
                currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
                arguments: ["ls-files", "--stage"],
                operation: "ls-files --stage"
            )
            return !listed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        try throwSubprocessFailure(operation: "diff-index --cached", result: result)
        return false
    }

    private func collectUntrackedMetadata(
        git: URL,
        context: WorktreeContext
    ) async throws -> [WorkspaceUntrackedFileMetadata] {
        let listing = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
            operation: "ls-files --others"
        )
        let paths = listing.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result: [WorkspaceUntrackedFileMetadata] = []
        result.reserveCapacity(paths.count)
        for path in paths {
            let normalized = try WorkspaceCheckpointValidation.validateRepoRelativePath(path)
            let fileURL = URL(fileURLWithPath: context.toplevelPath, isDirectory: true)
                .appendingPathComponent(normalized)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  attributes[.type] as? FileAttributeType != .typeDirectory else {
                continue
            }
            let isSymbolicLink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = attributes[.modificationDate] as? Date
            let oid = try await untrackedFingerprint(
                git: git,
                context: context,
                path: normalized,
                isSymbolicLink: isSymbolicLink
            )
            result.append(
                WorkspaceUntrackedFileMetadata(
                    path: normalized,
                    byteSize: size,
                    contentOID: oid,
                    isSymbolicLink: isSymbolicLink,
                    canRestoreContent: false,
                    modificationTime: mtime
                )
            )
        }
        return result.sorted { $0.path < $1.path }
    }

    private func hashObjectNoWrite(
        git: URL,
        context: WorktreeContext,
        path: String
    ) async throws -> String {
        // Never pass `-w`; content must not enter the object database from untracked capture.
        let oid = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["hash-object", "--", path],
            operation: "hash-object"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oid.isEmpty else {
            throw WorkspaceCheckpointError.subprocessFailed(
                operation: "hash-object",
                detail: "Empty OID for \(path)"
            )
        }
        return oid
    }

    private func untrackedFingerprint(
        git: URL,
        context: WorktreeContext,
        path: String,
        isSymbolicLink expectedSymlink: Bool? = nil
    ) async throws -> String {
        let fileURL = URL(fileURLWithPath: context.toplevelPath, isDirectory: true)
            .appendingPathComponent(path)
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let isSymbolicLink = attributes[.type] as? FileAttributeType == .typeSymbolicLink
        if let expectedSymlink, expectedSymlink != isSymbolicLink {
            return "type-changed"
        }
        if isSymbolicLink {
            let destination = try FileManager.default.destinationOfSymbolicLink(atPath: fileURL.path)
            let digest = SHA256.hash(data: Data(destination.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            return "symlink-sha256:\(digest)"
        }
        return try await hashObjectNoWrite(git: git, context: context, path: path)
    }

    private func writeTrackedSnapshot(
        git: URL,
        context: WorktreeContext,
        headOID: String?,
        ownership: WorkspaceCheckpointOwnership,
        boundary: WorkspaceCheckpointBoundary,
        checkpointID: UUID
    ) async throws -> SnapshotWrite {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory
            .appendingPathComponent("lattice-checkpoint-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let indexURL = tempRoot.appendingPathComponent("index")
        // Seed from the user's current index tree, then update only paths already tracked
        // there. This includes staged additions without ever sweeping unrelated untracked
        // files into Git objects. `write-tree` is read-only with respect to the real index.
        let indexTreeOID = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["write-tree"],
            operation: "write-tree current index"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runGitCommand(
            git: git,
            context: context,
            arguments: ["read-tree", indexTreeOID],
            operation: "read-tree current index",
            environmentOverrides: ["GIT_INDEX_FILE": indexURL.path]
        )

        _ = try await runGitCommand(
            git: git,
            context: context,
            arguments: ["add", "-u"],
            operation: "add -u",
            environmentOverrides: ["GIT_INDEX_FILE": indexURL.path]
        )

        let treeOID = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["write-tree"],
            operation: "write-tree",
            environmentOverrides: ["GIT_INDEX_FILE": indexURL.path]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        var commitArguments = ["commit-tree", treeOID]
        if let headOID {
            commitArguments += ["-p", headOID]
        }
        commitArguments += [
            "-m",
            "lattice-checkpoint \(boundary.rawValue) \(checkpointID.uuidString.lowercased())"
        ]
        let commitOID = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: commitArguments,
            operation: "commit-tree",
            environmentOverrides: [
                "GIT_INDEX_FILE": indexURL.path,
                "GIT_AUTHOR_NAME": "Lattice Checkpoint",
                "GIT_AUTHOR_EMAIL": "checkpoint@lattice.local",
                "GIT_COMMITTER_NAME": "Lattice Checkpoint",
                "GIT_COMMITTER_EMAIL": "checkpoint@lattice.local"
            ]
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let refName = Self.latticeRefName(
            ownership: ownership,
            boundary: boundary,
            checkpointID: checkpointID
        )
        _ = try await runGitCommand(
            git: git,
            context: context,
            // Empty expected-old value is compare-and-swap for "ref must not exist".
            arguments: ["update-ref", refName, commitOID, ""],
            operation: "update-ref"
        )

        return SnapshotWrite(treeOID: treeOID, commitOID: commitOID, refName: refName)
    }

    private func treeForCommit(git: URL, context: WorktreeContext, commit: String) async throws -> String {
        try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["rev-parse", "\(commit)^{tree}"],
            operation: "rev-parse tree"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func changeStats(
        git: URL,
        context: WorktreeContext,
        fromTree: String?,
        toTree: String
    ) async throws -> WorkspaceCheckpointChangeStats {
        let base = fromTree ?? "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
        if base == toTree {
            return WorkspaceCheckpointChangeStats()
        }
        let output = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["diff", "--numstat", base, toTree],
            operation: "diff --numstat"
        )
        return Self.parseNumstat(output)
    }

    public static func parseNumstat(_ output: String) -> WorkspaceCheckpointChangeStats {
        var files = 0
        var additions = 0
        var deletions = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            files += 1
            if parts[0] != "-", let add = Int(parts[0]) {
                additions += add
            }
            if parts[1] != "-", let del = Int(parts[1]) {
                deletions += del
            }
        }
        return WorkspaceCheckpointChangeStats(
            filesChanged: files,
            additions: additions,
            deletions: deletions
        )
    }

    private func diffFilesWithHunks(
        git: URL,
        context: WorktreeContext,
        fromTree: String,
        toTree: String
    ) async throws -> [WorkspaceCheckpointFileChange] {
        if fromTree == toTree { return [] }

        let nameStatus = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["diff", "--name-status", "-z", fromTree, toTree],
            operation: "diff --name-status"
        )
        let numstat = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["diff", "--numstat", "-z", fromTree, toTree],
            operation: "diff --numstat -z"
        )
        let patch = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["diff", "--unified=3", fromTree, toTree],
            operation: "diff unified"
        )

        let statuses = Self.parseNameStatus(nameStatus)
        let counts = Self.parseNumstatByPath(numstat)
        let hunksByPath = Self.parseUnifiedDiffHunks(patch)

        return statuses.map { entry in
            let count = counts[entry.path] ?? (0, 0)
            return WorkspaceCheckpointFileChange(
                path: entry.path,
                previousPath: entry.previousPath,
                status: entry.status,
                additions: count.0,
                deletions: count.1,
                hunks: hunksByPath[entry.path] ?? []
            )
        }
    }

    private static func untrackedChanges(
        before: WorkspaceCheckpoint,
        after: WorkspaceCheckpoint
    ) -> [WorkspaceCheckpointFileChange] {
        let beforeByPath = Dictionary(uniqueKeysWithValues: before.untrackedFiles.map { ($0.path, $0) })
        let afterByPath = Dictionary(uniqueKeysWithValues: after.untrackedFiles.map { ($0.path, $0) })
        return Set(beforeByPath.keys).union(afterByPath.keys).compactMap { path in
            let old = beforeByPath[path]
            let new = afterByPath[path]
            let status: WorkspaceCheckpointFileStatus
            switch (old, new) {
            case (nil, .some): status = .added
            case (.some, nil): status = .deleted
            case let (.some(lhs), .some(rhs)) where lhs.contentOID != rhs.contentOID || lhs.byteSize != rhs.byteSize:
                status = .modified
            default:
                return nil
            }
            return WorkspaceCheckpointFileChange(
                path: path,
                status: status,
                isUntracked: true,
                additions: 0,
                deletions: 0
            )
        }
    }

    private struct NameStatusEntry {
        var path: String
        var previousPath: String?
        var status: WorkspaceCheckpointFileStatus
    }

    private static func parseNameStatus(_ output: String) -> [NameStatusEntry] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var index = 0
        var entries: [NameStatusEntry] = []
        while index < tokens.count {
            let statusToken = tokens[index]
            index += 1
            guard let code = statusToken.first else { continue }
            switch code {
            case "R", "C":
                guard index + 1 < tokens.count else { return entries }
                let previous = tokens[index]
                let next = tokens[index + 1]
                index += 2
                entries.append(
                    NameStatusEntry(
                        path: next,
                        previousPath: previous,
                        status: code == "R" ? .renamed : .copied
                    )
                )
            case "A":
                guard index < tokens.count else { return entries }
                entries.append(NameStatusEntry(path: tokens[index], previousPath: nil, status: .added))
                index += 1
            case "D":
                guard index < tokens.count else { return entries }
                entries.append(NameStatusEntry(path: tokens[index], previousPath: nil, status: .deleted))
                index += 1
            case "M":
                guard index < tokens.count else { return entries }
                entries.append(NameStatusEntry(path: tokens[index], previousPath: nil, status: .modified))
                index += 1
            case "T":
                guard index < tokens.count else { return entries }
                entries.append(NameStatusEntry(path: tokens[index], previousPath: nil, status: .typeChanged))
                index += 1
            default:
                if index < tokens.count {
                    entries.append(NameStatusEntry(path: tokens[index], previousPath: nil, status: .unknown))
                    index += 1
                }
            }
        }
        return entries
    }

    static func parseNumstatByPath(_ output: String) -> [String: (Int, Int)] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var result: [String: (Int, Int)] = [:]
        // numstat -z: additions \t deletions \t path \0  OR with rename: additions \t deletions \0 path \0 path \0
        var index = 0
        while index < tokens.count {
            let head = tokens[index]
            index += 1
            let parts = head.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 3 {
                let add = parts[0] == "-" ? 0 : (Int(parts[0]) ?? 0)
                let del = parts[1] == "-" ? 0 : (Int(parts[1]) ?? 0)
                let path = parts[2...].joined(separator: "\t")
                result[path] = (add, del)
                continue
            }
            if parts.count == 2, index < tokens.count {
                let add = parts[0] == "-" ? 0 : (Int(parts[0]) ?? 0)
                let del = parts[1] == "-" ? 0 : (Int(parts[1]) ?? 0)
                // rename form: next tokens are old path, new path
                if index + 1 < tokens.count {
                    let newPath = tokens[index + 1]
                    result[newPath] = (add, del)
                    index += 2
                } else if index < tokens.count {
                    result[tokens[index]] = (add, del)
                    index += 1
                }
            }
        }
        return result
    }

    /// Parses `@@ -oldStart[,oldCount] +newStart[,newCount] @@` headers without regex force-unwraps.
    public static func parseHunkHeader(_ header: String) -> (
        oldStart: Int,
        oldCount: Int,
        newStart: Int,
        newCount: Int
    )? {
        guard header.hasPrefix("@@ ") else { return nil }
        let body = header.dropFirst(3)
        guard let firstAt = body.range(of: "@@") else { return nil }
        let ranges = body[..<firstAt.lowerBound]
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard ranges.count >= 2 else { return nil }

        func parseSide(_ token: String, expectedPrefix: Character) -> (Int, Int)? {
            guard token.first == expectedPrefix else { return nil }
            let rest = token.dropFirst()
            let parts = rest.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard let start = Int(parts[0]) else { return nil }
            let count: Int
            if parts.count == 1 {
                count = 1
            } else if let parsed = Int(parts[1]) {
                count = parsed
            } else {
                return nil
            }
            return (start, count)
        }

        guard let old = parseSide(ranges[0], expectedPrefix: "-"),
              let new = parseSide(ranges[1], expectedPrefix: "+") else {
            return nil
        }
        return (old.0, old.1, new.0, new.1)
    }

    public static func parseUnifiedDiffHunks(_ patch: String) -> [String: [WorkspaceCheckpointHunk]] {
        var currentPath: String?
        var currentHunks: [WorkspaceCheckpointHunk] = []
        var result: [String: [WorkspaceCheckpointHunk]] = [:]
        var hunkHeader: String?
        var oldStart = 0, oldCount = 0, newStart = 0, newCount = 0
        var lines: [WorkspaceCheckpointDiffLine] = []
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            guard let hunkHeader else { return }
            currentHunks.append(
                WorkspaceCheckpointHunk(
                    header: hunkHeader,
                    oldStart: oldStart,
                    oldCount: oldCount,
                    newStart: newStart,
                    newCount: newCount,
                    lines: lines
                )
            )
            lines = []
        }
        func flushFile() {
            flushHunk()
            hunkHeader = nil
            if let currentPath {
                result[currentPath] = currentHunks
            }
            currentHunks = []
            currentPath = nil
        }

        for rawLine in patch.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) {
            if rawLine.hasPrefix("diff --git ") {
                flushFile()
                // diff --git a/path b/path
                if let bRange = rawLine.range(of: " b/") {
                    currentPath = String(rawLine[bRange.upperBound...])
                }
                continue
            }
            if rawLine.hasPrefix("+++ ") {
                let value = String(rawLine.dropFirst(4))
                if value != "/dev/null" {
                    if value.hasPrefix("b/") {
                        currentPath = String(value.dropFirst(2))
                    } else {
                        currentPath = value
                    }
                }
                continue
            }
            if rawLine.hasPrefix("--- ") {
                continue
            }
            if rawLine.hasPrefix("@@ ") {
                flushHunk()
                guard let parsed = Self.parseHunkHeader(rawLine) else {
                    continue
                }
                oldStart = parsed.oldStart
                oldCount = parsed.oldCount
                newStart = parsed.newStart
                newCount = parsed.newCount
                hunkHeader = rawLine
                oldLine = oldStart
                newLine = newStart
                lines = []
                continue
            }
            guard hunkHeader != nil else { continue }
            if rawLine.hasPrefix("+") {
                let text = String(rawLine.dropFirst())
                lines.append(
                    WorkspaceCheckpointDiffLine(
                        kind: .addition,
                        text: text,
                        oldLineNumber: nil,
                        newLineNumber: newLine
                    )
                )
                newLine += 1
            } else if rawLine.hasPrefix("-") {
                let text = String(rawLine.dropFirst())
                lines.append(
                    WorkspaceCheckpointDiffLine(
                        kind: .deletion,
                        text: text,
                        oldLineNumber: oldLine,
                        newLineNumber: nil
                    )
                )
                oldLine += 1
            } else if rawLine.hasPrefix(" ") || rawLine.isEmpty {
                let text = rawLine.hasPrefix(" ") ? String(rawLine.dropFirst()) : rawLine
                lines.append(
                    WorkspaceCheckpointDiffLine(
                        kind: .context,
                        text: text,
                        oldLineNumber: oldLine,
                        newLineNumber: newLine
                    )
                )
                oldLine += 1
                newLine += 1
            } else if rawLine.hasPrefix("\\") {
                // "\ No newline at end of file"
                continue
            }
        }
        flushFile()
        return result
    }

    // MARK: Revert helpers

    private func requireCheckpoint(id: UUID) throws -> WorkspaceCheckpoint {
        guard let checkpoint = try store.checkpoint(id: id) else {
            throw WorkspaceCheckpointError.checkpointNotFound(id)
        }
        return checkpoint
    }

    private func requireCaptured(id: UUID) throws -> WorkspaceCheckpoint {
        let checkpoint = try requireCheckpoint(id: id)
        guard checkpoint.status == .captured else {
            throw WorkspaceCheckpointError.checkpointNotCaptured(id)
        }
        return checkpoint
    }

    private func validatePair(before: WorkspaceCheckpoint, after: WorkspaceCheckpoint) throws {
        guard before.boundary == .beforeRun, after.boundary == .afterRun else {
            throw WorkspaceCheckpointError.checkpointPairInvalid(
                "Expected beforeRun then afterRun boundaries."
            )
        }
        guard before.ownership.sessionID == after.ownership.sessionID,
              before.ownership.runID == after.ownership.runID,
              before.ownership.worktreeIdentity == after.ownership.worktreeIdentity else {
            throw WorkspaceCheckpointError.checkpointPairInvalid(
                "before/after ownership mismatch (session, run, or worktree)."
            )
        }
    }

    private func pairedBeforeCheckpoint(for after: WorkspaceCheckpoint) throws -> WorkspaceCheckpoint {
        let candidates = try store.checkpoints(
            sessionID: after.ownership.sessionID,
            runID: after.ownership.runID,
            worktreeIdentity: after.ownership.worktreeIdentity
        )
        .filter { $0.boundary == .beforeRun && $0.status == .captured }
        .sorted { $0.createdAt < $1.createdAt }

        guard let before = candidates.last else {
            throw WorkspaceCheckpointError.checkpointPairInvalid(
                "No captured before-run checkpoint for this session/run/worktree."
            )
        }
        try validatePair(before: before, after: after)
        return before
    }

    private func buildRevertPreview(
        before: WorkspaceCheckpoint,
        after: WorkspaceCheckpoint
    ) async throws -> WorkspaceCheckpointRevertPreview {
        let git = try resolveGit()
        let context = try await resolveWorktreeContext(
            git: git,
            worktreeURL: URL(fileURLWithPath: after.ownership.worktreePath, isDirectory: true)
        )
        guard context.worktreeIdentity == after.ownership.worktreeIdentity else {
            throw WorkspaceCheckpointError.revertPreviewRefused(
                "Worktree identity does not match the after-run checkpoint."
            )
        }

        guard let beforeTree = before.treeOID, let afterTree = after.treeOID else {
            throw WorkspaceCheckpointError.checkpointPairInvalid("Missing tree OIDs.")
        }

        var operations: [WorkspaceCheckpointRevertOperation] = []
        var warnings: [String] = []
        var targetPaths: [String] = []

        if beforeTree != afterTree {
            let files = try await diffFilesWithHunks(
                git: git,
                context: context,
                fromTree: afterTree,
                toTree: beforeTree
            )
            for file in files {
                targetPaths.append(file.path)
                if let previousPath = file.previousPath {
                    targetPaths.append(previousPath)
                }
                operations.append(
                    WorkspaceCheckpointRevertOperation(
                        kind: .applyTrackedReversePatch,
                        path: file.path,
                        detail: "Restore tracked path via reverse binary patch (\(file.status.rawValue))."
                    )
                )
            }
        }

        let beforeUntracked = Dictionary(uniqueKeysWithValues: before.untrackedFiles.map { ($0.path, $0) })
        let afterUntracked = Dictionary(uniqueKeysWithValues: after.untrackedFiles.map { ($0.path, $0) })

        // Pre-existing untracked that changed during the run cannot be restored.
        var unrestorable: [String] = []
        for (path, afterMeta) in afterUntracked {
            if let beforeMeta = beforeUntracked[path], beforeMeta.contentOID != afterMeta.contentOID {
                unrestorable.append(path)
            }
        }
        // Also: untracked present before but missing after — cannot recreate contents.
        for (path, _) in beforeUntracked where afterUntracked[path] == nil {
            unrestorable.append(path)
        }
        if !unrestorable.isEmpty {
            throw WorkspaceCheckpointError.revertUntrackedNotRestorable(paths: unrestorable.sorted())
        }

        // Run-created untracked (in after, not in before): delete only if current OID matches after.
        for (path, afterMeta) in afterUntracked where beforeUntracked[path] == nil {
            let fileURL = URL(fileURLWithPath: context.toplevelPath, isDirectory: true)
                .appendingPathComponent(path)
            if Self.pathExistsWithoutFollowingSymlink(fileURL) {
                let currentOID = try await untrackedFingerprint(
                    git: git,
                    context: context,
                    path: path,
                    isSymbolicLink: afterMeta.isSymbolicLink
                )
                if currentOID != afterMeta.contentOID {
                    throw WorkspaceCheckpointError.revertDivergence(
                        "Run-created untracked file \(path) was modified after the after-run checkpoint."
                    )
                }
            }
            targetPaths.append(path)
            operations.append(
                WorkspaceCheckpointRevertOperation(
                    kind: .deleteRunCreatedUntracked,
                    path: path,
                    detail: "Delete run-created untracked file whose content OID still matches the after checkpoint."
                )
            )
        }

        let uniqueTargets = Array(Set(targetPaths)).sorted()
        try await assertNoUnmergedPaths(git: git, context: context)
        try await assertNoStagedTargetChanges(git: git, context: context, targetPaths: uniqueTargets)
        try await assertWorkingTreeMatchesAfter(
            git: git,
            context: context,
            after: after,
            targetPaths: uniqueTargets.filter { path in
                operations.contains { $0.kind == .applyTrackedReversePatch && $0.path == path }
            }
        )

        if operations.isEmpty {
            warnings.append("No tracked or untracked changes to revert between before/after checkpoints.")
        }
        warnings.append("Untracked file contents are not restorable; only exact run-created deletes are supported.")

        var patchFingerprint = ""
        if beforeTree != afterTree {
            let patch = try await runGitData(
                git: git,
                context: context,
                arguments: ["diff", "--binary", afterTree, beforeTree],
                operation: "diff --binary"
            )
            patchFingerprint = SHA256.hash(data: patch).map { String(format: "%02x", $0) }.joined()
            if !patch.isEmpty {
                _ = try await runGitCommand(
                    git: git,
                    context: context,
                    arguments: ["apply", "--check", "--whitespace=nowarn"],
                    operation: "apply --check",
                    stdinData: patch
                )
            }
        }

        let fingerprint = Self.revertInputFingerprint(
            before: before,
            after: after,
            targetPaths: uniqueTargets,
            operations: operations,
            patchFingerprint: patchFingerprint
        )
        let token = "lattice-revert-v1:\(fingerprint)"

        return WorkspaceCheckpointRevertPreview(
            beforeCheckpointID: before.id,
            afterCheckpointID: after.id,
            ownership: after.ownership,
            targetPaths: uniqueTargets,
            operations: operations,
            warnings: warnings,
            confirmationToken: token,
            inputFingerprint: fingerprint
        )
    }

    static func revertInputFingerprint(
        before: WorkspaceCheckpoint,
        after: WorkspaceCheckpoint,
        targetPaths: [String],
        operations: [WorkspaceCheckpointRevertOperation],
        patchFingerprint: String
    ) -> String {
        var lines: [String] = [
            "before=\(before.id.uuidString.lowercased())",
            "after=\(after.id.uuidString.lowercased())",
            "beforeTree=\(before.treeOID ?? "")",
            "afterTree=\(after.treeOID ?? "")",
            "beforeCommit=\(before.snapshotCommitOID ?? "")",
            "afterCommit=\(after.snapshotCommitOID ?? "")",
            "worktree=\(after.ownership.worktreeIdentity)",
            "patch=\(patchFingerprint)"
        ]
        for path in targetPaths.sorted() {
            lines.append("target=\(path)")
        }
        for operation in operations.sorted(by: { $0.path == $1.path ? $0.kind.rawValue < $1.kind.rawValue : $0.path < $1.path }) {
            lines.append("op=\(operation.kind.rawValue)|\(operation.path)|\(operation.detail)")
        }
        let payload = lines.joined(separator: "\n")
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func assertNoStagedTargetChanges(
        git: URL,
        context: WorktreeContext,
        targetPaths: [String]
    ) async throws {
        guard !targetPaths.isEmpty else { return }
        let output = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["diff", "--cached", "--name-only", "-z", "--"] + targetPaths,
            operation: "diff --cached --name-only"
        )
        let staged = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        if !staged.isEmpty {
            throw WorkspaceCheckpointError.revertStagedChanges(paths: staged.sorted())
        }
    }

    private func assertNoUnmergedPaths(git: URL, context: WorktreeContext) async throws {
        let output = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["diff", "--name-only", "--diff-filter=U", "-z"],
            operation: "diff unmerged paths"
        )
        let paths = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        if !paths.isEmpty {
            throw WorkspaceCheckpointError.revertDivergence(
                "Repository has unresolved conflicts: \(paths.sorted().joined(separator: ", "))."
            )
        }
    }

    private func assertWorkingTreeMatchesAfter(
        git: URL,
        context: WorktreeContext,
        after: WorkspaceCheckpoint,
        targetPaths: [String]
    ) async throws {
        guard let afterTree = after.treeOID, !targetPaths.isEmpty else { return }

        let currentTree = try await writeCurrentTrackedTree(git: git, context: context)
        let changed = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["diff", "--name-only", "-z", afterTree, currentTree, "--"] + targetPaths,
            operation: "diff current tracked tree"
        )
        let divergentPaths = changed.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        if !divergentPaths.isEmpty {
            throw WorkspaceCheckpointError.revertDivergence(
                "Target paths changed after the checkpoint: \(divergentPaths.sorted().joined(separator: ", "))."
            )
        }
    }

    private func writeCurrentTrackedTree(git: URL, context: WorktreeContext) async throws -> String {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("lattice-checkpoint-compare-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }
        let indexURL = tempRoot.appendingPathComponent("index")
        let indexTreeOID = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["write-tree"],
            operation: "write-tree current index"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await runGitCommand(
            git: git,
            context: context,
            arguments: ["read-tree", indexTreeOID],
            operation: "read-tree current index",
            environmentOverrides: ["GIT_INDEX_FILE": indexURL.path]
        )
        _ = try await runGitCommand(
            git: git,
            context: context,
            arguments: ["add", "-u"],
            operation: "add -u",
            environmentOverrides: ["GIT_INDEX_FILE": indexURL.path]
        )
        return try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["write-tree"],
            operation: "write-tree current worktree",
            environmentOverrides: ["GIT_INDEX_FILE": indexURL.path]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assertUntrackedDeleteStillMatches(
        git: URL,
        context: WorktreeContext,
        after: WorkspaceCheckpoint,
        operations: [WorkspaceCheckpointRevertOperation]
    ) async throws {
        for operation in operations where operation.kind == .deleteRunCreatedUntracked {
            let fileURL = URL(fileURLWithPath: context.toplevelPath, isDirectory: true)
                .appendingPathComponent(operation.path)
            guard Self.pathExistsWithoutFollowingSymlink(fileURL) else { continue }
            guard let metadata = after.untrackedFiles.first(where: { $0.path == operation.path }) else {
                throw WorkspaceCheckpointError.revertDivergence("Missing untracked metadata for \(operation.path).")
            }
            let current = try await untrackedFingerprint(
                git: git,
                context: context,
                path: operation.path,
                isSymbolicLink: metadata.isSymbolicLink
            )
            guard current == metadata.contentOID else {
                throw WorkspaceCheckpointError.revertDivergence(
                    "Untracked path \(operation.path) no longer matches the after-run checkpoint."
                )
            }
        }
    }

    // MARK: Subprocess helpers

    private func runGitCommand(
        git: URL,
        context: WorktreeContext,
        arguments: [String],
        operation: String,
        environmentOverrides: [String: String] = [:],
        stdinData: Data? = nil
    ) async throws -> BoundedSubprocessResult {
        var environment = ProcessInfo.processInfo.environment
        // Keep process environment minimal mutations; never route through a shell.
        for (key, value) in environmentOverrides {
            environment[key] = value
        }
        // Avoid interactive prompts.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GC_AUTO"] = "0"

        let result = await BoundedSubprocess.run(
            BoundedSubprocessRequest(
                executableURL: git,
                arguments: arguments,
                stdinData: stdinData,
                currentDirectoryURL: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
                environment: environment,
                deadline: deadline,
                maximumOutputBytes: maximumOutputBytes
            )
        )
        if result.isSuccess { return result }
        try throwSubprocessFailure(operation: operation, result: result)
        return result
    }

    private static func pathExistsWithoutFollowingSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private func runGitString(
        git: URL,
        currentDirectory: URL,
        arguments: [String],
        operation: String,
        environmentOverrides: [String: String] = [:]
    ) async throws -> String {
        let context = WorktreeContext(
            toplevelPath: currentDirectory.path,
            gitCommonDir: "",
            worktreeIdentity: ""
        )
        let result = try await self.runGitCommand(
            git: git,
            context: context,
            arguments: arguments,
            operation: operation,
            environmentOverrides: environmentOverrides
        )
        return string(from: result.stdout)
    }

    private func runGitData(
        git: URL,
        context: WorktreeContext,
        arguments: [String],
        operation: String
    ) async throws -> Data {
        let result = try await self.runGitCommand(
            git: git,
            context: context,
            arguments: arguments,
            operation: operation
        )
        return result.stdout
    }

    private func string(from data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }

    private func throwSubprocessFailure(operation: String, result: BoundedSubprocessResult) throws {
        switch result.outcome {
        case .timedOut:
            throw WorkspaceCheckpointError.subprocessTimedOut(operation: operation)
        case .cancelled:
            throw WorkspaceCheckpointError.subprocessCancelled(operation: operation)
        case .launchFailed:
            throw WorkspaceCheckpointError.subprocessFailed(
                operation: operation,
                detail: result.launchErrorDescription ?? "Launch failed."
            )
        case .outputLimitExceeded:
            throw WorkspaceCheckpointError.subprocessFailed(
                operation: operation,
                detail: "Output limit exceeded (\(result.observedOutputBytes) bytes observed)."
            )
        case .exited, .completed:
            let stderr = string(from: result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = string(from: result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = [stderr, stdout].first(where: { !$0.isEmpty }) ?? "exit \(result.exitStatus ?? -1)"
            throw WorkspaceCheckpointError.subprocessFailed(operation: operation, detail: detail)
        }
    }
}
