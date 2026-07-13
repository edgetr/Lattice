import Foundation

// MARK: - Snapshot / fingerprint

/// Observation of a JSON object file used for conflict detection across read-modify-write.
///
/// Marked `@unchecked Sendable` because JSON object graphs use `[String: Any]` (Foundation
/// JSONSerialization) which is not statically Sendable; callers treat snapshots as
/// value-owned after read and do not share mutable references across isolation domains.
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

    /// Structural equality of conflict-relevant fields (object identity is not compared).
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
    case conflict
    case failure(String)

    public var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

// MARK: - Transaction helper

/// Conflict-aware atomic replacement of a JSON object file.
///
/// - Same-directory unique temporary file
/// - Mode `0600` before publish
/// - `replaceItemAt` / move for atomic replacement
/// - Does **not** treat malformed JSON as an empty object
public enum AtomicJSONFileTransaction {
    public static let defaultMaxAttempts = 5

    /// Reads a JSON object file. Missing file → empty object snapshot (`exists: false`).
    /// Malformed / non-object content fails closed (never coerced to `[:]`).
    public static func readObject(at url: URL) -> Result<JSONFileSnapshot, AtomicJSONFileReadError> {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return .success(JSONFileSnapshot(exists: false, object: [:]))
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let modificationDate = attributes?[.modificationDate] as? Date
        let fileSize = attributes?[.size] as? Int ?? data.count
        let fingerprint = fingerprint(for: data)

        guard !data.isEmpty else {
            // Empty file is malformed for an object store (not a valid JSON object).
            return .failure(.malformedJSON)
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return .failure(.malformedJSON)
        }
        guard let object = root as? [String: Any] else {
            return .failure(.notAJSONObject)
        }
        return .success(JSONFileSnapshot(
            exists: true,
            modificationDate: modificationDate,
            fileSize: fileSize,
            contentFingerprint: fingerprint,
            object: object
        ))
    }

    /// Applies `mutate` to the current object and publishes via temp + atomic replace.
    /// On concurrent modification (fingerprint / mtime / size change), re-reads and retries
    /// up to `maxAttempts`, re-applying `mutate` against the latest object each time so
    /// unknown/unrelated fields from concurrent writers can be preserved.
    public static func mutateObject(
        at url: URL,
        maxAttempts: Int = defaultMaxAttempts,
        mutate: (_ root: inout [String: Any]) throws -> Void
    ) -> AtomicJSONFileWriteResult {
        let attempts = max(1, maxAttempts)
        for _ in 0..<attempts {
            let read = readObject(at: url)
            let baseline: JSONFileSnapshot
            switch read {
            case .failure(let error):
                return .failure(error.message)
            case .success(let snapshot):
                baseline = snapshot
            }

            var root = baseline.object ?? [:]
            do {
                try mutate(&root)
            } catch {
                return .failure(error.localizedDescription)
            }

            let write = writeObject(root, to: url, expected: baseline)
            switch write {
            case .success, .failure:
                return write
            case .conflict:
                continue
            }
        }
        return .conflict
    }

    /// Writes `root` only when the on-disk fingerprint still matches `expected`.
    /// Missing expected file vs existing file (or vice versa) is a conflict.
    public static func writeObject(
        _ root: [String: Any],
        to url: URL,
        expected: JSONFileSnapshot
    ) -> AtomicJSONFileWriteResult {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()

        // Conflict check before staging.
        if let conflict = conflictMessage(at: url, expected: expected) {
            return conflict == "conflict" ? .conflict : .failure(conflict)
        }

        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        } catch {
            return .failure("Failed to encode JSON: \(error.localizedDescription)")
        }

        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            return .failure("Failed to create parent directory: \(error.localizedDescription)")
        }

        let temporary = parent.appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString)"
        )
        do {
            // Create exclusive temp file, write, set 0600, then atomic replace.
            let created = fm.createFile(
                atPath: temporary.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
            guard created else {
                return .failure("Failed to create temporary file.")
            }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.close()
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

            // Re-check conflict immediately before publish.
            if let conflict = conflictMessage(at: url, expected: expected) {
                try? fm.removeItem(at: temporary)
                return conflict == "conflict" ? .conflict : .failure(conflict)
            }

            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fm.moveItem(at: temporary, to: url)
            }
            // replaceItemAt consumes the temp item; clean up if anything remains.
            if fm.fileExists(atPath: temporary.path) {
                try? fm.removeItem(at: temporary)
            }
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return .success
        } catch {
            try? fm.removeItem(at: temporary)
            return .failure(error.localizedDescription)
        }
    }

    public static func fingerprint(for data: Data) -> String {
        // Lightweight stable fingerprint; not a security digest.
        var hash: UInt64 = 5381
        for byte in data {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return String(hash, radix: 16) + ":\(data.count)"
    }

    // MARK: Private

    private static func conflictMessage(at url: URL, expected: JSONFileSnapshot) -> String? {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        if exists != expected.exists {
            return "conflict"
        }
        guard exists else { return nil }

        let attributes = try? fm.attributesOfItem(atPath: url.path)
        let modificationDate = attributes?[.modificationDate] as? Date
        let fileSize = attributes?[.size] as? Int
        let data = try? Data(contentsOf: url)
        let fingerprint = data.map(Self.fingerprint(for:))

        if let expectedSize = expected.fileSize, fileSize != expectedSize {
            return "conflict"
        }
        if let expectedFingerprint = expected.contentFingerprint,
           fingerprint != expectedFingerprint {
            return "conflict"
        }
        if let expectedDate = expected.modificationDate {
            guard let modificationDate,
                  abs(expectedDate.timeIntervalSince(modificationDate)) <= 0.001 else {
                return "conflict"
            }
        }
        return nil
    }
}
