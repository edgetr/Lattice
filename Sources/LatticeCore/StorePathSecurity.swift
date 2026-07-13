import Darwin
import Foundation

enum LatticeStorePathError: LocalizedError, Sendable {
    case invalidPath(URL)
    case symlink(URL)
    case outsideRoot(URL)
    case notDirectory(URL)
    case notRegularFile(URL)
    case fileSystem(URL, Int32)

    var errorDescription: String? {
        switch self {
        case .invalidPath(let url):
            return "Invalid Lattice store path: \(url.path)."
        case .symlink(let url):
            return "Lattice store path uses a symlink and was rejected: \(url.path)."
        case .outsideRoot(let url):
            return "Lattice store path escapes its root and was rejected: \(url.path)."
        case .notDirectory(let url):
            return "Lattice store path is not a directory: \(url.path)."
        case .notRegularFile(let url):
            return "Lattice store path is not a regular file: \(url.path)."
        case .fileSystem(let url, let code):
            let message = String(cString: strerror(code))
            return "Could not access Lattice store path \(url.path): \(message)."
        }
    }
}

enum LatticeStorePathSecurity {
    static func prepareDirectory(at url: URL) throws {
        _ = try canonicalDirectory(at: url)
    }

    static func canonicalDirectory(at url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw LatticeStorePathError.invalidPath(url)
        }

        if let status = try lstat(at: standardized) {
            try validateDirectoryStatus(status, at: standardized)
        }

        // Resolve existing parent links before creation. The store root itself
        // is checked above and may not be a symlink.
        let canonical = try canonicalURL(for: standardized)
        try ensureDirectory(at: canonical)
        return canonical
    }

    static func createChildDirectory(named name: String, under rootURL: URL) throws -> URL {
        let root = try canonicalDirectory(at: rootURL)
        let child = try containedChild(named: name, under: root)
        try ensureDirectory(at: child)
        return child
    }

    static func existingChildDirectory(named name: String, under rootURL: URL) throws -> URL? {
        let root = try canonicalDirectory(at: rootURL)
        let child = try containedChild(named: name, under: root)
        guard let status = try lstat(at: child) else { return nil }
        try validateDirectoryStatus(status, at: child)
        try ensureDirectory(at: child, createMissing: false)
        return child
    }

    static func existingEntry(named name: String, under rootURL: URL) throws -> URL? {
        let root = try canonicalDirectory(at: rootURL)
        let child = try containedChild(named: name, under: root)
        guard try lstat(at: child) != nil else { return nil }
        try validateContainedPath(child, under: root)
        return child
    }

    static func readData(at url: URL, under rootURL: URL) throws -> Data {
        let root = try canonicalDirectory(at: rootURL)
        let file = try containedPath(url, under: root)
        return try readDataWithoutFollowingSymlinks(at: file)
    }

    static func readDataWithoutFollowingSymlinks(at url: URL) throws -> Data {
        let fd = try openFileWithoutFollowingSymlinks(at: url)
        defer { close(fd) }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if count == 0 { return result }
            if count < 0 {
                throw fileSystemError(for: url, code: errno)
            }
            result.append(buffer, count: count)
        }
    }

    static func writeDataAtomically(_ data: Data, to url: URL, under rootURL: URL) throws {
        let root = try canonicalDirectory(at: rootURL)
        let file = try containedPath(url, under: root)
        let parent = file.deletingLastPathComponent()
        try ensureDirectory(at: parent, createMissing: false)

        let parentFD = try openDirectoryWithoutFollowingSymlinks(at: parent)
        defer { close(parentFD) }

        let targetName = file.lastPathComponent
        if let status = try lstat(at: file) {
            if isSymlink(status) { throw LatticeStorePathError.symlink(file) }
        }

        let temporaryName = ".lattice-write-\(UUID().uuidString)"
        let temporaryFD = openat(
            parentFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o644)
        )
        guard temporaryFD >= 0 else {
            throw fileSystemError(for: file, code: errno)
        }

        var published = false
        defer {
            close(temporaryFD)
            if !published {
                _ = unlinkat(parentFD, temporaryName, 0)
            }
        }

        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    temporaryFD,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw fileSystemError(for: file, code: errno)
                }
                offset += count
            }
        }

        if let status = try lstat(at: file), isSymlink(status) {
            throw LatticeStorePathError.symlink(file)
        }
        guard renameat(parentFD, temporaryName, parentFD, targetName) == 0 else {
            throw fileSystemError(for: file, code: errno)
        }
        published = true
    }

    static func removeItem(at url: URL, under rootURL: URL) throws {
        let root = try canonicalDirectory(at: rootURL)
        let item = try containedPath(url, under: root)
        guard let status = try lstat(at: item) else { return }
        if isSymlink(status) { throw LatticeStorePathError.symlink(item) }

        let parent = item.deletingLastPathComponent()
        let parentFD = try openDirectoryWithoutFollowingSymlinks(at: parent)
        defer { close(parentFD) }
        if isDirectory(status) {
            try removeDirectoryContentsWithoutFollowingSymlinks(at: item)
        }
        let flags: Int32 = isDirectory(status) ? AT_REMOVEDIR : 0
        guard unlinkat(parentFD, item.lastPathComponent, flags) == 0 else {
            throw fileSystemError(for: item, code: errno)
        }
    }

    static func isDirectoryWithoutFollowingSymlinks(at url: URL) -> Bool {
        guard let status = try? lstat(at: url) else { return false }
        return isDirectory(status) && !isSymlink(status)
    }

    static func isRegularFileWithoutFollowingSymlinks(at url: URL) -> Bool {
        guard let status = try? lstat(at: url) else { return false }
        return isRegularFile(status) && !isSymlink(status)
    }

    private static func containedChild(named name: String, under root: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw LatticeStorePathError.invalidPath(root.appendingPathComponent(name))
        }
        let child = root.appendingPathComponent(name, isDirectory: true)
        return try containedPath(child, under: root)
    }

    private static func containedPath(_ url: URL, under root: URL) throws -> URL {
        let candidate = url
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
            throw LatticeStorePathError.invalidPath(url)
        }
        guard isContained(candidate.path, in: root.path) else {
            throw LatticeStorePathError.outsideRoot(url)
        }
        try validateContainedPath(candidate, under: root)
        return candidate
    }

    private static func validateContainedPath(_ url: URL, under root: URL) throws {
        guard isContained(url.path, in: root.path) else {
            throw LatticeStorePathError.outsideRoot(url)
        }
        try validateNoSymlinkComponents(url)
    }

    private static func validateNoSymlinkComponents(_ url: URL) throws {
        let components = url.path.split(separator: "/")
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components {
            current.appendPathComponent(String(component), isDirectory: true)
            guard let status = try lstat(at: current) else { continue }
            if isSymlink(status) { throw LatticeStorePathError.symlink(current) }
        }
    }

    private static func ensureDirectory(at url: URL, createMissing: Bool = true) throws {
        let directory = url
        let components = directory.path.split(separator: "/")
        var directoryFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw fileSystemError(for: directory, code: errno)
        }
        defer { close(directoryFD) }

        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components {
            let name = String(component)
            current.appendPathComponent(name, isDirectory: true)
            var status = stat()
            if fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) != 0 {
                guard errno == ENOENT, createMissing else {
                    throw fileSystemError(for: current, code: errno)
                }
                guard mkdirat(directoryFD, name, mode_t(0o755)) == 0 || errno == EEXIST else {
                    throw fileSystemError(for: current, code: errno)
                }
                guard fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                    throw fileSystemError(for: current, code: errno)
                }
            }
            guard isDirectory(status), !isSymlink(status) else {
                if isSymlink(status) { throw LatticeStorePathError.symlink(current) }
                throw LatticeStorePathError.notDirectory(current)
            }

            let nextFD = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard nextFD >= 0 else {
                throw fileSystemError(for: current, code: errno)
            }
            close(directoryFD)
            directoryFD = nextFD
        }
    }

    private static func openDirectoryWithoutFollowingSymlinks(at url: URL) throws -> Int32 {
        let directory = url
        let components = directory.path.split(separator: "/")
        var directoryFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else {
            throw fileSystemError(for: directory, code: errno)
        }

        do {
            for component in components {
                let name = String(component)
                let nextFD = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard nextFD >= 0 else {
                    throw fileSystemError(for: directory, code: errno)
                }
                close(directoryFD)
                directoryFD = nextFD
            }
            return directoryFD
        } catch {
            close(directoryFD)
            throw error
        }
    }

    private static func openFileWithoutFollowingSymlinks(at url: URL) throws -> Int32 {
        let file = url
        let parent = file.deletingLastPathComponent()
        let parentFD = try openDirectoryWithoutFollowingSymlinks(at: parent)
        defer { close(parentFD) }
        let fd = openat(parentFD, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw fileSystemError(for: file, code: errno)
        }
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            let code = errno
            close(fd)
            throw fileSystemError(for: file, code: code)
        }
        guard isRegularFile(status) else {
            close(fd)
            throw LatticeStorePathError.notRegularFile(file)
        }
        return fd
    }

    private static func removeDirectoryContentsWithoutFollowingSymlinks(at url: URL) throws {
        let directoryFD = try openDirectoryWithoutFollowingSymlinks(at: url)
        defer { close(directoryFD) }
        let children = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )
        for child in children {
            guard let status = try lstat(at: child) else { continue }
            if isSymlink(status) { throw LatticeStorePathError.symlink(child) }
            if isDirectory(status) {
                try removeDirectoryContentsWithoutFollowingSymlinks(at: child)
            }
            let flags: Int32 = isDirectory(status) ? AT_REMOVEDIR : 0
            guard unlinkat(directoryFD, child.lastPathComponent, flags) == 0 else {
                throw fileSystemError(for: child, code: errno)
            }
        }
    }

    private static func lstat(at url: URL) throws -> stat? {
        var status = stat()
        guard Darwin.lstat(url.path, &status) != -1 else {
            if errno == ENOENT { return nil }
            throw fileSystemError(for: url, code: errno)
        }
        return status
    }

    private static func canonicalURL(for url: URL) throws -> URL {
        var probe = url.standardizedFileURL
        var missingComponents: [String] = []
        while true {
            if let status = try lstat(at: probe) {
                // Only an existing store root is rejected as a symlink.
                // Existing parent links are resolved into canonical storage.
                if isSymlink(status), probe == url.standardizedFileURL {
                    throw LatticeStorePathError.symlink(probe)
                }
                guard let pointer = realpath(probe.path, nil) else {
                    throw fileSystemError(for: probe, code: errno)
                }
                defer { free(pointer) }
                var canonical = URL(fileURLWithPath: String(cString: pointer), isDirectory: true)
                for component in missingComponents {
                    canonical.appendPathComponent(component, isDirectory: true)
                }
                return canonical
            }

            let component = probe.lastPathComponent
            guard !component.isEmpty else {
                throw LatticeStorePathError.invalidPath(url)
            }
            missingComponents.insert(component, at: 0)
            let parent = probe.deletingLastPathComponent().standardizedFileURL
            guard parent.path != probe.path else {
                throw LatticeStorePathError.invalidPath(url)
            }
            probe = parent
        }
    }

    private static func validateDirectoryStatus(_ status: stat, at url: URL) throws {
        if isSymlink(status) { throw LatticeStorePathError.symlink(url) }
        guard isDirectory(status) else { throw LatticeStorePathError.notDirectory(url) }
    }

    private static func isContained(_ candidate: String, in root: String) -> Bool {
        candidate == root || candidate.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func isSymlink(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFLNK
    }

    private static func isDirectory(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFDIR
    }

    private static func isRegularFile(_ status: stat) -> Bool {
        status.st_mode & S_IFMT == S_IFREG
    }

    private static func fileSystemError(for url: URL, code: Int32) -> LatticeStorePathError {
        .fileSystem(url, code)
    }
}
