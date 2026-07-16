import Foundation

/// Exclusive session lock for shared Code session catalogs (desktop + future Lattice Terminal).
///
/// v1 sync model: shared Application Support disk + exclusive lock. Not live dual control.
/// Scope is Code sessions only. Grok/Antigravity native harnesses are out of scope.
///
/// **Not wired into desktop Code runs yet.** This type is a Terminal seam marker:
/// acquire/release will attach when Lattice Terminal ships. Do not claim dual-surface
/// exclusivity in product UI until desktop + Terminal both call `acquire`/`release`.
/// Current acquire is best-effort atomic write (TOCTOU under concurrent acquirers);
/// upgrade to `O_EXCL`/`flock` when wiring live dual surfaces.
public enum LatticeCodeSessionLock {
    public static let productSurface = "Lattice Terminal"
    public static let lockFileName = ".lattice-code-session.lock"
    public static let notesFileName = "LATTICE_TERMINAL_NOTES.md"

    public struct Holder: Equatable, Codable, Sendable {
        public let sessionID: UUID
        public let owner: String
        public let pid: Int32
        public let acquiredAt: Date

        public init(sessionID: UUID, owner: String, pid: Int32 = ProcessInfo.processInfo.processIdentifier, acquiredAt: Date = .now) {
            self.sessionID = sessionID
            self.owner = owner
            self.pid = pid
            self.acquiredAt = acquiredAt
        }
    }

    public enum Error: LocalizedError, Equatable, Sendable {
        case alreadyHeld(by: Holder)
        case invalidSession
        case io(String)

        public var errorDescription: String? {
            switch self {
            case .alreadyHeld(let holder):
                "Code session is locked by \(holder.owner) (pid \(holder.pid)). Close that surface before taking exclusive control."
            case .invalidSession:
                "Session id is required for a Code session lock."
            case .io(let message):
                message
            }
        }
    }

    /// Directory for a Code session lock: under Application Support HarnessSessions/CodeLocks/<session>.
    public static func lockDirectory(sessionID: UUID, applicationSupport: URL? = nil) -> URL {
        let root = applicationSupport
            ?? LatticeApplicationSupport.productRootURL()
        return root
            .appendingPathComponent("HarnessSessions", isDirectory: true)
            .appendingPathComponent("CodeLocks", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString.lowercased(), isDirectory: true)
    }

    public static func lockFileURL(sessionID: UUID, applicationSupport: URL? = nil) -> URL {
        lockDirectory(sessionID: sessionID, applicationSupport: applicationSupport)
            .appendingPathComponent(lockFileName)
    }

    public static func read(sessionID: UUID, applicationSupport: URL? = nil) -> Holder? {
        let url = lockFileURL(sessionID: sessionID, applicationSupport: applicationSupport)
        guard let data = try? Data(contentsOf: url),
              let holder = try? JSONDecoder().decode(Holder.self, from: data) else { return nil }
        return holder
    }

    /// Attempt exclusive acquire. Fails if another live owner holds the lock.
    /// Stale same-machine locks from dead PIDs are replaced.
    public static func acquire(
        sessionID: UUID,
        owner: String,
        applicationSupport: URL? = nil,
        isProcessAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) throws -> Holder {
        let dir = lockDirectory(sessionID: sessionID, applicationSupport: applicationSupport)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(lockFileName)
        let selfPID = ProcessInfo.processInfo.processIdentifier
        if let existing = read(sessionID: sessionID, applicationSupport: applicationSupport) {
            // Same owner + same pid re-enters successfully.
            if existing.owner == owner && existing.pid == selfPID {
                return existing
            }
            // Another live holder (including same process, different surface name) blocks acquire.
            let holderAlive = existing.pid == selfPID || isProcessAlive(existing.pid)
            if holderAlive {
                throw Error.alreadyHeld(by: existing)
            }
            // Stale lock from a dead pid may be replaced.
        }
        let holder = Holder(sessionID: sessionID, owner: owner)
        let data = try JSONEncoder().encode(holder)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return holder
    }

    public static func release(
        sessionID: UUID,
        owner: String,
        applicationSupport: URL? = nil
    ) throws {
        guard let existing = read(sessionID: sessionID, applicationSupport: applicationSupport) else { return }
        guard existing.owner == owner || existing.pid == ProcessInfo.processInfo.processIdentifier else {
            throw Error.alreadyHeld(by: existing)
        }
        let url = lockFileURL(sessionID: sessionID, applicationSupport: applicationSupport)
        try? FileManager.default.removeItem(at: url)
    }

    /// Short notes file documenting the Terminal sync contract for future work.
    public static func ensureNotes(applicationSupport: URL? = nil) throws {
        let root = applicationSupport ?? LatticeApplicationSupport.productRootURL()
        let dir = root.appendingPathComponent("HarnessSessions/CodeLocks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let notes = dir.appendingPathComponent(notesFileName)
        guard !FileManager.default.fileExists(atPath: notes.path) else { return }
        let body = """
        # Lattice Terminal session sync (v1)

        - Same Lattice Agent binary and Application Support profile as desktop Code mode.
        - Sync model: shared session catalog on disk + exclusive session lock (`\(lockFileName)`).
        - Not live dual control: only one surface holds a session lock at a time.
        - Scope: Code · Lattice Agent chats only. Grok and Antigravity remain native desktop harnesses.
        - Future: optional Lattice Terminal CLI/TUI that reuses this lock and session store.

        This file is a seam marker, not a runtime protocol.
        """
        try Data(body.utf8).write(to: notes, options: .atomic)
    }
}
