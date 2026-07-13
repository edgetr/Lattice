import Foundation
import Testing
@testable import LatticeCore

@Suite("Extension runtime")
struct ExtensionRuntimeTests {
    @Test func manifestEnvelopeRequiresExactlyOneManifestAndNoExtraText() throws {
        let valid = """
        <lattice-extension-manifest>
        {"schemaVersion":1,"id":"com.lattice.strict","name":"Strict","version":"1","summary":"Strict manifest."}
        </lattice-extension-manifest>
        """
        #expect(try LatticeExtensionManifestEnvelope.decode(from: valid).id == "com.lattice.strict")

        let extraText = "Here is the change.\n\(valid)"
        #expect(throws: Error.self) {
            try LatticeExtensionManifestEnvelope.decode(from: extraText)
        }

        let duplicate = """
        <lattice-extension-manifest>
        {"schemaVersion":1,"id":"com.lattice.one","name":"One","version":"1","summary":"One."}
        </lattice-extension-manifest>
        <lattice-extension-manifest>
        {"schemaVersion":1,"id":"com.lattice.two","name":"Two","version":"1","summary":"Two."}
        </lattice-extension-manifest>
        """
        #expect(throws: Error.self) {
            try LatticeExtensionManifestEnvelope.decode(from: duplicate)
        }

        let invalidJSON = """
        <lattice-extension-manifest>
        {"schemaVersion":1,
        </lattice-extension-manifest>
        """
        #expect(throws: Error.self) {
            try LatticeExtensionManifestEnvelope.decode(from: invalidJSON)
        }
    }

    @Test func operationPreviewsValidateAndLoad() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let manifest = LatticeExtensionManifest(
            id: "com.lattice.operation-preview",
            name: "Operation Preview",
            version: "1.0.0",
            summary: "Preview non-style work.",
            permissions: [.editUI],
            uiTargets: ["composer"],
            stylePatches: [.init(target: .composer, tintHex: "#88CCFF")],
            layoutPatches: [.init(target: .composer, density: .compact)],
            copyPatches: [.init(target: .askButton, text: "Ask softly")],
            promptTemplates: [.init(invocation: "/brief", title: "Brief", detail: "Make concise", prompt: "Make this concise.")],
            skillPatches: [.init(id: "subagents", title: "Subagents", summary: "Use helper agents.", markdown: "# Subagents\n\nUse bounded helper agents for independent subtasks.")],
            operationPreviews: [
                .init(targetSurfaceID: "composer", operation: .relayout, summary: "Make the composer compact.", detail: "Executable when backed by a composer layout patch."),
                .init(targetSurfaceID: "extensions", operation: .addSkill, summary: "Add subagents skill.", detail: "Executable when backed by a skill patch.")
            ]
        )
        #expect(store.validate(manifest).isEmpty)
        #expect(manifest.hasRuntimePatches)
        try store.writeGeneratedExtension(manifest)
        let loaded = try #require(store.load().first)
        #expect(loaded.hasRuntimePatches)
        #expect(loaded.layoutPatches == manifest.layoutPatches)
        #expect(loaded.copyPatches == manifest.copyPatches)
        #expect(loaded.promptTemplates == manifest.promptTemplates)
        #expect(loaded.skillPatches == manifest.skillPatches)
        #expect(loaded.promptTemplates.first?.command.replacementText == "Make this concise.")
        #expect(loaded.operationPreviews == manifest.operationPreviews)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func skillStoreImportsWritesTogglesAndDeletesSkills() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let global = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let globalSkill = global.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: globalSkill, withIntermediateDirectories: true)
        try Data("# Subagents\n\nUse helper agents.".utf8).write(to: globalSkill.appendingPathComponent("SKILL.md"))
        let store = LatticeSkillStore(rootURL: root, globalRoots: [global])
        try store.importGlobalSkills()
        var loaded = store.load()
        #expect(loaded.map(\.id) == ["subagents"])
        #expect(loaded.first?.source == .importedGlobal)
        let imported = try #require(loaded.first)
        #expect(LatticeSkillPromptBuilder.command(for: imported).invocation == "/subagents")
        let invocation = try #require(LatticeSkillPromptBuilder.invocation(in: "/subagents split this into helper tasks", records: loaded, disabledSkillIDs: []))
        #expect(invocation.skillID == "subagents")
        #expect(invocation.userRequest == "split this into helper tasks")
        let prompt = LatticeSkillPromptBuilder.prompt(for: invocation)
        #expect(prompt.contains("Lattice skill invocation: /subagents"))
        #expect(prompt.contains("# Subagents"))
        #expect(prompt.contains("split this into helper tasks"))
        #expect(LatticeSkillPromptBuilder.invocation(in: "/subagents split this", records: loaded, disabledSkillIDs: ["subagents"]) == nil)
        let visibleSkillMessage = ChatMessage(role: .user, text: "/subagents split this into helper tasks")
        let structuredSession = LatticeSession(
            title: "Skill chat",
            messages: [.init(role: .user, text: "Earlier"), .init(role: .assistant, text: "Earlier answer"), visibleSkillMessage, .init(role: .assistant, text: "")],
            backend: .ollama(model: "qwen3:8b")
        )
        let backendMessages = LatticeBackendMessageBuilder.structuredMessages(session: structuredSession, submittedText: prompt, additionalContext: "\n\nAttached paths:\n/tmp/a.swift")
        #expect(backendMessages.map(\.text).contains("Earlier"))
        #expect(backendMessages.last?.text.contains("Lattice skill invocation: /subagents") == true)
        #expect(backendMessages.last?.text.contains("/tmp/a.swift") == true)
        #expect(structuredSession.messages[2].text == "/subagents split this into helper tasks")

        let generated = LatticeSkillPatch(id: "review-buddy", title: "Review Buddy", summary: "Review changes.", markdown: "# Review Buddy\n\nReview patches for risk.")
        let generatedPreview = LatticeSkillPatchPreviewBuilder.preview(for: generated)
        #expect(generatedPreview.command == "/review-buddy")
        #expect(generatedPreview.fileName == "SKILL.md")
        #expect(generatedPreview.summary == "Review changes.")
        #expect(generatedPreview.markdownLineCount == 3)
        #expect(generatedPreview.markdownCharacterCount == generated.markdown.count)
        let fallbackPreview = LatticeSkillPatchPreviewBuilder.preview(for: .init(id: "quiet-mode", title: "Quiet Mode", summary: "", markdown: "# Quiet Mode\n\nKeep replies calm."))
        #expect(fallbackPreview.summary == "Quiet Mode")
        try store.writeGeneratedSkill(generated, ownerExtensionID: "com.lattice.review")
        loaded = store.load()
        #expect(Set(loaded.map(\.id)) == ["subagents", "review-buddy"])
        #expect(loaded.first { $0.id == "review-buddy" }?.source == .generated)
        #expect(loaded.first { $0.id == "review-buddy" }?.ownerExtensionID == "com.lattice.review")
        let ownedSkill = try #require(loaded.first { $0.id == "review-buddy" })
        #expect(!LatticeSkillActivationPolicy.isEnabled(ownedSkill, disabledSkillIDs: [], enabledExtensionIDs: []))
        #expect(LatticeSkillActivationPolicy.isEnabled(ownedSkill, disabledSkillIDs: [], enabledExtensionIDs: ["com.lattice.review"]))
        #expect(!LatticeSkillActivationPolicy.isEnabled(ownedSkill, disabledSkillIDs: ["review-buddy"], enabledExtensionIDs: ["com.lattice.review"]))
        let ownerDisabledIDs = LatticeSkillActivationPolicy.effectiveDisabledSkillIDs(records: loaded, disabledSkillIDs: [], enabledExtensionIDs: [])
        #expect(ownerDisabledIDs == ["review-buddy"])
        #expect(LatticeSkillPromptBuilder.invocation(in: "/review-buddy inspect this", records: loaded, disabledSkillIDs: ownerDisabledIDs) == nil)
        let ownerEnabledIDs = LatticeSkillActivationPolicy.effectiveDisabledSkillIDs(records: loaded, disabledSkillIDs: [], enabledExtensionIDs: ["com.lattice.review"])
        #expect(try #require(LatticeSkillPromptBuilder.invocation(in: "/review-buddy inspect this", records: loaded, disabledSkillIDs: ownerEnabledIDs)).skillID == "review-buddy")
        try store.deleteSkill(id: "review-buddy", ownedByExtensionID: "com.lattice.other")
        #expect(store.load().contains { $0.id == "review-buddy" })
        try store.deleteSkill(id: "review-buddy", ownedByExtensionID: "com.lattice.review")
        #expect(Set(store.load().map(\.id)) == ["subagents"])
        let existingSnapshot = store.snapshotSkill(id: "subagents")
        try store.writeGeneratedSkill(.init(id: "subagents", title: "Subagents Override", summary: "Override.", markdown: "# Subagents Override\n\nOverride."), ownerExtensionID: "com.lattice.override")
        #expect(store.load().first?.ownerExtensionID == "com.lattice.override")
        try store.restoreSkill(existingSnapshot, removingCurrentIfOwnedBy: "com.lattice.override")
        #expect(store.load().first?.source == .importedGlobal)
        #expect(store.load().first?.ownerExtensionID == nil)
        let missingSnapshot = store.snapshotSkill(id: "new-skill")
        try store.writeGeneratedSkill(.init(id: "new-skill", title: "New Skill", summary: "Temporary.", markdown: "# New Skill\n\nTemporary."), ownerExtensionID: "com.lattice.new")
        try store.restoreSkill(missingSnapshot, removingCurrentIfOwnedBy: "com.lattice.other")
        #expect(store.load().contains { $0.id == "new-skill" })
        try store.restoreSkill(missingSnapshot, removingCurrentIfOwnedBy: "com.lattice.new")
        #expect(!store.load().contains { $0.id == "new-skill" })
        try store.deleteSkill(id: "subagents")
        #expect(store.load().isEmpty)
        try store.importGlobalSkills()
        #expect(store.load().isEmpty)
        try store.writeGeneratedSkill(.init(id: "subagents", title: "Subagents", summary: "Generated replacement.", markdown: "# Subagents\n\nGenerated replacement."))
        #expect(store.load().map(\.id) == ["subagents"])
        #expect(store.load().first?.source == .generated)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: global)
    }

    @Test func globalSkillImportRejectsSymlinkedSourceFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let global = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let globalSkill = global.appendingPathComponent("linked-skill", isDirectory: true)
        let secret = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: globalSkill, withIntermediateDirectories: true)
        try Data("must not be imported".utf8).write(to: secret)
        try FileManager.default.createSymbolicLink(at: globalSkill.appendingPathComponent("SKILL.md"), withDestinationURL: secret)

        let store = LatticeSkillStore(rootURL: root, globalRoots: [global])
        try store.importGlobalSkills()
        #expect(store.load().isEmpty)

        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: global)
        try? FileManager.default.removeItem(at: secret)
    }

    @Test func importedSkillsMayContainFullWorkflowsBeyondGeneratedLimit() {
        let store = LatticeSkillStore(rootURL: URL(fileURLWithPath: "/tmp/unused"), globalRoots: [])
        let markdown = "# Hatch Pet\n\n" + String(repeating: "Detailed validation workflow.\n", count: 1_200)
        #expect(markdown.count > 24_000)
        #expect(store.validateExistingSkill(id: "hatch-pet", markdown: markdown).isEmpty)
        #expect(LatticeSkillStore.validate(.init(id: "hatch-pet", title: "Hatch Pet", summary: "", markdown: markdown)).contains("Skill markdown must be 24000 characters or fewer."))
    }

    @Test func globalSkillImportSynchronizesUntouchedCopiesWithoutOverwritingLocalChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let global = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sourceFolder = global.appendingPathComponent("shared-skill", isDirectory: true)
        let sourceURL = sourceFolder.appendingPathComponent("SKILL.md")
        let targetURL = root.appendingPathComponent("shared-skill/SKILL.md")
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let first = Data("# Shared Skill\n\nFirst global version.".utf8)
        let second = Data("# Shared Skill\n\nSecond global version.".utf8)
        let third = Data("# Shared Skill\n\nThird global version.".utf8)
        let fourth = Data("# Shared Skill\n\nFourth global version.".utf8)
        let local = Data("# Shared Skill\n\nLocally customized in Lattice.".utf8)
        try first.write(to: sourceURL)

        let store = LatticeSkillStore(rootURL: root, globalRoots: [global])
        try store.importGlobalSkills()
        #expect(try Data(contentsOf: targetURL) == first)

        try second.write(to: sourceURL, options: .atomic)
        try store.importGlobalSkills()
        #expect(try Data(contentsOf: targetURL) == second)

        let importedSnapshot = store.snapshotSkill(id: "shared-skill")
        #expect(importedSnapshot.importedBaselineData == second)
        try store.writeGeneratedSkill(
            .init(id: "shared-skill", title: "Generated Shared Skill", summary: "Generated replacement.", markdown: "# Generated Shared Skill\n\nGenerated replacement."),
            ownerExtensionID: "com.lattice.shared"
        )
        try store.restoreSkill(importedSnapshot, removingCurrentIfOwnedBy: "com.lattice.shared")
        try third.write(to: sourceURL, options: .atomic)
        try store.importGlobalSkills()
        #expect(try Data(contentsOf: targetURL) == third)

        try local.write(to: targetURL, options: .atomic)
        try fourth.write(to: sourceURL, options: .atomic)
        try store.importGlobalSkills()
        #expect(try Data(contentsOf: targetURL) == local)

        try store.writeGeneratedSkill(.init(id: "shared-skill", title: "Generated", summary: "Keep generated.", markdown: "# Generated\n\nKeep this generated skill."))
        try store.importGlobalSkills()
        #expect(try Data(contentsOf: targetURL) == Data("# Generated\n\nKeep this generated skill.".utf8))
        #expect(store.load().first?.source == .generated)

        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: global)
    }

    @Test func duplicateExtensionIDsLoadAsInvalidRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let firstBundle = root.appendingPathComponent("first", isDirectory: true)
        let secondBundle = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstBundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondBundle, withIntermediateDirectories: true)
        let first = LatticeExtensionManifest(
            id: "com.lattice.duplicate",
            name: "Duplicate A",
            version: "1",
            summary: "First.",
            permissions: [.editUI],
            stylePatches: [.init(target: .composer, tintHex: "#88CCFF")]
        )
        let second = LatticeExtensionManifest(
            id: "COM.LATTICE.DUPLICATE",
            name: "Duplicate B",
            version: "1",
            summary: "Second.",
            permissions: [.editUI],
            stylePatches: [.init(target: .overlay, tintHex: "#88CCFF")]
        )
        try JSONEncoder().encode(first).write(to: firstBundle.appendingPathComponent("lattice-extension.json"))
        try JSONEncoder().encode(second).write(to: secondBundle.appendingPathComponent("lattice-extension.json"))

        let loaded = LatticeExtensionStore(rootURL: root).load()
        #expect(loaded.count == 2)
        #expect(loaded.allSatisfy { !$0.isValid })
        #expect(loaded.allSatisfy { $0.validationMessages.contains { $0.contains("Duplicate extension id") } })
        try? FileManager.default.removeItem(at: root)
    }

    @Test func manifestIDRejectsUppercase() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let manifest = LatticeExtensionManifest(
            id: "COM.LATTICE.UPPERCASE",
            name: "Uppercase",
            version: "1",
            summary: "Uses uppercase id."
        )
        #expect(store.validate(manifest).contains("Id must be lowercase."))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func manifestDisplayMetadataRejectsMisleadingText() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let manifest = LatticeExtensionManifest(
            id: "com.lattice.bad-display-metadata",
            name: " Calmer\nLattice ",
            version: " 1\n.0 ",
            summary: " Softens\napp tone "
        )
        let validation = store.validate(manifest)
        #expect(validation.contains("Name must not have leading or trailing whitespace."))
        #expect(validation.contains("Name must be one line."))
        #expect(validation.contains("Version must not have leading or trailing whitespace."))
        #expect(validation.contains("Version must be one line."))
        #expect(validation.contains("Summary must not have leading or trailing whitespace."))
        #expect(validation.contains("Summary must be one line."))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func entrypointRejectsMisleadingPaths() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let emptyEntrypoint = LatticeExtensionManifest(
            id: "com.lattice.empty-entrypoint",
            name: "Empty Entrypoint",
            version: "1",
            summary: "Empty strings remain equivalent to an unset optional entrypoint.",
            entrypoint: ""
        )
        #expect(store.validate(emptyEntrypoint).isEmpty)

        let whitespace = LatticeExtensionManifest(
            id: "com.lattice.whitespace-entrypoint",
            name: "Whitespace Entrypoint",
            version: "1",
            summary: "Whitespace is misleading.",
            entrypoint: " run.js "
        )
        let whitespaceMessages = store.validate(whitespace)
        #expect(whitespaceMessages.contains("Entrypoint must not have leading or trailing whitespace."))

        let multiline = LatticeExtensionManifest(
            id: "com.lattice.multiline-entrypoint",
            name: "Multiline Entrypoint",
            version: "1",
            summary: "Newlines are misleading.",
            entrypoint: "run\n.js"
        )
        #expect(store.validate(multiline).contains("Entrypoint must be one line."))

        let escaping = LatticeExtensionManifest(
            id: "com.lattice.escaping-entrypoint",
            name: "Escaping Entrypoint",
            version: "1",
            summary: "Path traversal is unsafe.",
            entrypoint: "scripts/../run.js"
        )
        #expect(store.validate(escaping).contains("Entrypoint must stay inside the extension bundle."))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func rollbackRejectsMismatchedManifestID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let original = LatticeExtensionManifest(
            id: "com.lattice.original",
            name: "Original",
            version: "1.0.0",
            summary: "Original extension."
        )
        let replacement = LatticeExtensionManifest(
            id: "com.lattice.replacement",
            name: "Replacement",
            version: "1.0.0",
            summary: "Replacement extension."
        )
        try store.writeGeneratedExtension(replacement)
        #expect(throws: Error.self) {
            try store.restoreExtension(manifestID: replacement.id, previousManifestData: JSONEncoder().encode(original))
        }
        #expect(store.load().first?.id == replacement.id)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func extensionStoreRejectsSymlinkedBundleForWriteLoadRollbackAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundle = root.appendingPathComponent("com.lattice.escape", isDirectory: true)
        let outsideManifest = outside.appendingPathComponent("lattice-extension.json")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = Data("outside-extension-data".utf8)
        try sentinel.write(to: outsideManifest)
        try FileManager.default.createSymbolicLink(at: bundle, withDestinationURL: outside)

        let store = LatticeExtensionStore(rootURL: root)
        let manifest = LatticeExtensionManifest(
            id: "com.lattice.escape",
            name: "Escape",
            version: "1",
            summary: "Symlink escape test."
        )
        #expect(throws: (any Error).self) {
            try store.writeGeneratedExtension(manifest)
        }
        #expect(try Data(contentsOf: outsideManifest) == sentinel)
        #expect(store.manifestData(for: manifest.id) == nil)
        #expect(store.load().isEmpty)
        #expect(throws: (any Error).self) {
            try store.restoreExtension(manifestID: manifest.id, previousManifestData: JSONEncoder().encode(manifest))
        }
        #expect(throws: (any Error).self) {
            try store.restoreExtension(manifestID: manifest.id, previousManifestData: nil)
        }
        #expect(try Data(contentsOf: outsideManifest) == sentinel)
    }

    @Test func skillStoreRejectsSymlinkedFolderForWriteLoadRollbackAndDelete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("escape", isDirectory: true)
        let outsideSkill = outside.appendingPathComponent("SKILL.md")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = Data("outside-skill-data".utf8)
        try sentinel.write(to: outsideSkill)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)

        let store = LatticeSkillStore(rootURL: root, globalRoots: [])
        let patch = LatticeSkillPatch(id: "escape", title: "Escape", summary: "Symlink escape test.", markdown: "# Escape\n\nDo not follow links.")
        #expect(throws: (any Error).self) {
            try store.writeGeneratedSkill(patch)
        }
        #expect(store.load().isEmpty)
        #expect(store.snapshotSkill(id: patch.id).skillData == nil)
        let snapshot = LatticeSkillSnapshot(
            id: patch.id,
            skillData: Data("rollback".utf8),
            sourceRaw: LatticeSkillSource.generated.rawValue,
            originalPath: nil,
            ownerExtensionID: nil,
            wasDeletedGlobalSkill: false
        )
        #expect(throws: (any Error).self) {
            try store.restoreSkill(snapshot)
        }
        #expect(throws: (any Error).self) {
            try store.deleteSkill(id: patch.id)
        }
        #expect(throws: (any Error).self) {
            _ = try store.deleteSkill(id: patch.id, ownedByExtensionID: "com.lattice.owner")
        }
        #expect(try Data(contentsOf: outsideSkill) == sentinel)
    }

    @Test func enablementOnlyKeepsValidRuntimeExtensions() {
        let runtime = LatticeExtensionRecord(
            id: "runtime",
            name: "Runtime",
            version: "1",
            summary: "Has real patches.",
            permissions: [.editUI],
            uiTargets: [],
            stylePatches: [.init(target: .composer, tintHex: "#88CCFF")],
            manifestURL: URL(fileURLWithPath: "/runtime"),
            bundleURL: URL(fileURLWithPath: "/runtime"),
            validationMessages: []
        )
        let previewOnly = LatticeExtensionRecord(
            id: "preview",
            name: "Preview",
            version: "1",
            summary: "Preview-only.",
            permissions: [],
            uiTargets: [],
            operationPreviews: [.init(targetSurfaceID: "composer", operation: .relayout, summary: "Move composer.")],
            manifestURL: URL(fileURLWithPath: "/preview"),
            bundleURL: URL(fileURLWithPath: "/preview"),
            validationMessages: []
        )
        let layoutRuntime = LatticeExtensionRecord(
            id: "layout-runtime",
            name: "Layout Runtime",
            version: "1",
            summary: "Has real layout patches.",
            permissions: [.editUI],
            uiTargets: ["composer"],
            layoutPatches: [.init(target: .composer, density: .compact)],
            manifestURL: URL(fileURLWithPath: "/layout-runtime"),
            bundleURL: URL(fileURLWithPath: "/layout-runtime"),
            validationMessages: []
        )
        let invalidRuntime = LatticeExtensionRecord(
            id: "invalid",
            name: "Invalid",
            version: "1",
            summary: "Invalid but has patches.",
            permissions: [.editUI],
            uiTargets: [],
            stylePatches: [.init(target: .composer, tintHex: "#88CCFF")],
            manifestURL: URL(fileURLWithPath: "/invalid"),
            bundleURL: URL(fileURLWithPath: "/invalid"),
            validationMessages: ["Invalid"]
        )
        let result = LatticeExtensionEnablementPolicy.refresh(
            records: [runtime, previewOnly, layoutRuntime, invalidRuntime],
            storedEnabledIDs: ["preview", "invalid", "missing"],
            knownIDs: []
        )
        #expect(result.enabledIDs.isEmpty)
        #expect(result.knownIDs == ["layout-runtime", "runtime"])

        let explicitlyApplied = LatticeExtensionEnablementPolicy.refresh(
            records: [runtime],
            storedEnabledIDs: ["runtime"],
            knownIDs: []
        )
        #expect(explicitlyApplied.enabledIDs == ["runtime"])

        let disabledKnown = LatticeExtensionEnablementPolicy.refresh(
            records: [runtime],
            storedEnabledIDs: [],
            knownIDs: ["runtime", "formerly-invalid"]
        )
        #expect(disabledKnown.enabledIDs.isEmpty)
        #expect(disabledKnown.knownIDs == ["runtime", "formerly-invalid"])
    }

    @Test func operationPreviewRejectsUnsupportedSurfaceOperation() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let manifest = LatticeExtensionManifest(
            id: "com.lattice.bad-operation-preview",
            name: "Bad Operation",
            version: "1.0.0",
            summary: "Invalid operation.",
            operationPreviews: [
                .init(targetSurfaceID: "models", operation: .addControl, summary: "Add a button where controls are unsupported.")
            ]
        )
        #expect(store.validate(manifest).contains { $0.contains("Add control is not supported on Models") })
        #expect(!manifest.hasRuntimePatches)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func operationPreviewsRequireDeclaredPermissions() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let manifest = LatticeExtensionManifest(
            id: "com.lattice.missing-operation-permissions",
            name: "Missing Operation Permissions",
            version: "1.0.0",
            summary: "Missing permissions for requested operations.",
            operationPreviews: [
                .init(targetSurfaceID: "composer", operation: .relayout, summary: "Move the composer."),
                .init(targetSurfaceID: "extensions", operation: .addAutomation, summary: "Add a morning brief.")
            ]
        )
        let validation = store.validate(manifest)
        #expect(validation.contains("Relayout operation previews require Edit UI permission."))
        #expect(validation.contains("Add automation operation previews require Edit UI permission."))
        #expect(validation.contains("Add automation operation previews require Automation permission."))

        let permitted = LatticeExtensionManifest(
            id: "com.lattice.permitted-operation",
            name: "Permitted Operation",
            version: "1.0.0",
            summary: "A permitted relayout preview.",
            permissions: [.editUI],
            operationPreviews: [
                .init(targetSurfaceID: "composer", operation: .relayout, summary: "Move the composer.")
            ]
        )
        #expect(store.validate(permitted).isEmpty)
        #expect(LatticeExtensionOperationRuntimePolicy.execution(for: permitted.operationPreviews[0], in: permitted) == .recordedOnly)

        let executableRestyle = LatticeExtensionManifest(
            id: "com.lattice.executable-restyle",
            name: "Executable Restyle",
            version: "1.0.0",
            summary: "A backed restyle preview.",
            permissions: [.editUI],
            stylePatches: [.init(target: .composer, tintHex: "#88CCFF")],
            operationPreviews: [
                .init(targetSurfaceID: "composer", operation: .restyle, summary: "Tint the composer.")
            ]
        )
        #expect(LatticeExtensionOperationRuntimePolicy.execution(for: executableRestyle.operationPreviews[0], in: executableRestyle) == .executable)

        let executableLayout = LatticeExtensionManifest(
            id: "com.lattice.executable-layout",
            name: "Executable Layout",
            version: "1.0.0",
            summary: "A backed relayout preview.",
            permissions: [.editUI],
            uiTargets: ["composer"],
            layoutPatches: [.init(target: .composer, density: .compact)],
            operationPreviews: [
                .init(targetSurfaceID: "composer", operation: .relayout, summary: "Make the composer compact.")
            ]
        )
        #expect(LatticeExtensionOperationRuntimePolicy.execution(for: executableLayout.operationPreviews[0], in: executableLayout) == .executable)

        let executableCopy = LatticeExtensionManifest(
            id: "com.lattice.executable-copy",
            name: "Executable Copy",
            version: "1.0.0",
            summary: "A backed copy preview.",
            permissions: [.editUI],
            copyPatches: [.init(target: .askButton, text: "Ask softly")],
            operationPreviews: [
                .init(targetSurfaceID: "overlay", operation: .rewriteCopy, summary: "Rename the ask button.")
            ]
        )
        #expect(LatticeExtensionOperationRuntimePolicy.execution(for: executableCopy.operationPreviews[0], in: executableCopy) == .executable)

        let executableControl = LatticeExtensionManifest(
            id: "com.lattice.executable-control",
            name: "Executable Control",
            version: "1.0.0",
            summary: "A backed add-control preview.",
            permissions: [.editUI],
            promptTemplates: [.init(invocation: "/calm", title: "Calm", prompt: "Make this calmer.")],
            operationPreviews: [
                .init(targetSurfaceID: "composer", operation: .addControl, summary: "Add a calm prompt command.")
            ]
        )
        #expect(LatticeExtensionOperationRuntimePolicy.execution(for: executableControl.operationPreviews[0], in: executableControl) == .executable)
        #expect(LatticeExtensionOperationRuntimePolicy.executableOperationCount(in: executableControl) == 1)
        #expect(LatticeExtensionOperationRuntimePolicy.recordedOnlyOperationCount(in: executableControl) == 0)

        let executableSkill = LatticeExtensionManifest(
            id: "com.lattice.executable-skill",
            name: "Executable Skill",
            version: "1.0.0",
            summary: "A backed add-skill preview.",
            permissions: [.editUI],
            skillPatches: [.init(id: "subagents", title: "Subagents", summary: "Use helper agents.", markdown: "# Subagents\n\nUse helper agents.")],
            operationPreviews: [
                .init(targetSurfaceID: "extensions", operation: .addSkill, summary: "Add a subagents skill.")
            ]
        )
        #expect(LatticeExtensionOperationRuntimePolicy.execution(for: executableSkill.operationPreviews[0], in: executableSkill) == .executable)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func layoutPatchesRequirePermissionAndMatchingTarget() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let missingPermission = LatticeExtensionManifest(
            id: "com.lattice.layout-missing-permission",
            name: "Layout Missing Permission",
            version: "1",
            summary: "Missing permission.",
            layoutPatches: [.init(target: .composer, density: .compact)]
        )
        #expect(store.validate(missingPermission).contains("Layout patches require Edit UI permission."))

        let wrongTarget = LatticeExtensionManifest(
            id: "com.lattice.layout-wrong-target",
            name: "Layout Wrong Target",
            version: "1",
            summary: "Wrong target.",
            permissions: [.editUI],
            uiTargets: ["overlay"],
            layoutPatches: [.init(target: .composer, density: .compact)]
        )
        #expect(store.validate(wrongTarget).contains("Composer layout patches require composer in uiTargets."))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func operationPreviewTargetsRejectMisleadingWhitespace() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let manifest = LatticeExtensionManifest(
            id: "com.lattice.bad-operation-target",
            name: "Bad Operation Target",
            version: "1.0.0",
            summary: "Invalid operation target.",
            operationPreviews: [
                .init(targetSurfaceID: " composer\n", operation: .relayout, summary: "Move composer.")
            ]
        )
        let validation = store.validate(manifest)
        #expect(validation.contains { $0.contains("must not have leading or trailing whitespace") })
        #expect(validation.contains("Operation preview target must be one line."))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func operationPreviewTextRejectsMisleadingMetadata() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let manifest = LatticeExtensionManifest(
            id: "com.lattice.bad-operation-text",
            name: "Bad Operation Text",
            version: "1.0.0",
            summary: "Invalid operation metadata.",
            operationPreviews: [
                .init(targetSurfaceID: "composer", operation: .relayout, summary: " Move\ncomposer ", detail: " Details\nhere ")
            ]
        )
        let validation = store.validate(manifest)
        #expect(validation.contains("Operation preview summary for Composer must not have leading or trailing whitespace."))
        #expect(validation.contains("Operation preview summary for Composer must be one line."))
        #expect(validation.contains("Operation preview detail for Composer must not have leading or trailing whitespace."))
        #expect(validation.contains("Operation preview detail for Composer must be one line."))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func uiTargetsValidateAgainstSelfMap() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let manifest = LatticeExtensionManifest(
            id: "com.lattice.bad-targets",
            name: "Bad Targets",
            version: "1.0.0",
            summary: "Invalid targets.",
            uiTargets: [" composer", "spaceship", "composer"]
        )
        let validation = store.validate(manifest)
        #expect(validation.contains { $0.contains("must not have leading or trailing whitespace") })
        #expect(validation.contains("Unknown UI target: spaceship."))
        #expect(validation.contains("Duplicate UI target: composer."))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func copyPatchRejectsWhitespaceAndMissingPermission() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let manifest = LatticeExtensionManifest(
            id: "com.lattice.bad-copy",
            name: "Bad Copy",
            version: "1.0.0",
            summary: "Invalid copy.",
            copyPatches: [.init(target: .promptPlaceholder, text: " Ask\n")]
        )
        let validation = store.validate(manifest)
        #expect(validation.contains("Copy patches require Edit UI permission."))
        #expect(validation.contains { $0.contains("must not have leading or trailing whitespace") })
        #expect(validation.contains { $0.contains("must be one line") })
        try? FileManager.default.removeItem(at: root)
    }

    @Test func promptTemplatesValidateAsRuntimePatches() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LatticeExtensionStore(rootURL: root)
        let valid = LatticeExtensionManifest(
            id: "com.lattice.templates",
            name: "Templates",
            version: "1.0.0",
            summary: "Adds slash templates.",
            permissions: [.editUI],
            promptTemplates: [.init(invocation: "/summarize", title: "Summarize", prompt: "Summarize this.")]
        )
        #expect(valid.hasRuntimePatches)
        #expect(store.validate(valid).isEmpty)

        let invalid = LatticeExtensionManifest(
            id: "com.lattice.bad-templates",
            name: "Bad Templates",
            version: "1.0.0",
            summary: "Invalid templates.",
            permissions: [.editUI],
            promptTemplates: [
                .init(invocation: "/self-edit", title: "", prompt: ""),
                .init(invocation: "/bad command", title: "Bad", prompt: "No"),
                .init(invocation: "/messy", title: " Messy\nTitle ", detail: " Detail\nmetadata ", prompt: "Line one\nLine two")
            ]
        )
        let validation = store.validate(invalid)
        #expect(validation.contains { $0.contains("cannot replace /self-edit") })
        #expect(validation.contains { $0.contains("prompt is empty") })
        #expect(validation.contains { $0.contains("may only contain") })
        #expect(validation.contains("Prompt template /messy title must not have leading or trailing whitespace."))
        #expect(validation.contains("Prompt template /messy title must be one line."))
        #expect(validation.contains("Prompt template /messy detail must not have leading or trailing whitespace."))
        #expect(validation.contains("Prompt template /messy detail must be one line."))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func selfEditJobPersistsPriorEnabledStateAndDecodesLegacyRecords() throws {
        let previousSnapshot = LatticeSkillSnapshot(id: "subagents", skillData: Data("old".utf8), sourceRaw: "importedGlobal", originalPath: "/tmp/SKILL.md", ownerExtensionID: nil, wasDeletedGlobalSkill: false)
        let appliedSnapshot = LatticeSkillSnapshot(id: "subagents", skillData: Data("new".utf8), sourceRaw: "generated", originalPath: nil, ownerExtensionID: "com.lattice.calmer", wasDeletedGlobalSkill: false)
        let job = LatticeExtensionJobRecord(
            sessionID: UUID(),
            harnessThreadID: "thread-1",
            request: "Make Lattice calmer",
            manifestID: "com.lattice.calmer",
            manifestName: "Calmer Lattice",
            summary: "Softens app tone.",
            previousManifestData: nil,
            previousSkillSnapshots: [previousSnapshot],
            previousDisabledSkillIDs: ["subagents"],
            previousEnabled: false,
            appliedManifestData: Data("manifest".utf8),
            appliedSkillSnapshots: [appliedSnapshot],
            appliedEnabled: true
        )
        let decoded = try JSONDecoder().decode(LatticeExtensionJobRecord.self, from: JSONEncoder().encode(job))
        #expect(decoded.previousEnabled == false)
        #expect(decoded.previousSkillSnapshots == [previousSnapshot])
        #expect(decoded.previousDisabledSkillIDs == ["subagents"])
        #expect(decoded.appliedManifestData == Data("manifest".utf8))
        #expect(decoded.appliedSkillSnapshots == [appliedSnapshot])
        #expect(decoded.appliedEnabled == true)

        var legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        legacyObject.removeValue(forKey: "previousEnabled")
        legacyObject.removeValue(forKey: "previousSkillSnapshots")
        legacyObject.removeValue(forKey: "previousDisabledSkillIDs")
        legacyObject.removeValue(forKey: "appliedManifestData")
        legacyObject.removeValue(forKey: "appliedSkillSnapshots")
        legacyObject.removeValue(forKey: "appliedEnabled")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(LatticeExtensionJobRecord.self, from: legacyData)
        #expect(legacyDecoded.previousEnabled == nil)
        #expect(legacyDecoded.previousSkillSnapshots.isEmpty)
        #expect(legacyDecoded.previousDisabledSkillIDs == nil)
        #expect(legacyDecoded.appliedManifestData == nil)
        #expect(legacyDecoded.appliedSkillSnapshots.isEmpty)
        #expect(legacyDecoded.appliedEnabled == nil)
    }

    @Test func selfEditPreviewPersistsPriorEnabledStateAndDecodesLegacyRecords() throws {
        let editableManifest = LatticeExtensionManifest(
            id: "com.lattice.skills",
            name: "Lattice Skills",
            version: "1",
            summary: "Adds skills.",
            permissions: [.editUI],
            stylePatches: [.init(target: .composer, tintHex: "#223344", accentHex: "#8899AA", cornerRadius: 18)],
            layoutPatches: [.init(target: .composer, density: .compact)],
            copyPatches: [.init(target: .promptPlaceholder, text: "Ask Lattice")],
            promptTemplates: [.init(invocation: "/review", title: "Review", detail: "Review a change", prompt: "Review this change.")],
            skillPatches: [
                .init(id: "review-buddy", title: "Review Buddy", summary: "Review changes.", markdown: "# Review Buddy\n\nReview patches for risk."),
                .init(id: "subagents", title: "Subagents", summary: "Use helpers.", markdown: "# Subagents\n\nUse helper agents.")
            ],
            operationPreviews: [.init(targetSurfaceID: "extensions", operation: .addSkill, summary: "Add skills.", detail: "Creates reusable skills.")]
        )
        let editablePreview = LatticeExtensionPreviewRecord(
            id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            sessionID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            harnessThreadID: "thread-edit",
            request: "Add better skills",
            manifest: editableManifest,
            previousManifestData: Data("previous".utf8),
            previousSkillSnapshots: [
                .init(id: "review-buddy", skillData: nil, sourceRaw: nil, originalPath: nil, ownerExtensionID: nil, wasDeletedGlobalSkill: false),
                .init(id: "subagents", skillData: nil, sourceRaw: nil, originalPath: nil, ownerExtensionID: nil, wasDeletedGlobalSkill: false)
            ],
            previousDisabledSkillIDs: ["review-buddy"],
            previousEnabled: false,
            createdAt: Date(timeIntervalSince1970: 123)
        )
        let editedMetadataPreview = LatticeExtensionPreviewEditor.replacingMetadata(
            in: editablePreview,
            name: "Better Skills",
            version: "1.1.0",
            summary: "Adds reviewed reusable skills."
        )
        #expect(editedMetadataPreview.id == editablePreview.id)
        #expect(editedMetadataPreview.sessionID == editablePreview.sessionID)
        #expect(editedMetadataPreview.previousManifestData == editablePreview.previousManifestData)
        #expect(editedMetadataPreview.previousSkillSnapshots == editablePreview.previousSkillSnapshots)
        #expect(editedMetadataPreview.previousDisabledSkillIDs == ["review-buddy"])
        #expect(editedMetadataPreview.previousEnabled == false)
        #expect(editedMetadataPreview.createdAt == editablePreview.createdAt)
        #expect(editedMetadataPreview.manifest.id == editableManifest.id)
        #expect(editedMetadataPreview.manifest.name == "Better Skills")
        #expect(editedMetadataPreview.manifest.version == "1.1.0")
        #expect(editedMetadataPreview.manifest.summary == "Adds reviewed reusable skills.")
        #expect(editedMetadataPreview.manifest.skillPatches == editableManifest.skillPatches)
        let editedStylePreview = try LatticeExtensionPreviewEditor.replacingStylePatch(
            in: editablePreview,
            index: 0,
            tintHex: "#334455",
            accentHex: "#AABBCC",
            cornerRadius: 24
        )
        #expect(editedStylePreview.previousManifestData == editablePreview.previousManifestData)
        #expect(editedStylePreview.manifest.stylePatches[0].tintHex == "#334455")
        #expect(editedStylePreview.manifest.stylePatches[0].accentHex == "#AABBCC")
        #expect(editedStylePreview.manifest.stylePatches[0].cornerRadius == 24)
        #expect(editedStylePreview.manifest.layoutPatches == editableManifest.layoutPatches)
        let editedLayoutPreview = try LatticeExtensionPreviewEditor.replacingLayoutPatch(in: editablePreview, index: 0, density: .spacious)
        #expect(editedLayoutPreview.previousSkillSnapshots == editablePreview.previousSkillSnapshots)
        #expect(editedLayoutPreview.manifest.layoutPatches[0].density == .spacious)
        #expect(editedLayoutPreview.manifest.stylePatches == editableManifest.stylePatches)
        let editedCopyPreview = try LatticeExtensionPreviewEditor.replacingCopyPatch(in: editablePreview, target: .promptPlaceholder, text: "Ask calmly")
        #expect(editedCopyPreview.previousSkillSnapshots == editablePreview.previousSkillSnapshots)
        #expect(editedCopyPreview.previousDisabledSkillIDs == ["review-buddy"])
        #expect(editedCopyPreview.manifest.copyPatches.first { $0.target == .promptPlaceholder }?.text == "Ask calmly")
        #expect(editedCopyPreview.manifest.promptTemplates == editableManifest.promptTemplates)
        let editedTemplatePreview = try LatticeExtensionPreviewEditor.replacingPromptTemplate(
            in: editablePreview,
            originalInvocation: "/review",
            invocation: "/careful-review",
            title: "Careful Review",
            detail: "Review for risk",
            prompt: "Review this change for correctness and risk."
        )
        #expect(editedTemplatePreview.previousManifestData == editablePreview.previousManifestData)
        #expect(editedTemplatePreview.manifest.promptTemplates.first?.invocation == "/careful-review")
        #expect(editedTemplatePreview.manifest.promptTemplates.first?.title == "Careful Review")
        #expect(editedTemplatePreview.manifest.copyPatches == editableManifest.copyPatches)
        let editedOperationPreview = try LatticeExtensionPreviewEditor.replacingOperationPreview(
            in: editablePreview,
            index: 0,
            summary: "Add safer reusable skills.",
            detail: "Creates skill commands after Apply."
        )
        #expect(editedOperationPreview.previousEnabled == false)
        #expect(editedOperationPreview.manifest.operationPreviews[0].summary == "Add safer reusable skills.")
        #expect(editedOperationPreview.manifest.operationPreviews[0].detail == "Creates skill commands after Apply.")
        #expect(editedOperationPreview.manifest.skillPatches == editableManifest.skillPatches)
        let editedPreview = try LatticeExtensionPreviewEditor.replacingSkillPatch(
            in: editablePreview,
            skillID: "review-buddy",
            title: "Careful Reviewer",
            summary: "Review patches carefully.",
            markdown: "# Careful Reviewer\n\nCheck risks and edge cases."
        )
        #expect(editedPreview.id == editablePreview.id)
        #expect(editedPreview.sessionID == editablePreview.sessionID)
        #expect(editedPreview.previousManifestData == editablePreview.previousManifestData)
        #expect(editedPreview.previousSkillSnapshots == editablePreview.previousSkillSnapshots)
        #expect(editedPreview.previousDisabledSkillIDs == ["review-buddy"])
        #expect(editedPreview.previousEnabled == false)
        #expect(editedPreview.createdAt == editablePreview.createdAt)
        #expect(editedPreview.manifest.skillPatches.first { $0.id == "review-buddy" }?.title == "Careful Reviewer")
        #expect(editedPreview.manifest.skillPatches.first { $0.id == "review-buddy" }?.markdown.contains("edge cases") == true)
        #expect(editedPreview.manifest.skillPatches.first { $0.id == "subagents" } == editableManifest.skillPatches[1])
        #expect(throws: (any Error).self) {
            _ = try LatticeExtensionPreviewEditor.replacingSkillPatch(in: editablePreview, skillID: "missing", title: "Missing", summary: "", markdown: "# Missing")
        }
        #expect(throws: (any Error).self) {
            _ = try LatticeExtensionPreviewEditor.replacingStylePatch(in: editablePreview, index: 9, tintHex: nil, accentHex: nil, cornerRadius: nil)
        }
        #expect(throws: (any Error).self) {
            _ = try LatticeExtensionPreviewEditor.replacingLayoutPatch(in: editablePreview, index: 9, density: .comfortable)
        }
        #expect(throws: (any Error).self) {
            _ = try LatticeExtensionPreviewEditor.replacingCopyPatch(in: editablePreview, target: .askButton, text: "Ask")
        }
        #expect(throws: (any Error).self) {
            _ = try LatticeExtensionPreviewEditor.replacingPromptTemplate(in: editablePreview, originalInvocation: "/missing", invocation: "/missing", title: "Missing", detail: "", prompt: "Missing")
        }
        #expect(throws: (any Error).self) {
            _ = try LatticeExtensionPreviewEditor.replacingOperationPreview(in: editablePreview, index: 9, summary: "Missing", detail: "")
        }

        let preview = LatticeExtensionPreviewRecord(
            sessionID: UUID(),
            harnessThreadID: "thread-1",
            request: "Preview calmer Lattice",
            manifest: LatticeExtensionManifest(id: "com.lattice.calmer", name: "Calmer Lattice", version: "1", summary: "Softens app tone."),
            previousManifestData: nil,
            previousDisabledSkillIDs: ["subagents"],
            previousEnabled: true
        )
        let decoded = try JSONDecoder().decode(LatticeExtensionPreviewRecord.self, from: JSONEncoder().encode(preview))
        #expect(decoded.previousEnabled == true)
        #expect(decoded.previousSkillSnapshots.isEmpty)
        #expect(decoded.previousDisabledSkillIDs == ["subagents"])

        var legacyObject = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(preview)) as? [String: Any])
        legacyObject.removeValue(forKey: "previousEnabled")
        legacyObject.removeValue(forKey: "previousSkillSnapshots")
        legacyObject.removeValue(forKey: "previousDisabledSkillIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(LatticeExtensionPreviewRecord.self, from: legacyData)
        #expect(legacyDecoded.previousEnabled == nil)
        #expect(legacyDecoded.previousSkillSnapshots.isEmpty)
        #expect(legacyDecoded.previousDisabledSkillIDs == nil)
    }

    @Test func skillEnablementRollbackRestoresOnlyAffectedSkills() {
        let previous = LatticeSkillEnablementRollbackPolicy.disabledSnapshot(
            affectedSkillIDs: ["subagents", "review"],
            disabledSkillIDs: ["subagents", "unrelated"]
        )
        #expect(previous == ["subagents"])

        let restored = LatticeSkillEnablementRollbackPolicy.restoredDisabledIDs(
            current: ["review", "unrelated"],
            affectedSkillIDs: ["subagents", "review"],
            previousDisabledSkillIDs: Set(previous)
        )
        #expect(restored == ["subagents", "unrelated"])
    }
}
