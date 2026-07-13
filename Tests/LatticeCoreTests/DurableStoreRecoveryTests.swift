import Testing
import Foundation
@testable import LatticeCore

@Suite("Durable store recovery")
struct DurableStoreRecoveryTests {
    // MARK: - Load classification

    @Test func missingStoreIsNormalEmptyState() {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sessions.json")
        let result = DurableStoreRecovery.loadJSONArray(
            from: url,
            as: LatticeSession.self,
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName
        )
        if case .missing = result {
            #expect(true)
        } else {
            Issue.record("Absent file must be .missing, not a recovery failure")
        }
        let store = SessionPersistence(fileURL: url)
        #expect(store.load().isEmpty)
    }

    @Test func corruptJSONIsFailedCorruptNotEmptySuccess() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sessions.json")
        let corrupt = Data("{not-json".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try corrupt.write(to: url)

        let store = SessionPersistence(fileURL: url)
        switch store.loadResult() {
        case .failed(let issue):
            #expect(issue.kind == .corrupt)
            #expect(issue.storeID == SessionPersistence.storeID)
            #expect(issue.filePath == url.path)
            #expect(!issue.summary.isEmpty)
            #expect(issue.technicalDetails.contains("Path:"))
            #expect(issue.observedContentFingerprint == DurableStoreRecovery.contentFingerprint(for: corrupt))
            #expect((try Data(contentsOf: url)) == corrupt)
        case .missing, .loaded:
            Issue.record("Corrupt JSON must surface as .failed(.corrupt)")
        }
        // Compatibility load still returns empty without mutating the file.
        #expect(store.load().isEmpty)
        #expect((try Data(contentsOf: url)) == corrupt)
    }

    @Test func unreadablePermissionErrorUsesInjectableReader() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sessions.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: url)

        let permissionError = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EACCES),
            userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
        )
        let io = DurableStoreFileIO(
            fileExists: { _ in true },
            attributesOfItem: { _ in [.size: 2, .modificationDate: Date(timeIntervalSince1970: 100)] },
            readData: { _ in throw permissionError }
        )
        let store = SessionPersistence(fileURL: url, io: io)
        switch store.loadResult() {
        case .failed(let issue):
            #expect(issue.kind == .unreadable)
            #expect(issue.technicalDetails.contains("NSPOSIXErrorDomain") || issue.technicalDetails.contains("\(Int(EACCES))"))
            #expect(issue.observedFileSize == 2)
        case .missing, .loaded:
            Issue.record("Permission denial must surface as .failed(.unreadable)")
        }
    }

    @Test func inaccessiblePathIsNotMistakenForMissingWhenExistenceProbeFails() {
        let url = URL(fileURLWithPath: "/protected/Lattice/sessions.json")
        let permissionError = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EACCES),
            userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
        )
        let io = DurableStoreFileIO(
            fileExists: { _ in false },
            attributesOfItem: { _ in throw permissionError },
            readData: { _ in throw permissionError }
        )

        switch DurableStoreRecovery.loadJSONArray(
            from: url,
            as: LatticeSession.self,
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName,
            io: io
        ) {
        case .failed(let issue):
            #expect(issue.kind == .unreadable)
        case .missing, .loaded:
            Issue.record("An inaccessible path must not be treated as missing")
        }
    }

    @Test func cocoaPermissionErrorIsUnreadable() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, userInfo: nil)
        #expect(DurableStoreRecovery.isUnreadableError(error))
        #expect(!DurableStoreRecovery.isNotFoundError(error))
    }

    // MARK: - Self-edit stores

    @Test func selfEditJobsAndPreviewsReportCorruptIndependently() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jobsURL = root.appendingPathComponent("self-edit-jobs.json")
        let previewsURL = root.appendingPathComponent("self-edit-previews.json")
        let corrupt = Data("not-json".utf8)
        try corrupt.write(to: jobsURL)
        try corrupt.write(to: previewsURL)

        let jobStore = LatticeExtensionJobStore(fileURL: jobsURL)
        let previewStore = LatticeExtensionPreviewStore(fileURL: previewsURL)

        if case .failed(let jobIssue) = jobStore.loadResult() {
            #expect(jobIssue.kind == .corrupt)
            #expect(jobIssue.storeID == LatticeExtensionJobStore.storeID)
        } else {
            Issue.record("Jobs corrupt load must fail")
        }
        if case .failed(let previewIssue) = previewStore.loadResult() {
            #expect(previewIssue.kind == .corrupt)
            #expect(previewIssue.storeID == LatticeExtensionPreviewStore.storeID)
        } else {
            Issue.record("Previews corrupt load must fail")
        }
        #expect((try Data(contentsOf: jobsURL)) == corrupt)
        #expect((try Data(contentsOf: previewsURL)) == corrupt)
    }

    @Test func selfEditJobLegacyDecodeStillWorksViaLoadResult() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let jobsURL = root.appendingPathComponent("self-edit-jobs.json")
        let job = LatticeExtensionJobRecord(
            sessionID: UUID(),
            harnessThreadID: nil,
            request: "warm",
            manifestID: "com.lattice.theme",
            manifestName: "Theme",
            summary: "Warm theme",
            previousManifestData: nil
        )
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        object.removeValue(forKey: "previousEnabled")
        object.removeValue(forKey: "previousSkillSnapshots")
        object.removeValue(forKey: "previousDisabledSkillIDs")
        object.removeValue(forKey: "appliedManifestData")
        object.removeValue(forKey: "appliedSkillSnapshots")
        object.removeValue(forKey: "appliedEnabled")
        let data = try JSONSerialization.data(withJSONObject: [object])
        try data.write(to: jobsURL)

        let store = LatticeExtensionJobStore(fileURL: jobsURL)
        switch store.loadResult() {
        case .loaded(let records):
            #expect(records.count == 1)
            #expect(records.first?.previousEnabled == nil)
            #expect(records.first?.previousSkillSnapshots.isEmpty == true)
        case .missing, .failed:
            Issue.record("Legacy job JSON must still decode")
        }
    }

    // MARK: - Write gate

    @Test func writeGateBlocksSaveUntilUnblocked() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sessions.json")
        let gate = DurableStoreWriteGate()
        let store = SessionPersistence(fileURL: url, writeGate: gate)
        gate.block()
        do {
            try store.save([])
            Issue.record("Blocked gate must refuse save")
        } catch DurableStoreRecoveryError.writeBlocked(let storeName) {
            #expect(storeName == SessionPersistence.storeName)
        } catch {
            Issue.record("Expected writeBlocked, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        gate.unblock()
        try store.save([])
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Retry / repair

    @Test func retryAfterExternalRepairLoadsSessionsWithRuntimeRestore() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sessions.json")
        try Data("{bad".utf8).write(to: url)
        let store = SessionPersistence(fileURL: url)
        guard case .failed = store.loadResult() else {
            Issue.record("Expected initial corrupt failure")
            return
        }

        let response = ChatMessage(role: .assistant, text: "Partial")
        let action = SessionAction(
            messageID: response.id,
            kind: .tool,
            toolKind: .command,
            title: "Build",
            detail: "$ swift build",
            status: .running
        )
        let session = LatticeSession(
            title: "Recovered",
            messages: [response],
            backend: .codex(model: "gpt-5.4"),
            actions: [action],
            isStreaming: true
        )
        // External repair writes valid JSON without going through the blocked gate.
        let encoder = JSONEncoder()
        try encoder.encode([session]).write(to: url, options: .atomic)

        switch store.loadResult() {
        case .loaded(let sessions):
            #expect(sessions.count == 1)
            #expect(sessions.first?.isStreaming == false)
            #expect(sessions.first?.actions.first?.status == .interrupted)
        case .missing, .failed:
            Issue.record("Repaired file must load successfully")
        }
    }

    // MARK: - Backup / reset

    @Test func backupUsesCollisionSafeSuffixAndNeverReplacesExisting() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sessions.json")
        let original = Data("corrupt-bytes".utf8)
        try original.write(to: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try DurableStoreRecovery.preserveCopy(
            of: url,
            kind: .backup,
            now: now,
            uniqueToken: "aabbccdd-1111-2222-3333-444444444444"
        )
        #expect(first.preservedURL.lastPathComponent.contains(".corrupt-"))
        #expect(first.preservedURL.pathExtension == "backup")
        #expect((try Data(contentsOf: first.preservedURL)) == original)
        #expect((try Data(contentsOf: url)) == original)

        let second = try DurableStoreRecovery.preserveCopy(
            of: url,
            kind: .backup,
            now: now,
            uniqueToken: "aabbccdd-1111-2222-3333-444444444444"
        )
        #expect(second.preservedURL.path != first.preservedURL.path)
        #expect(FileManager.default.fileExists(atPath: first.preservedURL.path))
        #expect((try Data(contentsOf: first.preservedURL)) == original)
        #expect((try Data(contentsOf: second.preservedURL)) == original)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".partial-") }
        #expect(leftovers.isEmpty)
    }

    @Test func resetCreatesVerifiedBackupThenEmptyArray() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("self-edit-jobs.json")
        let original = Data("[{\"broken\":true".utf8)
        try original.write(to: url)

        let result = try DurableStoreRecovery.resetReplacingWithEmptyArray(at: url)
        #expect(FileManager.default.fileExists(atPath: result.preservedURL.path))
        #expect((try Data(contentsOf: result.preservedURL)) == original)
        let replaced = try Data(contentsOf: url)
        #expect(String(data: replaced, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "[]")

        let store = LatticeExtensionJobStore(fileURL: url)
        if case .loaded(let jobs) = store.loadResult() {
            #expect(jobs.isEmpty)
        } else {
            Issue.record("Reset store must load as empty array")
        }
    }

    @Test func resetFailsWithoutTouchingOriginalWhenBackupCannotBeCreated() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sessions.json")
        let original = Data("keep-me".utf8)
        try original.write(to: url)

        let copyFailure = NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: [NSLocalizedDescriptionKey: "I/O error"])
        let io = DurableStoreFileIO(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            attributesOfItem: { try FileManager.default.attributesOfItem(atPath: $0) },
            readData: { try Data(contentsOf: $0) },
            writeDataAtomically: { data, destination in try data.write(to: destination, options: .atomic) },
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            copyItem: { _, _ in throw copyFailure },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            replaceItem: { original, replacement in
                _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement)
            }
        )

        do {
            _ = try DurableStoreRecovery.resetReplacingWithEmptyArray(at: url, io: io)
            Issue.record("Reset must fail when backup cannot be created")
        } catch DurableStoreRecoveryError.resetFailed(let message) {
            #expect(message == "Reset aborted because a backup could not be created. Original left unchanged. Could not create a quarantine of sessions.json: I/O error")
            #expect((try Data(contentsOf: url)) == original)
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.contains(".partial-") }
            #expect(leftovers.isEmpty)
        } catch {
            Issue.record("Expected resetFailed for backup failure, got \(error)")
        }
    }

    @Test func resetFailsWithoutTouchingOriginalWhenBackupCannotBeVerified() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sessions.json")
        let original = Data("keep-unverified".utf8)
        try original.write(to: url)
        let verificationFailure = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EIO),
            userInfo: [NSLocalizedDescriptionKey: "Verification read failed"]
        )
        let io = DurableStoreFileIO(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            attributesOfItem: { try FileManager.default.attributesOfItem(atPath: $0) },
            readData: { source in
                if source.lastPathComponent.contains(".partial-") { throw verificationFailure }
                return try Data(contentsOf: source)
            },
            writeDataAtomically: { data, destination in try data.write(to: destination, options: .atomic) },
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            replaceItem: { original, replacement in
                _ = try FileManager.default.replaceItemAt(original, withItemAt: replacement)
            }
        )

        do {
            _ = try DurableStoreRecovery.resetReplacingWithEmptyArray(at: url, io: io)
            Issue.record("Reset must fail when the preservation copy cannot be verified")
        } catch DurableStoreRecoveryError.resetFailed(let message) {
            #expect(message.contains("Reset aborted because a backup could not be created."))
            #expect(message.contains("Verification read failed"))
            #expect((try Data(contentsOf: url)) == original)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(!remaining.contains { $0.hasSuffix(".backup") })
            #expect(!remaining.contains { $0.contains(".partial-") })
        } catch {
            Issue.record("Expected resetFailed for backup verification failure, got \(error)")
        }
    }

    @Test func resetRecoversAfterReplacementFailureWithoutLosingVerifiedBackup() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sessions.json")
        let original = Data("preserve-before-replace-failure".utf8)
        try original.write(to: url)

        let replacementFailure = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EIO),
            userInfo: [NSLocalizedDescriptionKey: "Replacement failed"]
        )
        let io = DurableStoreFileIO(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            attributesOfItem: { try FileManager.default.attributesOfItem(atPath: $0) },
            readData: { try Data(contentsOf: $0) },
            writeDataAtomically: { data, destination in try data.write(to: destination, options: .atomic) },
            createDirectory: { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) },
            copyItem: { try FileManager.default.copyItem(at: $0, to: $1) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            removeItem: { try FileManager.default.removeItem(at: $0) },
            replaceItem: { _, _ in throw replacementFailure }
        )

        do {
            _ = try DurableStoreRecovery.resetReplacingWithEmptyArray(at: url, io: io)
            Issue.record("Reset must fail when replacing the original fails")
        } catch DurableStoreRecoveryError.resetFailed(let message) {
            #expect(message.contains("replacing the original failed"))
            #expect(message.contains("Replacement failed"))
        } catch {
            Issue.record("Expected resetFailed for replacement failure, got \(error)")
        }

        #expect((try Data(contentsOf: url)) == original)
        let backups = try FileManager.default.contentsOfDirectory(at: root.path)
            .filter { $0.hasSuffix(".backup") }
        #expect(backups.count == 1)
        if let backup = backups.first {
            #expect((try Data(contentsOf: root.appendingPathComponent(backup))) == original)
        }
        let temporaryFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".tmp-") || $0.contains(".partial-") }
        #expect(temporaryFiles.isEmpty)

        try DurableStoreRecovery.resetReplacingWithEmptyArray(at: url)
        #expect(String(data: try Data(contentsOf: url), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "[]")
    }

    @Test func staleSourceProtectionRejectsResetWhenFileChanged() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sessions.json")
        try Data("version-1".utf8).write(to: url)

        let issue: DurableStoreIssue
        switch DurableStoreRecovery.loadJSONArray(
            from: url,
            as: LatticeSession.self,
            storeID: "sessions",
            storeName: "Chat sessions"
        ) {
        case .failed(let failed):
            issue = failed
        default:
            Issue.record("Expected corrupt issue for fingerprint capture")
            return
        }

        // External change after failure observation.
        try Data("version-2-changed".utf8).write(to: url)
        do {
            _ = try DurableStoreRecovery.resetReplacingWithEmptyArray(at: url, expected: issue)
            Issue.record("Stale source must reject reset")
        } catch DurableStoreRecoveryError.sourceChanged {
            #expect((try String(contentsOf: url, encoding: .utf8)) == "version-2-changed")
        } catch {
            Issue.record("Expected sourceChanged, got \(error)")
        }
    }

    @Test func resetOfObservedFailureRefusesWhenOriginalDisappeared() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sessions.json")
        try Data("corrupt".utf8).write(to: url)

        guard case .failed(let issue) = DurableStoreRecovery.loadJSONArray(
            from: url,
            as: LatticeSession.self,
            storeID: SessionPersistence.storeID,
            storeName: SessionPersistence.storeName
        ) else {
            Issue.record("Expected an observed corrupt store")
            return
        }
        try FileManager.default.removeItem(at: url)

        do {
            _ = try DurableStoreRecovery.resetReplacingWithEmptyArray(at: url, expected: issue)
            Issue.record("Reset must not claim preservation after the observed original disappeared")
        } catch DurableStoreRecoveryError.sourceMissing {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        } catch {
            Issue.record("Expected sourceMissing, got \(error)")
        }
    }

    @Test func exportRefusesExistingDestinationAndLeavesSourceUntouched() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("sessions.json")
        let destination = root.appendingPathComponent("export.json")
        let original = Data("export-me".utf8)
        try original.write(to: source)
        try Data("already-there".utf8).write(to: destination)

        do {
            try DurableStoreRecovery.exportCopy(of: source, to: destination)
            Issue.record("Export must refuse existing destination")
        } catch DurableStoreRecoveryError.destinationExists {
            #expect((try Data(contentsOf: source)) == original)
            #expect((try String(contentsOf: destination, encoding: .utf8)) == "already-there")
        } catch {
            Issue.record("Expected destinationExists, got \(error)")
        }

        let freeDestination = root.appendingPathComponent("export-free.json")
        try DurableStoreRecovery.exportCopy(of: source, to: freeDestination)
        #expect((try Data(contentsOf: freeDestination)) == original)
        #expect((try Data(contentsOf: source)) == original)
    }

    @Test func sessionRoundTripStillUsesCompatibilityLoad() throws {
        let root = uniqueTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let session = LatticeSession(title: "OK", backend: .codex(model: "gpt-5.4"), isPinned: true)
        try store.save([session])
        #expect(store.load() == [session])
        if case .loaded(let sessions) = store.loadResult() {
            #expect(sessions == [session])
        } else {
            Issue.record("Healthy store must load via loadResult")
        }
    }

    // MARK: - Helpers

    private func uniqueTempRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lattice-recovery-\(UUID().uuidString)", isDirectory: true)
    }
}
