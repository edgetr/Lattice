import Foundation
import Testing
@testable import LatticeCore

@Suite("Assistant image artifacts")
struct AssistantArtifactTests {
    // MARK: - Fixtures

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("lattice-artifact-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeWorkspaceAndSupport() throws -> (workspace: URL, appSupport: URL, cleanup: () -> Void) {
        let root = temporaryRoot()
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        let appSupport = root.appendingPathComponent("Application Support/Lattice", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return (workspace, appSupport, { try? FileManager.default.removeItem(at: root) })
    }

    /// Minimal valid 1x1 PNG.
    private var oneByOnePNG: Data {
        Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
            0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
            0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41,
            0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xDD, 0x8D,
            0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
            0x44, 0xAE, 0x42, 0x60, 0x82
        ])
    }

    private func writePNG(named name: String, under directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try oneByOnePNG.write(to: url)
        return url
    }

    // MARK: - Legacy decode / migration

    @Test func legacySessionDecodeWithoutArtifactsRemainsEmptyAndLoaded() throws {
        let session = LatticeSession(
            title: "Legacy",
            messages: [.init(role: .assistant, text: "hello")],
            backend: .codex(model: "gpt-5.4")
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(LatticeSession.self, from: data)
        #expect(decoded.artifacts.isEmpty)
        #expect(decoded.isArtifactsLoaded)
        #expect(decoded.artifactStorage == nil)
        #expect(decoded.messages.count == 1)
        #expect(!String(data: data, encoding: .utf8)!.contains("base64"))
    }

    @Test func legacyManifestJSONWithoutArtifactKeysDecodes() throws {
        let session = LatticeSession(title: "Old", backend: .codex(model: "gpt-5.4"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object["artifacts"] = nil
        object["artifactStorage"] = nil
        let decoded = try JSONDecoder().decode(LatticeSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.artifacts.isEmpty)
        #expect(decoded.isArtifactsLoaded)
        #expect(decoded.artifactStorage == nil)
    }

    // MARK: - Split persistence round trip

    @Test func splitArtifactPersistenceRoundTripKeepsMetadataOutOfTranscript() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let message = ChatMessage(role: .assistant, text: "See attached diagram")
        let artifact = AssistantArtifact(
            messageID: message.id,
            status: .available,
            displayName: "diagram.png",
            mimeType: "image/png",
            byteCount: 128,
            pixelWidth: 1,
            pixelHeight: 1,
            canonicalPath: "/tmp/workspace/diagram.png",
            provenance: .init(provider: "Codex", origin: .codexImageGeneration, eventID: "img-1")
        )
        let session = LatticeSession(
            title: "Artifacts",
            messages: [.init(role: .user, text: "draw"), message],
            artifacts: [artifact],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([session])

        let lazy = try #require(store.loadLazyResult().value?.sessions.first)
        #expect(lazy.messages.isEmpty)
        #expect(lazy.artifacts.isEmpty)
        #expect(!lazy.isTranscriptLoaded)
        #expect(!lazy.isArtifactsLoaded)
        #expect(lazy.artifactStorage?.artifactCount == 1)

        var materialized = lazy
        try store.materializeSessionContent(in: &materialized)
        #expect(materialized.messages.map(\.text) == ["draw", "See attached diagram"])
        #expect(materialized.artifacts.count == 1)
        #expect(materialized.artifacts[0].canonicalPath == artifact.canonicalPath)
        #expect(materialized.artifacts[0].mimeType == "image/png")
        #expect(materialized.artifacts[0].provenance.eventID == "img-1")

        let transcriptData = try Data(contentsOf: store.transcriptDirectoryURL
            .appendingPathComponent(try #require(lazy.transcriptStorage?.fileName)))
        let transcriptText = String(decoding: transcriptData, as: UTF8.self)
        #expect(!transcriptText.contains("diagram.png"))
        #expect(!transcriptText.contains("/tmp/workspace/diagram.png"))
        #expect(!transcriptText.contains("image/png"))

        let artifactData = try Data(contentsOf: store.artifactDirectoryURL
            .appendingPathComponent(try #require(lazy.artifactStorage?.fileName)))
        let artifactText = String(decoding: artifactData, as: UTF8.self)
        #expect(artifactText.contains("diagram.png"))
        #expect(!artifactText.contains(oneByOnePNG.base64EncodedString()))
        // No raw image bytes in metadata store.
        #expect(!artifactData.contains(oneByOnePNG.prefix(8)))
    }

    @Test func orphanArtifactSidecarsAreRemovedOnSave() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let message = ChatMessage(role: .assistant, text: "a")
        let first = AssistantArtifact(
            messageID: message.id,
            status: .available,
            displayName: "a.png",
            mimeType: "image/png",
            byteCount: 10,
            canonicalPath: "/tmp/a.png",
            provenance: .init(provider: "Codex", origin: .codexImageView)
        )
        try store.save([LatticeSession(title: "A", messages: [message], artifacts: [first], backend: .codex(model: "gpt-5.4"))])
        let firstName = try #require(store.loadLazyResult().value?.sessions.first?.artifactStorage?.fileName)

        let second = AssistantArtifact(
            messageID: message.id,
            status: .missing,
            displayName: "b.png",
            mimeType: "application/octet-stream",
            byteCount: 0,
            canonicalPath: "/tmp/b.png",
            provenance: .init(provider: "Codex", origin: .codexImageView)
        )
        try store.save([LatticeSession(title: "B", messages: [message], artifacts: [second], backend: .codex(model: "gpt-5.4"))])
        let kept = try #require(store.loadLazyResult().value?.sessions.first?.artifactStorage?.fileName)
        #expect(kept != firstName)
        #expect(!FileManager.default.fileExists(atPath: store.artifactDirectoryURL.appendingPathComponent(firstName).path))
        #expect(FileManager.default.fileExists(atPath: store.artifactDirectoryURL.appendingPathComponent(kept).path))
    }

    // MARK: - Path validation

    @Test func validatorAcceptsWorkspaceImageAndRejectsUnsafeForms() throws {
        let env = try makeWorkspaceAndSupport()
        defer { env.cleanup() }
        let imageURL = try writePNG(named: "ok.png", under: env.workspace)

        let accepted = AssistantImageArtifactPolicy.validate(
            path: imageURL.path,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        guard case .accepted(let image) = accepted else {
            Issue.record("Workspace PNG should be accepted")
            return
        }
        #expect(image.status == .available)
        #expect(image.mimeType == "image/png")
        #expect(image.byteCount == oneByOnePNG.count)
        #expect(image.pixelWidth == 1)
        #expect(image.pixelHeight == 1)

        let relative = AssistantImageArtifactPolicy.validate(
            path: "ok.png",
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        #expect({
            if case .accepted = relative { return true }
            return false
        }())

        for bad in [
            "https://example.com/a.png",
            "http://example.com/a.png",
            "file:///tmp/a.png",
            "data:image/png;base64,iVBORw0KGgo=",
            String(repeating: "A", count: 200) + "==",
            "/etc/passwd",
            env.workspace.deletingLastPathComponent().appendingPathComponent("outside.png").path
        ] {
            let outcome = AssistantImageArtifactPolicy.validate(
                path: bad,
                workspace: env.workspace,
                applicationSupportRoot: env.appSupport
            )
            guard case .rejected = outcome else {
                Issue.record("Expected rejection for \(bad.prefix(40))")
                return
            }
        }
    }

    @Test func validatorRejectsSymlinkEscapeSignatureMismatchAndOversize() throws {
        let env = try makeWorkspaceAndSupport()
        defer { env.cleanup() }

        let outside = env.workspace.deletingLastPathComponent().appendingPathComponent("secret.png")
        try oneByOnePNG.write(to: outside)
        let link = env.workspace.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: outside.path)
        let symlinkOutcome = AssistantImageArtifactPolicy.validate(
            path: link.path,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        #expect({
            if case .rejected(.outsideAuthorizedRoots) = symlinkOutcome { return true }
            return false
        }())

        let spoof = env.workspace.appendingPathComponent("spoof.png")
        try Data("not-an-image".utf8).write(to: spoof)
        let signature = AssistantImageArtifactPolicy.validate(
            path: spoof.path,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        #expect({
            if case .rejected(.unsupportedSignature) = signature { return true }
            return false
        }())

        let oversizePath = env.workspace.appendingPathComponent("big.png").path
        // Keep PNG magic so detection happens, but report a huge size via probe.
        let header = oneByOnePNG
        let probe = AssistantImageArtifactPolicy.FileProbe(
            fileExists: { $0 == oversizePath },
            isSymbolicLink: { _ in false },
            isRegularFile: { $0 == oversizePath },
            byteCount: { _ in AssistantImageArtifactPolicy.maximumByteCount + 1 },
            readHeader: { _, _ in header },
            realPath: { $0 }
        )
        // Authorize under workspace by reporting the path as existing at the standardized location.
        let oversized = AssistantImageArtifactPolicy.validate(
            path: oversizePath,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport,
            probe: probe
        )
        #expect({
            if case .rejected(.oversize) = oversized { return true }
            return false
        }())
    }

    @Test func missingAuthorizedPathBecomesMissingAndRevalidatesWhenPresent() throws {
        let env = try makeWorkspaceAndSupport()
        defer { env.cleanup() }
        let target = env.workspace.appendingPathComponent("later.png")

        let missing = AssistantImageArtifactPolicy.validate(
            path: target.path,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        guard case .accepted(let pending) = missing else {
            Issue.record("Authorized missing path should be accepted as missing")
            return
        }
        #expect(pending.status == .missing)
        #expect(pending.byteCount == 0)

        let observation = try #require(AssistantImageArtifactPolicy.observation(
            from: missing,
            provenance: .init(provider: "Codex", origin: .codexImageView, eventID: "v1")
        ))
        let artifact = observation.bound(to: UUID())
        #expect(artifact.status == .missing)

        try oneByOnePNG.write(to: target)
        let recovered = AssistantImageArtifactPolicy.revalidate(
            artifact: artifact,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        guard case .accepted(let available) = recovered else {
            Issue.record("Revalidation should recover the file")
            return
        }
        #expect(available.status == .available)
        #expect(available.mimeType == "image/png")
        #expect(available.byteCount == oneByOnePNG.count)
    }

    @Test func applicationSupportRootIsAuthorizedForGeneratedImages() throws {
        let env = try makeWorkspaceAndSupport()
        defer { env.cleanup() }
        let generated = try writePNG(named: "generated.png", under: env.appSupport)
        let outcome = AssistantImageArtifactPolicy.validate(
            path: generated.path,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        guard case .accepted(let image) = outcome else {
            Issue.record("App support images should be accepted")
            return
        }
        #expect(image.status == .available)
        #expect(image.displayName == "generated.png")
    }

    // MARK: - Codex decoding

    @Test func codexImageViewAndImageGenerationDecodeValidatedArtifacts() throws {
        let env = try makeWorkspaceAndSupport()
        defer { env.cleanup() }
        let viewURL = try writePNG(named: "view.png", under: env.workspace)
        let genURL = try writePNG(named: "gen.png", under: env.appSupport)

        let imageView: [String: Any] = [
            "method": "item/completed",
            "params": [
                "item": [
                    "type": "imageView",
                    "id": "view-1",
                    "path": viewURL.path
                ]
            ]
        ]
        let viewEvent = CodexExecHarness.appServerEvent(
            from: imageView,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        guard case .artifact(let viewArtifact) = viewEvent else {
            Issue.record("imageView should emit artifact")
            return
        }
        #expect(viewArtifact.status == .available)
        #expect(viewArtifact.provenance.origin == .codexImageView)
        #expect(viewArtifact.provenance.eventID == "view-1")
        #expect(viewArtifact.mimeType == "image/png")
        #expect(viewArtifact.canonicalPath == viewURL.path)

        let imageGeneration: [String: Any] = [
            "method": "item/completed",
            "params": [
                "item": [
                    "type": "imageGeneration",
                    "id": "gen-1",
                    "status": "completed",
                    "result": "THIS_IS_NOT_A_PATH_OR_FILE_AND_MUST_BE_IGNORED",
                    "savedPath": genURL.path
                ]
            ]
        ]
        let genEvent = CodexExecHarness.appServerEvent(
            from: imageGeneration,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        guard case .artifact(let genArtifact) = genEvent else {
            Issue.record("imageGeneration should emit artifact from savedPath")
            return
        }
        #expect(genArtifact.provenance.origin == .codexImageGeneration)
        #expect(genArtifact.canonicalPath == genURL.path)
        #expect(genArtifact.canonicalPath != "THIS_IS_NOT_A_PATH_OR_FILE_AND_MUST_BE_IGNORED")
    }

    @Test func codexUnsafeImageOutputsBecomeMetadataOnlyDiagnostics() throws {
        let env = try makeWorkspaceAndSupport()
        defer { env.cleanup() }

        let remote: [String: Any] = [
            "method": "item/completed",
            "params": [
                "item": [
                    "type": "imageView",
                    "id": "bad-1",
                    "path": "https://cdn.example/x.png"
                ]
            ]
        ]
        let remoteEvent = CodexExecHarness.appServerEvent(
            from: remote,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        guard case .providerDiagnostic(let diagnostic) = remoteEvent else {
            Issue.record("Unsafe imageView should be diagnostic")
            return
        }
        #expect(diagnostic.reason.contains("rejected"))
        #expect(!diagnostic.detail.contains("https://"))
        #expect(!diagnostic.detail.contains("cdn.example"))

        let base64Result: [String: Any] = [
            "method": "item/completed",
            "params": [
                "item": [
                    "type": "imageGeneration",
                    "id": "bad-2",
                    "status": "completed",
                    "result": String(repeating: "A", count: 256),
                    "savedPath": NSNull()
                ]
            ]
        ]
        // savedPath null / missing -> diagnostic; result base64 must not be retained.
        let object = base64Result as [String: Any]
        // Build with optional null carefully for JSON-like dictionary.
        let generation: [String: Any] = [
            "method": "item/completed",
            "params": [
                "item": [
                    "type": "imageGeneration",
                    "id": "bad-2",
                    "status": "completed",
                    "result": String(repeating: "A", count: 256)
                ] as [String: Any]
            ]
        ]
        let genEvent = CodexExecHarness.appServerEvent(
            from: generation,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        guard case .providerDiagnostic(let genDiagnostic) = genEvent else {
            Issue.record("imageGeneration without savedPath should be diagnostic")
            return
        }
        #expect(genDiagnostic.reason.contains("savedPath"))
        #expect(!genDiagnostic.detail.contains(String(repeating: "A", count: 32)))
        _ = object
    }

    // MARK: - Shared structured decoder

    @Test func sharedDecoderReadsExplicitToolResultImagePathOnly() throws {
        let env = try makeWorkspaceAndSupport()
        defer { env.cleanup() }
        let imageURL = try writePNG(named: "tool.png", under: env.workspace)

        #expect(StructuredAssistantArtifactDecoder.explicitImagePath(in: ["status": "success"]) == nil)
        #expect(StructuredAssistantArtifactDecoder.explicitImagePath(in: [
            "nested": ["imagePath": imageURL.path]
        ]) == nil)

        let path = StructuredAssistantArtifactDecoder.explicitImagePath(in: [
            "status": "success",
            "imagePath": imageURL.path
        ])
        #expect(path == imageURL.path)

        let envelope: [String: Any] = [
            "type": "tool_result",
            "tool_id": "tool-abc",
            "status": "success",
            "imagePath": imageURL.path
        ]
        let events = AntigravityCLIHarness.structuredEvent(
            from: try JSONSerialization.data(withJSONObject: envelope),
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        #expect(events.contains { event in
            if case .toolProgress = event { return true }
            return false
        })
        #expect(events.contains { event in
            if case .artifact(let artifact) = event {
                return artifact.canonicalPath == imageURL.path
                    && artifact.provenance.origin == .structuredToolResult
            }
            return false
        })

        let withoutPath: [String: Any] = [
            "type": "tool_result",
            "tool_id": "tool-xyz",
            "status": "success"
        ]
        let progressOnly = AntigravityCLIHarness.structuredEvent(
            from: try JSONSerialization.data(withJSONObject: withoutPath),
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        #expect(progressOnly.count == 1)
        if case .toolProgress = progressOnly[0] {
            // expected
        } else {
            Issue.record("tool_result without imagePath must not invent artifacts")
        }
    }

    // MARK: - Delete / branch semantics

    @Test func deleteAndBranchPruneArtifactsWithOwningMessages() throws {
        let firstUser = ChatMessage(role: .user, text: "First")
        let firstAssistant = ChatMessage(role: .assistant, text: "First reply")
        let secondUser = ChatMessage(role: .user, text: "Second")
        let secondAssistant = ChatMessage(role: .assistant, text: "Second reply")
        let kept = AssistantArtifact(
            messageID: firstAssistant.id,
            status: .available,
            displayName: "kept.png",
            mimeType: "image/png",
            byteCount: 10,
            canonicalPath: "/tmp/kept.png",
            provenance: .init(provider: "Codex", origin: .codexImageView, eventID: "k1")
        )
        let removed = AssistantArtifact(
            messageID: secondAssistant.id,
            status: .available,
            displayName: "gone.png",
            mimeType: "image/png",
            byteCount: 10,
            canonicalPath: "/tmp/gone.png",
            provenance: .init(provider: "Codex", origin: .codexImageGeneration, eventID: "g1")
        )
        var session = LatticeSession(
            title: "Media",
            messages: [firstUser, firstAssistant, secondUser, secondAssistant],
            artifacts: [kept, removed],
            backend: .codex(model: "gpt-5.4")
        )

        #expect(SessionTranscriptMutation.deleteMessageAndFollowing(messageID: secondUser.id, in: &session))
        #expect(session.messages.map(\.id) == [firstUser.id, firstAssistant.id])
        #expect(session.artifacts.map(\.id) == [kept.id])

        let branchSource = LatticeSession(
            title: "Source",
            messages: [firstUser, firstAssistant, secondUser, secondAssistant],
            artifacts: [kept, removed],
            backend: .codex(model: "gpt-5.4")
        )
        let branch = try #require(SessionTranscriptMutation.branchFromMessage(messageID: secondUser.id, in: branchSource))
        #expect(branch.artifacts.map(\.id) == [kept.id])
        #expect(branch.messages.map(\.id) == [firstUser.id, firstAssistant.id, secondUser.id])
        #expect(!branch.artifacts.contains(where: { $0.messageID == secondAssistant.id }))
    }

    // MARK: - No bytes in transcript / provider handoff surfaces

    @Test func artifactRecordsAndTranscriptNeverCarryImageBytes() throws {
        let message = ChatMessage(role: .assistant, text: "Rendered chart")
        let artifact = AssistantArtifact(
            messageID: message.id,
            status: .available,
            displayName: "chart.png",
            mimeType: "image/png",
            byteCount: oneByOnePNG.count,
            canonicalPath: "/workspace/chart.png",
            provenance: .init(provider: "Codex", origin: .codexImageGeneration, eventID: "c1")
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let messageData = try encoder.encode(message)
        let artifactData = try encoder.encode(artifact)
        let sessionData = try encoder.encode(LatticeSession(
            title: "Chart",
            messages: [message],
            artifacts: [artifact],
            backend: .codex(model: "gpt-5.4")
        ))

        for data in [messageData, artifactData, sessionData] {
            #expect(!data.contains(oneByOnePNG))
            let text = String(decoding: data, as: UTF8.self)
            #expect(!text.contains(oneByOnePNG.base64EncodedString()))
            #expect(!text.contains("iVBORw0KGgo"))
        }

        let observation = AssistantArtifactObservation(
            status: .available,
            displayName: "chart.png",
            mimeType: "image/png",
            byteCount: oneByOnePNG.count,
            canonicalPath: "/workspace/chart.png",
            provenance: .init(provider: "Codex", origin: .codexImageView)
        )
        let event: AgentEvent = .artifact(observation)
        // AgentEvent itself is not Codable; ensure bound artifact stays metadata-only.
        let bound = observation.bound(to: message.id)
        #expect(bound.byteCount == oneByOnePNG.count)
        #expect(bound.canonicalPath == "/workspace/chart.png")
        if case .artifact(let payload) = event {
            #expect(payload.displayName == "chart.png")
        } else {
            Issue.record("AgentEvent.artifact must round-trip through pattern match")
        }
    }

    @Test func hydrationLoadsArtifactsAlongsideTranscript() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let assistant = ChatMessage(role: .assistant, text: "done")
        let artifact = AssistantArtifact(
            messageID: assistant.id,
            status: .missing,
            displayName: "pending.png",
            mimeType: "application/octet-stream",
            byteCount: 0,
            canonicalPath: "/tmp/pending.png",
            provenance: .init(provider: "Codex", origin: .codexImageView, eventID: "p1")
        )
        let session = LatticeSession(
            title: "Hydrate",
            messages: [.init(role: .user, text: "go"), assistant],
            artifacts: [artifact],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([session])
        let lazy = try #require(store.loadLazyResult().value?.sessions.first)
        let storage = try #require(lazy.transcriptStorage)
        let result = store.hydrationResult(for: lazy)
        guard case .loaded(let content) = result else {
            Issue.record("Hydration should load")
            return
        }
        #expect(content.messages.count == 2)
        #expect(content.artifacts.count == 1)
        #expect(content.artifacts[0].status == .missing)
        #expect(content.artifacts[0].provenance.eventID == "p1")
        _ = storage
    }

    @Test func emptyArtifactCollectionsDoNotCreateSidecars() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SessionPersistence(fileURL: root.appendingPathComponent("sessions.json"))
        let session = LatticeSession(
            title: "Text only",
            messages: [.init(role: .assistant, text: "done")],
            backend: .codex(model: "gpt-5.4")
        )
        try store.save([session])
        let lazy = try #require(store.loadLazyResult().value?.sessions.first)
        #expect(lazy.artifactStorage == nil)
        let sidecars = try FileManager.default.contentsOfDirectory(
            at: store.artifactDirectoryURL,
            includingPropertiesForKeys: nil
        )
        #expect(sidecars.isEmpty)
    }

    @Test func presentationPolicyRecoversMissingFilesAndRejectsUnsafeDimensions() throws {
        let env = try makeWorkspaceAndSupport()
        defer { env.cleanup() }
        let target = env.workspace.appendingPathComponent("recover.png")
        let missingArtifact = AssistantArtifact(
            messageID: UUID(),
            status: .missing,
            displayName: "recover.png",
            mimeType: "application/octet-stream",
            byteCount: 0,
            canonicalPath: target.path,
            provenance: .init(provider: "Codex", origin: .codexImageGeneration)
        )
        let missing = AssistantArtifactPresentationPolicy.presentation(
            for: missingArtifact,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        #expect(missing.availability == .missing)
        #expect(!missing.canOpen && missing.canCopyPath)

        try oneByOnePNG.write(to: target)
        let recovered = AssistantArtifactPresentationPolicy.presentation(
            for: missingArtifact,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport
        )
        #expect(recovered.availability == .available)
        #expect(recovered.canOpen && recovered.canReveal && recovered.canSaveCopy)

        let hugePath = env.workspace.appendingPathComponent("huge.png").path
        var mutableHugeHeader = oneByOnePNG
        mutableHugeHeader.replaceSubrange(16..<20, with: [0x00, 0x00, 0x80, 0x01])
        mutableHugeHeader.replaceSubrange(20..<24, with: [0x00, 0x00, 0x80, 0x01])
        let hugeHeader = mutableHugeHeader
        let probe = AssistantImageArtifactPolicy.FileProbe(
            fileExists: { $0 == hugePath },
            isSymbolicLink: { _ in false },
            isRegularFile: { $0 == hugePath },
            byteCount: { _ in hugeHeader.count },
            readHeader: { _, _ in hugeHeader },
            realPath: { $0 }
        )
        let huge = AssistantImageArtifactPolicy.validate(
            path: hugePath,
            workspace: env.workspace,
            applicationSupportRoot: env.appSupport,
            probe: probe
        )
        #expect(huge == .rejected(.unsafeDimensions))
    }

    @Test func inlineImageDataIsRemovedAcrossStreamingDeltas() {
        let first = AssistantTranscriptMediaPolicy.appending(
            "Here is ![chart](data:image/png;base",
            to: "",
            isSuppressingPayload: false
        )
        #expect(!first.isSuppressingPayload)
        let second = AssistantTranscriptMediaPolicy.appending(
            "64,iVBORw0KGgoAAA",
            to: first.text,
            isSuppressingPayload: first.isSuppressingPayload
        )
        #expect(second.isSuppressingPayload)
        #expect(second.text == "Here is ![chart](\(AssistantTranscriptMediaPolicy.omissionMarker)")
        let third = AssistantTranscriptMediaPolicy.appending(
            "A==) finished",
            to: second.text,
            isSuppressingPayload: second.isSuppressingPayload
        )
        #expect(!third.isSuppressingPayload)
        #expect(third.text == "Here is ![chart](\(AssistantTranscriptMediaPolicy.omissionMarker)) finished")
        #expect(!third.text.contains("iVBOR"))
    }

    @Test func searchIndexFingerprintIsStableAcrossArtifactHydration() throws {
        let assistant = ChatMessage(role: .assistant, text: "diagram")
        let artifact = AssistantArtifact(
            messageID: assistant.id,
            status: .missing,
            displayName: "diagram.png",
            mimeType: "application/octet-stream",
            byteCount: 0,
            canonicalPath: "/tmp/diagram.png",
            provenance: .init(provider: "Codex", origin: .codexImageView)
        )
        let loaded = LatticeSession(
            title: "Diagram",
            messages: [assistant],
            artifacts: [artifact],
            backend: .codex(model: "gpt-5.4")
        )
        var index = SessionSearchIndex()
        index.update(session: loaded)

        var lazy = loaded
        lazy.transcriptStorage = try SessionPersistence.storageReference(sessionID: lazy.id, messages: lazy.messages)
        lazy.messages = []
        lazy.isTranscriptLoaded = false
        lazy.isTranscriptDirty = false
        lazy.artifactStorage = try SessionPersistence.artifactStorageReference(sessionID: lazy.id, artifacts: lazy.artifacts)
        lazy.artifacts = []
        lazy.isArtifactsLoaded = false
        lazy.isArtifactsDirty = false
        #expect(index.containsValidEntry(for: lazy))
    }
}

private extension DurableStoreLoadResult where Value == LazySessionLoad {
    var value: LazySessionLoad? {
        if case .loaded(let value) = self { return value }
        return nil
    }
}
