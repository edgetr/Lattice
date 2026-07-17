import Foundation
import Testing
@testable import LatticeCore

@Suite("Runtime provider handle persistence")
struct RuntimeHandlePersistenceTests {
    private func uniqueRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-runtime-handles-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func sessionHandleIsStrippedFromLegacyDecodeAndReencode() throws {
        let sessionID = UUID()
        var legacyObject = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(LatticeSession(id: sessionID, title: "Legacy", backend: .ollama(model: "qwen3:8b")))
            ) as? [String: Any]
        )
        legacyObject["harnessThreadID"] = "provider-secret-thread"
        let legacy = try JSONSerialization.data(withJSONObject: [legacyObject])
        let sessions = try JSONDecoder().decode([LatticeSession].self, from: legacy)
        #expect(sessions.first?.harnessThreadID == nil)
        let encoded = String(decoding: try JSONEncoder().encode(sessions), as: UTF8.self)
        #expect(!encoded.contains("harnessThreadID"))
        #expect(!encoded.contains("provider-secret-thread"))
    }

    @Test func extensionRecordsStripLegacyHandlesOnReencode() throws {
        let sessionID = UUID()
        let job = LatticeExtensionJobRecord(
            sessionID: sessionID,
            harnessThreadID: "runtime-thread",
            request: "Apply theme",
            manifestID: "com.example.theme",
            manifestName: "Theme",
            summary: "Theme",
            previousManifestData: nil
        )
        let encodedJob = String(decoding: try JSONEncoder().encode(job), as: UTF8.self)
        #expect(!encodedJob.contains("harnessThreadID"))
        #expect(!encodedJob.contains("runtime-thread"))

        let legacy = encodedJob.replacingOccurrences(of: "\"request\"", with: "\"harnessThreadID\":\"legacy-thread\",\"request\"")
        let decoded = try JSONDecoder().decode(LatticeExtensionJobRecord.self, from: Data(legacy.utf8))
        #expect(decoded.harnessThreadID == nil)
        #expect(!String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("legacy-thread"))
    }

    @Test func previewRecordStripsLegacyHandleOnDecodeAndReencode() throws {
        let preview = LatticeExtensionPreviewRecord(
            sessionID: UUID(),
            harnessThreadID: "runtime-preview-thread",
            request: "Apply theme",
            manifest: LatticeExtensionManifest(id: "com.example.theme", name: "Theme", version: "1", summary: "Theme"),
            previousManifestData: nil
        )
        let encoded = String(decoding: try JSONEncoder().encode(preview), as: UTF8.self)
        #expect(!encoded.contains("harnessThreadID"))
        let legacy = encoded.replacingOccurrences(of: "\"request\"", with: "\"harnessThreadID\":\"legacy-preview-thread\",\"request\"")
        let decoded = try JSONDecoder().decode(LatticeExtensionPreviewRecord.self, from: Data(legacy.utf8))
        #expect(decoded.harnessThreadID == nil)
        #expect(!String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self).contains("legacy-preview-thread"))
    }

    @Test func sessionPersistenceBytesAndLoadNeverPersistOrReviveHandle() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let action = SessionAction(
            messageID: UUID(),
            kind: .harness,
            title: "Antigravity session",
            detail: #"{"type":"init","session_id":"antigravity-session-secret"}"#,
            status: .completed
        )
        let session = LatticeSession(
            title: "Runtime",
            backend: .ollama(model: "qwen3:8b"),
            harnessThreadID: "provider-session-secret",
            actions: [action]
        )
        try store.save([session])
        let raw = String(decoding: try Data(contentsOf: store.fileURL), as: UTF8.self)
        #expect(!raw.contains("harnessThreadID"))
        #expect(!raw.contains("provider-session-secret"))
        #expect(!raw.contains("antigravity-session-secret"))
        #expect(try store.load().first?.harnessThreadID == nil)
        #expect(try store.load().first?.actions.first?.detail.contains("[REDACTED]") == true)
    }

    @Test func extensionStoresBytesAndLoadNeverPersistOrReviveHandles() throws {
        let root = try uniqueRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = LatticeExtensionJobRecord(
            sessionID: UUID(),
            harnessThreadID: "provider-job-secret",
            request: "Apply theme",
            manifestID: "com.example.theme",
            manifestName: "Theme",
            summary: "Theme",
            previousManifestData: nil
        )
        let manifest = LatticeExtensionManifest(id: "com.example.theme", name: "Theme", version: "1", summary: "Theme")
        let preview = LatticeExtensionPreviewRecord(
            sessionID: job.sessionID ?? UUID(),
            harnessThreadID: "provider-preview-secret",
            request: "Apply theme",
            manifest: manifest,
            previousManifestData: nil
        )
        let jobStore = LatticeExtensionJobStore(fileURL: root.appendingPathComponent("jobs.json"))
        let previewStore = LatticeExtensionPreviewStore(fileURL: root.appendingPathComponent("previews.json"))
        try jobStore.save([job])
        try previewStore.save([preview])
        let jobRaw = String(decoding: try Data(contentsOf: jobStore.fileURL), as: UTF8.self)
        let previewRaw = String(decoding: try Data(contentsOf: previewStore.fileURL), as: UTF8.self)
        #expect(!jobRaw.contains("harnessThreadID"))
        #expect(!jobRaw.contains("provider-job-secret"))
        #expect(!previewRaw.contains("harnessThreadID"))
        #expect(!previewRaw.contains("provider-preview-secret"))
        #expect(jobStore.load().first?.harnessThreadID == nil)
        #expect(previewStore.load().first?.harnessThreadID == nil)
    }
}
