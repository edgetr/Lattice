import Foundation

/// Atomic ownership for one interactive provider run per Lattice session.
///
/// Every mutable field belongs to an owner token. Cleanup from an older run can
/// observe its own cancellation, but cannot erase a replacement run's process,
/// input, provider IDs, or pending permission IDs.
final class InteractiveProcessRegistry: @unchecked Sendable {
    struct Owner: Sendable, Hashable {
        fileprivate let token: UUID
    }

    struct StartToken: Sendable, Hashable {
        fileprivate let token: UUID
    }

    struct Metadata: Sendable, Equatable {
        var threadID: String?
        var turnID: String?
        var providerSessionID: String?
        var pendingPermissionIDs: Set<UUID> = []
    }

    enum RegistrationResult {
        case accepted(Owner)
        case cancelled
    }

    struct CancellationTarget: @unchecked Sendable {
        let owner: Owner?
        let process: BoundedProcessTransport?
        let input: FileHandle?
        let metadata: Metadata
    }

    struct UnregistrationResult: Sendable, Equatable {
        let removedCurrentOwner: Bool
        let wasCancelled: Bool
        let metadata: Metadata
    }

    private struct Entry {
        let owner: Owner
        let process: BoundedProcessTransport
        let input: FileHandle?
        var metadata: Metadata
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    private var cancelledOwners: Set<Owner> = []
    private var starts: [UUID: StartToken] = [:]
    private var cancelledStarts: Set<StartToken> = []

    func beginStart(for sessionID: UUID) -> StartToken {
        lock.lock()
        defer { lock.unlock() }
        let token = StartToken(token: UUID())
        if let stale = starts.updateValue(token, forKey: sessionID) {
            cancelledStarts.remove(stale)
        }
        return token
    }

    func abandonStart(_ token: StartToken, sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasCancelled = cancelledStarts.remove(token) != nil
        if starts[sessionID] == token { starts[sessionID] = nil }
        return wasCancelled
    }

    func register(
        process: BoundedProcessTransport,
        input: FileHandle?,
        for sessionID: UUID,
        start: StartToken
    ) -> RegistrationResult {
        lock.lock()
        guard starts[sessionID] == start else {
            lock.unlock()
            return .cancelled
        }
        starts[sessionID] = nil
        if cancelledStarts.remove(start) != nil {
            lock.unlock()
            return .cancelled
        }
        let previous = entries[sessionID]
        let owner = Owner(token: UUID())
        entries[sessionID] = Entry(
            owner: owner,
            process: process,
            input: input,
            metadata: Metadata()
        )
        lock.unlock()

        // Replacement is accepted immediately. Its predecessor is cancelled
        // outside the registry lock and stale cleanup is owner-token guarded.
        previous?.process.cancel()
        return .accepted(owner)
    }

    func cancel(sessionID: UUID) -> CancellationTarget {
        lock.lock()
        let entry = entries[sessionID]
        if let entry {
            cancelledOwners.insert(entry.owner)
        } else if let start = starts[sessionID] {
            // Token scoping prevents this from cancelling a later unrelated run.
            cancelledStarts.insert(start)
        }
        lock.unlock()
        return CancellationTarget(
            owner: entry?.owner,
            process: entry?.process,
            input: entry?.input,
            metadata: entry?.metadata ?? Metadata()
        )
    }

    func isCancelled(_ owner: Owner?, sessionID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let owner { return cancelledOwners.contains(owner) }
        guard entries[sessionID] == nil, let start = starts[sessionID] else { return false }
        return cancelledStarts.contains(start)
    }

    @discardableResult
    func updateMetadata(
        _ owner: Owner,
        sessionID: UUID,
        _ update: (inout Metadata) -> Void
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[sessionID], entry.owner == owner else { return false }
        update(&entry.metadata)
        entries[sessionID] = entry
        return true
    }

    func metadata(for owner: Owner, sessionID: UUID) -> Metadata? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[sessionID], entry.owner == owner else { return nil }
        return entry.metadata
    }

    func unregister(_ owner: Owner, sessionID: UUID) -> UnregistrationResult {
        lock.lock()
        defer { lock.unlock() }
        let wasCancelled = cancelledOwners.remove(owner) != nil
        guard let entry = entries[sessionID], entry.owner == owner else {
            return UnregistrationResult(
                removedCurrentOwner: false,
                wasCancelled: wasCancelled,
                metadata: Metadata()
            )
        }
        entries[sessionID] = nil
        return UnregistrationResult(
            removedCurrentOwner: true,
            wasCancelled: wasCancelled,
            metadata: entry.metadata
        )
    }

}
