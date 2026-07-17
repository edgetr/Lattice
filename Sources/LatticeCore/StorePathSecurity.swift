import Darwin
import Foundation

public enum LatticeStorePathError: LocalizedError, Sendable {
    case invalidPath(URL)
    case symlink(URL)
    case outsideRoot(URL)
    case notDirectory(URL)
    case notRegularFile(URL)
    case oversized(URL, Int)
    case publishedButDurabilityUnconfirmed(URL, Int32)
    case fileSystem(URL, Int32)

    public var errorDescription: String? {
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
        case .oversized(let url, let count):
            return "Lattice store path exceeds the safe read limit (\(count) bytes): \(url.path)."
        case .publishedButDurabilityUnconfirmed(let url, let code):
            let message = String(cString: strerror(code))
            return "The store write was published, but durability could not be confirmed for \(url.path): \(message)."
        case .fileSystem(let url, let code):
            let message = String(cString: strerror(code))
            return "Could not access Lattice store path \(url.path): \(message)."
        }
    }
}

public enum LatticeStorePathSecurity {
    public static let maximumReadByteCount = 10 * 1024 * 1024
    public static func prepareDirectory(at url: URL) throws {
        _ = try canonicalDirectory(at: url)
    }

    public static func canonicalDirectory(at url: URL) throws -> URL {
        try rejectTraversalComponents(in: url)
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

    public static func createChildDirectory(named name: String, under rootURL: URL) throws -> URL {
        let root = try canonicalDirectory(at: rootURL)
        let child = try containedChild(named: name, under: root)
        try ensureDirectory(at: child)
        return child
    }

    public static func existingChildDirectory(named name: String, under rootURL: URL) throws -> URL? {
        let root = try canonicalDirectory(at: rootURL)
        let child = try containedChild(named: name, under: root)
        guard let status = try lstat(at: child) else { return nil }
        try validateDirectoryStatus(status, at: child)
        try ensureDirectory(at: child, createMissing: false)
        return child
    }

    public static func existingEntry(named name: String, under rootURL: URL) throws -> URL? {
        let root = try canonicalDirectory(at: rootURL)
        let child = try containedChild(named: name, under: root)
        guard try lstat(at: child) != nil else { return nil }
        try validateContainedPath(child, under: root)
        return child
    }

    public static func readData(at url: URL, under rootURL: URL) throws -> Data {
        let root = try canonicalDirectory(at: rootURL)
        let file = try containedPath(url, under: root, rootAlias: rootURL)
        return try readDataWithoutFollowingSymlinks(at: file)
    }

    public static func readDataWithoutFollowingSymlinks(at url: URL) throws -> Data {
        try readDataWithoutFollowingSymlinks(at: url, maximumByteCount: maximumReadByteCount)
    }

    public static func readDataWithoutFollowingSymlinks(at url: URL, maximumByteCount: Int) throws -> Data {
        let limit = max(0, maximumByteCount)
        let securedURL = normalizedSystemAliasURL(url)
        let fd = try openFileWithoutFollowingSymlinks(at: securedURL)
        defer { close(fd) }

        var before = stat()
        guard fstat(fd, &before) == 0 else {
            throw fileSystemError(for: securedURL, code: errno)
        }
        guard before.st_size <= off_t(limit) else {
            throw LatticeStorePathError.oversized(securedURL, limit)
        }

        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if result.count > limit {
                throw LatticeStorePathError.oversized(securedURL, limit)
            }
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if count == 0 {
                var after = stat()
                guard fstat(fd, &after) == 0 else { throw fileSystemError(for: securedURL, code: errno) }
                guard after.st_dev == before.st_dev, after.st_ino == before.st_ino, after.st_size == before.st_size else {
                    throw fileSystemError(for: securedURL, code: EAGAIN)
                }
                return result
            }
            if count < 0 {
                throw fileSystemError(for: securedURL, code: errno)
            }
            result.append(buffer, count: count)
        }
    }

    /// Secure direct-path variant used by the durable recovery IO defaults.
    /// The parent is opened descriptor-relative and every component is O_NOFOLLOW.
    public static func writeDataAtomicallyWithoutFollowingSymlinks(_ data: Data, to url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw LatticeStorePathError.invalidPath(url)
        }
        let file = normalizedSystemAliasURL(url).standardizedFileURL
        let parent = file.deletingLastPathComponent()
        try ensureDirectory(at: parent, createMissing: true)
        let parentFD = try openDirectoryWithoutFollowingSymlinks(at: parent)
        defer { close(parentFD) }
        try writeDataAtomically(data, to: file, parentFD: parentFD)
    }

    public static func writeDataAtomically(_ data: Data, to url: URL, under rootURL: URL) throws {
        let root = try canonicalDirectory(at: rootURL)
        let file = try containedPath(url, under: root, rootAlias: rootURL)
        let parent = file.deletingLastPathComponent()
        try ensureDirectory(at: parent, createMissing: false)

        let parentFD = try openDirectoryWithoutFollowingSymlinks(at: parent)
        defer { close(parentFD) }

        let targetName = file.lastPathComponent
        let targetBefore = try lstat(at: file)
        if let targetBefore, isSymlink(targetBefore) { throw LatticeStorePathError.symlink(file) }

        let temporaryName = ".lattice-write-\(UUID().uuidString)"
        let temporaryFD = openat(
            parentFD,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
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

        guard fsync(temporaryFD) == 0 else {
            throw fileSystemError(for: file, code: errno)
        }

        var targetAfter = stat()
        let targetProbe = fstatat(parentFD, targetName, &targetAfter, AT_SYMLINK_NOFOLLOW)
        guard targetProbe == 0 || errno == ENOENT else { throw fileSystemError(for: file, code: errno) }
        let targetAfterExists = targetProbe == 0
        if let targetBefore {
            guard targetAfterExists,
                  targetAfter.st_dev == targetBefore.st_dev,
                  targetAfter.st_ino == targetBefore.st_ino else {
                throw LatticeStorePathError.fileSystem(file, EAGAIN)
            }
        } else if targetAfterExists {
            throw LatticeStorePathError.fileSystem(file, EAGAIN)
        }
        guard renameat(parentFD, temporaryName, parentFD, targetName) == 0 else {
            throw fileSystemError(for: file, code: errno)
        }
        published = true
        guard fsync(parentFD) == 0 else {
            throw LatticeStorePathError.publishedButDurabilityUnconfirmed(file, errno)
        }
    }

    private static func writeDataAtomically(_ data: Data, to file: URL, parentFD: Int32) throws {
        let targetName = file.lastPathComponent
        let targetBefore = try lstat(at: file)
        if let targetBefore, isSymlink(targetBefore) { throw LatticeStorePathError.symlink(file) }
        let temporaryName = ".lattice-write-\(UUID().uuidString)"
        let temporaryFD = openat(parentFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard temporaryFD >= 0 else { throw fileSystemError(for: file, code: errno) }
        var published = false
        defer {
            close(temporaryFD)
            if !published { _ = unlinkat(parentFD, temporaryName, 0) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(temporaryFD, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw fileSystemError(for: file, code: errno) }
                offset += count
            }
        }
        guard fsync(temporaryFD) == 0 else { throw fileSystemError(for: file, code: errno) }
        var targetAfter = stat()
        let targetProbe = fstatat(parentFD, targetName, &targetAfter, AT_SYMLINK_NOFOLLOW)
        guard targetProbe == 0 || errno == ENOENT else { throw fileSystemError(for: file, code: errno) }
        let targetAfterExists = targetProbe == 0
        if let targetBefore {
            guard targetAfterExists,
                  targetAfter.st_dev == targetBefore.st_dev,
                  targetAfter.st_ino == targetBefore.st_ino else {
                throw LatticeStorePathError.fileSystem(file, EAGAIN)
            }
        } else if targetAfterExists {
            throw LatticeStorePathError.fileSystem(file, EAGAIN)
        }
        guard renameat(parentFD, temporaryName, parentFD, targetName) == 0 else { throw fileSystemError(for: file, code: errno) }
        published = true
        guard fsync(parentFD) == 0 else { throw LatticeStorePathError.publishedButDurabilityUnconfirmed(file, errno) }
    }

    public static func removeItem(at url: URL, under rootURL: URL) throws {
        let root = try canonicalDirectory(at: rootURL)
        let item = try containedPath(url, under: root, rootAlias: rootURL)
        guard item.path != root.path else {
            // Store root is not a removable child. This guard must run before
            // recursive contents removal so a caller cannot delete the store.
            throw LatticeStorePathError.invalidPath(url)
        }
        guard let status = try lstat(at: item) else { return }
        if isSymlink(status) { throw LatticeStorePathError.symlink(item) }

        let parent = item.deletingLastPathComponent()
        let parentFD = try openDirectoryWithoutFollowingSymlinks(at: parent)
        defer { close(parentFD) }
        var pinnedStatus = stat()
        guard fstatat(parentFD, item.lastPathComponent, &pinnedStatus, AT_SYMLINK_NOFOLLOW) == 0,
              pinnedStatus.st_dev == status.st_dev,
              pinnedStatus.st_ino == status.st_ino else {
            throw LatticeStorePathError.fileSystem(item, EAGAIN)
        }
        if isDirectory(status) {
            let childFD = openat(parentFD, item.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard childFD >= 0 else { throw fileSystemError(for: item, code: errno) }
            do {
                defer { close(childFD) }
                var childStatus = stat()
                guard fstat(childFD, &childStatus) == 0,
                      childStatus.st_dev == status.st_dev,
                      childStatus.st_ino == status.st_ino else {
                    throw LatticeStorePathError.fileSystem(item, EAGAIN)
                }
                try removeDirectoryContents(at: item, directoryFD: childFD)
            }
        }
        var finalItemStatus = stat()
        guard fstatat(parentFD, item.lastPathComponent, &finalItemStatus, AT_SYMLINK_NOFOLLOW) == 0,
              finalItemStatus.st_dev == status.st_dev,
              finalItemStatus.st_ino == status.st_ino else {
            throw LatticeStorePathError.fileSystem(item, EAGAIN)
        }
        let flags: Int32 = isDirectory(status) ? AT_REMOVEDIR : 0
        guard unlinkat(parentFD, item.lastPathComponent, flags) == 0 else {
            throw fileSystemError(for: item, code: errno)
        }
        guard fsync(parentFD) == 0 else {
            throw LatticeStorePathError.publishedButDurabilityUnconfirmed(item, errno)
        }
    }

    public static func isDirectoryWithoutFollowingSymlinks(at url: URL) -> Bool {
        guard let status = try? lstat(at: url) else { return false }
        return isDirectory(status) && !isSymlink(status)
    }

    public static func isRegularFileWithoutFollowingSymlinks(at url: URL) -> Bool {
        guard let status = try? lstat(at: url) else { return false }
        return isRegularFile(status) && !isSymlink(status)
    }

    public static func entryExistsWithoutFollowingSymlinks(at url: URL) -> Bool {
        (try? lstat(at: url)) != nil
    }

    public static func attributesWithoutFollowingSymlinks(at url: URL) throws -> [FileAttributeKey: Any] {
        let fd = try openFileWithoutFollowingSymlinks(at: url)
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw fileSystemError(for: url, code: errno) }
        let seconds = TimeInterval(status.st_mtimespec.tv_sec) + TimeInterval(status.st_mtimespec.tv_nsec) / 1_000_000_000
        return [.size: NSNumber(value: status.st_size), .modificationDate: Date(timeIntervalSince1970: seconds)]
    }

    public static func copyItemWithoutFollowingSymlinks(at source: URL, to destination: URL) throws {
        let sourceParentFD = try openDirectoryWithoutFollowingSymlinks(at: source.deletingLastPathComponent())
        defer { close(sourceParentFD) }
        var sourceStatus = stat()
        guard fstatat(sourceParentFD, source.lastPathComponent, &sourceStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw fileSystemError(for: source, code: errno)
        }
        guard sourceStatus.st_mode & S_IFMT == S_IFREG else { throw LatticeStorePathError.notRegularFile(source) }
        let sourceFD = openat(sourceParentFD, source.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceFD >= 0 else { throw fileSystemError(for: source, code: errno) }
        defer { close(sourceFD) }
        var openedStatus = stat()
        guard fstat(sourceFD, &openedStatus) == 0,
              openedStatus.st_dev == sourceStatus.st_dev,
              openedStatus.st_ino == sourceStatus.st_ino else {
            throw LatticeStorePathError.fileSystem(source, EAGAIN)
        }
        guard !entryExistsWithoutFollowingSymlinks(at: destination) else {
            throw fileSystemError(for: destination, code: EEXIST)
        }
        var copied = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(sourceFD, $0.baseAddress, $0.count) }
            if count == 0 { break }
            guard count > 0 else { throw fileSystemError(for: source, code: errno) }
            copied.append(buffer, count: count)
            guard copied.count <= maximumReadByteCount else { throw LatticeStorePathError.oversized(source, maximumReadByteCount) }
        }
        var finalStatus = stat()
        guard fstat(sourceFD, &finalStatus) == 0,
              finalStatus.st_dev == sourceStatus.st_dev,
              finalStatus.st_ino == sourceStatus.st_ino,
              finalStatus.st_size == sourceStatus.st_size else {
            throw LatticeStorePathError.fileSystem(source, EAGAIN)
        }
        try writeDataAtomicallyWithoutFollowingSymlinks(copied, to: destination)
    }

    public static func moveItemWithoutFollowingSymlinks(at source: URL, to destination: URL) throws {
        let sourceFD = try openDirectoryWithoutFollowingSymlinks(at: source.deletingLastPathComponent())
        defer { close(sourceFD) }
        let destinationFD = try openDirectoryWithoutFollowingSymlinks(at: destination.deletingLastPathComponent())
        defer { close(destinationFD) }
        var sourceStatus = stat()
        guard fstatat(sourceFD, source.lastPathComponent, &sourceStatus, AT_SYMLINK_NOFOLLOW) == 0,
              sourceStatus.st_mode & S_IFMT == S_IFREG else { throw LatticeStorePathError.notRegularFile(source) }
        var destinationStatus = stat()
        guard fstatat(destinationFD, destination.lastPathComponent, &destinationStatus, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT else { throw fileSystemError(for: destination, code: EEXIST) }
        var finalSourceStatus = stat()
        guard fstatat(sourceFD, source.lastPathComponent, &finalSourceStatus, AT_SYMLINK_NOFOLLOW) == 0,
              finalSourceStatus.st_dev == sourceStatus.st_dev,
              finalSourceStatus.st_ino == sourceStatus.st_ino else {
            throw LatticeStorePathError.fileSystem(source, EAGAIN)
        }
        var finalDestinationStatus = stat()
        let finalDestinationProbe = fstatat(destinationFD, destination.lastPathComponent, &finalDestinationStatus, AT_SYMLINK_NOFOLLOW)
        guard finalDestinationProbe != 0, errno == ENOENT else { throw LatticeStorePathError.fileSystem(destination, EEXIST) }
        guard renameat(sourceFD, source.lastPathComponent, destinationFD, destination.lastPathComponent) == 0 else {
            throw fileSystemError(for: destination, code: errno)
        }
        guard fsync(sourceFD) == 0, fsync(destinationFD) == 0 else {
            throw LatticeStorePathError.publishedButDurabilityUnconfirmed(destination, errno)
        }
    }

    public static func replaceItemWithoutFollowingSymlinks(at original: URL, with replacement: URL) throws {
        let originalFD = try openDirectoryWithoutFollowingSymlinks(at: original.deletingLastPathComponent())
        defer { close(originalFD) }
        let replacementFD = try openDirectoryWithoutFollowingSymlinks(at: replacement.deletingLastPathComponent())
        defer { close(replacementFD) }
        var replacementStatus = stat()
        guard fstatat(replacementFD, replacement.lastPathComponent, &replacementStatus, AT_SYMLINK_NOFOLLOW) == 0,
              replacementStatus.st_mode & S_IFMT == S_IFREG else { throw LatticeStorePathError.notRegularFile(replacement) }
        var finalReplacementStatus = stat()
        guard fstatat(replacementFD, replacement.lastPathComponent, &finalReplacementStatus, AT_SYMLINK_NOFOLLOW) == 0,
              finalReplacementStatus.st_dev == replacementStatus.st_dev,
              finalReplacementStatus.st_ino == replacementStatus.st_ino else {
            throw LatticeStorePathError.fileSystem(replacement, EAGAIN)
        }
        guard renameat(replacementFD, replacement.lastPathComponent, originalFD, original.lastPathComponent) == 0 else {
            throw fileSystemError(for: original, code: errno)
        }
        guard fsync(replacementFD) == 0, fsync(originalFD) == 0 else { throw LatticeStorePathError.publishedButDurabilityUnconfirmed(original, errno) }
    }

    public static func removeRegularFileWithoutFollowingSymlinks(at url: URL) throws {
        let parentFD = try openDirectoryWithoutFollowingSymlinks(at: url.deletingLastPathComponent())
        defer { close(parentFD) }
        var status = stat()
        guard fstatat(parentFD, url.lastPathComponent, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw fileSystemError(for: url, code: errno)
        }
        guard isRegularFile(status), !isSymlink(status) else { throw LatticeStorePathError.notRegularFile(url) }
        var finalStatus = stat()
        guard fstatat(parentFD, url.lastPathComponent, &finalStatus, AT_SYMLINK_NOFOLLOW) == 0,
              finalStatus.st_dev == status.st_dev,
              finalStatus.st_ino == status.st_ino else {
            throw LatticeStorePathError.fileSystem(url, EAGAIN)
        }
        guard unlinkat(parentFD, url.lastPathComponent, 0) == 0 else { throw fileSystemError(for: url, code: errno) }
        guard fsync(parentFD) == 0 else { throw LatticeStorePathError.publishedButDurabilityUnconfirmed(url, errno) }
    }

    public static func regularFilesWithoutFollowingSymlinks(in directory: URL) throws -> [URL] {
        try directoryEntriesWithoutFollowingSymlinks(in: directory)
            .filter(\.isRegularFile)
            .map { directory.appendingPathComponent($0.name) }
    }

    /// Removes only regular files directly in `directory`, while the directory
    /// descriptor remains pinned for enumeration and unlink. Never follows a
    /// symlink or recursively deletes arbitrary JSON paths.
    public static func removeRegularFilesWithoutFollowingSymlinks(
        in directory: URL,
        keeping names: Set<String> = [],
        matchingSuffix: String? = nil
    ) throws {
        let directoryFD = try openDirectoryWithoutFollowingSymlinks(at: directory)
        defer { close(directoryFD) }
        let streamFD = dup(directoryFD)
        guard streamFD >= 0, let stream = fdopendir(streamFD) else {
            if streamFD >= 0 { close(streamFD) }
            throw fileSystemError(for: directory, code: errno)
        }
        defer { closedir(stream) }
        var entryCount = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            entryCount += 1
            guard entryCount <= 4_096, name.utf8.count <= 255 else {
                throw LatticeStorePathError.fileSystem(directory, EOVERFLOW)
            }
            guard name != ".", name != "..", !names.contains(name) else { continue }
            if let matchingSuffix, !name.hasSuffix(matchingSuffix) { continue }
            var status = stat()
            guard fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw fileSystemError(for: directory.appendingPathComponent(name), code: errno)
            }
            guard status.st_mode & S_IFMT == S_IFREG else { continue }
            var finalStatus = stat()
            guard fstatat(directoryFD, name, &finalStatus, AT_SYMLINK_NOFOLLOW) == 0,
                  finalStatus.st_dev == status.st_dev,
                  finalStatus.st_ino == status.st_ino,
                  finalStatus.st_mode & S_IFMT == S_IFREG else {
                throw LatticeStorePathError.fileSystem(directory.appendingPathComponent(name), EAGAIN)
            }
            guard unlinkat(directoryFD, name, 0) == 0 else {
                throw fileSystemError(for: directory.appendingPathComponent(name), code: errno)
            }
        }
        guard fsync(directoryFD) == 0 else {
            throw LatticeStorePathError.publishedButDurabilityUnconfirmed(directory, errno)
        }
    }

    public struct DirectoryEntry: Sendable, Hashable {
        public let name: String
        public let isDirectory: Bool
        public let isRegularFile: Bool

        public init(name: String, isDirectory: Bool, isRegularFile: Bool) {
            self.name = name
            self.isDirectory = isDirectory
            self.isRegularFile = isRegularFile
        }
    }

    /// Enumerates names from a duplicated, O_NOFOLLOW directory descriptor. No
    /// path-based FileManager traversal or externally supplied child URL is used.
    public static func directoryEntriesWithoutFollowingSymlinks(in directory: URL) throws -> [DirectoryEntry] {
        let directoryFD = try openDirectoryWithoutFollowingSymlinks(at: directory)
        let streamFD = dup(directoryFD)
        close(directoryFD)
        guard streamFD >= 0, let stream = fdopendir(streamFD) else {
            if streamFD >= 0 { close(streamFD) }
            throw fileSystemError(for: directory, code: errno)
        }
        defer { closedir(stream) }
        var results: [DirectoryEntry] = []
        let maximumEntryCount = 4_096
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            guard name.utf8.count <= 255 else {
                throw LatticeStorePathError.fileSystem(directory, EOVERFLOW)
            }
            guard results.count < maximumEntryCount else {
                throw LatticeStorePathError.fileSystem(directory, EOVERFLOW)
            }
            var status = stat()
            guard fstatat(streamFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw fileSystemError(for: directory.appendingPathComponent(name), code: errno)
            }
            let mode = status.st_mode & S_IFMT
            if mode == S_IFDIR {
                results.append(.init(name: name, isDirectory: true, isRegularFile: false))
            } else if mode == S_IFREG {
                results.append(.init(name: name, isDirectory: false, isRegularFile: true))
            }
        }
        return results
    }

    private static func containedChild(named name: String, under root: URL) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw LatticeStorePathError.invalidPath(root.appendingPathComponent(name))
        }
        let child = root.appendingPathComponent(name, isDirectory: true)
        return try containedPath(child, under: root)
    }

    private static func containedPath(_ url: URL, under root: URL, rootAlias: URL? = nil) throws -> URL {
        let candidate = url
        guard candidate.isFileURL, candidate.path.hasPrefix("/") else {
            throw LatticeStorePathError.invalidPath(url)
        }
        try rejectTraversalComponents(in: candidate)
        if let rootAlias {
            let alias = rootAlias.standardizedFileURL
            let isAliasContained = isContained(candidate.path, in: alias.path)
            let isCanonicalContained = isContained(candidate.path, in: root.path)
            guard isAliasContained || isCanonicalContained else {
                throw LatticeStorePathError.outsideRoot(url)
            }
            // Resolve only after lexical containment. Accept either original
            // `/var` spelling or already-canonical `/private/var` descendants.
            let canonical = try canonicalURL(for: candidate)
            guard isContained(canonical.path, in: root.path) else {
                throw LatticeStorePathError.outsideRoot(url)
            }
            try validateNoSymlinkComponents(candidate, allowingPrefix: isAliasContained ? alias : root)
            return canonical
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

    private static func validateNoSymlinkComponents(_ url: URL, allowingPrefix: URL? = nil) throws {
        let components = url.path.split(separator: "/")
        let allowedComponentCount = allowingPrefix?.path.split(separator: "/").count ?? 0
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for (index, component) in components.enumerated() {
            current.appendPathComponent(String(component), isDirectory: true)
            if index < allowedComponentCount { continue }
            guard let status = try lstat(at: current) else { continue }
            if isSymlink(status) { throw LatticeStorePathError.symlink(current) }
        }
    }

    /// Reject traversal syntax instead of normalizing it. Normalization would make
    /// `root/../outside` look contained during lexical checks, while a later
    /// descriptor operation could still observe the original path components.
    private static func rejectTraversalComponents(in url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw LatticeStorePathError.invalidPath(url)
        }
        if url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) {
            throw LatticeStorePathError.invalidPath(url)
        }
    }

    private static func ensureDirectory(at url: URL, createMissing: Bool = true) throws {
        let directory = normalizedSystemAliasURL(url)
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
                guard mkdirat(directoryFD, name, mode_t(0o700)) == 0 || errno == EEXIST else {
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
        let directory = normalizedSystemAliasURL(url)
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
        let file = normalizedSystemAliasURL(url)
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
        let streamFD = dup(directoryFD)
        guard streamFD >= 0, let stream = fdopendir(streamFD) else {
            if streamFD >= 0 { close(streamFD) }
            throw fileSystemError(for: url, code: errno)
        }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            var status = stat()
            guard fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw fileSystemError(for: url.appendingPathComponent(name), code: errno)
            }
            let child = url.appendingPathComponent(name)
            let mode = status.st_mode & S_IFMT
            guard mode == S_IFREG || mode == S_IFDIR else {
                throw LatticeStorePathError.notRegularFile(child)
            }
            if mode == S_IFDIR {
                let childFD = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else { throw fileSystemError(for: child, code: errno) }
                do {
                    defer { close(childFD) }
                    try removeDirectoryContents(at: child, directoryFD: childFD)
                }
            }
            var finalStatus = stat()
            guard fstatat(directoryFD, name, &finalStatus, AT_SYMLINK_NOFOLLOW) == 0,
                  finalStatus.st_dev == status.st_dev,
                  finalStatus.st_ino == status.st_ino else {
                throw LatticeStorePathError.fileSystem(child, EAGAIN)
            }
            let flags: Int32 = mode == S_IFDIR ? AT_REMOVEDIR : 0
            guard unlinkat(directoryFD, name, flags) == 0 else { throw fileSystemError(for: child, code: errno) }
        }
        guard fsync(directoryFD) == 0 else { throw LatticeStorePathError.publishedButDurabilityUnconfirmed(url, errno) }
    }

    private static func removeDirectoryContents(at url: URL, directoryFD: Int32) throws {
        let streamFD = dup(directoryFD)
        guard streamFD >= 0, let stream = fdopendir(streamFD) else {
            if streamFD >= 0 { close(streamFD) }
            throw fileSystemError(for: url, code: errno)
        }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            var status = stat()
            guard fstatat(directoryFD, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw fileSystemError(for: url.appendingPathComponent(name), code: errno)
            }
            let child = url.appendingPathComponent(name)
            let mode = status.st_mode & S_IFMT
            guard mode == S_IFREG || mode == S_IFDIR else { throw LatticeStorePathError.notRegularFile(child) }
            if mode == S_IFDIR {
                let childFD = openat(directoryFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard childFD >= 0 else { throw fileSystemError(for: child, code: errno) }
                do {
                    defer { close(childFD) }
                    try removeDirectoryContents(at: child, directoryFD: childFD)
                }
            }
            var finalStatus = stat()
            guard fstatat(directoryFD, name, &finalStatus, AT_SYMLINK_NOFOLLOW) == 0,
                  finalStatus.st_dev == status.st_dev,
                  finalStatus.st_ino == status.st_ino else {
                throw LatticeStorePathError.fileSystem(child, EAGAIN)
            }
            guard unlinkat(directoryFD, name, mode == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else {
                throw fileSystemError(for: child, code: errno)
            }
        }
        guard fsync(directoryFD) == 0 else { throw LatticeStorePathError.publishedButDurabilityUnconfirmed(url, errno) }
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

    private static func normalizedSystemAliasURL(_ url: URL) -> URL {
        guard url.isFileURL else { return url }
        let path = url.standardizedFileURL.path
        for (alias, canonical) in [("/var", "/private/var"), ("/tmp", "/private/tmp"), ("/etc", "/private/etc")] {
            if path == alias || path.hasPrefix(alias + "/") {
                return URL(fileURLWithPath: canonical + String(path.dropFirst(alias.count)), isDirectory: url.hasDirectoryPath)
            }
        }
        return url.standardizedFileURL
    }
}
