import Foundation
import LatticeCore
import SwiftUI

struct EditableSelfEditSkillDraft: Equatable {
    var title: String
    var summary: String
    var markdown: String
}

struct EditableSelfEditManifestDraft: Equatable {
    var name: String
    var version: String
    var summary: String
}

struct EditableSelfEditStylePatchDraft: Equatable {
    var tintHex: String
    var accentHex: String
    var cornerRadius: String
}

struct EditableSelfEditLayoutPatchDraft: Equatable {
    var density: LatticeLayoutDensity
}

struct EditableSelfEditCopyPatchDraft: Equatable {
    var text: String
}

struct EditableSelfEditPromptTemplateDraft: Equatable {
    var invocation: String
    var title: String
    var detail: String
    var prompt: String
}

struct EditableSelfEditOperationPreviewDraft: Equatable {
    var summary: String
    var detail: String
}


/// Owns self-edit preview draft maps and pure CRUD against LatticeExtensionPreviewEditor.
@MainActor
final class SelfEditDraftStore: ObservableObject {
    @Published var editableSelfEditManifestDrafts: [UUID: EditableSelfEditManifestDraft] = [:]
    @Published var editableSelfEditSkillDrafts: [String: EditableSelfEditSkillDraft] = [:]
    @Published var editableSelfEditStylePatchDrafts: [String: EditableSelfEditStylePatchDraft] = [:]
    @Published var editableSelfEditLayoutPatchDrafts: [String: EditableSelfEditLayoutPatchDraft] = [:]
    @Published var editableSelfEditCopyPatchDrafts: [String: EditableSelfEditCopyPatchDraft] = [:]
    @Published var editableSelfEditPromptTemplateDrafts: [String: EditableSelfEditPromptTemplateDraft] = [:]
    @Published var editableSelfEditOperationPreviewDrafts: [String: EditableSelfEditOperationPreviewDraft] = [:]
    @Published var expandedSelfEditSkillPreviewIDs: Set<String> = []
    @Published var expandedSelfEditReviewIDs: Set<UUID> = []

    func editableSelfEditManifest(preview: LatticeExtensionPreviewRecord) -> LatticeExtensionManifest {
        let draft = editableSelfEditManifestDraft(preview: preview)
        return LatticeExtensionPreviewEditor.replacingMetadata(
            in: preview,
            name: draft.name,
            version: draft.version,
            summary: draft.summary
        ).manifest
    }

    func editableSelfEditManifestDraft(preview: LatticeExtensionPreviewRecord) -> EditableSelfEditManifestDraft {
        editableSelfEditManifestDrafts[preview.id] ?? .init(
            name: preview.manifest.name,
            version: preview.manifest.version,
            summary: preview.manifest.summary
        )
    }

    func setEditableSelfEditManifestName(preview: LatticeExtensionPreviewRecord, name: String) {
        updateEditableSelfEditManifestDraft(preview: preview) { $0.name = name }
    }

    func setEditableSelfEditManifestVersion(preview: LatticeExtensionPreviewRecord, version: String) {
        updateEditableSelfEditManifestDraft(preview: preview) { $0.version = version }
    }

    func setEditableSelfEditManifestSummary(preview: LatticeExtensionPreviewRecord, summary: String) {
        updateEditableSelfEditManifestDraft(preview: preview) { $0.summary = summary }
    }

    func isEditableSelfEditManifestDirty(preview: LatticeExtensionPreviewRecord) -> Bool {
        let draft = editableSelfEditManifestDraft(preview: preview)
        return draft.name != preview.manifest.name
            || draft.version != preview.manifest.version
            || draft.summary != preview.manifest.summary
    }

    func resetEditableSelfEditManifest(previewID: UUID) {
        editableSelfEditManifestDrafts.removeValue(forKey: previewID)
    }

    private func updateEditableSelfEditManifestDraft(preview: LatticeExtensionPreviewRecord, mutate: (inout EditableSelfEditManifestDraft) -> Void) {
        var draft = editableSelfEditManifestDraft(preview: preview)
        mutate(&draft)
        editableSelfEditManifestDrafts[preview.id] = draft
    }

    func hasUnsavedSelfEditPreviewEdits(_ preview: LatticeExtensionPreviewRecord) -> Bool {
        if isEditableSelfEditManifestDirty(preview: preview) { return true }
        for (index, patch) in preview.manifest.stylePatches.enumerated()
        where isEditableSelfEditStylePatchDirty(previewID: preview.id, index: index, patch: patch) {
            return true
        }
        for (index, patch) in preview.manifest.layoutPatches.enumerated()
        where isEditableSelfEditLayoutPatchDirty(previewID: preview.id, index: index, patch: patch) {
            return true
        }
        for patch in preview.manifest.copyPatches
        where isEditableSelfEditCopyPatchDirty(previewID: preview.id, patch: patch) {
            return true
        }
        for template in preview.manifest.promptTemplates
        where isEditableSelfEditPromptTemplateDirty(previewID: preview.id, template: template) {
            return true
        }
        for (index, operationPreview) in preview.manifest.operationPreviews.enumerated()
        where isEditableSelfEditOperationPreviewDirty(previewID: preview.id, index: index, preview: operationPreview) {
            return true
        }
        for skill in preview.manifest.skillPatches
        where isEditableSelfEditSkillDirty(previewID: preview.id, skill: skill) {
            return true
        }
        return false
    }

    func editableSelfEditStylePatch(previewID: UUID, index: Int, patch: LatticeStylePatch) -> LatticeStylePatch {
        let draft = editableSelfEditStylePatchDraft(previewID: previewID, index: index, patch: patch)
        return .init(
            target: patch.target,
            tintHex: optionalPatchString(draft.tintHex),
            accentHex: optionalPatchString(draft.accentHex),
            cornerRadius: Double(draft.cornerRadius.trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }

    func editableSelfEditStylePatchDraft(previewID: UUID, index: Int, patch: LatticeStylePatch) -> EditableSelfEditStylePatchDraft {
        editableSelfEditStylePatchDrafts[selfEditStylePatchKey(previewID: previewID, index: index)] ?? .init(
            tintHex: patch.tintHex ?? "",
            accentHex: patch.accentHex ?? "",
            cornerRadius: patch.cornerRadius.map { String(format: "%.0f", $0) } ?? ""
        )
    }

    func setEditableSelfEditStyleTint(previewID: UUID, index: Int, patch: LatticeStylePatch, tintHex: String) {
        updateEditableSelfEditStylePatchDraft(previewID: previewID, index: index, patch: patch) { $0.tintHex = tintHex }
    }

    func setEditableSelfEditStyleAccent(previewID: UUID, index: Int, patch: LatticeStylePatch, accentHex: String) {
        updateEditableSelfEditStylePatchDraft(previewID: previewID, index: index, patch: patch) { $0.accentHex = accentHex }
    }

    func setEditableSelfEditStyleRadius(previewID: UUID, index: Int, patch: LatticeStylePatch, cornerRadius: String) {
        updateEditableSelfEditStylePatchDraft(previewID: previewID, index: index, patch: patch) { $0.cornerRadius = cornerRadius }
    }

    func isEditableSelfEditStylePatchDirty(previewID: UUID, index: Int, patch: LatticeStylePatch) -> Bool {
        editableSelfEditStylePatchDraft(previewID: previewID, index: index, patch: patch) != .init(
            tintHex: patch.tintHex ?? "",
            accentHex: patch.accentHex ?? "",
            cornerRadius: patch.cornerRadius.map { String(format: "%.0f", $0) } ?? ""
        )
    }

    func resetEditableSelfEditStylePatch(previewID: UUID, index: Int) {
        editableSelfEditStylePatchDrafts.removeValue(forKey: selfEditStylePatchKey(previewID: previewID, index: index))
    }

    func editableSelfEditLayoutPatch(previewID: UUID, index: Int, patch: LatticeLayoutPatch) -> LatticeLayoutPatch {
        let draft = editableSelfEditLayoutPatchDraft(previewID: previewID, index: index, patch: patch)
        return .init(target: patch.target, density: draft.density)
    }

    func editableSelfEditLayoutPatchDraft(previewID: UUID, index: Int, patch: LatticeLayoutPatch) -> EditableSelfEditLayoutPatchDraft {
        editableSelfEditLayoutPatchDrafts[selfEditLayoutPatchKey(previewID: previewID, index: index)] ?? .init(density: patch.density)
    }

    func setEditableSelfEditLayoutDensity(previewID: UUID, index: Int, patch: LatticeLayoutPatch, density: LatticeLayoutDensity) {
        editableSelfEditLayoutPatchDrafts[selfEditLayoutPatchKey(previewID: previewID, index: index)] = .init(density: density)
    }

    func isEditableSelfEditLayoutPatchDirty(previewID: UUID, index: Int, patch: LatticeLayoutPatch) -> Bool {
        editableSelfEditLayoutPatch(previewID: previewID, index: index, patch: patch) != patch
    }

    func resetEditableSelfEditLayoutPatch(previewID: UUID, index: Int) {
        editableSelfEditLayoutPatchDrafts.removeValue(forKey: selfEditLayoutPatchKey(previewID: previewID, index: index))
    }

    private func updateEditableSelfEditStylePatchDraft(previewID: UUID, index: Int, patch: LatticeStylePatch, mutate: (inout EditableSelfEditStylePatchDraft) -> Void) {
        let key = selfEditStylePatchKey(previewID: previewID, index: index)
        var draft = editableSelfEditStylePatchDraft(previewID: previewID, index: index, patch: patch)
        mutate(&draft)
        editableSelfEditStylePatchDrafts[key] = draft
    }

    func optionalPatchString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func editableSelfEditCopyPatch(previewID: UUID, patch: LatticeCopyPatch) -> LatticeCopyPatch {
        let draft = editableSelfEditCopyPatchDraft(previewID: previewID, patch: patch)
        return .init(target: patch.target, text: draft.text)
    }

    func editableSelfEditCopyPatchDraft(previewID: UUID, patch: LatticeCopyPatch) -> EditableSelfEditCopyPatchDraft {
        editableSelfEditCopyPatchDrafts[selfEditCopyPatchKey(previewID: previewID, target: patch.target)] ?? .init(text: patch.text)
    }

    func setEditableSelfEditCopyPatchText(previewID: UUID, patch: LatticeCopyPatch, text: String) {
        editableSelfEditCopyPatchDrafts[selfEditCopyPatchKey(previewID: previewID, target: patch.target)] = .init(text: text)
    }

    func isEditableSelfEditCopyPatchDirty(previewID: UUID, patch: LatticeCopyPatch) -> Bool {
        editableSelfEditCopyPatch(previewID: previewID, patch: patch) != patch
    }

    func resetEditableSelfEditCopyPatch(previewID: UUID, target: LatticeCopyTarget) {
        editableSelfEditCopyPatchDrafts.removeValue(forKey: selfEditCopyPatchKey(previewID: previewID, target: target))
    }

    func editableSelfEditPromptTemplate(previewID: UUID, template: LatticePromptTemplate) -> LatticePromptTemplate {
        let draft = editableSelfEditPromptTemplateDraft(previewID: previewID, template: template)
        return .init(invocation: draft.invocation, title: draft.title, detail: draft.detail, prompt: draft.prompt)
    }

    func editableSelfEditPromptTemplateDraft(previewID: UUID, template: LatticePromptTemplate) -> EditableSelfEditPromptTemplateDraft {
        editableSelfEditPromptTemplateDrafts[selfEditPromptTemplateKey(previewID: previewID, invocation: template.invocation)] ?? .init(
            invocation: template.invocation,
            title: template.title,
            detail: template.detail,
            prompt: template.prompt
        )
    }

    func setEditableSelfEditPromptTemplateInvocation(previewID: UUID, template: LatticePromptTemplate, invocation: String) {
        updateEditableSelfEditPromptTemplateDraft(previewID: previewID, template: template) { $0.invocation = invocation }
    }

    func setEditableSelfEditPromptTemplateTitle(previewID: UUID, template: LatticePromptTemplate, title: String) {
        updateEditableSelfEditPromptTemplateDraft(previewID: previewID, template: template) { $0.title = title }
    }

    func setEditableSelfEditPromptTemplateDetail(previewID: UUID, template: LatticePromptTemplate, detail: String) {
        updateEditableSelfEditPromptTemplateDraft(previewID: previewID, template: template) { $0.detail = detail }
    }

    func setEditableSelfEditPromptTemplatePrompt(previewID: UUID, template: LatticePromptTemplate, prompt: String) {
        updateEditableSelfEditPromptTemplateDraft(previewID: previewID, template: template) { $0.prompt = prompt }
    }

    func isEditableSelfEditPromptTemplateDirty(previewID: UUID, template: LatticePromptTemplate) -> Bool {
        editableSelfEditPromptTemplate(previewID: previewID, template: template) != template
    }

    func resetEditableSelfEditPromptTemplate(previewID: UUID, invocation: String) {
        editableSelfEditPromptTemplateDrafts.removeValue(forKey: selfEditPromptTemplateKey(previewID: previewID, invocation: invocation))
    }

    private func updateEditableSelfEditPromptTemplateDraft(previewID: UUID, template: LatticePromptTemplate, mutate: (inout EditableSelfEditPromptTemplateDraft) -> Void) {
        let key = selfEditPromptTemplateKey(previewID: previewID, invocation: template.invocation)
        var draft = editableSelfEditPromptTemplateDrafts[key] ?? .init(
            invocation: template.invocation,
            title: template.title,
            detail: template.detail,
            prompt: template.prompt
        )
        mutate(&draft)
        editableSelfEditPromptTemplateDrafts[key] = draft
    }

    func editableSelfEditOperationPreview(previewID: UUID, index: Int, preview: LatticeExtensionOperationPreview) -> LatticeExtensionOperationPreview {
        let draft = editableSelfEditOperationPreviewDraft(previewID: previewID, index: index, preview: preview)
        return .init(targetSurfaceID: preview.targetSurfaceID, operation: preview.operation, summary: draft.summary, detail: draft.detail)
    }

    func editableSelfEditOperationPreviewDraft(previewID: UUID, index: Int, preview: LatticeExtensionOperationPreview) -> EditableSelfEditOperationPreviewDraft {
        editableSelfEditOperationPreviewDrafts[selfEditOperationPreviewKey(previewID: previewID, index: index)] ?? .init(
            summary: preview.summary,
            detail: preview.detail
        )
    }

    func setEditableSelfEditOperationPreviewSummary(previewID: UUID, index: Int, preview: LatticeExtensionOperationPreview, summary: String) {
        updateEditableSelfEditOperationPreviewDraft(previewID: previewID, index: index, preview: preview) { $0.summary = summary }
    }

    func setEditableSelfEditOperationPreviewDetail(previewID: UUID, index: Int, preview: LatticeExtensionOperationPreview, detail: String) {
        updateEditableSelfEditOperationPreviewDraft(previewID: previewID, index: index, preview: preview) { $0.detail = detail }
    }

    func isEditableSelfEditOperationPreviewDirty(previewID: UUID, index: Int, preview: LatticeExtensionOperationPreview) -> Bool {
        editableSelfEditOperationPreview(previewID: previewID, index: index, preview: preview) != preview
    }

    func resetEditableSelfEditOperationPreview(previewID: UUID, index: Int) {
        editableSelfEditOperationPreviewDrafts.removeValue(forKey: selfEditOperationPreviewKey(previewID: previewID, index: index))
    }

    private func updateEditableSelfEditOperationPreviewDraft(previewID: UUID, index: Int, preview: LatticeExtensionOperationPreview, mutate: (inout EditableSelfEditOperationPreviewDraft) -> Void) {
        let key = selfEditOperationPreviewKey(previewID: previewID, index: index)
        var draft = editableSelfEditOperationPreviewDrafts[key] ?? .init(summary: preview.summary, detail: preview.detail)
        mutate(&draft)
        editableSelfEditOperationPreviewDrafts[key] = draft
    }

    func editableSelfEditSkillPatch(previewID: UUID, skill: LatticeSkillPatch) -> LatticeSkillPatch {
        let draft = editableSelfEditSkillDraft(previewID: previewID, skill: skill)
        return .init(id: skill.id, title: draft.title, summary: draft.summary, markdown: draft.markdown)
    }

    func editableSelfEditSkillDraft(previewID: UUID, skill: LatticeSkillPatch) -> EditableSelfEditSkillDraft {
        let key = selfEditSkillPreviewKey(previewID: previewID, skillID: skill.id)
        return editableSelfEditSkillDrafts[key] ?? .init(title: skill.title, summary: skill.summary, markdown: skill.markdown)
    }

    func setEditableSelfEditSkillTitle(previewID: UUID, skill: LatticeSkillPatch, title: String) {
        updateEditableSelfEditSkillDraft(previewID: previewID, skill: skill) { $0.title = title }
    }

    func setEditableSelfEditSkillSummary(previewID: UUID, skill: LatticeSkillPatch, summary: String) {
        updateEditableSelfEditSkillDraft(previewID: previewID, skill: skill) { $0.summary = summary }
    }

    func setEditableSelfEditSkillMarkdown(previewID: UUID, skill: LatticeSkillPatch, markdown: String) {
        updateEditableSelfEditSkillDraft(previewID: previewID, skill: skill) { $0.markdown = markdown }
    }

    func isEditableSelfEditSkillDirty(previewID: UUID, skill: LatticeSkillPatch) -> Bool {
        editableSelfEditSkillPatch(previewID: previewID, skill: skill) != skill
    }

    func resetEditableSelfEditSkill(previewID: UUID, skillID: String) {
        editableSelfEditSkillDrafts.removeValue(forKey: selfEditSkillPreviewKey(previewID: previewID, skillID: skillID))
    }

    private func updateEditableSelfEditSkillDraft(previewID: UUID, skill: LatticeSkillPatch, mutate: (inout EditableSelfEditSkillDraft) -> Void) {
        let key = selfEditSkillPreviewKey(previewID: previewID, skillID: skill.id)
        var draft = editableSelfEditSkillDrafts[key] ?? .init(title: skill.title, summary: skill.summary, markdown: skill.markdown)
        mutate(&draft)
        editableSelfEditSkillDrafts[key] = draft
    }

    func isSelfEditSkillPreviewExpanded(previewID: UUID, skillID: String) -> Bool {
        expandedSelfEditSkillPreviewIDs.contains(selfEditSkillPreviewKey(previewID: previewID, skillID: skillID))
    }

    func isSelfEditReviewExpanded(previewID: UUID) -> Bool {
        expandedSelfEditReviewIDs.contains(previewID)
    }

    func setSelfEditReviewExpanded(previewID: UUID, isExpanded: Bool) {
        if isExpanded {
            expandedSelfEditReviewIDs.insert(previewID)
        } else {
            expandedSelfEditReviewIDs.remove(previewID)
        }
    }

    func toggleSelfEditSkillPreview(previewID: UUID, skillID: String) {
        let key = selfEditSkillPreviewKey(previewID: previewID, skillID: skillID)
        if expandedSelfEditSkillPreviewIDs.contains(key) {
            expandedSelfEditSkillPreviewIDs.remove(key)
        } else {
            expandedSelfEditSkillPreviewIDs.insert(key)
        }
    }

    private func selfEditSkillPreviewKey(previewID: UUID, skillID: String) -> String {
        "\(previewID.uuidString)::\(skillID)"
    }

    private func selfEditStylePatchKey(previewID: UUID, index: Int) -> String {
        "\(previewID.uuidString)::style::\(index)"
    }

    private func selfEditLayoutPatchKey(previewID: UUID, index: Int) -> String {
        "\(previewID.uuidString)::layout::\(index)"
    }

    private func selfEditCopyPatchKey(previewID: UUID, target: LatticeCopyTarget) -> String {
        "\(previewID.uuidString)::copy::\(target.rawValue)"
    }

    private func selfEditPromptTemplateKey(previewID: UUID, invocation: String) -> String {
        "\(previewID.uuidString)::template::\(invocation)"
    }

    private func selfEditOperationPreviewKey(previewID: UUID, index: Int) -> String {
        "\(previewID.uuidString)::operation::\(index)"
    }


}
