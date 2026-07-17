import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// MARK: - Snapshot / fingerprint

/// Observation of a JSON object file used for conflict detection across read-modify-write.
///
/// JSON object graphs are Foundation reference values, so snapshots are marked unchecked
/// sendable. Callers receive an owned graph and must not mutate it across isolation domains.
public struct JSONFileSnapshot: @unchecked Sendable, Equatable {
    public var exists: Bool
    public var modificationDate: Date?
    public var fileSize: Int?
    public var contentFingerprint: String?
    public var object: [String: Any]?

    public init(
        exists: Bool,
        modificationDate: Date? = nil,
        fileSize: Int? = nil,
        contentFingerprint: String? = nil,
        object: [String: Any]? = nil
    ) {
        self.exists = exists
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.contentFingerprint = contentFingerprint
        self.object = object
    }

    public static func == (lhs: JSONFileSnapshot, rhs: JSONFileSnapshot) -> Bool {
        lhs.exists == rhs.exists
            && lhs.modificationDate == rhs.modificationDate
            && lhs.fileSize == rhs.fileSize
            && lhs.contentFingerprint == rhs.contentFingerprint
    }
}

public enum AtomicJSONFileReadError: Error, Sendable, Equatable {
    case malformedJSON
    case notAJSONObject
    case unreadable(String)

    public var message: String {
        switch self {
        case .malformedJSON: "File exists but is not valid JSON."
        case .notAJSONObject: "File exists but root value is not a JSON object."
        case .unreadable(let detail): "File could not be read: \(detail)"
        }
    }
}

public enum AtomicJSONFileWriteResult: Sendable, Equatable {
    case success
    /// The rename committed, but parent-directory durability could not be confirmed.
    case publishedButDurabilityUnconfirmed(String)
    case conflict
    case failure(String)

    public var isSuccess: Bool {
        switch self {
        case .success, .publishedButDurabilityUnconfirmed: return true
        case .conflict, .failure: return false
        }
    }

    public var warningDetail: String? {
        if case .publishedButDurabilityUnconfirmed(let detail) = self { return detail }
        return nil
    }
}

/// Conflict-aware atomic replacement of a bounded JSON object file.
///
/// All filesystem operations use absolute file URLs, reject symlink components, read only
/// regular files within the size limit, and publish through a descriptor-relative temp file
/// and `renameat`. The in-process lock is keyed by the canonical target path so `/var` and
/// `/private/var` aliases cannot bypass serialization. The advisory sidecar lock serializes
/// cooperating Lattice processes; it is not a defense against a same-user process that
/// deliberately mutates the target or parent directory outside this protocol.
public enum AtomicJSONFileTransaction {
    public static let defaultMaxAttempts = 5
    public static let maximumMutationAttempts = 20
    public static let maximumFileBytes = 1_048_576

    private static let lockRegistry = URLLockRegistry()

    public static func readObject(at url: URL) -> Result<JSONFileSnapshot, AtomicJSONFileReadError> {
        guard let url = securedURL(url) else { return .failure(.unreadable("An absolute file URL is required.")) }
        guard !isReservedLockLeaf(url.lastPathComponent) else {
            return .failure(.unreadable("The interprocess lock path is reserved."))
        }
        // Descriptor-stable reads are atomic with respect to rename. If a cooperating
        // writer already has a safe sidecar, take a bounded shared lock; never create one
        // or require write permission on a read-only parent.
        return lockRegistry.withLock(for: url) {
            switch withInterprocessLock(for: url, createMissing: false, createLock: false, shared: true, body: { readObjectUnlocked(at: url) }) {
            case .success(let result): return result
            case .failure(let detail): return .failure(.unreadable(detail))
            }
        }
    }

    private static func readObjectUnlocked(at url: URL) -> Result<JSONFileSnapshot, AtomicJSONFileReadError> {
        guard !hasSymlinkPathComponent(url) else {
            return .failure(.unreadable("Refusing to read through a symbolic link."))
        }
        switch readRegularFile(at: url) {
        case .missing:
            return .success(JSONFileSnapshot(exists: false, object: [:]))
        case .failure(let detail):
            return .failure(.unreadable(detail))
        case .success(let file):
            let fingerprint = fingerprint(for: file.data)
            guard !file.data.isEmpty else { return .failure(.malformedJSON) }
            let root: Any
            do {
                root = try JSONSerialization.jsonObject(with: file.data, options: [])
            } catch {
                return .failure(.malformedJSON)
            }
            guard let object = root as? [String: Any] else { return .failure(.notAJSONObject) }
            return .success(JSONFileSnapshot(
                exists: true,
                modificationDate: file.modificationDate,
                fileSize: file.data.count,
                contentFingerprint: fingerprint,
                object: object
            ))
        }
    }

    public static func mutateObject(
        at url: URL,
        maxAttempts: Int = defaultMaxAttempts,
        mutate: (_ root: inout [String: Any]) throws -> Void
    ) -> AtomicJSONFileWriteResult {
        guard let url = securedURL(url) else { return .failure("An absolute file URL is required.") }
        guard !isReservedLockLeaf(url.lastPathComponent) else { return .failure("The interprocess lock path is reserved.") }
        return lockRegistry.withLock(for: url) {
            let attempts = min(max(1, maxAttempts), maximumMutationAttempts)
            let result: InterprocessLockResult<AtomicJSONFileWriteResult> = withInterprocessLock(for: url, createMissing: true) {
                for _ in 0..<attempts {
                let baseline: JSONFileSnapshot
                switch readObjectUnlocked(at: url) {
                case .failure(let error): return .failure(error.message)
                case .success(let snapshot): baseline = snapshot
                }
                var root = baseline.object ?? [:]
                do { try mutate(&root) } catch { return .failure(error.localizedDescription) }
                let write = writeObjectUnlocked(root, to: url, expected: baseline)
                switch write {
                case .success, .publishedButDurabilityUnconfirmed, .failure: return write
                case .conflict: continue
                }
            }
            return .conflict
            }
            switch result {
            case .success(let value): return value
            case .failure(let detail): return .failure(detail)
            }
        }
    }

    public static func writeObject(
        _ root: [String: Any],
        to url: URL,
        expected: JSONFileSnapshot
    ) -> AtomicJSONFileWriteResult {
        guard let url = securedURL(url) else { return .failure("An absolute file URL is required.") }
        guard !isReservedLockLeaf(url.lastPathComponent) else { return .failure("The interprocess lock path is reserved.") }
        return lockRegistry.withLock(for: url) {
            switch withInterprocessLock(for: url, createMissing: true, body: { writeObjectUnlocked(root, to: url, expected: expected) }) {
            case .success(let result): return result
            case .failure(let detail): return .failure(detail)
            }
        }
    }

    private static func writeObjectUnlocked(
        _ root: [String: Any], to url: URL, expected: JSONFileSnapshot
    ) -> AtomicJSONFileWriteResult {
        guard !hasSymlinkPathComponent(url) else { return .failure("Refusing to write through a symbolic link.") }
        guard isCompleteBaseline(expected) else {
            return .failure("Refusing an incomplete existing file snapshot.")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return .failure("Failed to encode JSON.")
        }
        guard data.count <= maximumFileBytes else { return .failure("JSON file exceeds the size limit.") }

        let parent = URL(
            fileURLWithPath: (url.path as NSString).deletingLastPathComponent,
            isDirectory: true
        )
        let parentFD: Int32
        switch openDirectoryHierarchy(parent, createMissing: true) {
        case .success(let descriptor):
            parentFD = descriptor
        case .missing:
            return .failure("Failed to create the parent directory.")
        case .failure(let detail):
            return .failure("Failed to open parent directory: \(detail)")
        }
        defer { close(parentFD) }

        if let conflict = conflictMessage(at: url, expected: expected, parentFD: parentFD) { return conflict }
        let leaf = url.lastPathComponent
        let temporary = ".\(leaf).tmp-\(UUID().uuidString)"
        let tempFD = openat(parentFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard tempFD >= 0 else { return .failure("Failed to create temporary file: \(posixError())") }
        defer { unlinkat(parentFD, temporary, 0); close(tempFD) }
        guard writeAll(data, to: tempFD), fchmod(tempFD, mode_t(0o600)) == 0 else {
            return .failure("Failed to write temporary file: \(posixError())")
        }
        guard fsync(tempFD) == 0 else {
            return .failure("Failed to flush temporary JSON file: \(posixError())")
        }

        if let conflict = conflictMessage(at: url, expected: expected, parentFD: parentFD) { return conflict }
        guard renameat(parentFD, temporary, parentFD, leaf) == 0 else {
            return .failure("Failed to publish JSON file: \(posixError())")
        }
        guard fsync(parentFD) == 0 else {
            return .publishedButDurabilityUnconfirmed("JSON was published, but parent-directory durability could not be confirmed: \(posixError())")
        }
        // Descriptor-relative readback verifies the bytes that actually won the publish.
        switch readRegularFile(at: parentFD, leaf: leaf) {
        case .success(let file) where fingerprint(for: file.data) == fingerprint(for: data): return .success
        case .success: return .conflict
        case .missing: return .conflict
        case .failure(let detail): return .failure("Published file could not be verified: \(detail)")
        }
    }

    public static func fingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: POSIX / validation

    private struct RegularFile { let data: Data; let modificationDate: Date }
    private struct FileSignature: Equatable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }
    private enum ReadResult { case success(RegularFile); case missing; case failure(String) }
    private enum DirectoryOpenResult { case success(Int32); case missing; case failure(String) }
    private enum InterprocessLockResult<T> { case success(T); case failure(String) }
    private static let interprocessLockName = ".lattice-atomic-json.lock"
    private static let interprocessLockPollCount = 50
    private static let interprocessLockPollMicroseconds: useconds_t = 10_000

    private static func isReservedLockLeaf(_ leaf: String) -> Bool {
        leaf.caseInsensitiveCompare(interprocessLockName) == .orderedSame
    }

    /// Holds a parent-scoped advisory lock for the complete read/modify/publish sequence.
    /// The non-blocking bounded retry keeps UI callers from waiting indefinitely while a
    /// crashed or wedged peer process is investigated by the user.
    private static func withInterprocessLock<T>(
        for url: URL,
        createMissing: Bool,
        createLock: Bool = true,
        shared: Bool = false,
        body: () -> T
    ) -> InterprocessLockResult<T> {
        let parent = URL(
            fileURLWithPath: (url.path as NSString).deletingLastPathComponent,
            isDirectory: true
        )
        let parentFD: Int32
        switch openDirectoryHierarchy(parent, createMissing: createMissing) {
        case .missing:
            return .success(body())
        case .failure(let detail):
            return .failure(detail)
        case .success(let descriptor):
            parentFD = descriptor
        }
        defer { close(parentFD) }

        var existing = stat()
        let inspected = fstatat(parentFD, interprocessLockName, &existing, AT_SYMLINK_NOFOLLOW)
        if inspected == 0,
           (existing.st_mode & mode_t(S_IFMT)) != mode_t(S_IFREG) {
            return .failure("The interprocess lock path is not a regular file.")
        }
        if inspected != 0, errno == ENOENT, !createLock {
            return .success(body())
        }
        if inspected != 0, errno != ENOENT {
            return .failure("Unable to inspect interprocess lock: \(posixError())")
        }

        let baseFlags = (shared ? O_RDONLY : O_RDWR) | O_CLOEXEC | O_NOFOLLOW
        var lockFD = openat(parentFD, interprocessLockName, baseFlags, mode_t(0o600))
        if lockFD < 0, errno == ENOENT, createLock {
            lockFD = openat(parentFD, interprocessLockName, baseFlags | O_CREAT | O_EXCL, mode_t(0o600))
        }
        if lockFD < 0, errno == EEXIST {
            lockFD = openat(parentFD, interprocessLockName, baseFlags)
        }
        guard lockFD >= 0 else { return .failure("Unable to open interprocess lock: \(posixError())") }
        defer { close(lockFD) }

        var lockStat = stat()
        guard fstat(lockFD, &lockStat) == 0 else { return .failure("Unable to inspect interprocess lock: \(posixError())") }
        guard (lockStat.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return .failure("The interprocess lock path is not a regular file.")
        }
        guard lockStat.st_uid == geteuid() else {
            return .failure("The interprocess lock is not owned by the current user.")
        }
        if !shared {
            guard fchmod(lockFD, mode_t(0o600)) == 0 else {
                return .failure("Unable to secure interprocess lock: \(posixError())")
            }
        }
        var acquired = false
        for _ in 0..<interprocessLockPollCount {
            if flock(lockFD, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) == 0 {
                acquired = true
                break
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                return .failure("Unable to acquire interprocess lock: \(posixError())")
            }
            usleep(interprocessLockPollMicroseconds)
        }
        guard acquired else { return .failure("Timed out acquiring interprocess lock.") }
        defer { _ = flock(lockFD, LOCK_UN) }
        return .success(body())
    }

    private static func readRegularFile(at url: URL) -> ReadResult {
        let parent = URL(
            fileURLWithPath: (url.path as NSString).deletingLastPathComponent,
            isDirectory: true
        )
        let parentFD: Int32
        switch openDirectoryHierarchy(parent, createMissing: false) {
        case .success(let descriptor):
            parentFD = descriptor
        case .missing:
            return .missing
        case .failure(let detail):
            return .failure(detail)
        }
        defer { close(parentFD) }
        return readRegularFile(at: parentFD, leaf: url.lastPathComponent)
    }

    private static func readRegularFile(at parentFD: Int32, leaf: String) -> ReadResult {
        var candidate = stat()
        guard fstatat(parentFD, leaf, &candidate, AT_SYMLINK_NOFOLLOW) == 0 else {
            return errno == ENOENT ? .missing : .failure(posixError())
        }
        guard (candidate.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return .failure("The path is not a regular file.")
        }
        let fd = openat(parentFD, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return .missing }
            return .failure(posixError())
        }
        defer { close(fd) }
        return readRegularFile(from: fd)
    }

    private static func readRegularFile(from fd: Int32) -> ReadResult {
        for attempt in 0..<3 {
            var initial = stat()
            guard fstat(fd, &initial) == 0 else { return .failure(posixError()) }
            guard (initial.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return .failure("The path is not a regular file.") }
            guard initial.st_size >= 0, initial.st_size <= off_t(maximumFileBytes) else {
                return .failure("The file exceeds the size limit.")
            }
            guard lseek(fd, 0, SEEK_SET) >= 0 else { return .failure(posixError()) }
            var data = Data()
            data.reserveCapacity(Int(initial.st_size))
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let remaining = maximumFileBytes + 1 - data.count
                guard remaining > 0 else { return .failure("The file exceeds the size limit.") }
                let wanted = min(buffer.count, remaining)
                let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, wanted) }
                if count < 0 {
                    if errno == EINTR { continue }
                    return .failure(posixError())
                }
                if count == 0 { break }
                data.append(buffer, count: count)
            }
            var final = stat()
            guard fstat(fd, &final) == 0 else { return .failure(posixError()) }
            let stable = fileSignature(initial) == fileSignature(final)
                && final.st_size == off_t(data.count)
                && data.count <= maximumFileBytes
            if stable {
                return .success(RegularFile(data: data, modificationDate: modificationDate(of: final)))
            }
            if attempt < 2 { continue }
            return .failure("The file changed while it was being read.")
        }
        return .failure("The file changed while it was being read.")
    }

    private static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if count <= 0 { return false }
                offset += count
            }
            return true
        }
    }

    /// Opens an absolute directory one component at a time. No intermediate
    /// symlink can be followed or swapped into the traversal because every next
    /// component is resolved relative to the already-open parent descriptor.
    private static func openDirectoryHierarchy(
        _ directory: URL,
        createMissing: Bool
    ) -> DirectoryOpenResult {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            return .failure("An absolute directory path is required.")
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { return .failure(posixError()) }

        for component in directory.path.split(separator: "/") {
            let name = String(component)
            var next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT, createMissing {
                guard mkdirat(descriptor, name, mode_t(0o700)) == 0 || errno == EEXIST else {
                    let detail = posixError()
                    close(descriptor)
                    return .failure(detail)
                }
                next = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                let missing = errno == ENOENT
                let detail = posixError()
                close(descriptor)
                return missing ? .missing : .failure(detail)
            }
            close(descriptor)
            descriptor = next
        }
        return .success(descriptor)
    }

    private static func conflictMessage(at url: URL, expected: JSONFileSnapshot, parentFD: Int32) -> AtomicJSONFileWriteResult? {
        var current = stat()
        let leaf = url.lastPathComponent
        if fstatat(parentFD, leaf, &current, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return expected.exists ? .conflict : nil }
            return .failure("Unable to inspect JSON file: \(posixError())")
        }
        guard (current.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return .failure("The JSON path is not a regular file.") }
        guard expected.exists else { return .conflict }
        let currentRead = readRegularFile(at: parentFD, leaf: leaf)
        guard case .success(let file) = currentRead else { return .conflict }
        guard let size = expected.fileSize, let digest = expected.contentFingerprint, let date = expected.modificationDate else {
            return .failure("Refusing an incomplete existing file snapshot.")
        }
        guard size == file.data.count, digest == fingerprint(for: file.data), abs(date.timeIntervalSince(file.modificationDate)) <= 0.001 else { return .conflict }
        return nil
    }

    private static func isCompleteBaseline(_ snapshot: JSONFileSnapshot) -> Bool {
        !snapshot.exists || (snapshot.fileSize != nil && snapshot.contentFingerprint != nil && snapshot.modificationDate != nil)
    }

    /// Normalize only macOS's stable system aliases. User-controlled symlinks
    /// remain in the path and are rejected by descriptor traversal.
    private static func securedURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let path = (url.path as NSString).standardizingPath
        guard path.hasPrefix("/"), path != "/", !(path as NSString).lastPathComponent.isEmpty else {
            return nil
        }
        #if canImport(Darwin)
        let aliases = [
            (alias: "/var", canonical: "/private/var"),
            (alias: "/tmp", canonical: "/private/tmp"),
            (alias: "/etc", canonical: "/private/etc")
        ]
        for mapping in aliases where path == mapping.alias || path.hasPrefix(mapping.alias + "/") {
            let suffix = path.dropFirst(mapping.alias.count)
            return URL(fileURLWithPath: mapping.canonical + String(suffix), isDirectory: false)
        }
        #endif
        return URL(fileURLWithPath: path, isDirectory: false)
    }

    private static func hasSymlinkPathComponent(_ url: URL) -> Bool {
        let absolute = url.path
        var current = absolute.hasPrefix("/") ? "/" : ""
        for component in absolute.split(separator: "/") {
            if current.isEmpty || current == "/" { current += component }
            else { current += "/\(component)" }
            var st = stat()
            if lstat(current, &st) == 0 {
                if (st.st_mode & mode_t(S_IFMT)) == mode_t(S_IFLNK) { return true }
            } else if errno != ENOENT {
                return true
            } else {
                // A missing component is safe; any dangling parent symlink would have
                // been observed before the missing child.
                return false
            }
        }
        return false
    }

    private static func modificationDate(of statBuffer: stat) -> Date {
        #if canImport(Darwin)
        return Date(timeIntervalSince1970: TimeInterval(statBuffer.st_mtimespec.tv_sec) + TimeInterval(statBuffer.st_mtimespec.tv_nsec) / 1_000_000_000)
        #else
        return Date(timeIntervalSince1970: TimeInterval(statBuffer.st_mtim.tv_sec) + TimeInterval(statBuffer.st_mtim.tv_nsec) / 1_000_000_000)
        #endif
    }

    private static func fileSignature(_ statBuffer: stat) -> FileSignature {
        #if canImport(Darwin)
        return FileSignature(
            device: UInt64(statBuffer.st_dev), inode: UInt64(statBuffer.st_ino), size: Int64(statBuffer.st_size),
            modificationSeconds: Int64(statBuffer.st_mtimespec.tv_sec), modificationNanoseconds: Int64(statBuffer.st_mtimespec.tv_nsec),
            changeSeconds: Int64(statBuffer.st_ctimespec.tv_sec), changeNanoseconds: Int64(statBuffer.st_ctimespec.tv_nsec)
        )
        #else
        return FileSignature(
            device: UInt64(statBuffer.st_dev), inode: UInt64(statBuffer.st_ino), size: Int64(statBuffer.st_size),
            modificationSeconds: Int64(statBuffer.st_mtim.tv_sec), modificationNanoseconds: Int64(statBuffer.st_mtim.tv_nsec),
            changeSeconds: Int64(statBuffer.st_ctim.tv_sec), changeNanoseconds: Int64(statBuffer.st_ctim.tv_nsec)
        )
        #endif
    }

    private static func posixError() -> String { String(cString: strerror(errno)) }
}

private final class URLLockRegistry: @unchecked Sendable {
    private final class Entry { let lock = NSRecursiveLock(); var users = 0 }
    private let registryLock = NSLock()
    private var entries: [String: Entry] = [:]

    func withLock<T>(for url: URL, _ body: () -> T) -> T {
        let key = url.path
        registryLock.lock()
        let entry = entries[key] ?? Entry()
        entries[key] = entry
        entry.users += 1
        registryLock.unlock()
        entry.lock.lock()
        defer {
            entry.lock.unlock()
            registryLock.lock()
            entry.users -= 1
            if entry.users == 0, entries[key] === entry { entries.removeValue(forKey: key) }
            registryLock.unlock()
        }
        return body()
    }
}
