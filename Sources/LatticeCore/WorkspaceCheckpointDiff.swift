import Foundation

public extension WorkspaceCheckpointService {
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

    func diffFilesWithHunks(
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

    static func untrackedChanges(
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

    struct NameStatusEntry {
        var path: String
        var previousPath: String?
        var status: WorkspaceCheckpointFileStatus
    }

    static func parseNameStatus(_ output: String) -> [NameStatusEntry] {
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

}
