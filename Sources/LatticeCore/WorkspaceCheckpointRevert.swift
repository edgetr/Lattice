import CryptoKit
import Foundation

public extension WorkspaceCheckpointService {
    // MARK: Guarded revert

    /// Builds a revert preview from an after-run checkpoint back to its paired before-run checkpoint.
    func previewRevert(afterCheckpointID: UUID) async throws -> WorkspaceCheckpointRevertPreview {
        try await withWorkspaceMutationLock {
            try await self.previewRevertUnlocked(afterCheckpointID: afterCheckpointID)
        }
    }

    private func previewRevertUnlocked(afterCheckpointID: UUID) async throws -> WorkspaceCheckpointRevertPreview {
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
    func confirmRevert(
        afterCheckpointID: UUID,
        confirmationToken: String
    ) async throws -> WorkspaceCheckpointRevertResult {
        try await withWorkspaceMutationLock {
            try await self.confirmRevertUnlocked(
                afterCheckpointID: afterCheckpointID,
                confirmationToken: confirmationToken
            )
        }
    }

    private func confirmRevertUnlocked(
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
        let afterUntracked = try Self.validatedUntrackedMap(after, label: "after-run checkpoint")
        var preparedDeletes: [PreparedUntrackedDeletion] = []
        var preparedBytes = 0
        for operation in preview.operations where operation.kind == .deleteRunCreatedUntracked {
            guard let metadata = afterUntracked[operation.path], !metadata.isSymbolicLink else {
                throw WorkspaceCheckpointError.revertDivergence(
                    "Missing regular-file metadata for " + operation.path + "."
                )
            }
            if let prepared = try prepareRegularRepoFile(
                context: context,
                relativePath: operation.path,
                expectedFingerprint: metadata.contentOID
            ) {
                guard preparedBytes <= Self.maximumUntrackedAggregateBytes - prepared.bytes.count else {
                    throw WorkspaceCheckpointError.revertApplyFailed(
                        "Run-created files exceed the bounded revert backup limit."
                    )
                }
                preparedBytes += prepared.bytes.count
                preparedDeletes.append(prepared)
            }
        }

        // Preflight every destructive operation before mutating either tracked
        // or untracked state. Deleted regular files remain in bounded memory
        // until the tracked patch and every unlink have succeeded.
        let preApplyTrackedTree = try await writeCurrentTrackedTree(git: git, context: context)
        var forwardPatch = Data()
        var compensationPatch = Data()
        if let beforeTree = before.treeOID, let afterTree = after.treeOID, beforeTree != afterTree {
            let validatedBeforeTree = try Self.validateGitOID(beforeTree, label: "before tree")
            let validatedAfterTree = try Self.validateGitOID(afterTree, label: "after tree")
            forwardPatch = try await runGitData(
                git: git,
                context: context,
                arguments: ["diff", "--no-ext-diff", "--no-textconv", "--binary", validatedAfterTree, validatedBeforeTree, "--"],
                operation: "diff --binary"
            )
            compensationPatch = try await runGitData(
                git: git,
                context: context,
                arguments: ["diff", "--no-ext-diff", "--no-textconv", "--binary", validatedBeforeTree, validatedAfterTree, "--"],
                operation: "diff compensation --binary"
            )
            if !forwardPatch.isEmpty {
                _ = try await runGitCommand(
                    git: git,
                    context: context,
                    arguments: ["apply", "--check", "--whitespace=nowarn"],
                    operation: "apply --check",
                    stdinData: forwardPatch
                )
            }
        }
        let revalidatedTree = try await writeCurrentTrackedTree(git: git, context: context)
        guard revalidatedTree == preApplyTrackedTree else {
            throw WorkspaceCheckpointError.revertDivergence(
                "Tracked worktree changed during revert preflight."
            )
        }

        var trackedPatchAttempted = false
        var deleted: [PreparedUntrackedDeletion] = []
        do {
            if !forwardPatch.isEmpty {
                trackedPatchAttempted = true
                _ = try await runGitCommand(
                    git: git,
                    context: context,
                    arguments: ["apply", "--whitespace=nowarn"],
                    operation: "apply",
                    stdinData: forwardPatch
                )
            }
            for (index, prepared) in preparedDeletes.enumerated() {
                try unlinkPreparedRegularRepoFile(
                    context: context,
                    prepared: prepared,
                    ordinal: index + 1
                )
                deleted.append(prepared)
            }
        } catch {
            let original = (error as? WorkspaceCheckpointError)?.message ?? error.localizedDescription
            var recoveryFailures: [String] = []
            if trackedPatchAttempted {
                do {
                    let current = try await writeCurrentTrackedTree(git: git, context: context)
                    if current != preApplyTrackedTree {
                        guard !compensationPatch.isEmpty else {
                            throw WorkspaceCheckpointError.revertApplyFailed("No compensation patch was available.")
                        }
                        _ = try await runGitCommand(
                            git: git,
                            context: context,
                            arguments: ["apply", "--check", "--whitespace=nowarn"],
                            operation: "compensation apply --check",
                            stdinData: compensationPatch
                        )
                        _ = try await runGitCommand(
                            git: git,
                            context: context,
                            arguments: ["apply", "--whitespace=nowarn"],
                            operation: "compensation apply",
                            stdinData: compensationPatch
                        )
                    }
                } catch {
                    recoveryFailures.append("tracked files: " + error.localizedDescription)
                }
            }
            for prepared in deleted.reversed() {
                do {
                    try restorePreparedRegularRepoFile(context: context, prepared: prepared)
                } catch {
                    recoveryFailures.append(prepared.path + ": " + error.localizedDescription)
                }
            }
            if recoveryFailures.isEmpty {
                throw WorkspaceCheckpointError.revertApplyFailed(
                    "Revert failed; all mutations were restored. Original failure: " + original
                )
            }
            throw WorkspaceCheckpointError.revertApplyFailed(
                "Revert failed and recovery is incomplete. Original failure: " + original
                    + " Recovery failures: " + recoveryFailures.joined(separator: "; ")
                    + ". Manual recovery is required."
            )
        }

        return WorkspaceCheckpointRevertResult(
            beforeCheckpointID: before.id,
            afterCheckpointID: after.id,
            appliedOperations: preview.operations,
            summary: "Reverted run \(after.ownership.runID.uuidString) from after-run checkpoint to before-run checkpoint."
        )
    }

    // MARK: Revert helpers

    func requireCheckpoint(id: UUID) throws -> WorkspaceCheckpoint {
        guard let checkpoint = try store.checkpoint(id: id) else {
            throw WorkspaceCheckpointError.checkpointNotFound(id)
        }
        return checkpoint
    }

    func requireCaptured(id: UUID) throws -> WorkspaceCheckpoint {
        let checkpoint = try requireCheckpoint(id: id)
        guard checkpoint.status == .captured else {
            throw WorkspaceCheckpointError.checkpointNotCaptured(id)
        }
        return checkpoint
    }

    func validatePair(before: WorkspaceCheckpoint, after: WorkspaceCheckpoint) throws {
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
        if let value = before.treeOID { _ = try Self.validateGitOID(value, label: "before tree") }
        if let value = after.treeOID { _ = try Self.validateGitOID(value, label: "after tree") }
        if let value = before.snapshotCommitOID { _ = try Self.validateGitOID(value, label: "before snapshot commit") }
        if let value = after.snapshotCommitOID { _ = try Self.validateGitOID(value, label: "after snapshot commit") }
        _ = try Self.validatedUntrackedMap(before, label: "before-run checkpoint")
        _ = try Self.validatedUntrackedMap(after, label: "after-run checkpoint")
    }

    static func validatedUntrackedMap(
        _ checkpoint: WorkspaceCheckpoint,
        label: String
    ) throws -> [String: WorkspaceUntrackedFileMetadata] {
        var result: [String: WorkspaceUntrackedFileMetadata] = [:]
        for metadata in checkpoint.untrackedFiles {
            let path = try WorkspaceCheckpointValidation.validateRepoRelativePath(metadata.path)
            guard path == metadata.path else {
                throw WorkspaceCheckpointError.checkpointPairInvalid(
                    label + " contains a non-canonical untracked path."
                )
            }
            guard result[path] == nil else {
                throw WorkspaceCheckpointError.checkpointPairInvalid(
                    label + " contains duplicate untracked path " + path + "."
                )
            }
            guard !metadata.contentOID.isEmpty, metadata.contentOID.utf8.count <= 160 else {
                throw WorkspaceCheckpointError.checkpointPairInvalid(
                    label + " contains an invalid untracked fingerprint for " + path + "."
                )
            }
            result[path] = metadata
        }
        return result
    }

    func pairedBeforeCheckpoint(for after: WorkspaceCheckpoint) throws -> WorkspaceCheckpoint {
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

    func buildRevertPreview(
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

        guard let rawBeforeTree = before.treeOID, let rawAfterTree = after.treeOID else {
            throw WorkspaceCheckpointError.checkpointPairInvalid("Missing tree OIDs.")
        }
        let beforeTree = try Self.validateGitOID(rawBeforeTree, label: "before tree")
        let afterTree = try Self.validateGitOID(rawAfterTree, label: "after tree")

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

        let beforeUntracked = try Self.validatedUntrackedMap(before, label: "before-run checkpoint")
        let afterUntracked = try Self.validatedUntrackedMap(after, label: "after-run checkpoint")

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
            if afterMeta.isSymbolicLink {
                warnings.append(
                    "Run-created symlink " + path + " is non-revertible and will be left unchanged."
                )
                continue
            }
            _ = try prepareRegularRepoFile(
                context: context,
                relativePath: path,
                expectedFingerprint: afterMeta.contentOID
            )
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
        warnings.append("Only bounded, exact run-created regular files are deleted; symlinks and pre-existing untracked content remain untouched.")

        var patchFingerprint = ""
        if beforeTree != afterTree {
            let patch = try await runGitData(
                git: git,
                context: context,
                arguments: ["diff", "--no-ext-diff", "--no-textconv", "--binary", afterTree, beforeTree, "--"],
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

    func assertNoStagedTargetChanges(
        git: URL,
        context: WorktreeContext,
        targetPaths: [String]
    ) async throws {
        guard !targetPaths.isEmpty else { return }
        let output = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["diff", "--no-ext-diff", "--no-textconv", "--cached", "--name-only", "-z", "--"] + targetPaths,
            operation: "diff --cached --name-only"
        )
        let staged = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        if !staged.isEmpty {
            throw WorkspaceCheckpointError.revertStagedChanges(paths: staged.sorted())
        }
    }

    func assertNoUnmergedPaths(git: URL, context: WorktreeContext) async throws {
        let output = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["diff", "--no-ext-diff", "--no-textconv", "--name-only", "--diff-filter=U", "-z", "--"],
            operation: "diff unmerged paths"
        )
        let paths = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        if !paths.isEmpty {
            throw WorkspaceCheckpointError.revertDivergence(
                "Repository has unresolved conflicts: \(paths.sorted().joined(separator: ", "))."
            )
        }
    }

    func assertWorkingTreeMatchesAfter(
        git: URL,
        context: WorktreeContext,
        after: WorkspaceCheckpoint,
        targetPaths: [String]
    ) async throws {
        guard let rawAfterTree = after.treeOID, !targetPaths.isEmpty else { return }
        let afterTree = try Self.validateGitOID(rawAfterTree, label: "after tree")

        let currentTree = try await writeCurrentTrackedTree(git: git, context: context)
        let changed = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", afterTree, currentTree, "--"] + targetPaths,
            operation: "diff current tracked tree"
        )
        let divergentPaths = changed.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        if !divergentPaths.isEmpty {
            throw WorkspaceCheckpointError.revertDivergence(
                "Target paths changed after the checkpoint: \(divergentPaths.sorted().joined(separator: ", "))."
            )
        }
    }

    func writeCurrentTrackedTree(git: URL, context: WorktreeContext) async throws -> String {
        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory
            .appendingPathComponent("lattice-checkpoint-compare-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: tempRoot) }
        let indexURL = tempRoot.appendingPathComponent("index")
        let indexTreeOID = try await currentIndexTreeOID(git: git, context: context)
        return try await writeTrackedWorktreeTree(
            git: git,
            context: context,
            temporaryIndexURL: indexURL,
            sourceIndexTreeOID: indexTreeOID
        )
    }

}
