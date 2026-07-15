import Darwin
import Foundation

// MARK: - Models

public enum WorkspaceFileNodeKind: String, Sendable, Equatable, Codable {
    case directory
    case file
    case symbolicLink
    case other
}

public struct WorkspaceFileNode: Sendable, Equatable, Identifiable, Hashable {
    public var id: String { relativePath }
    public var name: String
    /// Repo-relative POSIX path using `/` separators. Root entries are single path components.
    public var relativePath: String
    public var kind: WorkspaceFileNodeKind
    public var byteSize: Int64?
    public var isSecretPath: Bool
    public var isIgnored: Bool

    public init(
        name: String,
        relativePath: String,
        kind: WorkspaceFileNodeKind,
        byteSize: Int64? = nil,
        isSecretPath: Bool = false,
        isIgnored: Bool = false
    ) {
        self.name = name
        self.relativePath = relativePath
        self.kind = kind
        self.byteSize = byteSize
        self.isSecretPath = isSecretPath
        self.isIgnored = isIgnored
    }
}

public struct WorkspaceFileListingRequest: Sendable, Equatable {
    public var rootPath: String
    public var relativeDirectory: String
    public var maximumEntries: Int
    public var includeIgnored: Bool

    public static let defaultMaximumEntries = 400

    public init(
        rootPath: String,
        relativeDirectory: String = "",
        maximumEntries: Int = Self.defaultMaximumEntries,
        includeIgnored: Bool = false
    ) {
        self.rootPath = rootPath
        self.relativeDirectory = relativeDirectory
        self.maximumEntries = max(1, maximumEntries)
        self.includeIgnored = includeIgnored
    }
}

public struct WorkspaceFileListingResult: Sendable, Equatable {
    public var nodes: [WorkspaceFileNode]
    public var truncated: Bool
    public var rootPath: String
    public var relativeDirectory: String

    public init(
        nodes: [WorkspaceFileNode],
        truncated: Bool,
        rootPath: String,
        relativeDirectory: String
    ) {
        self.nodes = nodes
        self.truncated = truncated
        self.rootPath = rootPath
        self.relativeDirectory = relativeDirectory
    }
}

public enum WorkspaceFileListingError: Error, Sendable, Equatable, LocalizedError {
    case emptyRoot
    case rootNotDirectory
    case pathEscapesRoot
    case pathRejected
    case cancelled
    case ioFailure(String)

    public var errorDescription: String? {
        switch self {
        case .emptyRoot: "No workspace is selected."
        case .rootNotDirectory: "Workspace path is not a directory."
        case .pathEscapesRoot: "Path escapes the workspace."
        case .pathRejected: "That path cannot be listed."
        case .cancelled: "Listing was cancelled."
        case .ioFailure(let message): message
        }
    }
}

public enum WorkspaceFilePreviewKind: String, Sendable, Equatable {
    case text
    case image
    case binary
    case secretBlocked
    case missing
    case tooLarge
}

public struct WorkspaceFilePreview: Sendable, Equatable {
    public var relativePath: String
    public var kind: WorkspaceFilePreviewKind
    public var text: String?
    /// Image/binary bytes loaded under no-follow containment (never via symlink escape).
    public var data: Data?
    public var byteSize: Int64
    public var message: String?

    public init(
        relativePath: String,
        kind: WorkspaceFilePreviewKind,
        text: String? = nil,
        data: Data? = nil,
        byteSize: Int64 = 0,
        message: String? = nil
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.text = text
        self.data = data
        self.byteSize = byteSize
        self.message = message
    }
}

// MARK: - Policy

/// Bounded, cancellable workspace directory listing with ignore + secret-path policy.
///
/// Never auto-opens secrets. Symlinks are classified but never followed for listing children
/// or preview content. Intermediate directory symlinks that escape the root are rejected.
public enum WorkspaceFileListingPolicy {
    public static let defaultIgnoreDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", ".build", "DerivedData",
        ".swiftpm", "Pods", "Carthage",
        ".venv", "venv", "__pycache__",
        ".idea", ".vscode", ".cursor",
        "dist", "coverage", ".next", ".turbo"
    ]

    /// Exact basenames that are always secret-blocked.
    public static let secretExactNames: Set<String> = [
        ".env", ".env.local", ".env.production", ".env.development", ".env.test",
        "credentials.json", "secrets.json", "service-account.json",
        "id_rsa", "id_ed25519", "id_ecdsa", "id_dsa",
        ".netrc", "auth.json", "token.json", "htpasswd", "shadow"
    ]

    /// Path segments (full component match) treated as secret-containing directories.
    public static let secretPathSegments: Set<String> = [
        "secrets", "credentials", "private_keys", "private-keys"
    ]

    public static let maximumPreviewBytes = 256_000
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic", "heif"
    ]
    public static let textExtensions: Set<String> = [
        "swift", "md", "txt", "json", "yml", "yaml", "toml", "xml", "html", "css", "js", "ts",
        "tsx", "jsx", "py", "rb", "go", "rs", "c", "h", "cpp", "hpp", "m", "mm", "sh", "zsh",
        "bash", "fish", "plist", "pbxproj", "xcconfig", "gitignore", "dockerignore", "makefile",
        "cmake", "gradle", "kts", "java", "kt", "sql", "graphql", "proto", "csv", "log", "conf",
        "ini", "cfg", "env.example", "r", "jl", "lua", "vim", "editorconfig", "lock"
    ]

    public static func isIgnoredName(_ name: String) -> Bool {
        if name == "." || name == ".." { return true }
        if name.hasPrefix(".") && defaultIgnoreDirectoryNames.contains(name) { return true }
        return defaultIgnoreDirectoryNames.contains(name)
    }

    /// Prefer exact basenames, well-known suffixes, and path segments — not broad substring matches
    /// like `contains("token")` that false-positive on `Tokenizer.swift`.
    public static func isSecretPath(relativePath: String, name: String) -> Bool {
        let lowerName = name.lowercased()
        if secretExactNames.contains(lowerName) { return true }
        if lowerName.hasPrefix(".env") { return true }
        if lowerName.hasSuffix(".pem") || lowerName.hasSuffix(".p12") || lowerName.hasSuffix(".pfx") {
            return true
        }
        // Private key material: `*.key` but not `publickey` / `AppleDevelopment.p8` style product keys
        // remain open only when clearly not PEM-like secret names; keep `.key` blocked.
        if lowerName.hasSuffix(".key") && !lowerName.hasSuffix(".publickey") { return true }
        if lowerName == "id_rsa" || lowerName == "id_ed25519" || lowerName == "id_ecdsa" || lowerName == "id_dsa" {
            return true
        }
        if lowerName.hasPrefix("id_rsa") || lowerName.hasPrefix("id_ed25519") {
            return true
        }

        let segments = relativePath
            .split(separator: "/")
            .map { $0.lowercased() }
        for segment in segments {
            if secretPathSegments.contains(segment) { return true }
            if secretExactNames.contains(segment) { return true }
            if segment.hasPrefix(".env") { return true }
        }
        return false
    }

    public static func previewKind(forRelativePath path: String, isSecret: Bool) -> WorkspaceFilePreviewKind {
        if isSecret { return .secretBlocked }
        let ext = ((path as NSString).pathExtension).lowercased()
        if imageExtensions.contains(ext) { return .image }
        if textExtensions.contains(ext) || ext.isEmpty { return .text }
        return .binary
    }

    public static func normalizeRelativePath(_ value: String) -> Result<String, WorkspaceFileListingError> {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success("") }
        if trimmed.hasPrefix("/") { return .failure(.pathEscapesRoot) }
        let parts = trimmed.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return .success("") }
        guard !parts.contains(".."), !parts.contains(".") else { return .failure(.pathEscapesRoot) }
        guard parts.allSatisfy({ !$0.isEmpty }) else { return .failure(.pathEscapesRoot) }
        return .success(parts.joined(separator: "/"))
    }

    /// Backward-compatible alias.
    public static func normalizeRelativeDirectory(_ value: String) -> Result<String, WorkspaceFileListingError> {
        normalizeRelativePath(value)
    }

    public static func joinRelative(directory: String, name: String) -> String {
        directory.isEmpty ? name : "\(directory)/\(name)"
    }

    /// Resolves `root` via realpath and verifies `relativePath` stays under it without following leaf symlinks.
    /// Intermediate path components must not be escaping symlinks.
    public static func resolveContainedPath(
        rootPath: String,
        relativePath: String
    ) -> Result<URL, WorkspaceFileListingError> {
        let rootTrimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootTrimmed.isEmpty else { return .failure(.emptyRoot) }

        guard let resolvedRoot = realPath(rootTrimmed) else {
            return .failure(.rootNotDirectory)
        }
        var rootStatus = stat()
        guard lstat(resolvedRoot, &rootStatus) == 0, (rootStatus.st_mode & S_IFMT) == S_IFDIR else {
            return .failure(.rootNotDirectory)
        }
        // Root itself must not be a symlink to an unexpected target after realpath (realpath already resolved).
        let rootURL = URL(fileURLWithPath: resolvedRoot, isDirectory: true)

        let relative: String
        switch normalizeRelativePath(relativePath) {
        case .success(let value): relative = value
        case .failure(let error): return .failure(error)
        }

        if relative.isEmpty {
            return .success(rootURL)
        }

        // Walk components with lstat; reject symlink components that escape (or any intermediate symlink).
        var current = resolvedRoot
        let parts = relative.split(separator: "/").map(String.init)
        for (index, part) in parts.enumerated() {
            let next = (current as NSString).appendingPathComponent(part)
            var status = stat()
            if lstat(next, &status) != 0 {
                // Missing path is ok for reveal validation of open targets that may not exist yet —
                // but listing/preview require existence. Callers handle missing.
                if errno == ENOENT {
                    // Ensure lexical containment even when missing.
                    if next == resolvedRoot || next.hasPrefix(resolvedRoot + "/") {
                        current = next
                        continue
                    }
                    return .failure(.pathEscapesRoot)
                }
                return .failure(.ioFailure(String(cString: strerror(errno))))
            }

            let isLink = (status.st_mode & S_IFMT) == S_IFLNK
            let isLast = index == parts.count - 1
            if isLink {
                // Never follow any symlink for containment walks. Intermediate links are rejected;
                // leaf links are classified by callers without reading through them.
                if !isLast {
                    return .failure(.pathEscapesRoot)
                }
                // Leaf symlink: still require the link path itself is under root (not resolved target).
                if !(next == resolvedRoot || next.hasPrefix(resolvedRoot + "/")) {
                    return .failure(.pathEscapesRoot)
                }
                return .success(URL(fileURLWithPath: next))
            }

            // Non-symlink: for directories, confirm realpath stays under root (defense in depth).
            if (status.st_mode & S_IFMT) == S_IFDIR {
                if let real = realPath(next) {
                    if !(real == resolvedRoot || real.hasPrefix(resolvedRoot + "/")) {
                        return .failure(.pathEscapesRoot)
                    }
                    current = real
                } else {
                    current = next
                }
            } else {
                if !(next == resolvedRoot || next.hasPrefix(resolvedRoot + "/")) {
                    return .failure(.pathEscapesRoot)
                }
                current = next
            }
        }

        if !(current == resolvedRoot || current.hasPrefix(resolvedRoot + "/")) {
            return .failure(.pathEscapesRoot)
        }
        return .success(URL(fileURLWithPath: current))
    }

    public static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Opens and reads a regular file with O_NOFOLLOW (never follows symlinks).
    public static func readFileDataWithoutFollowingSymlinks(
        at url: URL,
        maximumBytes: Int? = nil
    ) throws -> Data {
        let path = url.path
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw WorkspaceFileListingError.ioFailure(String(cString: strerror(errno)))
        }
        if (status.st_mode & S_IFMT) == S_IFLNK {
            throw WorkspaceFileListingError.pathRejected
        }
        if (status.st_mode & S_IFMT) != S_IFREG {
            throw WorkspaceFileListingError.pathRejected
        }

        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw WorkspaceFileListingError.ioFailure(String(cString: strerror(errno)))
        }
        defer { close(fd) }

        var result = Data()
        if let maximumBytes, maximumBytes >= 0 {
            result.reserveCapacity(min(maximumBytes, 64 * 1024))
        }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let maximumBytes, result.count >= maximumBytes {
                break
            }
            let toRead: Int
            if let maximumBytes {
                toRead = min(buffer.count, maximumBytes - result.count)
            } else {
                toRead = buffer.count
            }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, toRead)
            }
            if count == 0 { break }
            if count < 0 {
                throw WorkspaceFileListingError.ioFailure(String(cString: strerror(errno)))
            }
            result.append(buffer, count: count)
        }
        return result
    }
}

// MARK: - Lister

public struct WorkspaceFileLister: Sendable {
    public init() {}

    public func list(
        _ request: WorkspaceFileListingRequest,
        isCancelled: () -> Bool = { false }
    ) throws -> WorkspaceFileListingResult {
        let fileManager = FileManager.default
        let rootTrimmed = request.rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootTrimmed.isEmpty else { throw WorkspaceFileListingError.emptyRoot }

        let directoryURL: URL
        switch WorkspaceFileListingPolicy.resolveContainedPath(
            rootPath: rootTrimmed,
            relativePath: request.relativeDirectory
        ) {
        case .success(let url): directoryURL = url
        case .failure(let error): throw error
        }

        // Reject listing through a symlink directory (leaf of relative path).
        var dirStatus = stat()
        if lstat(directoryURL.path, &dirStatus) == 0, (dirStatus.st_mode & S_IFMT) == S_IFLNK {
            throw WorkspaceFileListingError.pathEscapesRoot
        }
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw WorkspaceFileListingError.rootNotDirectory
        }

        let relativeDirectory: String
        switch WorkspaceFileListingPolicy.normalizeRelativePath(request.relativeDirectory) {
        case .success(let value): relativeDirectory = value
        case .failure(let error): throw error
        }

        let resolvedRoot: String
        if let real = WorkspaceFileListingPolicy.realPath(rootTrimmed) {
            resolvedRoot = real
        } else {
            resolvedRoot = (rootTrimmed as NSString).standardizingPath
        }

        if isCancelled() { throw WorkspaceFileListingError.cancelled }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey
                ],
                options: [.skipsPackageDescendants]
            )
        } catch {
            throw WorkspaceFileListingError.ioFailure(error.localizedDescription)
        }

        var nodes: [WorkspaceFileNode] = []
        nodes.reserveCapacity(min(contents.count, request.maximumEntries))
        var truncated = false

        let sorted = contents.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        for url in sorted {
            if isCancelled() { throw WorkspaceFileListingError.cancelled }
            if nodes.count >= request.maximumEntries {
                truncated = true
                break
            }

            let name = url.lastPathComponent
            if name == "." || name == ".." { continue }

            let ignored = WorkspaceFileListingPolicy.isIgnoredName(name)
            if ignored && !request.includeIgnored { continue }

            let relativePath = WorkspaceFileListingPolicy.joinRelative(directory: relativeDirectory, name: name)

            // Classify via lstat (no follow).
            var status = stat()
            let hasStatus = lstat(url.path, &status) == 0
            let kind: WorkspaceFileNodeKind
            if hasStatus {
                let type = status.st_mode & S_IFMT
                if type == S_IFLNK {
                    kind = .symbolicLink
                } else if type == S_IFDIR {
                    kind = .directory
                } else if type == S_IFREG {
                    kind = .file
                } else {
                    kind = .other
                }
            } else {
                kind = .other
            }

            let secret = WorkspaceFileListingPolicy.isSecretPath(relativePath: relativePath, name: name)
            let size: Int64? = hasStatus && (status.st_mode & S_IFMT) == S_IFREG ? Int64(status.st_size) : nil
            nodes.append(
                WorkspaceFileNode(
                    name: name,
                    relativePath: relativePath,
                    kind: kind,
                    byteSize: size,
                    isSecretPath: secret,
                    isIgnored: ignored
                )
            )
        }

        nodes.sort { lhs, rhs in
            let ld = lhs.kind == .directory
            let rd = rhs.kind == .directory
            if ld != rd { return ld && !rd }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        return WorkspaceFileListingResult(
            nodes: nodes,
            truncated: truncated,
            rootPath: resolvedRoot,
            relativeDirectory: relativeDirectory
        )
    }

    public func preview(
        rootPath: String,
        relativePath: String,
        maximumBytes: Int = WorkspaceFileListingPolicy.maximumPreviewBytes,
        isCancelled: () -> Bool = { false }
    ) throws -> WorkspaceFilePreview {
        let rootTrimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rootTrimmed.isEmpty else { throw WorkspaceFileListingError.emptyRoot }

        let normalized: String
        switch WorkspaceFileListingPolicy.normalizeRelativePath(relativePath) {
        case .success(let value):
            normalized = value
            guard !normalized.isEmpty else {
                return WorkspaceFilePreview(
                    relativePath: relativePath,
                    kind: .binary,
                    message: "Directories cannot be previewed as text."
                )
            }
        case .failure(let error):
            throw error
        }

        let name = (normalized as NSString).lastPathComponent
        let isSecret = WorkspaceFileListingPolicy.isSecretPath(relativePath: normalized, name: name)
        if isSecret {
            return WorkspaceFilePreview(
                relativePath: normalized,
                kind: .secretBlocked,
                message: "Secret-looking paths are never auto-opened. Open outside Lattice only if you intend to."
            )
        }

        let fileURL: URL
        switch WorkspaceFileListingPolicy.resolveContainedPath(rootPath: rootTrimmed, relativePath: normalized) {
        case .success(let url): fileURL = url
        case .failure(let error): throw error
        }

        if isCancelled() { throw WorkspaceFileListingError.cancelled }

        var status = stat()
        guard lstat(fileURL.path, &status) == 0 else {
            if errno == ENOENT {
                return WorkspaceFilePreview(relativePath: normalized, kind: .missing, message: "File is missing.")
            }
            throw WorkspaceFileListingError.ioFailure(String(cString: strerror(errno)))
        }

        let type = status.st_mode & S_IFMT
        if type == S_IFLNK {
            return WorkspaceFilePreview(
                relativePath: normalized,
                kind: .binary,
                message: "Symlinks are not followed for preview."
            )
        }
        if type == S_IFDIR {
            return WorkspaceFilePreview(
                relativePath: normalized,
                kind: .binary,
                message: "Directories cannot be previewed as text."
            )
        }
        if type != S_IFREG {
            return WorkspaceFilePreview(
                relativePath: normalized,
                kind: .binary,
                message: "Unsupported file type."
            )
        }

        let size = Int64(status.st_size)
        let kind = WorkspaceFileListingPolicy.previewKind(forRelativePath: normalized, isSecret: false)

        if kind == .binary {
            return WorkspaceFilePreview(
                relativePath: normalized,
                kind: .binary,
                byteSize: size,
                message: "Binary file — open externally if needed."
            )
        }
        if size > Int64(maximumBytes) {
            return WorkspaceFilePreview(
                relativePath: normalized,
                kind: .tooLarge,
                byteSize: size,
                message: "File exceeds the \(maximumBytes)-byte preview limit."
            )
        }

        if isCancelled() { throw WorkspaceFileListingError.cancelled }

        let data: Data
        do {
            data = try WorkspaceFileListingPolicy.readFileDataWithoutFollowingSymlinks(
                at: fileURL,
                maximumBytes: maximumBytes + 1
            )
        } catch let error as WorkspaceFileListingError {
            throw error
        } catch {
            throw WorkspaceFileListingError.ioFailure(error.localizedDescription)
        }

        if data.count > maximumBytes {
            return WorkspaceFilePreview(
                relativePath: normalized,
                kind: .tooLarge,
                byteSize: size,
                message: "File exceeds the \(maximumBytes)-byte preview limit."
            )
        }

        if kind == .image {
            return WorkspaceFilePreview(
                relativePath: normalized,
                kind: .image,
                data: data,
                byteSize: size
            )
        }

        if data.contains(0) {
            return WorkspaceFilePreview(
                relativePath: normalized,
                kind: .binary,
                byteSize: size,
                message: "Binary content detected."
            )
        }
        let text = String(decoding: data, as: UTF8.self)
        return WorkspaceFilePreview(
            relativePath: normalized,
            kind: .text,
            text: text,
            byteSize: size
        )
    }

    /// Safe absolute path for reveal/open only after containment succeeds (may be a leaf symlink path, never resolved target).
    public func containedAbsolutePath(rootPath: String, relativePath: String) throws -> String {
        switch WorkspaceFileListingPolicy.resolveContainedPath(rootPath: rootPath, relativePath: relativePath) {
        case .success(let url): return url.path
        case .failure(let error): throw error
        }
    }
}
