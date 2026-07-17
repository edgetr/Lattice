import Foundation
import CryptoKit

// MARK: - Evidence-rich load results

/// Classifies durable JSON-array store load failures that require recovery UI.
/// Missing storage is intentionally not a failure — it is the normal empty state.
public enum DurableStoreIssueKind: String, Sendable, Hashable, Codable {
    case corrupt
    case unreadable
    case oversized

    public var displayName: String {
        switch self {
        case .corrupt: "Corrupt or invalid JSON"
        case .unreadable: "Unreadable"
        case .oversized: "Too large"
        }
    }
}

/// Evidence captured when a durable store cannot be loaded.
public struct DurableStoreIssue: Sendable, Hashable, Identifiable, Codable {
    public let storeID: String
    public let storeName: String
    public let filePath: String
    public let kind: DurableStoreIssueKind
    public let summary: String
    public let technicalDetails: String
    public let observedModificationDate: Date?
    public let observedFileSize: Int?
    public let observedContentFingerprint: String?

    public var id: String { storeID }
    public var fileURL: URL { URL(fileURLWithPath: filePath) }

    public init(
        storeID: String,
        storeName: String,
        filePath: String,
        kind: DurableStoreIssueKind,
        summary: String,
        technicalDetails: String,
        observedModificationDate: Date? = nil,
        observedFileSize: Int? = nil,
        observedContentFingerprint: String? = nil
    ) {
        self.storeID = storeID
        self.storeName = storeName
        self.filePath = filePath
        self.kind = kind
        self.summary = summary
        self.technicalDetails = technicalDetails
        self.observedModificationDate = observedModificationDate
        self.observedFileSize = observedFileSize
        self.observedContentFingerprint = observedContentFingerprint
    }
}

/// Typed load outcome. Missing remains the normal empty state.
public enum DurableStoreLoadResult<Value: Sendable>: Sendable {
    case missing
    case loaded(Value)
    case failed(DurableStoreIssue)

    public var issue: DurableStoreIssue? {
        if case .failed(let issue) = self { return issue }
        return nil
    }

    public var isWriteBlocked: Bool {
        if case .failed = self { return true }
        return false
    }
}

// MARK: - Write gate

/// Blocks normal persistence writes for a store until recovery resolves the failure.
public final class DurableStoreWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let writeLock = NSLock()
    private var blocked = false

    public init(blocked: Bool = false) {
        self.blocked = blocked
    }

    public var isBlocked: Bool {
        lock.lock(); defer { lock.unlock() }
        return blocked
    }

    /// Marks the gate blocked after every already-running write finishes. The write lock is
    /// intentionally acquired before the state lock so a recovery transition has a clear
    /// linearization point and cannot race a save that already passed its writable check.
    public func block() {
        writeLock.lock()
        lock.lock()
        blocked = true
        lock.unlock()
        writeLock.unlock()
    }

    public func unblock() {
        writeLock.lock()
        lock.lock(); blocked = false; lock.unlock()
        writeLock.unlock()
    }

    /// Nonblocking transition for MainActor/UI callers. `false` means a persistence
    /// transaction currently owns the gate; the caller should retry asynchronously.
    @discardableResult
    public func trySetBlocked(_ value: Bool) -> Bool {
        guard writeLock.try() else { return false }
        lock.lock(); blocked = value; lock.unlock()
        writeLock.unlock()
        return true
    }

    @discardableResult
    public func tryBlock() -> Bool { trySetBlocked(true) }

    @discardableResult
    public func tryUnblock() -> Bool { trySetBlocked(false) }

    /// Executes a recovery transition without exposing the write lock to callers.
    /// This is useful when a transition must be retried on a background task.
    public func withExclusiveTransition<T>(_ body: () throws -> T) rethrows -> T {
        writeLock.lock()
        defer { writeLock.unlock() }
        return try body()
    }

    /// Serializes complete store transactions for every persistence value sharing this gate.
    /// `SessionPersistence` is a value type, so this reference-backed gate is the safe place
    /// to retain the lock across copied instances without introducing a process-wide registry.
    public func withExclusiveWrite<T>(_ body: () throws -> T) rethrows -> T {
        writeLock.lock()
        defer { writeLock.unlock() }
        return try body()
    }
}

// MARK: - Injectable filesystem

/// Injectable IO surface so recovery is testable without AppKit and without unreliable chmod.
public struct DurableStoreFileIO: Sendable {
    public var fileExists: @Sendable (String) -> Bool
    public var attributesOfItem: @Sendable (String) throws -> [FileAttributeKey: Any]
    public var readData: @Sendable (URL) throws -> Data
    public var readDataUpTo: @Sendable (URL, Int) throws -> Data
    public var writeDataAtomically: @Sendable (Data, URL) throws -> Void
    public var createDirectory: @Sendable (URL) throws -> Void
    public var copyItem: @Sendable (URL, URL) throws -> Void
    public var moveItem: @Sendable (URL, URL) throws -> Void
    public var removeItem: @Sendable (URL) throws -> Void
    public var replaceItem: @Sendable (URL, URL) throws -> Void
    public var contentsOfDirectory: @Sendable (URL) throws -> [URL]

    public init(
        fileExists: @escaping @Sendable (String) -> Bool = { LatticeStorePathSecurity.entryExistsWithoutFollowingSymlinks(at: URL(fileURLWithPath: $0)) },
        attributesOfItem: @escaping @Sendable (String) throws -> [FileAttributeKey: Any] = { try LatticeStorePathSecurity.attributesWithoutFollowingSymlinks(at: URL(fileURLWithPath: $0)) },
        readData: @escaping @Sendable (URL) throws -> Data = { try LatticeStorePathSecurity.readDataWithoutFollowingSymlinks(at: $0) },
        readDataUpTo: @escaping @Sendable (URL, Int) throws -> Data = { url, limit in
            try LatticeStorePathSecurity.readDataWithoutFollowingSymlinks(at: url, maximumByteCount: limit)
        },
        writeDataAtomically: @escaping @Sendable (Data, URL) throws -> Void = { try LatticeStorePathSecurity.writeDataAtomicallyWithoutFollowingSymlinks($0, to: $1) },
        createDirectory: @escaping @Sendable (URL) throws -> Void = { try LatticeStorePathSecurity.prepareDirectory(at: $0) },
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = { try LatticeStorePathSecurity.copyItemWithoutFollowingSymlinks(at: $0, to: $1) },
        moveItem: @escaping @Sendable (URL, URL) throws -> Void = { try LatticeStorePathSecurity.moveItemWithoutFollowingSymlinks(at: $0, to: $1) },
        removeItem: @escaping @Sendable (URL) throws -> Void = { try LatticeStorePathSecurity.removeRegularFileWithoutFollowingSymlinks(at: $0) },
        replaceItem: @escaping @Sendable (URL, URL) throws -> Void = { original, replacement in try LatticeStorePathSecurity.replaceItemWithoutFollowingSymlinks(at: original, with: replacement) },
        contentsOfDirectory: @escaping @Sendable (URL) throws -> [URL] = { try LatticeStorePathSecurity.regularFilesWithoutFollowingSymlinks(in: $0) }
    ) {
        self.fileExists = fileExists
        self.attributesOfItem = attributesOfItem
        self.readData = readData
        self.readDataUpTo = readDataUpTo
        self.writeDataAtomically = writeDataAtomically
        self.createDirectory = createDirectory
        self.copyItem = copyItem
        self.moveItem = moveItem
        self.removeItem = removeItem
        self.replaceItem = replaceItem
        self.contentsOfDirectory = contentsOfDirectory
    }

    public static let `default` = DurableStoreFileIO()
}

// MARK: - Errors

public enum DurableStoreRecoveryError: Error, LocalizedError, Sendable, Equatable {
    case destinationExists(path: String)
    case sourceMissing(path: String)
    case sourceChanged(path: String)
    case backupFailed(message: String)
    case resetFailed(message: String)
    case exportFailed(message: String)
    case writeBlocked(storeName: String)
    case operationFailed(message: String)

    public var errorDescription: String? {
        switch self {
        case .destinationExists(let path):
            return "A file already exists at \(path). Choose a different destination."
        case .sourceMissing(let path):
            return "The original file is no longer present at \(path)."
        case .sourceChanged(let path):
            return "The file at \(path) changed after the failure was observed. Retry loading before resetting."
        case .backupFailed(let message),
             .resetFailed(let message),
             .exportFailed(let message),
             .operationFailed(let message):
            return message
        case .writeBlocked(let storeName):
            return "Writing to \(storeName) is blocked until recovery is complete."
        }
    }
}

public struct DurableStorePreserveResult: Sendable, Equatable {
    public let preservedURL: URL
    public let note: String?

    public init(preservedURL: URL, note: String? = nil) {
        self.preservedURL = preservedURL
        self.note = note
    }
}

public enum DurableStorePreserveKind: String, Sendable {
    case backup
    case quarantine
}

// MARK: - Recovery primitives

/// Focused, AppKit-free recovery primitives for durable JSON array stores.
public enum DurableStoreRecovery: Sendable {
    public static let emptyJSONArray = Data("[]\n".utf8)
    public static let maximumStoreByteCount = 10 * 1024 * 1024

    public static func enforceWritable(gate: DurableStoreWriteGate, storeName: String = "this store") throws {
        if gate.isBlocked {
            throw DurableStoreRecoveryError.writeBlocked(storeName: storeName)
        }
    }

    /// Classifies Foundation/POSIX/Cocoa read failures using direct error evidence (not localized strings alone).
    public static func isUnreadableError(_ error: Error) -> Bool {
        // Secure store I/O throws LatticeStorePathError rather than Cocoa/POSIX NSErrors.
        if case .fileSystem(_, let code) = error as? LatticeStorePathError {
            let codes: Set<Int32> = [EACCES, EPERM, EIO, EBUSY, EAGAIN]
            if codes.contains(code) { return true }
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            let codes: Set<Int> = [
                NSFileReadNoPermissionError,
                NSFileReadUnknownError,
                NSFileReadCorruptFileError,
                NSFileLockingError,
                NSFileReadInvalidFileNameError
            ]
            if codes.contains(nsError.code) { return true }
        }
        if nsError.domain == NSPOSIXErrorDomain {
            let codes: Set<Int> = [Int(EACCES), Int(EPERM), Int(EIO), Int(EBUSY), Int(EAGAIN)]
            if codes.contains(nsError.code) { return true }
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isUnreadableError(underlying)
        }
        return false
    }

    public static func isNotFoundError(_ error: Error) -> Bool {
        // Secure store I/O throws LatticeStorePathError.fileSystem(_, ENOENT) for absent files.
        // Without this branch, missing stores would be misclassified as unreadable failures.
        if case .fileSystem(_, let code) = error as? LatticeStorePathError, code == ENOENT {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isNotFoundError(underlying)
        }
        return false
    }

    public static func contentFingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func observation(
        of fileURL: URL,
        io: DurableStoreFileIO = .default
    ) -> (modificationDate: Date?, fileSize: Int?, fingerprint: String?) {
        let metadata = metadata(of: fileURL, io: io)
        let fingerprint: String?
        if let fileSize = metadata.fileSize, fileSize > maximumStoreByteCount {
            fingerprint = nil
        } else if let data = try? io.readDataUpTo(fileURL, maximumStoreByteCount),
                  data.count <= maximumStoreByteCount {
            fingerprint = contentFingerprint(for: data)
        } else {
            fingerprint = nil
        }
        return (metadata.modificationDate, metadata.fileSize, fingerprint)
    }

    /// Loads a JSON array store. Missing is normal empty; corrupt, unreadable, and oversized stores fail.
    public static func loadJSONArray<Element: Decodable & Sendable>(
        from fileURL: URL,
        as elementType: Element.Type = Element.self,
        storeID: String,
        storeName: String,
        io: DurableStoreFileIO = .default
    ) -> DurableStoreLoadResult<[Element]> {
        let observed = metadata(of: fileURL, io: io)
        if let fileSize = observed.fileSize, fileSize > maximumStoreByteCount {
            return .failed(
                oversizedIssue(
                    storeID: storeID,
                    storeName: storeName,
                    fileURL: fileURL,
                    observed: (observed.modificationDate, observed.fileSize, nil)
                )
            )
        }

        let data: Data
        do {
            data = try io.readDataUpTo(fileURL, maximumStoreByteCount)
        } catch {
            if isNotFoundError(error) {
                return .missing
            }
            return .failed(
                makeIssue(
                    storeID: storeID,
                    storeName: storeName,
                    fileURL: fileURL,
                    kind: .unreadable,
                    summary: "\(storeName) could not be read. Lattice left the original file untouched.",
                    error: error,
                    dataPreview: nil,
                    observation: (observed.modificationDate, observed.fileSize, nil)
                )
            )
        }

        if data.count > maximumStoreByteCount {
            return .failed(
                oversizedIssue(
                    storeID: storeID,
                    storeName: storeName,
                    fileURL: fileURL,
                    observed: (
                        observed.modificationDate,
                        observed.fileSize,
                        nil
                    )
                )
            )
        }

        do {
            let decoded = try JSONDecoder().decode([Element].self, from: data)
            return .loaded(decoded)
        } catch {
            return .failed(
                makeIssue(
                    storeID: storeID,
                    storeName: storeName,
                    fileURL: fileURL,
                    kind: .corrupt,
                    summary: "\(storeName) contains invalid or corrupt JSON. Lattice left the original file untouched.",
                    error: error,
                    dataPreview: data,
                    observation: (
                        observed.modificationDate,
                        observed.fileSize ?? data.count,
                        contentFingerprint(for: data)
                    )
                )
            )
        }
    }

    /// Non-destructive export. Refuses to replace an existing destination.
    public static func exportCopy(
        of fileURL: URL,
        to destinationURL: URL,
        io: DurableStoreFileIO = .default
    ) throws {
        guard io.fileExists(fileURL.path) else {
            throw DurableStoreRecoveryError.sourceMissing(path: fileURL.path)
        }
        if io.fileExists(destinationURL.path) {
            throw DurableStoreRecoveryError.destinationExists(path: destinationURL.path)
        }
        do {
            try io.createDirectory(destinationURL.deletingLastPathComponent())
            try io.copyItem(fileURL, destinationURL)
        } catch let recovery as DurableStoreRecoveryError {
            throw recovery
        } catch {
            throw DurableStoreRecoveryError.exportFailed(
                message: "Could not export a copy: \(error.localizedDescription)"
            )
        }
    }

    /// Creates a collision-safe backup/quarantine copy next to the original. Never replaces an existing backup.
    public static func preserveCopy(
        of fileURL: URL,
        kind: DurableStorePreserveKind = .backup,
        io: DurableStoreFileIO = .default,
        now: Date = Date(),
        uniqueToken: String = UUID().uuidString,
        writeGate: DurableStoreWriteGate? = nil,
        storeName: String = "this store"
    ) throws -> DurableStorePreserveResult {
        if let writeGate {
            return try writeGate.withExclusiveTransition {
                return try preserveCopy(of: fileURL, kind: kind, io: io, now: now, uniqueToken: uniqueToken)
            }
        }
        guard io.fileExists(fileURL.path) else {
            throw DurableStoreRecoveryError.sourceMissing(path: fileURL.path)
        }
        let preservedURL = try uniquePreserveURL(
            for: fileURL,
            kind: kind,
            now: now,
            uniqueToken: uniqueToken,
            io: io
        )
        let temporaryURL = preservedURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(preservedURL.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            try io.copyItem(fileURL, temporaryURL)
        } catch {
            try? io.removeItem(temporaryURL)
            throw DurableStoreRecoveryError.backupFailed(
                message: "Could not create a \(kind.rawValue) of \(fileURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
        guard io.fileExists(temporaryURL.path) else {
            try? io.removeItem(temporaryURL)
            throw DurableStoreRecoveryError.backupFailed(
                message: "\(kind.rawValue.capitalized) temporary copy was not created near \(fileURL.path)."
            )
        }
        let original: Data
        let copy: Data
        do {
            original = try io.readData(fileURL)
            copy = try io.readData(temporaryURL)
        } catch {
            try? io.removeItem(temporaryURL)
            throw DurableStoreRecoveryError.backupFailed(
                message: "\(kind.rawValue.capitalized) could not be verified for \(fileURL.lastPathComponent); original left unchanged. \(error.localizedDescription)"
            )
        }
        guard original == copy else {
            try? io.removeItem(temporaryURL)
            throw DurableStoreRecoveryError.backupFailed(
                message: "\(kind.rawValue.capitalized) verification failed for \(fileURL.lastPathComponent); original left unchanged."
            )
        }
        do {
            try io.moveItem(temporaryURL, preservedURL)
        } catch {
            try? io.removeItem(temporaryURL)
            throw DurableStoreRecoveryError.backupFailed(
                message: "Could not finalize the verified \(kind.rawValue) of \(fileURL.lastPathComponent): \(error.localizedDescription)"
            )
        }
        guard io.fileExists(preservedURL.path) else {
            throw DurableStoreRecoveryError.backupFailed(
                message: "\(kind.rawValue.capitalized) was not finalized at \(preservedURL.path)."
            )
        }
        return .init(
            preservedURL: preservedURL,
            note: "Original left in place at \(fileURL.path)."
        )
    }

    /// Creates a verified backup/quarantine copy, then atomically replaces the original with a valid empty JSON array.
    /// If backup cannot be created, the original is never touched.
    /// When `expected` is provided, rejects stale sources that changed after the failure was observed.
    public static func resetReplacingWithEmptyArray(
        at fileURL: URL,
        expected: DurableStoreIssue? = nil,
        io: DurableStoreFileIO = .default,
        now: Date = Date(),
        uniqueToken: String = UUID().uuidString,
        writeGate: DurableStoreWriteGate? = nil,
        storeName: String = "this store"
    ) throws -> DurableStorePreserveResult {
        if let writeGate {
            return try writeGate.withExclusiveTransition {
                return try resetReplacingWithEmptyArray(at: fileURL, expected: expected, io: io, now: now, uniqueToken: uniqueToken)
            }
        }
        if !io.fileExists(fileURL.path) {
            if expected != nil {
                throw DurableStoreRecoveryError.sourceMissing(path: fileURL.path)
            }
            let durable = try writeEmptyArray(at: fileURL, io: io)
            return .init(preservedURL: fileURL, note: durable ? "No original existed; wrote a new empty store." : "No original existed; empty store was published but durability could not be confirmed.")
        }

        if let expected {
            try ensureSourceMatchesExpected(fileURL: fileURL, expected: expected, io: io)
        }

        let sourceBeforePreserve = observation(of: fileURL, io: io)
        guard sourceBeforePreserve.fingerprint != nil else {
            throw DurableStoreRecoveryError.resetFailed(
                message: "Reset aborted because the original could not be bounded and fingerprinted safely. Original left unchanged."
            )
        }

        let preserved: DurableStorePreserveResult
        do {
            preserved = try preserveCopy(of: fileURL, kind: .quarantine, io: io, now: now, uniqueToken: uniqueToken)
        } catch {
            throw DurableStoreRecoveryError.resetFailed(
                message: "Reset aborted because a backup could not be created. Original left unchanged. \(error.localizedDescription)"
            )
        }

        let sourceAfterPreserve = observation(of: fileURL, io: io)
        guard observationsMatch(sourceBeforePreserve, sourceAfterPreserve) else {
            throw DurableStoreRecoveryError.resetFailed(
                message: "Reset aborted because the original changed while its backup was being created. Original left unchanged."
            )
        }

        // Close the final race window between backup verification and publish.
        let sourceImmediatelyBeforeReplace = observation(of: fileURL, io: io)
        guard observationsMatch(sourceAfterPreserve, sourceImmediatelyBeforeReplace) else {
            throw DurableStoreRecoveryError.resetFailed(
                message: "Reset aborted because the original changed immediately before replacement. Original left unchanged."
            )
        }

        do {
            let durable = try writeEmptyArray(at: fileURL, io: io)
            let durabilityNote = durable ? "" : " Durability could not be confirmed after publication."
            return .init(
                preservedURL: preserved.preservedURL,
                note: "Original preserved; new empty JSON array installed.\(durabilityNote)"
            )
        } catch {
            throw DurableStoreRecoveryError.resetFailed(
                message: "Backup was saved to \(preserved.preservedURL.path), but replacing the original failed: \(error.localizedDescription)"
            )
        }
    }

    public static func uniquePreserveURL(
        for fileURL: URL,
        kind: DurableStorePreserveKind = .backup,
        now: Date = Date(),
        uniqueToken: String = UUID().uuidString,
        io: DurableStoreFileIO = .default
    ) throws -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let baseName = sanitizeFileNameComponent(fileURL.lastPathComponent)
        let timestamp = utcTimestamp(now)
        let token = sanitizeFileNameComponent(
            String(uniqueToken.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        )
        // Required suffix style: .corrupt-<UTC timestamp>-<unique>.backup
        // Both backup and quarantine use the same visible corrupt marker so users can identify failed originals.
        let label = "corrupt"
        var candidate = directory.appendingPathComponent("\(baseName).\(label)-\(timestamp)-\(token).backup")
        var attempt = 1
        while io.fileExists(candidate.path) {
            attempt += 1
            candidate = directory.appendingPathComponent("\(baseName).\(label)-\(timestamp)-\(token)-\(attempt).backup")
            if attempt > 64 {
                throw DurableStoreRecoveryError.backupFailed(
                    message: "Could not allocate a unique backup name near \(directory.path)."
                )
            }
        }
        return candidate
    }

    public static func ensureSourceMatchesExpected(
        fileURL: URL,
        expected: DurableStoreIssue,
        io: DurableStoreFileIO = .default
    ) throws {
        // Without a bounded content fingerprint, same-size mutations cannot be
        // distinguished safely. Refuse destructive recovery rather than guess.
        guard expected.observedContentFingerprint != nil else {
            throw DurableStoreRecoveryError.sourceChanged(path: fileURL.path)
        }
        let current = observation(of: fileURL, io: io)
        if let expectedSize = expected.observedFileSize {
            guard current.fileSize == expectedSize else {
                throw DurableStoreRecoveryError.sourceChanged(path: fileURL.path)
            }
        }
        if let expectedFingerprint = expected.observedContentFingerprint {
            guard current.fingerprint == expectedFingerprint else {
                throw DurableStoreRecoveryError.sourceChanged(path: fileURL.path)
            }
        }
        if let expectedDate = expected.observedModificationDate {
            guard let currentDate = current.modificationDate,
                  abs(expectedDate.timeIntervalSince(currentDate)) <= 0.001 else {
                throw DurableStoreRecoveryError.sourceChanged(path: fileURL.path)
            }
        }
    }

    // MARK: - Helpers

    private static func metadata(
        of fileURL: URL,
        io: DurableStoreFileIO
    ) -> (modificationDate: Date?, fileSize: Int?) {
        let attrs = try? io.attributesOfItem(fileURL.path)
        return (
            attrs?[.modificationDate] as? Date,
            (attrs?[.size] as? NSNumber)?.intValue
        )
    }

    private static func observationsMatch(
        _ lhs: (modificationDate: Date?, fileSize: Int?, fingerprint: String?),
        _ rhs: (modificationDate: Date?, fileSize: Int?, fingerprint: String?)
    ) -> Bool {
        lhs.fileSize == rhs.fileSize && lhs.fingerprint == rhs.fingerprint
    }

    private static func oversizedIssue(
        storeID: String,
        storeName: String,
        fileURL: URL,
        observed: (modificationDate: Date?, fileSize: Int?, fingerprint: String?)
    ) -> DurableStoreIssue {
        let observedLength = observed.fileSize.map { String($0) } ?? "more than \(maximumStoreByteCount)"
        return DurableStoreIssue(
            storeID: storeID,
            storeName: storeName,
            filePath: fileURL.path,
            kind: .oversized,
            summary: "\(storeName) exceeds Lattice's safe storage limit. Lattice left the original file untouched.",
            technicalDetails: [
                "Path: \(fileURL.path)",
                "Category: oversized",
                "Observed byte length: \(observedLength)",
                "Maximum allowed byte length: \(maximumStoreByteCount)"
            ].joined(separator: "\n"),
            observedModificationDate: observed.modificationDate,
            observedFileSize: observed.fileSize,
            observedContentFingerprint: observed.fingerprint
        )
    }

    private static func writeEmptyArray(at fileURL: URL, io: DurableStoreFileIO) throws -> Bool {
        try io.createDirectory(fileURL.deletingLastPathComponent())
        let temporary = fileURL.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try io.writeDataAtomically(emptyJSONArray, temporary)
            if io.fileExists(fileURL.path) {
                try io.replaceItem(fileURL, temporary)
            } else {
                try io.moveItem(temporary, fileURL)
            }
        } catch {
            if (try? io.readDataUpTo(fileURL, maximumStoreByteCount)) == emptyJSONArray {
                try? io.removeItem(temporary)
                return false
            }
            try? io.removeItem(temporary)
            throw error
        }
        if io.fileExists(temporary.path) {
            try? io.removeItem(temporary)
        }
        return true
    }

    private static func sanitizeFileNameComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let cleaned = String(scalars)
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return cleaned.isEmpty ? "store" : cleaned
    }

    private static func utcTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func makeIssue(
        storeID: String,
        storeName: String,
        fileURL: URL,
        kind: DurableStoreIssueKind,
        summary: String,
        error: Error,
        dataPreview: Data?,
        observation: (modificationDate: Date?, fileSize: Int?, fingerprint: String?)
    ) -> DurableStoreIssue {
        let nsError = error as NSError
        var lines: [String] = [
            "Path: \(fileURL.path)",
            "Category: \(kind.rawValue)",
            "Domain: \(nsError.domain)",
            "Code: \(nsError.code)",
            "Description: \(nsError.localizedDescription)"
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            lines.append("Underlying: \(underlying.domain) (\(underlying.code)) \(underlying.localizedDescription)")
        }
        if let dataPreview {
            lines.append("Byte length: \(dataPreview.count)")
        }
        return DurableStoreIssue(
            storeID: storeID,
            storeName: storeName,
            filePath: fileURL.path,
            kind: kind,
            summary: summary,
            technicalDetails: lines.joined(separator: "\n"),
            observedModificationDate: observation.modificationDate,
            observedFileSize: observation.fileSize,
            observedContentFingerprint: observation.fingerprint
        )
    }
}
