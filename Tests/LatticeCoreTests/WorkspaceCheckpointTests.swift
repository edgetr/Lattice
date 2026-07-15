import Foundation
import Testing
@testable import LatticeCore

@Suite("Workspace checkpoint service")
struct WorkspaceCheckpointTests {
    // MARK: - Fixtures

    private struct TempGitRepo {
        let root: URL
        let git: URL

        var path: String { root.path }
    }

    private func makeStore() throws -> (store: WorkspaceCheckpointStore, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-checkpoint-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = WorkspaceCheckpointStore(fileURL: root.appendingPathComponent("workspace-checkpoints.json"))
        return (store, root)
    }

    private func resolveGit() throws -> URL {
        guard let git = ExecutableDiscovery.locate("git") else {
            throw WorkspaceCheckpointError.gitExecutableUnavailable
        }
        return git
    }

    private func runGit(
        _ git: URL,
        in directory: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        input: Data? = nil
    ) async throws -> String {
        var env = ProcessInfo.processInfo.environment
        if let environment {
            for (key, value) in environment {
                env[key] = value
            }
        }
        env["GIT_TERMINAL_PROMPT"] = "0"
        let result = await BoundedSubprocess.run(
            BoundedSubprocessRequest(
                executableURL: git,
                arguments: arguments,
                stdinData: input,
                currentDirectoryURL: directory,
                environment: env,
                deadline: 30,
                maximumOutputBytes: BoundedSubprocessRequest.defaultMaximumOutputBytes
            )
        )
        guard result.isSuccess else {
            let detail = String(data: result.stderr, encoding: .utf8)
                ?? String(data: result.stdout, encoding: .utf8)
                ?? "exit \(result.exitStatus ?? -1)"
            throw WorkspaceCheckpointError.subprocessFailed(operation: arguments.joined(separator: " "), detail: detail)
        }
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }

    private func makeRepo(named: String = "repo") async throws -> TempGitRepo {
        let git = try resolveGit()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-checkpoint-\(named)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        _ = try await runGit(git, in: root, ["init"])
        // Local identity only inside temp repos (never touch global gitconfig).
        _ = try await runGit(git, in: root, ["config", "user.email", "checkpoint-tests@lattice.local"])
        _ = try await runGit(git, in: root, ["config", "user.name", "Lattice Checkpoint Tests"])
        _ = try await runGit(git, in: root, ["config", "commit.gpgsign", "false"])

        try "hello\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        _ = try await runGit(git, in: root, ["add", "tracked.txt"])
        _ = try await runGit(git, in: root, ["commit", "-m", "init"])

        return TempGitRepo(root: root, git: git)
    }

    private func makeService(store: WorkspaceCheckpointStore, git: URL) -> WorkspaceCheckpointService {
        WorkspaceCheckpointService(store: store, gitExecutableURL: git, deadline: 30)
    }

    // MARK: - Capture

    @Test func cleanWorktreeCaptureRecordsTruthfulDirtiness() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let service = makeService(store: store, git: repo.git)
        let sessionID = UUID()
        let runID = UUID()

        let checkpoint = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .beforeRun
        )

        #expect(checkpoint.status == .captured)
        #expect(checkpoint.ownership.sessionID == sessionID)
        #expect(checkpoint.ownership.runID == runID)
        #expect(checkpoint.hasTrackedDirtiness == false)
        #expect(checkpoint.hasIndexDirtiness == false)
        #expect(checkpoint.untrackedFiles.isEmpty)
        #expect(checkpoint.treeOID != nil)
        #expect(checkpoint.snapshotCommitOID != nil)
        #expect(checkpoint.refName?.hasPrefix("refs/lattice/checkpoints/") == true)
        #expect(checkpoint.refName?.contains(sessionID.uuidString.lowercased()) == true)
        #expect(checkpoint.refName?.contains(runID.uuidString.lowercased()) == true)

        // Ref exists and is collision-scoped.
        let resolved = try await runGit(
            repo.git,
            in: repo.root,
            ["rev-parse", checkpoint.refName!]
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(resolved == checkpoint.snapshotCommitOID)
    }

    @Test func trackedDirtyCaptureDoesNotUseDestructiveGitCommands() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        try "dirty tracked\n".write(
            to: repo.root.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let headBefore = try await runGit(repo.git, in: repo.root, ["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workingBefore = try String(
            contentsOf: repo.root.appendingPathComponent("tracked.txt"),
            encoding: .utf8
        )

        let service = makeService(store: store, git: repo.git)
        let checkpoint = try await service.capture(
            worktreeURL: repo.root,
            sessionID: UUID(),
            runID: UUID(),
            boundary: .beforeRun
        )

        #expect(checkpoint.status == .captured)
        #expect(checkpoint.hasTrackedDirtiness == true)
        #expect(checkpoint.changeStats.filesChanged >= 1)

        let headAfter = try await runGit(repo.git, in: repo.root, ["rev-parse", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workingAfter = try String(
            contentsOf: repo.root.appendingPathComponent("tracked.txt"),
            encoding: .utf8
        )
        #expect(headAfter == headBefore)
        #expect(workingAfter == workingBefore)

        // Snapshot tree must reflect dirty content, not HEAD clean content.
        let show = try await runGit(
            repo.git,
            in: repo.root,
            ["show", "\(checkpoint.treeOID!):tracked.txt"]
        )
        #expect(show == workingBefore)
    }

    @Test func untrackedMetadataIsRecordedWithoutWritingObjectsOrContents() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let secret = "super-secret-untracked-payload-\(UUID().uuidString)\n"
        try secret.write(to: repo.root.appendingPathComponent("scratch.secret"), atomically: true, encoding: .utf8)
        try "ignored\n".write(to: repo.root.appendingPathComponent("noise.log"), atomically: true, encoding: .utf8)
        try "*.log\n".write(to: repo.root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let outsideSecret = storeRoot.appendingPathComponent("outside-secret.txt")
        let outsidePayload = "must-not-be-read-through-symlink-\(UUID().uuidString)"
        try outsidePayload.write(to: outsideSecret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: repo.root.appendingPathComponent("outside-link"),
            withDestinationURL: outsideSecret
        )
        // Keep .gitignore untracked for this privacy assertion so we only care about secret/log.

        let service = makeService(store: store, git: repo.git)
        let checkpoint = try await service.capture(
            worktreeURL: repo.root,
            sessionID: UUID(),
            runID: UUID(),
            boundary: .beforeRun
        )

        let paths = Set(checkpoint.untrackedFiles.map(\.path))
        #expect(paths.contains("scratch.secret"))
        #expect(!paths.contains("noise.log"), "Ignored files must be excluded")
        #expect(paths.contains(".gitignore"))

        let secretMeta = try #require(checkpoint.untrackedFiles.first(where: { $0.path == "scratch.secret" }))
        #expect(secretMeta.canRestoreContent == false)
        #expect(!secretMeta.contentOID.isEmpty)
        #expect(secretMeta.byteSize == Int64(secret.utf8.count))
        let linkMeta = try #require(checkpoint.untrackedFiles.first(where: { $0.path == "outside-link" }))
        #expect(linkMeta.isSymbolicLink)
        #expect(linkMeta.contentOID.hasPrefix("symlink-sha256:"))

        // Content must not be written into the object database.
        let cat = await BoundedSubprocess.run(
            BoundedSubprocessRequest(
                executableURL: repo.git,
                arguments: ["cat-file", "-t", secretMeta.contentOID],
                currentDirectoryURL: repo.root,
                deadline: 10
            )
        )
        #expect(cat.isSuccess == false)

        // Durable store must not retain untracked contents.
        let rawStore = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!rawStore.contains("super-secret-untracked-payload"))
        #expect(!rawStore.contains("must-not-be-read-through-symlink"))
        #expect(rawStore.contains(secretMeta.contentOID))
    }

    // MARK: - Diff / review

    @Test func beforeAfterDiffIncludesHunkLineRanges() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let service = makeService(store: store, git: repo.git)
        let sessionID = UUID()
        let runID = UUID()

        let before = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .beforeRun
        )

        try "hello\nworld\n".write(
            to: repo.root.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "brand new\n".write(
            to: repo.root.appendingPathComponent("added.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await runGit(repo.git, in: repo.root, ["add", "added.txt"])
        try "untracked during run\n".write(
            to: repo.root.appendingPathComponent("untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let after = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .afterRun
        )

        let changes = try await service.changes(
            beforeCheckpointID: before.id,
            afterCheckpointID: after.id
        )
        #expect(changes.files.contains(where: { $0.path == "tracked.txt" && $0.status == .modified }))
        #expect(changes.files.contains(where: { $0.path == "added.txt" && $0.status == .added && !$0.isUntracked }))
        #expect(changes.files.contains(where: { $0.path == "untracked.txt" && $0.status == .added && $0.isUntracked }))
        #expect(changes.stats.filesChanged >= 1)

        let tracked = try #require(changes.files.first(where: { $0.path == "tracked.txt" }))
        #expect(!tracked.hunks.isEmpty)
        let hunk = try #require(tracked.hunks.first)
        #expect(hunk.oldStart >= 1)
        #expect(hunk.newStart >= 1)
        #expect(hunk.lines.contains(where: { $0.kind == .addition && $0.text.contains("world") }))
        #expect(hunk.lines.contains(where: { $0.kind == .addition && $0.newLineNumber != nil }))
    }

    // MARK: - Guarded revert

    @Test func guardedRevertRestoresTrackedStateAndDeletesRunCreatedUntracked() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let service = makeService(store: store, git: repo.git)
        let sessionID = UUID()
        let runID = UUID()

        let before = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .beforeRun
        )
        #expect(before.status == .captured)

        try "mutated by agent\n".write(
            to: repo.root.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "created during run\n".write(
            to: repo.root.appendingPathComponent("agent-temp.txt"),
            atomically: true,
            encoding: .utf8
        )

        let after = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .afterRun
        )

        let preview = try await service.previewRevert(afterCheckpointID: after.id)
        #expect(!preview.confirmationToken.isEmpty)
        #expect(preview.operations.contains(where: { $0.path == "tracked.txt" }))
        #expect(preview.operations.contains(where: {
            $0.kind == .deleteRunCreatedUntracked && $0.path == "agent-temp.txt"
        }))

        // Stale token must refuse.
        do {
            _ = try await service.confirmRevert(
                afterCheckpointID: after.id,
                confirmationToken: "lattice-revert-v1:deadbeef"
            )
            Issue.record("Stale confirmation must fail")
        } catch let error as WorkspaceCheckpointError {
            #expect(error == .revertConfirmationStale)
        }

        let result = try await service.confirmRevert(
            afterCheckpointID: after.id,
            confirmationToken: preview.confirmationToken
        )
        #expect(result.beforeCheckpointID == before.id)

        let restored = try String(contentsOf: repo.root.appendingPathComponent("tracked.txt"), encoding: .utf8)
        #expect(restored == "hello\n")
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("agent-temp.txt").path))
    }

    @Test func revertRefusesWhenTrackedPathDivergesFromAfterCheckpoint() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let service = makeService(store: store, git: repo.git)
        let sessionID = UUID()
        let runID = UUID()

        _ = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .beforeRun
        )
        try "after state\n".write(
            to: repo.root.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        let after = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .afterRun
        )

        // User edits after the after-run checkpoint.
        try "newer user edit\n".write(
            to: repo.root.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        do {
            _ = try await service.previewRevert(afterCheckpointID: after.id)
            Issue.record("Preview must refuse divergent working tree")
        } catch let error as WorkspaceCheckpointError {
            guard case .revertDivergence = error else {
                Issue.record("Expected revertDivergence, got \(error)")
                return
            }
        }

        // An unresolved index conflict is a separate refusal path from a newer
        // worktree edit. Populate stages 1/2/3 directly in this disposable repo.
        let baseOID = try await runGit(repo.git, in: repo.root, ["rev-parse", "HEAD:tracked.txt"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let oursOID = try await runGit(
            repo.git,
            in: repo.root,
            ["hash-object", "-w", "--stdin"],
            input: Data("ours\n".utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let theirsOID = try await runGit(
            repo.git,
            in: repo.root,
            ["hash-object", "-w", "--stdin"],
            input: Data("theirs\n".utf8)
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let indexInfo = "100644 \(baseOID) 1\ttracked.txt\n100644 \(oursOID) 2\ttracked.txt\n100644 \(theirsOID) 3\ttracked.txt\n"
        _ = try await runGit(
            repo.git,
            in: repo.root,
            ["update-index", "--index-info"],
            input: Data(indexInfo.utf8)
        )
        do {
            _ = try await service.previewRevert(afterCheckpointID: after.id)
            Issue.record("Preview must refuse unresolved index conflicts")
        } catch let error as WorkspaceCheckpointError {
            guard case .revertDivergence(let detail) = error,
                  detail.contains("unresolved conflicts") else {
                Issue.record("Expected unresolved conflict refusal, got \(error)")
                return
            }
        }
    }

    @Test func revertRefusesStagedTargetPathChanges() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let service = makeService(store: store, git: repo.git)
        let sessionID = UUID()
        let runID = UUID()

        _ = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .beforeRun
        )
        try "after\n".write(
            to: repo.root.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        let after = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .afterRun
        )

        // Stage a change on the target path after capture (index dirty).
        try "staged after capture\n".write(
            to: repo.root.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await runGit(repo.git, in: repo.root, ["add", "tracked.txt"])
        // Restore working tree to after-checkpoint content so only index diverges on stage check path...
        // Actually after staging, working tree equals staged. Put working tree back to after content while keeping index.
        // Simpler: leave both staged and worktree as "staged after capture" — divergence check hits first.
        // Force worktree to match after, keep index staged differently using update-index.
        try "after\n".write(
            to: repo.root.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        // Index still has "staged after capture" from git add; worktree has "after\n".

        do {
            _ = try await service.previewRevert(afterCheckpointID: after.id)
            Issue.record("Preview must refuse staged target changes")
        } catch let error as WorkspaceCheckpointError {
            guard case .revertStagedChanges = error else {
                Issue.record("Expected revertStagedChanges, got \(error)")
                return
            }
        }
    }

    @Test func revertRefusesWhenPreexistingUntrackedChanged() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        try "preexisting\n".write(
            to: repo.root.appendingPathComponent("notes.local"),
            atomically: true,
            encoding: .utf8
        )

        let service = makeService(store: store, git: repo.git)
        let sessionID = UUID()
        let runID = UUID()

        _ = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .beforeRun
        )
        try "changed untracked during run\n".write(
            to: repo.root.appendingPathComponent("notes.local"),
            atomically: true,
            encoding: .utf8
        )
        let after = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .afterRun
        )

        do {
            _ = try await service.previewRevert(afterCheckpointID: after.id)
            Issue.record("Must refuse unrestorable pre-existing untracked changes")
        } catch let error as WorkspaceCheckpointError {
            guard case .revertUntrackedNotRestorable(let paths) = error else {
                Issue.record("Expected revertUntrackedNotRestorable, got \(error)")
                return
            }
            #expect(paths.contains("notes.local"))
        }
    }

    // MARK: - Parallel worktree ownership

    @Test func parallelWorktreesGetDistinctRefsAndIdentities() async throws {
        let primary = try await makeRepo(named: "primary")
        defer { try? FileManager.default.removeItem(at: primary.root) }

        let worktreePath = primary.root.deletingLastPathComponent()
            .appendingPathComponent("lattice-wt-\(UUID().uuidString)", isDirectory: true)
        _ = try await runGit(
            primary.git,
            in: primary.root,
            ["worktree", "add", "--detach", worktreePath.path, "HEAD"]
        )
        defer {
            _ = try? FileManager.default.removeItem(at: worktreePath)
            // Best-effort prune registration.
            let process = Process()
            process.executableURL = primary.git
            process.arguments = ["-C", primary.root.path, "worktree", "prune"]
            try? process.run()
            process.waitUntilExit()
        }

        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let service = makeService(store: store, git: primary.git)

        let sessionA = UUID()
        let sessionB = UUID()
        let runA = UUID()
        let runB = UUID()

        let a = try await service.capture(
            worktreeURL: primary.root,
            sessionID: sessionA,
            runID: runA,
            boundary: .beforeRun
        )
        let b = try await service.capture(
            worktreeURL: worktreePath,
            sessionID: sessionB,
            runID: runB,
            boundary: .beforeRun
        )

        #expect(a.ownership.worktreeIdentity != b.ownership.worktreeIdentity)
        #expect(a.refName != b.refName)
        #expect(a.refName?.contains(a.ownership.worktreeIdentity) == true)
        #expect(b.refName?.contains(b.ownership.worktreeIdentity) == true)

        let refA = try await runGit(primary.git, in: primary.root, ["rev-parse", a.refName!])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refB = try await runGit(primary.git, in: worktreePath, ["rev-parse", b.refName!])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(refA == a.snapshotCommitOID)
        #expect(refB == b.snapshotCommitOID)
    }

    // MARK: - Review notes + validation

    @Test func reviewNoteValidationAndDurability() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let service = makeService(store: store, git: repo.git)
        let checkpoint = try await service.capture(
            worktreeURL: repo.root,
            sessionID: UUID(),
            runID: UUID(),
            boundary: .beforeRun
        )

        do {
            _ = try service.addReviewNote(
                checkpointID: checkpoint.id,
                path: "tracked.txt",
                body: "   "
            )
            Issue.record("Empty review text must fail")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeWriteFailed = error else {
                Issue.record("Expected storeWriteFailed, got \(error)")
                return
            }
        }

        do {
            _ = try service.addReviewNote(
                checkpointID: checkpoint.id,
                path: "/etc/passwd",
                body: "bad"
            )
            Issue.record("Absolute path must fail")
        } catch let error as WorkspaceCheckpointError {
            guard case .invalidRepoRelativePath = error else {
                Issue.record("Expected invalidRepoRelativePath, got \(error)")
                return
            }
        }

        do {
            _ = try service.addReviewNote(
                checkpointID: checkpoint.id,
                path: "../escape.txt",
                body: "bad"
            )
            Issue.record("Parent escape must fail")
        } catch let error as WorkspaceCheckpointError {
            guard case .invalidRepoRelativePath = error else {
                Issue.record("Expected invalidRepoRelativePath, got \(error)")
                return
            }
        }

        do {
            _ = try service.addReviewNote(
                checkpointID: checkpoint.id,
                path: "tracked.txt",
                body: "bad range",
                lineRange: WorkspaceReviewLineRange(start: 0, end: 2)
            )
            Issue.record("Non-positive line range must fail")
        } catch let error as WorkspaceCheckpointError {
            guard case .invalidLineRange = error else {
                Issue.record("Expected invalidLineRange, got \(error)")
                return
            }
        }

        do {
            _ = try service.addReviewNote(
                checkpointID: checkpoint.id,
                path: "tracked.txt",
                body: "bad order",
                lineRange: WorkspaceReviewLineRange(start: 5, end: 2)
            )
            Issue.record("Unordered line range must fail")
        } catch let error as WorkspaceCheckpointError {
            guard case .invalidLineRange = error else {
                Issue.record("Expected invalidLineRange, got \(error)")
                return
            }
        }

        let note = try service.addReviewNote(
            checkpointID: checkpoint.id,
            path: "tracked.txt",
            body: "Please double-check this change",
            kind: .followUpPrompt,
            lineRange: WorkspaceReviewLineRange(start: 1, end: 3),
            hunkHeader: "@@ -1 +1,3 @@"
        )
        #expect(note.sessionID == checkpoint.ownership.sessionID)
        #expect(note.runID == checkpoint.ownership.runID)

        let reloaded = try service.reviewNotes(checkpointID: checkpoint.id)
        #expect(reloaded.count == 1)
        #expect(reloaded[0].body == "Please double-check this change")
        #expect(reloaded[0].lineRange?.start == 1)
        #expect(reloaded[0].kind == .followUpPrompt)
    }

    // MARK: - Legacy persistence migration

    @Test func legacyV1StoreMigratesMissingNotesAndNewerFields() throws {
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let ownership = WorkspaceCheckpointOwnership(
            worktreePath: "/tmp/example",
            worktreeIdentity: "abc123",
            sessionID: UUID(),
            runID: UUID()
        )
        // Minimal legacy v1 shape: version 1, checkpoints without notes array and without some newer fields.
        let legacy: [String: Any] = [
            "version": 1,
            "checkpoints": [
                [
                    "id": ownership.sessionID.uuidString, // placeholder replaced below
                    "ownership": [
                        "worktreePath": ownership.worktreePath,
                        "worktreeIdentity": ownership.worktreeIdentity,
                        "sessionID": ownership.sessionID.uuidString,
                        "runID": ownership.runID.uuidString
                    ],
                    "boundary": "beforeRun",
                    "status": "captured",
                    "createdAt": "2024-01-01T00:00:00Z",
                    "treeOID": "deadbeef"
                    // intentionally omit hasTrackedDirtiness, untrackedFiles, changeStats, notes
                ]
            ]
        ]
        // Fix checkpoint id to a real UUID string.
        var checkpoints = legacy["checkpoints"] as! [[String: Any]]
        let checkpointID = UUID()
        checkpoints[0]["id"] = checkpointID.uuidString
        let document: [String: Any] = [
            "version": 1,
            "checkpoints": checkpoints
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: store.fileURL)

        let migrated = try store.load()
        #expect(migrated.version == WorkspaceCheckpointStoreDocument.currentVersion)
        #expect(migrated.notes.isEmpty)
        #expect(migrated.checkpoints.count == 1)
        #expect(migrated.checkpoints[0].id == checkpointID)
        #expect(migrated.checkpoints[0].treeOID == "deadbeef")
        #expect(migrated.checkpoints[0].hasTrackedDirtiness == false)
        #expect(migrated.checkpoints[0].untrackedFiles.isEmpty)
        #expect(migrated.checkpoints[0].changeStats.filesChanged == 0)

        // Round-trip rewrite should persist as current version with notes key.
        try store.save(migrated)
        let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(raw.contains("\"version\" : \(WorkspaceCheckpointStoreDocument.currentVersion)")
            || raw.contains("\"version\": \(WorkspaceCheckpointStoreDocument.currentVersion)"))
        #expect(raw.contains("notes"))
    }

    @Test func confirmationTokenBoundToImmutablePreviewInputs() async throws {
        let repo = try await makeRepo()
        defer { try? FileManager.default.removeItem(at: repo.root) }
        let (store, storeRoot) = try makeStore()
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let service = makeService(store: store, git: repo.git)
        let sessionID = UUID()
        let runID = UUID()
        _ = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .beforeRun
        )
        try "x\n".write(to: repo.root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        let after = try await service.capture(
            worktreeURL: repo.root,
            sessionID: sessionID,
            runID: runID,
            boundary: .afterRun
        )
        let preview1 = try await service.previewRevert(afterCheckpointID: after.id)
        let preview2 = try await service.previewRevert(afterCheckpointID: after.id)
        #expect(preview1.confirmationToken == preview2.confirmationToken)
        #expect(preview1.inputFingerprint == preview2.inputFingerprint)
        #expect(preview1.confirmationToken.hasPrefix("lattice-revert-v1:"))
    }
}
