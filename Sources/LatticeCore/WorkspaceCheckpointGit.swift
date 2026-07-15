import CryptoKit
import Foundation

public extension WorkspaceCheckpointService {
    // MARK: Internals — worktree / git

    struct WorktreeContext: Sendable {
        var toplevelPath: String
        var gitCommonDir: String
        var worktreeIdentity: String
    }

    struct SnapshotWrite: Sendable {
        var treeOID: String
        var commitOID: String
        var refName: String
    }

    func resolveGit() throws -> URL {
        if let gitExecutableURL {
            return gitExecutableURL
        }
        if let discovered = ExecutableDiscovery.locate("git") {
            return discovered
        }
        throw WorkspaceCheckpointError.gitExecutableUnavailable
    }

    func resolveWorktreeContext(git: URL, worktreeURL: URL) async throws -> WorktreeContext {
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

    func readHeadCommit(git: URL, context: WorktreeContext) async throws -> String? {
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

    func hasTrackedDirtiness(git: URL, context: WorktreeContext) async throws -> Bool {
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

    func hasIndexDirtiness(git: URL, context: WorktreeContext) async throws -> Bool {
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

    func collectUntrackedMetadata(
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

    func hashObjectNoWrite(
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

    func untrackedFingerprint(
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

    func writeTrackedSnapshot(
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

    func treeForCommit(git: URL, context: WorktreeContext, commit: String) async throws -> String {
        try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["rev-parse", "\(commit)^{tree}"],
            operation: "rev-parse tree"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func changeStats(
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

    // MARK: Subprocess helpers

    func runGitCommand(
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

    static func pathExistsWithoutFollowingSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    func runGitString(
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

    func runGitData(
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

    func string(from data: Data) -> String {
        String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
    }

    func throwSubprocessFailure(operation: String, result: BoundedSubprocessResult) throws {
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
