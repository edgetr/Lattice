import CryptoKit
import Foundation

public extension WorkspaceCheckpointService {
    // MARK: Guarded revert

    /// Builds a revert preview from an after-run checkpoint back to its paired before-run checkpoint.
    func previewRevert(afterCheckpointID: UUID) async throws -> WorkspaceCheckpointRevertPreview {
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

    func assertNoStagedTargetChanges(
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

    func assertNoUnmergedPaths(git: URL, context: WorktreeContext) async throws {
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

    func assertWorkingTreeMatchesAfter(
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

    func writeCurrentTrackedTree(git: URL, context: WorktreeContext) async throws -> String {
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

    func assertUntrackedDeleteStillMatches(
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

}
