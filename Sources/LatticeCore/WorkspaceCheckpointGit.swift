import CryptoKit
import Foundation
import Darwin

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
        var sourceIndexTreeOID: String
    }

    struct PreparedUntrackedDeletion: Sendable {
        var path: String
        var bytes: Data
        var permissions: mode_t
        var device: dev_t
        var inode: ino_t
        var fingerprint: String
    }

    struct RepoEntrySnapshot: Sendable {
        var bytes: Data
        var permissions: mode_t
        var device: dev_t
        var inode: ino_t
        var isSymbolicLink: Bool
        var modificationTime: Date?
    }

    static let maximumUntrackedFileBytes = 8 * 1_024 * 1_024
    static let maximumUntrackedAggregateBytes = 32 * 1_024 * 1_024
    static let maximumTrackedFileBytes = 64 * 1_024 * 1_024

    static func validateGitOID(_ raw: String, label: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 40 || value.count == 64,
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 97...102: return true
                  default: return false
                  }
              }) else {
            throw WorkspaceCheckpointError.checkpointPairInvalid("Invalid " + label + " Git object ID.")
        }
        return value
    }

    static func validateLatticeRefName(_ raw: String) throws -> String {
        let prefix = "refs/lattice/checkpoints/"
        guard raw.hasPrefix(prefix),
              !raw.contains(".."),
              !raw.contains("@{"),
              !raw.contains("\\"),
              raw.unicodeScalars.allSatisfy({ scalar in
                  scalar.value > 0x20 && scalar.value != 0x7f
              }) else {
            throw WorkspaceCheckpointError.captureFailed("Checkpoint ref name failed validation.")
        }
        return raw
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
        let result = await runGitResult(
            git: git,
            context: context,
            arguments: ["rev-parse", "-q", "--verify", "HEAD"]
        )
        if result.outcome == .exited {
            if result.exitStatus == 0 {
                let oid = string(from: result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
                return oid.isEmpty ? nil : try Self.validateGitOID(oid, label: "HEAD")
            }
            // `rev-parse -q --verify HEAD` returns 1 for an unborn HEAD.
            if result.exitStatus == 1 { return nil }
        }
        try throwSubprocessFailure(operation: "rev-parse HEAD", result: result)
        return nil
    }

    func hasTrackedDirtiness(git: URL, context: WorktreeContext) async throws -> Bool {
        let result = await runGitResult(
            git: git,
            context: context,
            arguments: ["diff-files", "--quiet", "--no-ext-diff", "--no-textconv"]
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
            arguments = ["diff-index", "--quiet", "--cached", "--no-ext-diff", "--no-textconv", head, "--"]
        } else {
            let emptyTree = try await emptyTreeOID(git: git, context: context)
            arguments = ["diff-index", "--quiet", "--cached", "--no-ext-diff", "--no-textconv", emptyTree, "--"]
        }
        let result = await runGitResult(git: git, context: context, arguments: arguments)
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
        var seen: Set<String> = []
        var aggregateBytes = 0
        for path in paths {
            let normalized = try WorkspaceCheckpointValidation.validateRepoRelativePath(path)
            guard seen.insert(normalized).inserted else {
                throw WorkspaceCheckpointError.captureFailed("Git returned duplicate untracked path " + normalized + ".")
            }
            let snapshot = try readRepoEntrySnapshot(
                context: context,
                relativePath: normalized,
                maximumBytes: Self.maximumUntrackedFileBytes
            )
            guard aggregateBytes <= Self.maximumUntrackedAggregateBytes - snapshot.bytes.count else {
                throw WorkspaceCheckpointError.captureFailed(
                    "Untracked metadata exceeds the " + String(Self.maximumUntrackedAggregateBytes) + "-byte aggregate capture limit."
                )
            }
            aggregateBytes += snapshot.bytes.count
            let oid = snapshot.isSymbolicLink
                ? "symlink-sha256:" + Self.sha256Hex(snapshot.bytes)
                : "sha256:" + Self.sha256Hex(snapshot.bytes)
            result.append(
                WorkspaceUntrackedFileMetadata(
                    path: normalized,
                    byteSize: Int64(snapshot.bytes.count),
                    contentOID: oid,
                    isSymbolicLink: snapshot.isSymbolicLink,
                    canRestoreContent: false,
                    modificationTime: snapshot.modificationTime
                )
            )
        }
        return result.sorted { $0.path < $1.path }
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func openRepoParent(
        context: WorktreeContext,
        relativePath: String
    ) throws -> (descriptor: Int32, leaf: String, normalized: String) {
        let normalized = try WorkspaceCheckpointValidation.validateRepoRelativePath(relativePath)
        let components = normalized.split(separator: "/").map(String.init)
        guard let leaf = components.last else {
            throw WorkspaceCheckpointError.invalidRepoRelativePath(relativePath)
        }
        var descriptor = open(context.toplevelPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw WorkspaceCheckpointError.revertApplyFailed(
                "Unable to open worktree for " + relativePath + " (errno " + String(errno) + ")."
            )
        }
        for component in components.dropLast() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else {
                close(descriptor)
                throw WorkspaceCheckpointError.revertDivergence(
                    "Parent path for " + relativePath + " changed or disappeared."
                )
            }
            close(descriptor)
            descriptor = next
        }
        return (descriptor, leaf, normalized)
    }

    func readRepoEntrySnapshot(
        context: WorktreeContext,
        relativePath: String,
        maximumBytes: Int
    ) throws -> RepoEntrySnapshot {
        let parent = try openRepoParent(context: context, relativePath: relativePath)
        defer { close(parent.descriptor) }
        var pathStat = Darwin.stat()
        guard fstatat(parent.descriptor, parent.leaf, &pathStat, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw WorkspaceCheckpointError.revertDivergence(
                "Path " + relativePath + " changed or disappeared during inspection."
            )
        }
        let type = pathStat.st_mode & S_IFMT
        let bytes: Data
        let isSymbolicLink: Bool
        if type == S_IFLNK {
            isSymbolicLink = true
            let linkLimit = min(maximumBytes, 16 * 1_024)
            var buffer = [UInt8](repeating: 0, count: linkLimit + 1)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                readlinkat(parent.descriptor, parent.leaf, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count >= 0, count <= linkLimit else {
                throw WorkspaceCheckpointError.captureFailed(
                    "Workspace symlink " + relativePath + " exceeds the bounded metadata limit."
                )
            }
            bytes = Data(buffer.prefix(Int(count)))
            var finalStat = Darwin.stat()
            guard fstatat(parent.descriptor, parent.leaf, &finalStat, AT_SYMLINK_NOFOLLOW) == 0,
                  Self.sameFileVersion(pathStat, finalStat) else {
                throw WorkspaceCheckpointError.revertDivergence(
                    "Workspace symlink " + relativePath + " changed while being read."
                )
            }
        } else if type == S_IFREG {
            isSymbolicLink = false
            guard pathStat.st_size >= 0, pathStat.st_size <= off_t(maximumBytes) else {
                throw WorkspaceCheckpointError.captureFailed(
                    "Workspace file " + relativePath + " exceeds the " + String(maximumBytes) + "-byte capture limit."
                )
            }
            let descriptor = openat(
                parent.descriptor,
                parent.leaf,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            guard descriptor >= 0 else {
                throw WorkspaceCheckpointError.revertDivergence(
                    "Workspace file " + relativePath + " could not be opened safely."
                )
            }
            defer { close(descriptor) }
            var openedStat = Darwin.stat()
            guard fstat(descriptor, &openedStat) == 0,
                  (openedStat.st_mode & S_IFMT) == S_IFREG,
                  openedStat.st_dev == pathStat.st_dev,
                  openedStat.st_ino == pathStat.st_ino else {
                throw WorkspaceCheckpointError.revertDivergence(
                    "Workspace file " + relativePath + " changed during inspection."
                )
            }
            bytes = try readBoundedFileDescriptor(
                descriptor,
                maximumBytes: maximumBytes,
                path: relativePath
            )
            var finalStat = Darwin.stat()
            guard fstat(descriptor, &finalStat) == 0,
                  Self.sameFileVersion(openedStat, finalStat),
                  finalStat.st_size == off_t(bytes.count) else {
                throw WorkspaceCheckpointError.revertDivergence(
                    "Workspace file " + relativePath + " changed while being read."
                )
            }
        } else {
            throw WorkspaceCheckpointError.captureFailed(
                "Workspace path " + relativePath + " is not a regular file or symlink."
            )
        }
        let seconds = TimeInterval(pathStat.st_mtimespec.tv_sec)
        let nanoseconds = TimeInterval(pathStat.st_mtimespec.tv_nsec) / 1_000_000_000
        return RepoEntrySnapshot(
            bytes: bytes,
            permissions: pathStat.st_mode & 0o777,
            device: pathStat.st_dev,
            inode: pathStat.st_ino,
            isSymbolicLink: isSymbolicLink,
            modificationTime: Date(timeIntervalSince1970: seconds + nanoseconds)
        )
    }

    func readBoundedFileDescriptor(
        _ descriptor: Int32,
        maximumBytes: Int,
        path: String
    ) throws -> Data {
        var data = Data()
        data.reserveCapacity(min(maximumBytes, 64 * 1_024))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                throw WorkspaceCheckpointError.revertApplyFailed(
                    "Could not read " + path + " safely (errno " + String(errno) + ")."
                )
            }
            guard data.count <= maximumBytes - Int(count) else {
                throw WorkspaceCheckpointError.captureFailed(
                    "Untracked file " + path + " exceeds the " + String(maximumBytes) + "-byte capture limit."
                )
            }
            data.append(contentsOf: buffer.prefix(Int(count)))
        }
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
        let indexTreeOID = try await currentIndexTreeOID(git: git, context: context)
        let treeOID = try await writeTrackedWorktreeTree(
            git: git,
            context: context,
            temporaryIndexURL: indexURL,
            sourceIndexTreeOID: indexTreeOID
        )

        var commitArguments = ["commit-tree", treeOID]
        if let headOID {
            commitArguments += ["-p", try Self.validateGitOID(headOID, label: "HEAD")]
        }
        commitArguments += [
            "-m",
            "lattice-checkpoint \(boundary.rawValue) \(checkpointID.uuidString.lowercased())"
        ]
        let commitOID = try Self.validateGitOID(try await runGitString(
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
        ).trimmingCharacters(in: .whitespacesAndNewlines), label: "snapshot commit")

        let refName = try Self.validateLatticeRefName(Self.latticeRefName(
            ownership: ownership,
            boundary: boundary,
            checkpointID: checkpointID
        ))
        _ = try await runGitCommand(
            git: git,
            context: context,
            // Empty expected-old value is compare-and-swap for "ref must not exist".
            arguments: ["update-ref", refName, commitOID, ""],
            operation: "update-ref"
        )

        return SnapshotWrite(
            treeOID: treeOID,
            commitOID: commitOID,
            refName: refName,
            sourceIndexTreeOID: indexTreeOID
        )
    }

    func currentIndexTreeOID(git: URL, context: WorktreeContext) async throws -> String {
        try Self.validateGitOID(try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["write-tree"],
            operation: "write-tree current index"
        ).trimmingCharacters(in: .whitespacesAndNewlines), label: "index tree")
    }

    func emptyTreeOID(git: URL, context: WorktreeContext) async throws -> String {
        let result = try await runGitCommand(
            git: git,
            context: context,
            arguments: ["hash-object", "-t", "tree", "--stdin"],
            operation: "hash empty tree",
            stdinData: Data()
        )
        return try Self.validateGitOID(string(from: result.stdout), label: "empty tree")
    }

    func writeTrackedWorktreeTree(
        git: URL,
        context: WorktreeContext,
        temporaryIndexURL: URL,
        sourceIndexTreeOID: String
    ) async throws -> String {
        let validatedIndex = try Self.validateGitOID(sourceIndexTreeOID, label: "index tree")
        _ = try await runGitCommand(
            git: git,
            context: context,
            arguments: ["read-tree", validatedIndex],
            operation: "read-tree current index",
            environmentOverrides: ["GIT_INDEX_FILE": temporaryIndexURL.path]
        )
        let listing = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["diff-files", "--name-only", "-z", "--no-ext-diff", "--no-textconv", "--"],
            operation: "diff-files tracked paths"
        )
        let paths = listing.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var seen: Set<String> = []
        for rawPath in paths {
            let path = try WorkspaceCheckpointValidation.validateRepoRelativePath(rawPath)
            guard seen.insert(path).inserted else {
                throw WorkspaceCheckpointError.captureFailed("Git returned duplicate tracked path " + path + ".")
            }
            var fileStat = Darwin.stat()
            let absolute = URL(fileURLWithPath: context.toplevelPath, isDirectory: true)
                .appendingPathComponent(path).path
            if lstat(absolute, &fileStat) != 0 {
                guard errno == ENOENT else {
                    throw WorkspaceCheckpointError.captureFailed(
                        "Could not inspect tracked path " + path + " (errno " + String(errno) + ")."
                    )
                }
                _ = try await runGitCommand(
                    git: git,
                    context: context,
                    arguments: ["update-index", "--force-remove", "--", path],
                    operation: "update-index remove tracked path",
                    environmentOverrides: ["GIT_INDEX_FILE": temporaryIndexURL.path]
                )
                continue
            }
            let entry = try readRepoEntrySnapshot(
                context: context,
                relativePath: path,
                maximumBytes: Self.maximumTrackedFileBytes
            )
            let mode = entry.isSymbolicLink
                ? "120000"
                : ((entry.permissions & S_IXUSR) != 0 ? "100755" : "100644")
            guard entry.isSymbolicLink || (fileStat.st_mode & S_IFMT) == S_IFREG else {
                throw WorkspaceCheckpointError.captureFailed(
                    "Tracked path " + path + " is not a regular file or symlink."
                )
            }
            let result = try await runGitCommand(
                git: git,
                context: context,
                arguments: ["hash-object", "-w", "--no-filters", "--stdin"],
                operation: "hash-object tracked content without filters",
                stdinData: entry.bytes
            )
            let blobOID = try Self.validateGitOID(string(from: result.stdout), label: "tracked blob")
            _ = try await runGitCommand(
                git: git,
                context: context,
                arguments: ["update-index", "--add", "--cacheinfo", mode, blobOID, path],
                operation: "update-index tracked path",
                environmentOverrides: ["GIT_INDEX_FILE": temporaryIndexURL.path]
            )
        }
        return try Self.validateGitOID(try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["write-tree"],
            operation: "write-tree worktree",
            environmentOverrides: ["GIT_INDEX_FILE": temporaryIndexURL.path]
        ), label: "worktree tree")
    }

    func treeForCommit(git: URL, context: WorktreeContext, commit: String) async throws -> String {
        let validatedCommit = try Self.validateGitOID(commit, label: "commit")
        return try Self.validateGitOID(try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["rev-parse", "--verify", validatedCommit + "^{tree}"],
            operation: "rev-parse tree"
        ), label: "commit tree")
    }

    func changeStats(
        git: URL,
        context: WorktreeContext,
        fromTree: String?,
        toTree: String
    ) async throws -> WorkspaceCheckpointChangeStats {
        let rawBase: String
        if let fromTree {
            rawBase = fromTree
        } else {
            rawBase = try await emptyTreeOID(git: git, context: context)
        }
        let base = try Self.validateGitOID(rawBase, label: "base tree")
        let target = try Self.validateGitOID(toTree, label: "target tree")
        if base == target {
            return WorkspaceCheckpointChangeStats()
        }
        let output = try await runGitString(
            git: git,
            currentDirectory: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
            arguments: ["diff", "--no-ext-diff", "--no-textconv", "--numstat", base, target, "--"],
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
        let result = await runGitResult(
            git: git,
            context: context,
            arguments: arguments,
            environmentOverrides: environmentOverrides,
            stdinData: stdinData
        )
        if result.isSuccess { return result }
        try throwSubprocessFailure(operation: operation, result: result)
        return result
    }

    func runGitResult(
        git: URL,
        context: WorktreeContext,
        arguments: [String],
        environmentOverrides: [String: String] = [:],
        stdinData: Data? = nil
    ) async -> BoundedSubprocessResult {
        // Do not inherit Git's ambient configuration, helpers, hooks, diff
        // drivers, or credential environment. Only the executable search path
        // and explicitly scoped operation variables are allowed through.
        var environment: [String: String] = [:]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            environment["PATH"] = path
        }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_PAGER"] = "cat"
        environment["GIT_EDITOR"] = "true"
        environment["GIT_SEQUENCE_EDITOR"] = "true"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        let allowedOverrides: Set<String> = [
            "GIT_INDEX_FILE",
            "GIT_AUTHOR_NAME",
            "GIT_AUTHOR_EMAIL",
            "GIT_COMMITTER_NAME",
            "GIT_COMMITTER_EMAIL"
        ]
        for (key, value) in environmentOverrides where allowedOverrides.contains(key) {
            environment[key] = value
        }

        // Explicit flags defend against repository-local config and make the
        // safety contract auditable even if a caller changes the environment.
        let safeArguments = [
            "-c", "core.pager=cat",
            "-c", "interactive.diffFilter=",
            "-c", "diff.external=",
            "-c", "core.fsmonitor=",
            "-c", "core.hooksPath=/dev/null",
            "-c", "credential.helper=",
            "-c", "core.sshCommand=",
            "-c", "protocol.ext.allow=never",
            "-c", "submodule.recurse=false",
            "-c", "filter.lfs.clean=",
            "-c", "filter.lfs.process=",
            "-c", "filter.lfs.smudge="
        ] + arguments

        return await BoundedSubprocess.run(
            BoundedSubprocessRequest(
                executableURL: git,
                arguments: safeArguments,
                stdinData: stdinData,
                currentDirectoryURL: URL(fileURLWithPath: context.toplevelPath, isDirectory: true),
                environment: environment,
                deadline: deadline,
                maximumOutputBytes: maximumOutputBytes
            )
        )
    }

    func deleteCheckpointRef(
        git: URL,
        context: WorktreeContext,
        refName: String
    ) async throws {
        if captureTestFailRefCleanup {
            throw WorkspaceCheckpointError.captureFailed("Injected checkpoint ref cleanup failure.")
        }
        let validatedRef = try Self.validateLatticeRefName(refName)
        _ = try await runGitCommand(
            git: git,
            context: context,
            arguments: ["update-ref", "-d", validatedRef],
            operation: "update-ref cleanup"
        )
    }

    func prepareRegularRepoFile(
        context: WorktreeContext,
        relativePath: String,
        expectedFingerprint: String
    ) throws -> PreparedUntrackedDeletion? {
        let parent = try openRepoParent(context: context, relativePath: relativePath)
        defer { close(parent.descriptor) }
        var pathStat = Darwin.stat()
        guard fstatat(parent.descriptor, parent.leaf, &pathStat, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw WorkspaceCheckpointError.revertDivergence(
                "Untracked path " + relativePath + " could not be inspected."
            )
        }
        guard (pathStat.st_mode & S_IFMT) == S_IFREG else {
            throw WorkspaceCheckpointError.revertDivergence(
                "Untracked path " + relativePath + " is not a regular file."
            )
        }
        let descriptor = openat(
            parent.descriptor,
            parent.leaf,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw WorkspaceCheckpointError.revertDivergence(
                "Untracked path " + relativePath + " could not be opened safely."
            )
        }
        defer { close(descriptor) }
        var openedStat = Darwin.stat()
        guard fstat(descriptor, &openedStat) == 0,
              (openedStat.st_mode & S_IFMT) == S_IFREG,
              openedStat.st_dev == pathStat.st_dev,
              openedStat.st_ino == pathStat.st_ino else {
            throw WorkspaceCheckpointError.revertDivergence(
                "Untracked path " + relativePath + " changed during preflight."
            )
        }
        let bytes = try readBoundedFileDescriptor(
            descriptor,
            maximumBytes: Self.maximumUntrackedFileBytes,
            path: relativePath
        )
        guard Self.contentFingerprint(bytes, matches: expectedFingerprint) else {
            throw WorkspaceCheckpointError.revertDivergence(
                "Untracked path " + relativePath + " changed before delete."
            )
        }
        return PreparedUntrackedDeletion(
            path: parent.normalized,
            bytes: bytes,
            permissions: openedStat.st_mode & 0o777,
            device: openedStat.st_dev,
            inode: openedStat.st_ino,
            fingerprint: expectedFingerprint
        )
    }

    func unlinkPreparedRegularRepoFile(
        context: WorktreeContext,
        prepared: PreparedUntrackedDeletion,
        ordinal: Int
    ) throws {
        let parent = try openRepoParent(context: context, relativePath: prepared.path)
        defer { close(parent.descriptor) }
        let descriptor = openat(
            parent.descriptor,
            parent.leaf,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw WorkspaceCheckpointError.revertDivergence(
                "Untracked path " + prepared.path + " changed before delete."
            )
        }
        defer { close(descriptor) }
        var openedStat = Darwin.stat()
        guard fstat(descriptor, &openedStat) == 0,
              (openedStat.st_mode & S_IFMT) == S_IFREG,
              openedStat.st_dev == prepared.device,
              openedStat.st_ino == prepared.inode else {
            throw WorkspaceCheckpointError.revertDivergence(
                "Untracked path " + prepared.path + " changed before delete."
            )
        }
        let bytes = try readBoundedFileDescriptor(
            descriptor,
            maximumBytes: Self.maximumUntrackedFileBytes,
            path: prepared.path
        )
        guard bytes == prepared.bytes,
              Self.contentFingerprint(bytes, matches: prepared.fingerprint) else {
            throw WorkspaceCheckpointError.revertDivergence(
                "Untracked path " + prepared.path + " content changed before delete."
            )
        }
        revertTestBeforeUnlink?(prepared.path)
        var finalOpenedStat = Darwin.stat()
        guard fstat(descriptor, &finalOpenedStat) == 0,
              Self.sameFileVersion(openedStat, finalOpenedStat) else {
            throw WorkspaceCheckpointError.revertDivergence(
                "Untracked path " + prepared.path + " changed during delete."
            )
        }
        var pathStat = Darwin.stat()
        guard fstatat(parent.descriptor, parent.leaf, &pathStat, AT_SYMLINK_NOFOLLOW) == 0,
              (pathStat.st_mode & S_IFMT) == S_IFREG,
              pathStat.st_dev == openedStat.st_dev,
              pathStat.st_ino == openedStat.st_ino else {
            throw WorkspaceCheckpointError.revertDivergence(
                "Untracked path " + prepared.path + " was replaced during delete."
            )
        }
        if revertTestUnlinkFailureOrdinal == ordinal {
            throw WorkspaceCheckpointError.revertApplyFailed(
                "Injected unlink failure for " + prepared.path + "."
            )
        }
        guard unlinkat(parent.descriptor, parent.leaf, 0) == 0 else {
            throw WorkspaceCheckpointError.revertApplyFailed(
                "Failed to delete untracked file " + prepared.path + " (errno " + String(errno) + ")."
            )
        }
    }

    func restorePreparedRegularRepoFile(
        context: WorktreeContext,
        prepared: PreparedUntrackedDeletion
    ) throws {
        let parent = try openRepoParent(context: context, relativePath: prepared.path)
        defer { close(parent.descriptor) }
        let descriptor = openat(
            parent.descriptor,
            parent.leaf,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            prepared.permissions
        )
        guard descriptor >= 0 else {
            throw WorkspaceCheckpointError.revertApplyFailed(
                "Could not restore " + prepared.path + " (errno " + String(errno) + ")."
            )
        }
        var keepFile = false
        defer {
            close(descriptor)
            if !keepFile { _ = unlinkat(parent.descriptor, parent.leaf, 0) }
        }
        var offset = 0
        while offset < prepared.bytes.count {
            let written = prepared.bytes.withUnsafeBytes { rawBuffer -> Int in
                guard let base = rawBuffer.baseAddress else { return 0 }
                return write(descriptor, base.advanced(by: offset), prepared.bytes.count - offset)
            }
            if written <= 0 {
                if written < 0, errno == EINTR { continue }
                throw WorkspaceCheckpointError.revertApplyFailed(
                    "Could not restore " + prepared.path + " (errno " + String(errno) + ")."
                )
            }
            offset += written
        }
        guard fsync(descriptor) == 0 else {
            throw WorkspaceCheckpointError.revertApplyFailed(
                "Could not sync restored file " + prepared.path + "."
            )
        }
        guard fsync(parent.descriptor) == 0 else {
            throw WorkspaceCheckpointError.revertApplyFailed(
                "Could not sync the restored parent directory for " + prepared.path + "."
            )
        }
        keepFile = true
    }

    static func contentFingerprint(_ data: Data, matches expected: String) -> Bool {
        if expected.hasPrefix("sha256:") {
            return expected == "sha256:" + sha256Hex(data)
        }
        let normalized = expected.lowercased()
        guard normalized.count == 40 || normalized.count == 64,
              normalized.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (97...102).contains($0.value)
              }) else { return false }
        var blob = Data("blob \(data.count)\0".utf8)
        blob.append(data)
        if normalized.count == 40 {
            let digest = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
            return normalized == digest
        }
        return normalized == sha256Hex(blob)
    }

    static func sameFileVersion(_ lhs: Darwin.stat, _ rhs: Darwin.stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
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
