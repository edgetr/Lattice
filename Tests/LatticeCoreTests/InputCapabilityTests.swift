import Foundation
import Testing
@testable import LatticeCore

@Suite("Typed execution input capability")
struct InputCapabilityTests {
    @Test func executionRequestKeepsAttachmentsSeparateFromVisiblePrompt() {
        let attachment = ContextAttachment(
            path: "/tmp/screenshot.png",
            kind: .image,
            source: .screenshot
        )
        let route = ExecutionRoute(mode: .code, providerID: "openai", modelID: "gpt-test", runtimeID: "codex")
        let request = ExecutionRequest(sessionID: UUID(), route: route, prompt: "Describe this", attachments: [attachment])

        #expect(request.prompt == "Describe this")
        #expect(!request.prompt.contains(attachment.path))
        #expect(request.attachments == [attachment])
    }

    @Test func codexRequiresRuntimeProtocolAndModelImageEvidence() {
        let route = ExecutionRoute(mode: .code, providerID: "openai", modelID: "vision", runtimeID: "codex")
        let supportedModel = ProviderModel(id: "vision", name: "Vision", inputModalities: [.text, .image])
        let textModel = ProviderModel(id: "text", name: "Text", inputModalities: [.text])
        let unknownModel = ProviderModel(id: "unknown", name: "Unknown")

        #expect(ImageInputCapability.resolve(route: route, model: supportedModel, protocolSupport: .supported).support == .supported)
        #expect(ImageInputCapability.resolve(route: route, model: textModel, protocolSupport: .supported).support == .unsupported)
        #expect(ImageInputCapability.resolve(route: route, model: unknownModel, protocolSupport: .supported).support == .unknown)
        #expect(ImageInputCapability.resolve(route: route, model: supportedModel, protocolSupport: .unknown).support == .unknown)
    }

    @Test func unprovenHarnessesFailTruthfully() {
        for runtimeID in ["pi", "hermes", "opencode", "grok", "antigravity", "lattice"] {
            let route = ExecutionRoute(mode: .code, providerID: "provider", modelID: "model", runtimeID: runtimeID)
            let capability = ImageInputCapability.resolve(route: route, model: nil, protocolSupport: .unsupported)
            #expect(capability.support == .unsupported)
            #expect(capability.unavailableReason?.contains(runtimeID) == true)
        }
    }

    @Test func missingAndOversizeImagesAreActionable() {
        let capability = ImageInputCapability(support: .supported)
        let missing = ContextAttachment(path: "/tmp/missing.png", isMissing: false)
        let missingReason = ExecutionInputAttachmentPolicy.unavailableReason(
            attachments: [missing],
            capability: capability,
            inspector: ClosureContextAttachmentInspector { _ in .init(fileExists: false) }
        )
        #expect(missingReason?.localizedCaseInsensitiveContains("missing") == true)

        let large = ContextAttachment(path: "/tmp/large.png")
        let largeReason = ExecutionInputAttachmentPolicy.unavailableReason(
            attachments: [large],
            capability: capability,
            inspector: ClosureContextAttachmentInspector { _ in
                .init(
                    fileExists: true,
                    byteCount: 2_000,
                    contentTypeIdentifier: "public.png",
                    mimeType: "image/png",
                    typeEvidenceFromContent: true
                )
            },
            limits: .init(maximumByteCount: 1_000)
        )
        #expect(largeReason?.localizedCaseInsensitiveContains("limit") == true)
    }

    @Test func providerModelLegacyCodingLeavesModalitiesUnknown() throws {
        let legacy = Data(#"{"id":"legacy","name":"Legacy","description":"","reasoningOptions":[],"contextWindow":null,"isDefault":false}"#.utf8)
        let decoded = try JSONDecoder().decode(ProviderModel.self, from: legacy)
        #expect(decoded.inputModalities == nil)

        let current = ProviderModel(id: "current", name: "Current", inputModalities: [.text, .image])
        let roundTrip = try JSONDecoder().decode(ProviderModel.self, from: JSONEncoder().encode(current))
        #expect(roundTrip.inputModalities == [.text, .image])
    }

    @Test func codexTurnSerializationUsesLocalReferencesWithoutBase64() throws {
        let attachment = ContextAttachment(path: "/tmp/screenshot.png", kind: .image, source: .screenshot)
        let input = CodexExecHarness.turnInput(prompt: "Inspect", attachments: [attachment])
        let data = try JSONSerialization.data(withJSONObject: input)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(input.count == 2)
        #expect(input[0]["type"] as? String == "text")
        #expect(input[1]["type"] as? String == "localImage")
        #expect(input[1]["path"] as? String == attachment.path)
        #expect(!json.localizedCaseInsensitiveContains("base64"))
        #expect(!json.contains("Attached paths"))
    }
}
