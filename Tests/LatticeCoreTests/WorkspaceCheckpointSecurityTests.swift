import Foundation
import Testing
@testable import LatticeCore

@Suite("Workspace checkpoint Git safety")
struct WorkspaceCheckpointSecurityTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-checkpoint-security-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fakeGit(at url: URL, trace: URL? = nil, output: String = "ok\n") throws {
        var script = "#!/bin/sh\n"
        if let trace {
            script += "env > '" + trace.path + "'\n"
            script += "printf '%s\\n' \"$@\" > '" + trace.deletingPathExtension().appendingPathExtension("args").path + "'\n"
        }
        script += "printf '" + output.replacingOccurrences(of: "'", with: "'\\''") + "'\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func gitExecutable() throws -> URL {
        try #require(ExecutableDiscovery.locate("git"))
    }

    @discardableResult
    private func runGit(_ git: URL, at directory: URL, _ arguments: [String]) async throws -> String {
        let result = await BoundedSubprocess.run(
            BoundedSubprocessRequest(
                executableURL: git,
                arguments: arguments,
                currentDirectoryURL: directory,
                environment: ProcessInfo.processInfo.environment,
                deadline: 20
            )
        )
        guard result.isSuccess else {
            throw WorkspaceCheckpointError.subprocessFailed(
                operation: arguments.joined(separator: " "),
                detail: String(decoding: result.stderr + result.stdout, as: UTF8.self)
            )
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private func initializeRepository(root: URL) async throws -> (repo: URL, git: URL) {
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let git = try gitExecutable()
        try await runGit(git, at: repo, ["init"])
        try await runGit(git, at: repo, ["config", "user.name", "Lattice Test"])
        try await runGit(git, at: repo, ["config", "user.email", "test@lattice.local"])
        try Data("before\n".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try await runGit(git, at: repo, ["add", "tracked.txt"])
        try await runGit(git, at: repo, ["commit", "-m", "initial"])
        return (repo, git)
    }

    @Test("Git subprocesses use a minimal hostile-config-free environment")
    func gitEnvironmentIsAllowlisted() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let trace = directory.appendingPathComponent("env.txt")
        let git = directory.appendingPathComponent("git")
        try fakeGit(at: git, trace: trace)
        let service = WorkspaceCheckpointService(
            store: WorkspaceCheckpointStore(fileURL: directory.appendingPathComponent("store.json")),
            gitExecutableURL: git
        )
        let context = WorkspaceCheckpointService.WorktreeContext(
            toplevelPath: directory.path,
            gitCommonDir: directory.path,
            worktreeIdentity: "test"
        )
        _ = try await service.runGitCommand(
            git: git,
            context: context,
            arguments: ["status"],
            operation: "status",
            environmentOverrides: [
                "GIT_EXTERNAL_DIFF": "evil",
                "GIT_CONFIG_GLOBAL": "/tmp/evil",
                "GIT_INDEX_FILE": directory.appendingPathComponent("index").path
            ]
        )
        let body = try String(contentsOf: trace, encoding: .utf8)
        #expect(!body.contains("GIT_EXTERNAL_DIFF=evil"))
        #expect(!body.contains("GIT_CONFIG_GLOBAL=/tmp/evil"))
        #expect(body.contains("GIT_CONFIG_NOSYSTEM=1"))
        #expect(body.contains("GIT_TERMINAL_PROMPT=0"))
    }

    @Test("Untracked revert deletion is descriptor-relative and regular-file-only")
    func regularDeletionRefusesSymlinkAndDeletesExactFile() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = directory.appendingPathComponent("git")
        try fakeGit(at: git, output: "abc\n")
        var service = WorkspaceCheckpointService(
            store: WorkspaceCheckpointStore(fileURL: directory.appendingPathComponent("store.json")),
            gitExecutableURL: git
        )
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("agent.txt")
        try Data("content".utf8).write(to: file)
        let context = WorkspaceCheckpointService.WorktreeContext(
            toplevelPath: directory.path,
            gitCommonDir: directory.path,
            worktreeIdentity: "test"
        )
        let prepared = try #require(service.prepareRegularRepoFile(
            context: context,
            relativePath: "nested/agent.txt",
            expectedFingerprint: "sha256:" + WorkspaceCheckpointService.sha256Hex(Data("content".utf8))
        ))
        try service.unlinkPreparedRegularRepoFile(
            context: context,
            prepared: prepared,
            ordinal: 1
        )
        #expect(!FileManager.default.fileExists(atPath: file.path))

        let outside = directory.deletingLastPathComponent().appendingPathComponent("outside-" + UUID().uuidString)
        try Data("outside".utf8).write(to: outside)
        let link = nested.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        do {
            _ = try service.prepareRegularRepoFile(
                context: context,
                relativePath: "nested/link",
                expectedFingerprint: "sha256:" + WorkspaceCheckpointService.sha256Hex(Data("outside".utf8))
            )
            Issue.record("Symlink deletion must fail closed")
        } catch let error as WorkspaceCheckpointError {
            guard case .revertDivergence = error else { Issue.record("Unexpected error: \(error)") ; return }
        }
        #expect(FileManager.default.fileExists(atPath: link.path))
        try? FileManager.default.removeItem(at: outside)
    }

    @Test("Leaf replacement between descriptor hash and unlink is refused")
    func unlinkRaceFailsClosed() throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("agent.txt")
        let outside = directory.appendingPathComponent("outside.txt")
        try Data("agent".utf8).write(to: file)
        try Data("outside".utf8).write(to: outside)
        var service = WorkspaceCheckpointService(
            store: WorkspaceCheckpointStore(fileURL: directory.appendingPathComponent("store.json"))
        )
        let context = WorkspaceCheckpointService.WorktreeContext(
            toplevelPath: directory.path,
            gitCommonDir: directory.path,
            worktreeIdentity: "test"
        )
        let prepared = try #require(service.prepareRegularRepoFile(
            context: context,
            relativePath: "agent.txt",
            expectedFingerprint: "sha256:" + WorkspaceCheckpointService.sha256Hex(Data("agent".utf8))
        ))
        service.revertTestBeforeUnlink = { _ in
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        }
        do {
            try service.unlinkPreparedRegularRepoFile(context: context, prepared: prepared, ordinal: 1)
            Issue.record("Path replacement must fail closed")
        } catch let error as WorkspaceCheckpointError {
            guard case .revertDivergence = error else { Issue.record("Unexpected error: \(error)"); return }
        }
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    }

    @Test("Second unlink failure compensates tracked patch and prior deletes")
    func secondUnlinkFailureIsTransactional() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = try await initializeRepository(root: directory)
        let store = WorkspaceCheckpointStore(fileURL: directory.appendingPathComponent("checkpoints.json"))
        var service = WorkspaceCheckpointService(store: store, gitExecutableURL: setup.git)
        let sessionID = UUID()
        let runID = UUID()
        _ = try await service.capture(
            worktreeURL: setup.repo,
            sessionID: sessionID,
            runID: runID,
            boundary: .beforeRun
        )
        try Data("after\n".utf8).write(to: setup.repo.appendingPathComponent("tracked.txt"))
        let first = setup.repo.appendingPathComponent("a.txt")
        let second = setup.repo.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: first)
        try Data("b".utf8).write(to: second)
        let outside = directory.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let link = setup.repo.appendingPathComponent("run-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let after = try await service.capture(
            worktreeURL: setup.repo,
            sessionID: sessionID,
            runID: runID,
            boundary: .afterRun
        )
        let preview = try await service.previewRevert(afterCheckpointID: after.id)
        #expect(!preview.operations.contains { $0.path == "run-link" })
        #expect(preview.warnings.contains { $0.contains("non-revertible") && $0.contains("run-link") })
        service.revertTestUnlinkFailureOrdinal = 2
        do {
            _ = try await service.confirmRevert(
                afterCheckpointID: after.id,
                confirmationToken: preview.confirmationToken
            )
            Issue.record("Injected second unlink must fail")
        } catch let error as WorkspaceCheckpointError {
            guard case .revertApplyFailed(let detail) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(detail.contains("all mutations were restored"))
        }
        #expect(try Data(contentsOf: setup.repo.appendingPathComponent("tracked.txt")) == Data("after\n".utf8))
        #expect(try Data(contentsOf: first) == Data("a".utf8))
        #expect(try Data(contentsOf: second) == Data("b".utf8))
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test("Duplicate untracked metadata fails validation instead of trapping")
    func duplicateUntrackedMetadataFailsClosed() throws {
        let ownership = WorkspaceCheckpointOwnership(
            worktreePath: "/tmp/repo",
            worktreeIdentity: "identity",
            sessionID: UUID(),
            runID: UUID()
        )
        let metadata = WorkspaceUntrackedFileMetadata(
            path: "duplicate.txt",
            byteSize: 1,
            contentOID: "sha256:" + String(repeating: "a", count: 64)
        )
        let checkpoint = WorkspaceCheckpoint(
            ownership: ownership,
            boundary: .beforeRun,
            status: .captured,
            untrackedFiles: [metadata, metadata]
        )
        do {
            _ = try WorkspaceCheckpointService.validatedUntrackedMap(checkpoint, label: "test")
            Issue.record("Duplicate untracked metadata must fail")
        } catch let error as WorkspaceCheckpointError {
            guard case .checkpointPairInvalid = error else { Issue.record("Unexpected error: \(error)"); return }
        }
    }

    @Test("Oversized untracked content fails capture before hashing")
    func oversizedUntrackedCaptureFailsWithTrail() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = try await initializeRepository(root: directory)
        let store = WorkspaceCheckpointStore(fileURL: directory.appendingPathComponent("checkpoints.json"))
        let service = WorkspaceCheckpointService(store: store, gitExecutableURL: setup.git)
        let huge = setup.repo.appendingPathComponent("huge.bin")
        try Data(repeating: 0x41, count: WorkspaceCheckpointService.maximumUntrackedFileBytes + 1).write(to: huge)
        do {
            _ = try await service.capture(
                worktreeURL: setup.repo,
                sessionID: UUID(),
                runID: UUID(),
                boundary: .beforeRun
            )
            Issue.record("Oversized untracked content must fail capture")
        } catch let error as WorkspaceCheckpointError {
            guard case .captureFailed(let detail) = error else { Issue.record("Unexpected error: \(error)"); return }
            #expect(detail.contains("capture limit"))
        }
        let failures = try store.load().checkpoints.filter { $0.status == .failed }
        #expect(failures.count == 1)
        #expect(failures[0].failureSummary?.contains("capture limit") == true)
        #expect(failures[0].refName == nil)
    }

    @Test("Checkpoint snapshot bypasses repository clean and process filters")
    func captureDoesNotExecuteRepositoryFilters() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = try await initializeRepository(root: directory)
        let attributes = setup.repo.appendingPathComponent(".gitattributes")
        try Data("tracked.txt filter=hostile\n".utf8).write(to: attributes)
        try await runGit(setup.git, at: setup.repo, ["add", ".gitattributes"])
        try await runGit(setup.git, at: setup.repo, ["commit", "-m", "attributes"])
        let marker = directory.appendingPathComponent("filter-ran")
        let filter = directory.appendingPathComponent("filter.sh")
        let body = "#!/bin/sh\nprintf ran > '" + marker.path + "'\n/bin/cat\n"
        try body.write(to: filter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: filter.path)
        try await runGit(setup.git, at: setup.repo, ["config", "filter.hostile.clean", filter.path])
        try await runGit(setup.git, at: setup.repo, ["config", "filter.hostile.process", filter.path])
        try Data("changed\n".utf8).write(to: setup.repo.appendingPathComponent("tracked.txt"))
        let service = WorkspaceCheckpointService(
            store: WorkspaceCheckpointStore(fileURL: directory.appendingPathComponent("checkpoints.json")),
            gitExecutableURL: setup.git
        )
        let checkpoint = try await service.capture(
            worktreeURL: setup.repo,
            sessionID: UUID(),
            runID: UUID(),
            boundary: .beforeRun
        )
        #expect(checkpoint.status == .captured)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let content = try await runGit(
            setup.git,
            at: setup.repo,
            ["show", try #require(checkpoint.treeOID) + ":tracked.txt"]
        )
        #expect(content == "changed\n")
    }

    @Test("Failed ref cleanup is durable and reconciled by the next capture")
    func orphanRefCleanupReconciles() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = try await initializeRepository(root: directory)
        let store = WorkspaceCheckpointStore(fileURL: directory.appendingPathComponent("checkpoints.json"))
        var failing = WorkspaceCheckpointService(store: store, gitExecutableURL: setup.git)
        failing.captureTestFailAfterRef = true
        failing.captureTestFailRefCleanup = true
        do {
            _ = try await failing.capture(
                worktreeURL: setup.repo,
                sessionID: UUID(),
                runID: UUID(),
                boundary: .beforeRun
            )
            Issue.record("Injected post-ref failure must fail capture")
        } catch let error as WorkspaceCheckpointError {
            guard case .captureFailed = error else { Issue.record("Unexpected error: \(error)"); return }
        }
        let failed = try #require(store.load().checkpoints.first { $0.status == .failed })
        let orphanRef = try #require(failed.refName)
        #expect(failed.failureSummary?.contains("cleanup failed") == true)
        _ = try await runGit(setup.git, at: setup.repo, ["rev-parse", "--verify", orphanRef])

        let recovering = WorkspaceCheckpointService(store: store, gitExecutableURL: setup.git)
        _ = try await recovering.capture(
            worktreeURL: setup.repo,
            sessionID: UUID(),
            runID: UUID(),
            boundary: .beforeRun
        )
        let reconciled = try #require(store.checkpoint(id: failed.id))
        #expect(reconciled.refName == nil)
        #expect(reconciled.failureSummary?.contains("reconciled") == true)
        let lookup = await BoundedSubprocess.run(
            BoundedSubprocessRequest(
                executableURL: setup.git,
                arguments: ["show-ref", "--verify", "--quiet", orphanRef],
                currentDirectoryURL: setup.repo,
                deadline: 10
            )
        )
        #expect(!lookup.isSuccess)
    }

    @Test("Early capture failure surfaces failure-trail persistence errors")
    func earlyFailureStoreErrorIsVisible() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidStoreTarget = directory.appendingPathComponent("store-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidStoreTarget, withIntermediateDirectories: true)
        let service = WorkspaceCheckpointService(
            store: WorkspaceCheckpointStore(fileURL: invalidStoreTarget),
            gitExecutableURL: directory.appendingPathComponent("missing-git")
        )
        do {
            _ = try await service.capture(
                worktreeURL: directory,
                sessionID: UUID(),
                runID: UUID(),
                boundary: .beforeRun
            )
            Issue.record("Early failure plus store failure must surface")
        } catch let error as WorkspaceCheckpointError {
            guard case .storeWriteFailed(let detail) = error else { Issue.record("Unexpected error: \(error)"); return }
            #expect(detail.contains("failure trail"))
            #expect(detail.contains("Primary failure"))
        }
    }

    @Test("Capture discards and cleans a ref when worktree changes after snapshot")
    func captureRevalidatesAfterRefCreation() async throws {
        let directory = try root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = try await initializeRepository(root: directory)
        let tracked = setup.repo.appendingPathComponent("tracked.txt")
        try Data("snapshot\n".utf8).write(to: tracked)
        let store = WorkspaceCheckpointStore(fileURL: directory.appendingPathComponent("checkpoints.json"))
        var service = WorkspaceCheckpointService(store: store, gitExecutableURL: setup.git)
        service.captureTestAfterRef = {
            try? Data("raced\n".utf8).write(to: tracked)
        }
        do {
            _ = try await service.capture(
                worktreeURL: setup.repo,
                sessionID: UUID(),
                runID: UUID(),
                boundary: .beforeRun
            )
            Issue.record("Raced snapshot must be discarded")
        } catch let error as WorkspaceCheckpointError {
            guard case .captureFailed(let detail) = error else { Issue.record("Unexpected error: \(error)"); return }
            #expect(detail.contains("changed during checkpoint capture"))
        }
        let failed = try #require(store.load().checkpoints.first { $0.status == .failed })
        #expect(failed.refName == nil)
        let refs = try await runGit(
            setup.git,
            at: setup.repo,
            ["for-each-ref", "--format=%(refname)", "refs/lattice/checkpoints/"]
        )
        #expect(refs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
