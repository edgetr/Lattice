import Foundation
import Testing
@testable import LatticeCore

@Suite("Screenshot / Appshot LatticeCore foundation")
struct ScreenshotCaptureFoundationTests {

    // MARK: - ContextAttachment migration

    @Test func legacyContextAttachmentJSONDecodesWithoutImageMetadata() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","path":"/tmp/note.txt","isMissing":false}
        """
        let decoded = try JSONDecoder().decode(ContextAttachment.self, from: Data(json.utf8))
        #expect(decoded.id == id)
        #expect(decoded.path == "/tmp/note.txt")
        #expect(!decoded.isMissing)
        #expect(decoded.imageMetadata == nil)
        #expect(!decoded.isLatticeManagedCapture)
    }

    @Test func contextAttachmentPathIsMissingDefaultInitializerStillCompiles() {
        let attachment = ContextAttachment(path: "/tmp/shot.png", isMissing: false)
        #expect(attachment.path == "/tmp/shot.png")
        #expect(!attachment.isMissing)
        #expect(attachment.isImage)
        #expect(attachment.imageMetadata == nil)
    }

    @Test func imageMetadataDropsUnauthorizedAccessibilityText() throws {
        let metadata = ContextAttachmentImageMetadata(
            isLatticeManaged: true,
            source: .regionCapture,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            contextMetadataAuthorized: false,
            frontmostApplicationName: "Xcode",
            frontmostApplicationBundleID: "com.apple.dt.Xcode",
            frontmostWindowTitle: "App.swift",
            accessibilityTextAuthorized: false,
            accessibilityText: "SECRET_UI_TREE",
            imageOnlyFallback: .imageOnly(reason: "User did not authorize Accessibility text.")
        )
        #expect(metadata.accessibilityText == nil)
        #expect(metadata.frontmostApplicationName == nil)
        #expect(!metadata.accessibilityTextAuthorized)
        #expect(metadata.imageOnlyFallback.isImageOnly)
        #expect(metadata.isCapture)

        let attachment = ContextAttachment(
            path: "/tmp/captures/a.png",
            imageMetadata: metadata
        )
        let data = try JSONEncoder().encode(attachment)
        let decoded = try JSONDecoder().decode(ContextAttachment.self, from: data)
        #expect(decoded.imageMetadata?.accessibilityText == nil)
        #expect(decoded.imageMetadata?.isLatticeManaged == true)
        #expect(decoded.imageMetadata?.source == .regionCapture)
    }

    @Test func imageMetadataKeepsAuthorizedBoundedAccessibilityText() {
        let long = String(repeating: "a", count: ContextAttachmentImageMetadata.maxAccessibilityTextLength + 50)
        let metadata = ContextAttachmentImageMetadata(
            isLatticeManaged: true,
            source: .windowCapture,
            contextMetadataAuthorized: true,
            accessibilityTextAuthorized: true,
            accessibilityText: long
        )
        #expect(metadata.accessibilityText?.count == ContextAttachmentImageMetadata.maxAccessibilityTextLength)
        #expect(!metadata.imageOnlyFallback.isImageOnly)
    }

    @Test func corruptJSONWithUnauthorizedTextIsStrippedOnDecode() throws {
        let id = UUID()
        let json = """
        {
          "id":"\(id.uuidString)",
          "path":"/tmp/x.png",
          "isMissing":false,
          "imageMetadata":{
            "isLatticeManaged":true,
            "source":"clipboard",
            "accessibilityTextAuthorized":false,
            "accessibilityText":"should-not-survive",
            "imageOnlyFallback":{"isImageOnly":true,"reason":"clipboard image only"}
          }
        }
        """
        let decoded = try JSONDecoder().decode(ContextAttachment.self, from: Data(json.utf8))
        #expect(decoded.imageMetadata?.accessibilityText == nil)
        #expect(decoded.imageMetadata?.source == .clipboard)
        #expect(decoded.imageMetadata?.imageOnlyFallback.isImageOnly == true)
    }

    // MARK: - ProviderModel modalities + transport

    @Test func providerModelMissingModalitiesFailsClosedAsUnknown() throws {
        let json = """
        {"id":"gpt-test","name":"GPT Test","description":"","reasoningOptions":[],"isDefault":false}
        """
        let model = try JSONDecoder().decode(ProviderModel.self, from: Data(json.utf8))
        // Nil means the runtime never advertised modalities; never invent image support.
        #expect(model.inputModalities == nil)
        #expect(!model.acceptsImages)
    }

    @Test func providerModelEmptyModalitiesDoesNotAdvertiseImages() throws {
        let json = """
        {"id":"gpt-test","name":"GPT Test","description":"","reasoningOptions":[],"isDefault":false,"inputModalities":[]}
        """
        let model = try JSONDecoder().decode(ProviderModel.self, from: Data(json.utf8))
        #expect(model.inputModalities?.isEmpty != false || model.inputModalities == [])
        #expect(!model.acceptsImages)
    }

    @Test func providerModelAdvertisedImageModalityRoundTrips() throws {
        let model = ProviderModel(
            id: "vision",
            name: "Vision",
            inputModalities: [.text, .image]
        )
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(ProviderModel.self, from: data)
        #expect(decoded.acceptsImages)
        #expect(decoded.inputModalities == [.text, .image])
    }

    @Test func providerModelMetadataParsesInputModalitiesFailClosed() {
        #expect(ProviderModelMetadata.inputModalities(from: [:]) == [.text])
        #expect(ProviderModelMetadata.inputModalities(from: ["inputModalities": ["text", "image"]]) == [.text, .image])
        #expect(ProviderModelMetadata.inputModalities(from: ["input_modalities": "vision"]) == [.image])
        #expect(ProviderModelMetadata.inputModalities(from: ["inputModalities": ["audio", "video"]]) == [.text])
        #expect(ProviderModelMetadata.inputModalities(from: [
            "capabilities": ["inputModalities": ["IMAGE", "TEXT"]]
        ]) == [.text, .image])
    }

    @Test func attachmentTransportAllowsWhenNoImages() {
        let model = ProviderModel(id: "t", name: "Text")
        let decision = AttachmentTransportPolicy.evaluate(
            attachments: [ContextAttachment(path: "/tmp/a.swift")],
            model: model
        )
        #expect(decision == .allowed)
    }

    @Test func attachmentTransportBlocksImagesWhenNotAdvertised() {
        let model = ProviderModel(id: "t", name: "Text Only")
        let decision = AttachmentTransportPolicy.evaluate(
            attachments: [ContextAttachment(path: "/tmp/shot.png")],
            model: model
        )
        guard case .blocked(let reason) = decision else {
            Issue.record("Images must be blocked when model does not advertise image input")
            return
        }
        #expect(reason.contains("image"))
        #expect(!model.acceptsImages)
    }

    @Test func attachmentTransportAllowsImagesWhenAdvertised() {
        let model = ProviderModel(id: "v", name: "Vision", inputModalities: [.text, .image])
        let decision = AttachmentTransportPolicy.evaluate(
            attachments: [
                ContextAttachment(
                    path: "/tmp/shot.png",
                    imageMetadata: .init(isLatticeManaged: true, source: .regionCapture)
                )
            ],
            model: model
        )
        #expect(decision == .allowed)
    }

    // MARK: - Computer frame accumulator + presentation

    @Test func computerFrameRejectsNonFileAndEmptyPaths() {
        var accumulator = ComputerFrameAccumulator(minimumInterval: 0, recentCapacity: 3)
        let base = Date(timeIntervalSince1970: 1_000)

        #expect(accumulator.offer(frame(path: "https://example.com/a.png"), observedAt: base) == .rejectedInvalidPath)
        #expect(accumulator.offer(frame(path: ""), observedAt: base.addingTimeInterval(1)) == .rejectedInvalidPath)
        #expect(accumulator.offer(frame(path: "relative.png"), observedAt: base.addingTimeInterval(2)) == .rejectedInvalidPath)
        #expect(accumulator.latest == nil)
        #expect(accumulator.droppedCount == 3)
    }

    @Test func computerFrameRateLimitsAndKeepsLatestPlusBoundedRecent() {
        var accumulator = ComputerFrameAccumulator(minimumInterval: 1.0, recentCapacity: 2)
        let t0 = Date(timeIntervalSince1970: 5_000)

        #expect(accumulator.offer(frame(id: uuid(1), path: "/tmp/f1.png", sequence: 1), observedAt: t0) == .accepted)
        #expect(accumulator.offer(frame(id: uuid(2), path: "/tmp/f2.png", sequence: 2), observedAt: t0.addingTimeInterval(0.5)) == .rejectedRateLimited)
        #expect(accumulator.offer(frame(id: uuid(3), path: "/tmp/f3.png", sequence: 3), observedAt: t0.addingTimeInterval(1.0)) == .accepted)
        #expect(accumulator.offer(frame(id: uuid(4), path: "/tmp/f4.png", sequence: 4), observedAt: t0.addingTimeInterval(2.0)) == .accepted)

        #expect(accumulator.latest?.id == uuid(4))
        #expect(accumulator.recent.map(\.id) == [uuid(3), uuid(4)])
        #expect(accumulator.droppedCount == 1)
    }

    @Test func computerFrameStopAndCancelRejectFurtherFrames() {
        var accumulator = ComputerFrameAccumulator(minimumInterval: 0, recentCapacity: 4)
        let t0 = Date(timeIntervalSince1970: 9_000)
        #expect(accumulator.offer(frame(path: "/tmp/a.png"), observedAt: t0) == .accepted)

        accumulator.stop()
        #expect(accumulator.offer(frame(path: "/tmp/b.png"), observedAt: t0.addingTimeInterval(1)) == .rejectedStopped)
        #expect(accumulator.latest?.imagePath == "/tmp/a.png")

        accumulator.cancel()
        #expect(accumulator.offer(frame(path: "/tmp/c.png"), observedAt: t0.addingTimeInterval(2)) == .rejectedCancelled)
        #expect(accumulator.droppedCount == 2)
    }

    @Test func computerFramePresentationPolicyStates() {
        var accumulator = ComputerFrameAccumulator(minimumInterval: 0, recentCapacity: 1)
        var presentation = ComputerFramePresentationPolicy.presentation(for: accumulator)
        #expect(presentation.visibility == .hidden)
        #expect(presentation.controlsRemainProviderOwned)
        #expect(presentation.controlBoundaryStatement.contains("provider-owned"))

        _ = accumulator.offer(frame(path: "/tmp/live.png"), observedAt: Date(timeIntervalSince1970: 1))
        presentation = ComputerFramePresentationPolicy.presentation(for: accumulator)
        #expect(presentation.visibility == .visible)
        if case .latestFrameOnly(let frame) = presentation.content {
            #expect(frame.imagePath == "/tmp/live.png")
        } else {
            Issue.record("Expected latest-frame-only content")
        }

        accumulator.stop()
        presentation = ComputerFramePresentationPolicy.presentation(for: accumulator)
        #expect(presentation.isStopped)
        #expect(!presentation.isCancelled)

        accumulator.cancel()
        presentation = ComputerFramePresentationPolicy.presentation(for: accumulator)
        #expect(presentation.isCancelled)

        var invalid = ComputerFrameAccumulator(minimumInterval: 0, recentCapacity: 1)
        // Bypass offer validation by injecting an invalid latest for presentation edge case.
        invalid = ComputerFrameAccumulator(
            minimumInterval: 0,
            recentCapacity: 1,
            latest: frame(path: "https://evil.example/x.png"),
            recent: [],
            droppedCount: 0
        )
        presentation = ComputerFramePresentationPolicy.presentation(for: invalid)
        #expect(presentation.visibility == .visible)
        if case .imageUnavailable = presentation.content {
            // expected
        } else {
            Issue.record("Invalid latest path must surface as image unavailable")
        }
    }

    @Test func agentEventComputerFrameRoundTripEquality() {
        let frame = ComputerFrame(
            provider: "codex",
            timestamp: Date(timeIntervalSince1970: 42),
            imagePath: "/tmp/frame.png",
            sequence: 7,
            sourceIdentity: "tool-call-1"
        )
        let event = AgentEvent.computerFrame(frame)
        #expect(event == .computerFrame(frame))
        #expect(frame.controlBoundary.state == .observeOnly)
        #expect(frame.controlBoundary.statement.contains("does not mediate"))
    }

    @Test func codexComputerDynamicToolMapsOnlyStructuredLocalImageFrames() {
        let object: [String: Any] = [
            "method": "item/completed",
            "params": ["item": [
                "type": "dynamicToolCall",
                "id": "computer-1",
                "tool": "computer_use",
                "status": "completed",
                "contentItems": [["type": "inputImage", "imageUrl": "file:///tmp/provider-frame.png"]]
            ]]
        ]
        guard case .computerFrame(let frame)? = CodexExecHarness.appServerEvent(
            from: object,
            workspace: URL(fileURLWithPath: "/tmp")
        ) else {
            Issue.record("Structured computer tool image output should map to an observable frame")
            return
        }
        #expect(frame.imageURL?.path == "/tmp/provider-frame.png")
        #expect(frame.controlBoundary.state == .observeOnly)

        let remoteObject: [String: Any] = [
            "method": "item/completed",
            "params": ["item": [
                "type": "dynamicToolCall",
                "id": "computer-2",
                "tool": "computer_use",
                "status": "completed",
                "contentItems": [["type": "inputImage", "imageUrl": "https://example.com/frame.png"]]
            ]]
        ]
        if case .computerFrame = CodexExecHarness.appServerEvent(from: remoteObject, workspace: URL(fileURLWithPath: "/tmp")) {
            Issue.record("Remote image URLs must not become local observable frames")
        }
    }

    // MARK: - Capture storage

    @Test func captureStorageWritesAtomicallyAndCleansByCountAndAge() throws {
        let root = try uniqueRoot("capture-store")
        defer { try? FileManager.default.removeItem(at: root) }

        final class Clock: @unchecked Sendable {
            var value = Date(timeIntervalSince1970: 10_000)
        }
        let clock = Clock()
        let store = CaptureStorage(
            rootURL: root,
            configuration: CaptureStorageConfiguration(maxCaptureCount: 2, maxAge: 100),
            now: { clock.value }
        )

        let first = try store.writeCapture(
            imageData: Data([0x89, 0x50, 0x4E, 0x47]),
            imageExtension: "png",
            metadata: CaptureSidecarMetadata(
                source: .regionCapture,
                capturedAt: clock.value,
                accessibilityTextAuthorized: false,
                accessibilityText: "nope",
                imageOnlyFallback: .imageOnly(reason: "not authorized"),
                imageFileName: "ignored.png"
            )
        )
        #expect(first.attachment.isLatticeManagedCapture)
        #expect(first.attachment.imageMetadata?.accessibilityText == nil)
        #expect(FileManager.default.fileExists(atPath: first.imageURL.path))
        #expect(FileManager.default.fileExists(atPath: first.sidecarURL.path))

        clock.value = clock.value.addingTimeInterval(10)
        _ = try store.writeCapture(
            imageData: Data([0x01, 0x02]),
            imageExtension: "jpg",
            metadata: CaptureSidecarMetadata(source: .clipboard, capturedAt: clock.value, imageFileName: "x.jpg")
        )

        clock.value = clock.value.addingTimeInterval(10)
        let third = try store.writeCapture(
            imageData: Data([0x03]),
            imageExtension: "png",
            metadata: CaptureSidecarMetadata(source: .windowCapture, capturedAt: clock.value, imageFileName: "y.png")
        )

        // maxCaptureCount = 2 should have dropped the oldest capture pair.
        #expect(!FileManager.default.fileExists(atPath: first.imageURL.path))
        #expect(FileManager.default.fileExists(atPath: third.imageURL.path))

        // Age out remaining captures.
        clock.value = clock.value.addingTimeInterval(1_000)
        let cleanup = try store.cleanup()
        #expect(cleanup.remainingCaptureCount == 0)
        #expect(cleanup.removedFileCount > 0)
    }

    @Test func captureStorageRejectsTraversalAndOnlyDeletesKnownNames() throws {
        let root = try uniqueRoot("capture-traversal")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStorage(rootURL: root)

        let outside = root.deletingLastPathComponent().appendingPathComponent("secret.png")
        #expect(throws: CaptureStorageError.self) {
            try store.removeCapture(at: outside)
        }

        let nested = root.appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).png")
        #expect(throws: CaptureStorageError.self) {
            try store.removeCapture(at: nested)
        }

        // Plant an unrelated file inside the root; cleanup must not delete it.
        let decoy = root.appendingPathComponent("notes.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: decoy)

        let written = try store.writeCapture(
            imageData: Data([0xFF]),
            imageExtension: "png",
            metadata: CaptureSidecarMetadata(source: .regionCapture, imageFileName: "a.png")
        )
        try store.removeCapture(attachment: written.attachment)
        #expect(!FileManager.default.fileExists(atPath: written.imageURL.path))
        #expect(FileManager.default.fileExists(atPath: decoy.path))
        #expect(try String(contentsOf: decoy, encoding: .utf8) == "keep")
    }

    @Test func captureStorageProtectsLiveAttachmentsDuringCountCleanup() throws {
        let root = try uniqueRoot("capture-store-protected")
        defer { try? FileManager.default.removeItem(at: root) }

        let store = CaptureStorage(
            rootURL: root,
            configuration: CaptureStorageConfiguration(maxCaptureCount: 1, maxAge: 10_000),
            now: { Date(timeIntervalSince1970: 10_000) }
        )
        let first = try store.writeCapture(
            imageData: Data([0x01]),
            imageExtension: "png",
            metadata: CaptureSidecarMetadata(source: .clipboard, imageFileName: "first.png")
        )
        let second = try store.writeCapture(
            imageData: Data([0x02]),
            imageExtension: "png",
            metadata: CaptureSidecarMetadata(source: .clipboard, imageFileName: "second.png"),
            protectedCaptureIDs: [first.attachment.id]
        )

        #expect(FileManager.default.fileExists(atPath: first.imageURL.path))
        #expect(FileManager.default.fileExists(atPath: second.imageURL.path))
        _ = try store.cleanup(protectedCaptureIDs: [first.attachment.id])
        #expect(FileManager.default.fileExists(atPath: first.imageURL.path))
        #expect(!FileManager.default.fileExists(atPath: second.imageURL.path))
    }

    @Test func captureSidecarDecodeDropsUnauthorizedContext() throws {
        let metadata = CaptureSidecarMetadata(
            source: .windowCapture,
            frontmostApplicationName: "Private App",
            frontmostWindowTitle: "Private Window",
            accessibilityTextAuthorized: true,
            accessibilityText: "Private text",
            imageFileName: "capture.png"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CaptureSidecarMetadata.self, from: encoder.encode(metadata))
        #expect(decoded.frontmostApplicationName == nil)
        #expect(decoded.frontmostWindowTitle == nil)
        #expect(decoded.accessibilityText == nil)
    }

    @Test func captureStorageRejectsEmptyImageData() throws {
        let root = try uniqueRoot("capture-empty")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CaptureStorage(rootURL: root)
        #expect(throws: CaptureStorageError.self) {
            try store.writeCapture(
                imageData: Data(),
                imageExtension: "png",
                metadata: CaptureSidecarMetadata(source: .clipboard, imageFileName: "x.png")
            )
        }
    }

    // MARK: - Permission + lifecycle policy

    @Test func screenRecordingAndAccessibilityAreDistinct() {
        let needs = ScreenCapturePermissionPolicy.capability(
            screenRecording: .notDetermined,
            accessibility: .authorized,
            includeAccessibilityText: true
        )
        #expect(needs == .needsScreenRecordingPermission)
        #expect(!needs.allowsImageCapture)

        let imageOnly = ScreenCapturePermissionPolicy.capability(
            screenRecording: .authorized,
            accessibility: .denied,
            includeAccessibilityText: true
        )
        #expect(imageOnly.allowsImageCapture)
        #expect(!imageOnly.allowsAuthorizedAccessibilityText)
        if case .accessibilityOptionalDenied = imageOnly {
            // expected
        } else {
            Issue.record("Denied Accessibility must not block image capture")
        }

        let ready = ScreenCapturePermissionPolicy.capability(
            screenRecording: .authorized,
            accessibility: .authorized,
            includeAccessibilityText: true
        )
        #expect(ready == .ready)
        #expect(ready.allowsAuthorizedAccessibilityText)

        #expect(!ScreenCapturePermissionPolicy.mayRequestScreenRecording(.denied))
        #expect(ScreenCapturePermissionPolicy.mayRequestScreenRecording(.notDetermined))
        #expect(ScreenCapturePermissionPolicy.mayRequestAccessibility(.notDetermined))
        #expect(!CaptureLifecyclePolicy.allowsHiddenOrContinuousCapture())
    }

    @Test func captureLifecycleRequiresUserInitiationAndBlocksContinuousCapture() {
        var state = CaptureLifecycleState()

        guard case .applied(let started) = CaptureLifecyclePolicy.reduce(
            .userInitiatedCapture(includeAccessibilityText: true),
            into: state
        ) else {
            Issue.record("User-initiated capture must apply from idle")
            return
        }
        state = started
        #expect(state.phase == .userInitiated)

        // Continuous / stacked capture rejected while active.
        guard case .rejected(let reason) = CaptureLifecyclePolicy.reduce(
            .userInitiatedCapture(includeAccessibilityText: false),
            into: state
        ) else {
            Issue.record("Stacked capture must be rejected")
            return
        }
        #expect(reason.contains("Continuous") || reason.contains("user-initiated"))

        guard case .applied(let requesting) = CaptureLifecyclePolicy.reduce(.permissionRequestStarted, into: state) else {
            Issue.record("Permission request should apply")
            return
        }
        state = requesting
        #expect(state.phase == .requestingPermission)

        guard case .applied(let capturing) = CaptureLifecyclePolicy.reduce(.captureStarted, into: state) else {
            Issue.record("Capture start should apply")
            return
        }
        state = capturing
        #expect(state.phase == .capturing)

        guard case .applied(let done) = CaptureLifecyclePolicy.reduce(.completedWithAuthorizedContext, into: state) else {
            Issue.record("Authorized completion should apply")
            return
        }
        #expect(done.phase == .completedWithAuthorizedContext)
        #expect(done.isTerminal)

        // Image-only path without accessibility opt-in.
        state = CaptureLifecycleState()
        guard case .applied(let user) = CaptureLifecyclePolicy.reduce(
            .userInitiatedCapture(includeAccessibilityText: false),
            into: state
        ) else { return }
        guard case .applied(let cap) = CaptureLifecyclePolicy.reduce(.captureStarted, into: user) else { return }
        guard case .rejected = CaptureLifecyclePolicy.reduce(.completedWithAuthorizedContext, into: cap) else {
            Issue.record("Authorized context completion without opt-in must fail")
            return
        }
        guard case .applied(let imageOnly) = CaptureLifecyclePolicy.reduce(.completedImageOnly, into: cap) else {
            Issue.record("Image-only completion should apply")
            return
        }
        #expect(imageOnly.phase == .completedImageOnly)

        // Cancel + fail paths.
        state = CaptureLifecycleState(phase: .capturing)
        guard case .applied(let cancelled) = CaptureLifecyclePolicy.reduce(.cancelled, into: state) else {
            Issue.record("Cancel should apply while capturing")
            return
        }
        #expect(cancelled.phase == .cancelled)

        state = CaptureLifecycleState(phase: .capturing)
        guard case .applied(let failed) = CaptureLifecyclePolicy.reduce(.failed("disk full"), into: state) else {
            Issue.record("Fail should apply while capturing")
            return
        }
        #expect(failed.phase == .failed)
        #expect(failed.failureReason == "disk full")
    }

    // MARK: - Helpers

    private func uniqueRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lattice-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func frame(
        id: UUID = UUID(),
        path: String,
        sequence: Int? = nil
    ) -> ComputerFrame {
        ComputerFrame(
            id: id,
            provider: "codex",
            timestamp: Date(timeIntervalSince1970: 0),
            imagePath: path,
            sequence: sequence,
            sourceIdentity: "stream-1"
        )
    }

    private func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
}
