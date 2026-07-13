import Foundation

public struct SessionPersistence: Sendable {
    public static let storeID = "sessions"
    public static let storeName = "Chat sessions"
    public static let fileName = "sessions.json"

    public let fileURL: URL
    public let writeGate: DurableStoreWriteGate
    public let io: DurableStoreFileIO

    public init(
        fileURL: URL? = nil,
        writeGate: DurableStoreWriteGate = DurableStoreWriteGate(),
        io: DurableStoreFileIO = .default
    ) {
        self.writeGate = writeGate
        self.io = io
        if let fileURL {
            self.fileURL = fileURL
            return
        }
        if let overridePath = LatticeApplicationSupport.sessionStoreOverridePath() {
            self.fileURL = URL(fileURLWithPath: overridePath)
            return
        }
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        self.fileURL = LatticeApplicationSupport.productRootURL().appendingPathComponent(Self.fileName)
    }

    /// Evidence-rich load API. Missing storage is the normal empty state; corrupt/unreadable files fail without mutation.
    public func loadResult() -> DurableStoreLoadResult<[LatticeSession]> {
        switch DurableStoreRecovery.loadJSONArray(
            from: fileURL,
            as: LatticeSession.self,
            storeID: Self.storeID,
            storeName: Self.storeName,
            io: io
        ) {
        case .missing:
            return .missing
        case .failed(let issue):
            return .failed(issue)
        case .loaded(let sessions):
            return .loaded(Self.restoreRuntimeState(sessions))
        }
    }

    /// Compatibility loader for callers/tests that only need success/missing-empty behavior.
    /// Production AppState must use `loadResult()` so failures cannot be silently overwritten.
    public func load() -> [LatticeSession] {
        switch loadResult() {
        case .loaded(let sessions):
            return sessions
        case .missing, .failed:
            return []
        }
    }

    public func save(_ sessions: [LatticeSession]) throws {
        try DurableStoreRecovery.enforceWritable(gate: writeGate, storeName: Self.storeName)
        try io.createDirectory(fileURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try io.writeDataAtomically(try encoder.encode(sessions), fileURL)
    }

    public static func restoreRuntimeState(_ sessions: [LatticeSession]) -> [LatticeSession] {
        sessions.map { session in
            var restored = session
            restored.isStreaming = false
            for index in restored.actions.indices where [.running, .waiting].contains(restored.actions[index].status) {
                restored.actions[index].status = .interrupted
                restored.actions[index].updatedAt = .now
            }
            return restored
        }.sorted { $0.lastUpdated > $1.lastUpdated }
    }
}
