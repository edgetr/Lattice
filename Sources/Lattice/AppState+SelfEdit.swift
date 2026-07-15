import Foundation
import Combine
import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers
import LatticeCore

@MainActor
extension AppState {
    // MARK: - Self-edit draft façade

    var editableSelfEditManifestDrafts: [UUID: EditableSelfEditManifestDraft] {
        get { selfEditDrafts.editableSelfEditManifestDrafts }
        set { selfEditDrafts.editableSelfEditManifestDrafts = newValue }
    }
    var editableSelfEditSkillDrafts: [String: EditableSelfEditSkillDraft] {
        get { selfEditDrafts.editableSelfEditSkillDrafts }
        set { selfEditDrafts.editableSelfEditSkillDrafts = newValue }
    }
    var editableSelfEditStylePatchDrafts: [String: EditableSelfEditStylePatchDraft] {
        get { selfEditDrafts.editableSelfEditStylePatchDrafts }
        set { selfEditDrafts.editableSelfEditStylePatchDrafts = newValue }
    }
    var editableSelfEditLayoutPatchDrafts: [String: EditableSelfEditLayoutPatchDraft] {
        get { selfEditDrafts.editableSelfEditLayoutPatchDrafts }
        set { selfEditDrafts.editableSelfEditLayoutPatchDrafts = newValue }
    }
    var editableSelfEditCopyPatchDrafts: [String: EditableSelfEditCopyPatchDraft] {
        get { selfEditDrafts.editableSelfEditCopyPatchDrafts }
        set { selfEditDrafts.editableSelfEditCopyPatchDrafts = newValue }
    }
    var editableSelfEditPromptTemplateDrafts: [String: EditableSelfEditPromptTemplateDraft] {
        get { selfEditDrafts.editableSelfEditPromptTemplateDrafts }
        set { selfEditDrafts.editableSelfEditPromptTemplateDrafts = newValue }
    }
    var editableSelfEditOperationPreviewDrafts: [String: EditableSelfEditOperationPreviewDraft] {
        get { selfEditDrafts.editableSelfEditOperationPreviewDrafts }
        set { selfEditDrafts.editableSelfEditOperationPreviewDrafts = newValue }
    }
    var expandedSelfEditSkillPreviewIDs: Set<String> {
        get { selfEditDrafts.expandedSelfEditSkillPreviewIDs }
        set { selfEditDrafts.expandedSelfEditSkillPreviewIDs = newValue }
    }
    var expandedSelfEditReviewIDs: Set<UUID> {
        get { selfEditDrafts.expandedSelfEditReviewIDs }
        set { selfEditDrafts.expandedSelfEditReviewIDs = newValue }
    }

    func editableSelfEditManifest(preview: LatticeExtensionPreviewRecord) -> LatticeExtensionManifest {
        selfEditDrafts.editableSelfEditManifest(preview: preview)
    }
    func editableSelfEditManifestDraft(preview: LatticeExtensionPreviewRecord) -> EditableSelfEditManifestDraft {
        selfEditDrafts.editableSelfEditManifestDraft(preview: preview)
    }
    func setEditableSelfEditManifestName(preview: LatticeExtensionPreviewRecord, name: String) {
        selfEditDrafts.setEditableSelfEditManifestName(preview: preview, name: name)
    }
    func setEditableSelfEditManifestVersion(preview: LatticeExtensionPreviewRecord, version: String) {
        selfEditDrafts.setEditableSelfEditManifestVersion(preview: preview, version: version)
    }
    func setEditableSelfEditManifestSummary(preview: LatticeExtensionPreviewRecord, summary: String) {
        selfEditDrafts.setEditableSelfEditManifestSummary(preview: preview, summary: summary)
    }
    func isEditableSelfEditManifestDirty(preview: LatticeExtensionPreviewRecord) -> Bool {
        selfEditDrafts.isEditableSelfEditManifestDirty(preview: preview)
    }
    func resetEditableSelfEditManifest(previewID: UUID) {
        selfEditDrafts.resetEditableSelfEditManifest(previewID: previewID)
    }
    func editableSelfEditStylePatch(previewID: UUID, index: Int, patch: LatticeStylePatch) -> LatticeStylePatch {
        selfEditDrafts.editableSelfEditStylePatch(previewID: previewID, index: index, patch: patch)
    }
    func editableSelfEditStylePatchDraft(previewID: UUID, index: Int, patch: LatticeStylePatch) -> EditableSelfEditStylePatchDraft {
        selfEditDrafts.editableSelfEditStylePatchDraft(previewID: previewID, index: index, patch: patch)
    }
    func setEditableSelfEditStyleTint(previewID: UUID, index: Int, patch: LatticeStylePatch, tintHex: String) {
        selfEditDrafts.setEditableSelfEditStyleTint(previewID: previewID, index: index, patch: patch, tintHex: tintHex)
    }
    func setEditableSelfEditStyleAccent(previewID: UUID, index: Int, patch: LatticeStylePatch, accentHex: String) {
        selfEditDrafts.setEditableSelfEditStyleAccent(previewID: previewID, index: index, patch: patch, accentHex: accentHex)
    }
    func setEditableSelfEditStyleRadius(previewID: UUID, index: Int, patch: LatticeStylePatch, cornerRadius: String) {
        selfEditDrafts.setEditableSelfEditStyleRadius(previewID: previewID, index: index, patch: patch, cornerRadius: cornerRadius)
    }
    func isEditableSelfEditStylePatchDirty(previewID: UUID, index: Int, patch: LatticeStylePatch) -> Bool {
        selfEditDrafts.isEditableSelfEditStylePatchDirty(previewID: previewID, index: index, patch: patch)
    }
    func resetEditableSelfEditStylePatch(previewID: UUID, index: Int) {
        selfEditDrafts.resetEditableSelfEditStylePatch(previewID: previewID, index: index)
    }
    func editableSelfEditLayoutPatch(previewID: UUID, index: Int, patch: LatticeLayoutPatch) -> LatticeLayoutPatch {
        selfEditDrafts.editableSelfEditLayoutPatch(previewID: previewID, index: index, patch: patch)
    }
    func editableSelfEditLayoutPatchDraft(previewID: UUID, index: Int, patch: LatticeLayoutPatch) -> EditableSelfEditLayoutPatchDraft {
        selfEditDrafts.editableSelfEditLayoutPatchDraft(previewID: previewID, index: index, patch: patch)
    }
    func setEditableSelfEditLayoutDensity(previewID: UUID, index: Int, patch: LatticeLayoutPatch, density: LatticeLayoutDensity) {
        selfEditDrafts.setEditableSelfEditLayoutDensity(previewID: previewID, index: index, patch: patch, density: density)
    }
    func isEditableSelfEditLayoutPatchDirty(previewID: UUID, index: Int, patch: LatticeLayoutPatch) -> Bool {
        selfEditDrafts.isEditableSelfEditLayoutPatchDirty(previewID: previewID, index: index, patch: patch)
    }
    func resetEditableSelfEditLayoutPatch(previewID: UUID, index: Int) {
        selfEditDrafts.resetEditableSelfEditLayoutPatch(previewID: previewID, index: index)
    }
    func editableSelfEditCopyPatch(previewID: UUID, patch: LatticeCopyPatch) -> LatticeCopyPatch {
        selfEditDrafts.editableSelfEditCopyPatch(previewID: previewID, patch: patch)
    }
    func editableSelfEditCopyPatchDraft(previewID: UUID, patch: LatticeCopyPatch) -> EditableSelfEditCopyPatchDraft {
        selfEditDrafts.editableSelfEditCopyPatchDraft(previewID: previewID, patch: patch)
    }
    func setEditableSelfEditCopyPatchText(previewID: UUID, patch: LatticeCopyPatch, text: String) {
        selfEditDrafts.setEditableSelfEditCopyPatchText(previewID: previewID, patch: patch, text: text)
    }
    func isEditableSelfEditCopyPatchDirty(previewID: UUID, patch: LatticeCopyPatch) -> Bool {
        selfEditDrafts.isEditableSelfEditCopyPatchDirty(previewID: previewID, patch: patch)
    }
    func resetEditableSelfEditCopyPatch(previewID: UUID, target: LatticeCopyTarget) {
        selfEditDrafts.resetEditableSelfEditCopyPatch(previewID: previewID, target: target)
    }
    func editableSelfEditPromptTemplate(previewID: UUID, template: LatticePromptTemplate) -> LatticePromptTemplate {
        selfEditDrafts.editableSelfEditPromptTemplate(previewID: previewID, template: template)
    }
    func editableSelfEditPromptTemplateDraft(previewID: UUID, template: LatticePromptTemplate) -> EditableSelfEditPromptTemplateDraft {
        selfEditDrafts.editableSelfEditPromptTemplateDraft(previewID: previewID, template: template)
    }
    func setEditableSelfEditPromptTemplateInvocation(previewID: UUID, template: LatticePromptTemplate, invocation: String) {
        selfEditDrafts.setEditableSelfEditPromptTemplateInvocation(previewID: previewID, template: template, invocation: invocation)
    }
    func setEditableSelfEditPromptTemplateTitle(previewID: UUID, template: LatticePromptTemplate, title: String) {
        selfEditDrafts.setEditableSelfEditPromptTemplateTitle(previewID: previewID, template: template, title: title)
    }
    func setEditableSelfEditPromptTemplateDetail(previewID: UUID, template: LatticePromptTemplate, detail: String) {
        selfEditDrafts.setEditableSelfEditPromptTemplateDetail(previewID: previewID, template: template, detail: detail)
    }
    func setEditableSelfEditPromptTemplatePrompt(previewID: UUID, template: LatticePromptTemplate, prompt: String) {
        selfEditDrafts.setEditableSelfEditPromptTemplatePrompt(previewID: previewID, template: template, prompt: prompt)
    }
    func isEditableSelfEditPromptTemplateDirty(previewID: UUID, template: LatticePromptTemplate) -> Bool {
        selfEditDrafts.isEditableSelfEditPromptTemplateDirty(previewID: previewID, template: template)
    }
    func resetEditableSelfEditPromptTemplate(previewID: UUID, invocation: String) {
        selfEditDrafts.resetEditableSelfEditPromptTemplate(previewID: previewID, invocation: invocation)
    }
    func editableSelfEditOperationPreview(previewID: UUID, index: Int, preview: LatticeExtensionOperationPreview) -> LatticeExtensionOperationPreview {
        selfEditDrafts.editableSelfEditOperationPreview(previewID: previewID, index: index, preview: preview)
    }
    func editableSelfEditOperationPreviewDraft(previewID: UUID, index: Int, preview: LatticeExtensionOperationPreview) -> EditableSelfEditOperationPreviewDraft {
        selfEditDrafts.editableSelfEditOperationPreviewDraft(previewID: previewID, index: index, preview: preview)
    }
    func setEditableSelfEditOperationPreviewSummary(previewID: UUID, index: Int, preview: LatticeExtensionOperationPreview, summary: String) {
        selfEditDrafts.setEditableSelfEditOperationPreviewSummary(previewID: previewID, index: index, preview: preview, summary: summary)
    }
    func setEditableSelfEditOperationPreviewDetail(previewID: UUID, index: Int, preview: LatticeExtensionOperationPreview, detail: String) {
        selfEditDrafts.setEditableSelfEditOperationPreviewDetail(previewID: previewID, index: index, preview: preview, detail: detail)
    }
    func isEditableSelfEditOperationPreviewDirty(previewID: UUID, index: Int, preview: LatticeExtensionOperationPreview) -> Bool {
        selfEditDrafts.isEditableSelfEditOperationPreviewDirty(previewID: previewID, index: index, preview: preview)
    }
    func resetEditableSelfEditOperationPreview(previewID: UUID, index: Int) {
        selfEditDrafts.resetEditableSelfEditOperationPreview(previewID: previewID, index: index)
    }
    func editableSelfEditSkillPatch(previewID: UUID, skill: LatticeSkillPatch) -> LatticeSkillPatch {
        selfEditDrafts.editableSelfEditSkillPatch(previewID: previewID, skill: skill)
    }
    func editableSelfEditSkillDraft(previewID: UUID, skill: LatticeSkillPatch) -> EditableSelfEditSkillDraft {
        selfEditDrafts.editableSelfEditSkillDraft(previewID: previewID, skill: skill)
    }
    func setEditableSelfEditSkillTitle(previewID: UUID, skill: LatticeSkillPatch, title: String) {
        selfEditDrafts.setEditableSelfEditSkillTitle(previewID: previewID, skill: skill, title: title)
    }
    func setEditableSelfEditSkillSummary(previewID: UUID, skill: LatticeSkillPatch, summary: String) {
        selfEditDrafts.setEditableSelfEditSkillSummary(previewID: previewID, skill: skill, summary: summary)
    }
    func setEditableSelfEditSkillMarkdown(previewID: UUID, skill: LatticeSkillPatch, markdown: String) {
        selfEditDrafts.setEditableSelfEditSkillMarkdown(previewID: previewID, skill: skill, markdown: markdown)
    }
    func isEditableSelfEditSkillDirty(previewID: UUID, skill: LatticeSkillPatch) -> Bool {
        selfEditDrafts.isEditableSelfEditSkillDirty(previewID: previewID, skill: skill)
    }
    func resetEditableSelfEditSkill(previewID: UUID, skillID: String) {
        selfEditDrafts.resetEditableSelfEditSkill(previewID: previewID, skillID: skillID)
    }
    func toggleSelfEditSkillPreview(previewID: UUID, skillID: String) {
        selfEditDrafts.toggleSelfEditSkillPreview(previewID: previewID, skillID: skillID)
    }
    func isSelfEditSkillPreviewExpanded(previewID: UUID, skillID: String) -> Bool {
        selfEditDrafts.isSelfEditSkillPreviewExpanded(previewID: previewID, skillID: skillID)
    }

    func saveEditableSelfEditManifest(previewID: UUID) {
        guard let preview = selfEditPreviews.first(where: { $0.id == previewID }) else {
            setError("This self-edit preview no longer exists.")
            return
        }
        let draft = editableSelfEditManifestDraft(preview: preview)
        let updatedPreview = LatticeExtensionPreviewEditor.replacingMetadata(
            in: preview,
            name: draft.name,
            version: draft.version,
            summary: draft.summary
        )
        guard validateEditedSelfEditPreview(updatedPreview, original: preview) else { return }
        do {
            selfEditPreviews = try extensionPreviewStore.record(updatedPreview, in: selfEditPreviews)
            resetEditableSelfEditManifest(previewID: previewID)
            clearError()
        } catch {
            setError(error.localizedDescription, sessionID: preview.sessionID)
        }
    }

    func saveEditableSelfEditStylePatch(previewID: UUID, index: Int) {
        guard let preview = selfEditPreviews.first(where: { $0.id == previewID }),
              preview.manifest.stylePatches.indices.contains(index) else {
            setError("This style preview no longer exists.")
            return
        }
        let patch = preview.manifest.stylePatches[index]
        let draft = editableSelfEditStylePatchDraft(previewID: previewID, index: index, patch: patch)
        let trimmedRadius = draft.cornerRadius.trimmingCharacters(in: .whitespacesAndNewlines)
        let radius: Double?
        if trimmedRadius.isEmpty {
            radius = nil
        } else if let parsed = Double(trimmedRadius) {
            radius = parsed
        } else {
            setError("Corner radius must be a number.", sessionID: preview.sessionID)
            return
        }
        do {
            let updatedPreview = try LatticeExtensionPreviewEditor.replacingStylePatch(
                in: preview,
                index: index,
                tintHex: selfEditDrafts.optionalPatchString(draft.tintHex),
                accentHex: selfEditDrafts.optionalPatchString(draft.accentHex),
                cornerRadius: radius
            )
            guard validateEditedSelfEditPreview(updatedPreview, original: preview) else { return }
            selfEditPreviews = try extensionPreviewStore.record(updatedPreview, in: selfEditPreviews)
            resetEditableSelfEditStylePatch(previewID: previewID, index: index)
            clearError()
        } catch {
            setError(error.localizedDescription, sessionID: preview.sessionID)
        }
    }

    func saveEditableSelfEditLayoutPatch(previewID: UUID, index: Int) {
        guard let preview = selfEditPreviews.first(where: { $0.id == previewID }),
              preview.manifest.layoutPatches.indices.contains(index) else {
            setError("This layout preview no longer exists.")
            return
        }
        let patch = preview.manifest.layoutPatches[index]
        let draft = editableSelfEditLayoutPatchDraft(previewID: previewID, index: index, patch: patch)
        do {
            let updatedPreview = try LatticeExtensionPreviewEditor.replacingLayoutPatch(
                in: preview,
                index: index,
                density: draft.density
            )
            guard validateEditedSelfEditPreview(updatedPreview, original: preview) else { return }
            selfEditPreviews = try extensionPreviewStore.record(updatedPreview, in: selfEditPreviews)
            resetEditableSelfEditLayoutPatch(previewID: previewID, index: index)
            clearError()
        } catch {
            setError(error.localizedDescription, sessionID: preview.sessionID)
        }
    }

    func saveEditableSelfEditCopyPatch(previewID: UUID, target: LatticeCopyTarget) {
        guard let preview = selfEditPreviews.first(where: { $0.id == previewID }),
              let patch = preview.manifest.copyPatches.first(where: { $0.target == target }) else {
            setError("This copy preview no longer exists.")
            return
        }
        let draft = editableSelfEditCopyPatchDraft(previewID: previewID, patch: patch)
        do {
            let updatedPreview = try LatticeExtensionPreviewEditor.replacingCopyPatch(
                in: preview,
                target: target,
                text: draft.text
            )
            guard validateEditedSelfEditPreview(updatedPreview, original: preview) else { return }
            selfEditPreviews = try extensionPreviewStore.record(updatedPreview, in: selfEditPreviews)
            resetEditableSelfEditCopyPatch(previewID: previewID, target: target)
            clearError()
        } catch {
            setError(error.localizedDescription, sessionID: preview.sessionID)
        }
    }

    func saveEditableSelfEditPromptTemplate(previewID: UUID, invocation: String) {
        guard let preview = selfEditPreviews.first(where: { $0.id == previewID }),
              let template = preview.manifest.promptTemplates.first(where: { $0.invocation == invocation }) else {
            setError("This prompt template preview no longer exists.")
            return
        }
        let draft = editableSelfEditPromptTemplateDraft(previewID: previewID, template: template)
        do {
            let updatedPreview = try LatticeExtensionPreviewEditor.replacingPromptTemplate(
                in: preview,
                originalInvocation: invocation,
                invocation: draft.invocation,
                title: draft.title,
                detail: draft.detail,
                prompt: draft.prompt
            )
            guard validateEditedSelfEditPreview(updatedPreview, original: preview) else { return }
            selfEditPreviews = try extensionPreviewStore.record(updatedPreview, in: selfEditPreviews)
            resetEditableSelfEditPromptTemplate(previewID: previewID, invocation: invocation)
            clearError()
        } catch {
            setError(error.localizedDescription, sessionID: preview.sessionID)
        }
    }

    func saveEditableSelfEditOperationPreview(previewID: UUID, index: Int) {
        guard let preview = selfEditPreviews.first(where: { $0.id == previewID }),
              preview.manifest.operationPreviews.indices.contains(index) else {
            setError("This operation preview no longer exists.")
            return
        }
        let operationPreview = preview.manifest.operationPreviews[index]
        let draft = editableSelfEditOperationPreviewDraft(previewID: previewID, index: index, preview: operationPreview)
        do {
            let updatedPreview = try LatticeExtensionPreviewEditor.replacingOperationPreview(
                in: preview,
                index: index,
                summary: draft.summary,
                detail: draft.detail
            )
            guard validateEditedSelfEditPreview(updatedPreview, original: preview) else { return }
            selfEditPreviews = try extensionPreviewStore.record(updatedPreview, in: selfEditPreviews)
            resetEditableSelfEditOperationPreview(previewID: previewID, index: index)
            clearError()
        } catch {
            setError(error.localizedDescription, sessionID: preview.sessionID)
        }
    }

    func saveEditableSelfEditSkill(previewID: UUID, skillID: String) {
        guard let preview = selfEditPreviews.first(where: { $0.id == previewID }),
              let skill = preview.manifest.skillPatches.first(where: { $0.id == skillID }) else {
            setError("This skill preview no longer exists.")
            return
        }
        let draft = editableSelfEditSkillDraft(previewID: previewID, skill: skill)
        do {
            let updatedPreview = try LatticeExtensionPreviewEditor.replacingSkillPatch(
                in: preview,
                skillID: skillID,
                title: draft.title,
                summary: draft.summary,
                markdown: draft.markdown
            )
            guard validateEditedSelfEditPreview(updatedPreview, original: preview) else { return }
            selfEditPreviews = try extensionPreviewStore.record(updatedPreview, in: selfEditPreviews)
            resetEditableSelfEditSkill(previewID: previewID, skillID: skillID)
            clearError()
        } catch {
            setError(error.localizedDescription, sessionID: preview.sessionID)
        }
    }

    func validateEditedSelfEditPreview(_ updatedPreview: LatticeExtensionPreviewRecord, original: LatticeExtensionPreviewRecord) -> Bool {
        let validation = extensionStore.validate(updatedPreview.manifest)
            + LatticeSelfEditGeneratedSkillValidationPolicy.validationMessages(for: updatedPreview.manifest)
        guard validation.isEmpty else {
            setError(validation.joined(separator: " "), sessionID: original.sessionID)
            return false
        }
        return true
    }

    func clearExpandedSkillPreviews(for preview: LatticeExtensionPreviewRecord) {
        let prefix = "\(preview.id.uuidString)::"
        selfEditDrafts.expandedSelfEditSkillPreviewIDs = selfEditDrafts.expandedSelfEditSkillPreviewIDs.filter { !$0.hasPrefix(prefix) }
        selfEditDrafts.editableSelfEditSkillDrafts = selfEditDrafts.editableSelfEditSkillDrafts.filter { !$0.key.hasPrefix(prefix) }
        selfEditDrafts.editableSelfEditStylePatchDrafts = selfEditDrafts.editableSelfEditStylePatchDrafts.filter { !$0.key.hasPrefix(prefix) }
        selfEditDrafts.editableSelfEditLayoutPatchDrafts = selfEditDrafts.editableSelfEditLayoutPatchDrafts.filter { !$0.key.hasPrefix(prefix) }
        selfEditDrafts.editableSelfEditCopyPatchDrafts = selfEditDrafts.editableSelfEditCopyPatchDrafts.filter { !$0.key.hasPrefix(prefix) }
        selfEditDrafts.editableSelfEditPromptTemplateDrafts = selfEditDrafts.editableSelfEditPromptTemplateDrafts.filter { !$0.key.hasPrefix(prefix) }
        selfEditDrafts.editableSelfEditOperationPreviewDrafts = selfEditDrafts.editableSelfEditOperationPreviewDrafts.filter { !$0.key.hasPrefix(prefix) }
        selfEditDrafts.editableSelfEditManifestDrafts.removeValue(forKey: preview.id)
        selfEditDrafts.expandedSelfEditReviewIDs.remove(preview.id)
    }


    func hasUnsavedSelfEditPreviewEdits(_ preview: LatticeExtensionPreviewRecord) -> Bool {
        selfEditDrafts.hasUnsavedSelfEditPreviewEdits(preview)
    }
    func isSelfEditReviewExpanded(previewID: UUID) -> Bool {
        selfEditDrafts.isSelfEditReviewExpanded(previewID: previewID)
    }
    func setSelfEditReviewExpanded(previewID: UUID, isExpanded: Bool) {
        selfEditDrafts.setSelfEditReviewExpanded(previewID: previewID, isExpanded: isExpanded)
    }

    func acceptSelfEditPreview(_ preview: LatticeExtensionPreviewRecord) {
        do {
            let acceptedPreview = try materializedSelfEditPreview(preview)
            let validation = extensionStore.validate(acceptedPreview.manifest)
                + LatticeSelfEditGeneratedSkillValidationPolicy.validationMessages(for: acceptedPreview.manifest)
            guard validation.isEmpty else {
                setError(validation.joined(separator: " "), sessionID: preview.sessionID)
                return
            }
            applySelfEditPreview(acceptedPreview)
        } catch {
            setError(error.localizedDescription, sessionID: preview.sessionID)
        }
    }

    func materializedSelfEditPreview(_ preview: LatticeExtensionPreviewRecord) throws -> LatticeExtensionPreviewRecord {
        let metadata = editableSelfEditManifestDraft(preview: preview)
        var updated = LatticeExtensionPreviewEditor.replacingMetadata(
            in: preview,
            name: metadata.name,
            version: metadata.version,
            summary: metadata.summary
        )
        for (index, patch) in preview.manifest.stylePatches.enumerated() {
            let draft = editableSelfEditStylePatchDraft(previewID: preview.id, index: index, patch: patch)
            let radiusText = draft.cornerRadius.trimmingCharacters(in: .whitespacesAndNewlines)
            guard radiusText.isEmpty || Double(radiusText) != nil else {
                throw NSError(domain: "LatticeSelfEdit", code: 1, userInfo: [NSLocalizedDescriptionKey: "Corner radius must be a number."])
            }
            updated = try LatticeExtensionPreviewEditor.replacingStylePatch(
                in: updated,
                index: index,
                tintHex: selfEditDrafts.optionalPatchString(draft.tintHex),
                accentHex: selfEditDrafts.optionalPatchString(draft.accentHex),
                cornerRadius: radiusText.isEmpty ? nil : Double(radiusText)
            )
        }
        for (index, patch) in preview.manifest.layoutPatches.enumerated() {
            let draft = editableSelfEditLayoutPatchDraft(previewID: preview.id, index: index, patch: patch)
            updated = try LatticeExtensionPreviewEditor.replacingLayoutPatch(in: updated, index: index, density: draft.density)
        }
        for patch in preview.manifest.copyPatches {
            let draft = editableSelfEditCopyPatchDraft(previewID: preview.id, patch: patch)
            updated = try LatticeExtensionPreviewEditor.replacingCopyPatch(in: updated, target: patch.target, text: draft.text)
        }
        for template in preview.manifest.promptTemplates {
            let draft = editableSelfEditPromptTemplateDraft(previewID: preview.id, template: template)
            updated = try LatticeExtensionPreviewEditor.replacingPromptTemplate(
                in: updated,
                originalInvocation: template.invocation,
                invocation: draft.invocation,
                title: draft.title,
                detail: draft.detail,
                prompt: draft.prompt
            )
        }
        for (index, operation) in preview.manifest.operationPreviews.enumerated() {
            let draft = editableSelfEditOperationPreviewDraft(previewID: preview.id, index: index, preview: operation)
            updated = try LatticeExtensionPreviewEditor.replacingOperationPreview(in: updated, index: index, summary: draft.summary, detail: draft.detail)
        }
        for skill in preview.manifest.skillPatches {
            let draft = editableSelfEditSkillDraft(previewID: preview.id, skill: skill)
            updated = try LatticeExtensionPreviewEditor.replacingSkillPatch(
                in: updated,
                skillID: skill.id,
                title: draft.title,
                summary: draft.summary,
                markdown: draft.markdown
            )
        }
        return updated
    }

    func applySelfEditPreview(_ preview: LatticeExtensionPreviewRecord) {
        guard !hasUnsavedSelfEditPreviewEdits(preview) else {
            setError("The pending review edits could not be applied.", sessionID: preview.sessionID)
            return
        }
        let validation = extensionStore.validate(preview.manifest)
            + LatticeSelfEditGeneratedSkillValidationPolicy.validationMessages(for: preview.manifest)
        guard validation.isEmpty else {
            setError(validation.joined(separator: " "), sessionID: preview.sessionID)
            return
        }
        let previousManifest = preview.previousManifestData.flatMap { try? JSONDecoder().decode(LatticeExtensionManifest.self, from: $0) }
        guard LatticeExtensionChangeReviewBuilder.review(current: preview.manifest, previous: previousManifest).hasChanges else {
            setError("This review does not change anything. Discard it or ask for a revision.", sessionID: preview.sessionID)
            return
        }
        guard extensionStore.manifestData(for: preview.manifest.id) == preview.previousManifestData else {
            setError("This extension changed after the preview was created. Discard it and generate a new preview.", sessionID: preview.sessionID)
            return
        }
        let affectedSkillIDs = Set(preview.manifest.skillPatches.map(\.id))
        if !affectedSkillIDs.isEmpty {
            guard preview.previousSkillSnapshots.count == preview.manifest.skillPatches.count,
                  preview.manifest.skillPatches.map({ skillStore.snapshotSkill(id: $0.id) }) == preview.previousSkillSnapshots,
                  let previousDisabledSkillIDs = preview.previousDisabledSkillIDs,
                  LatticeSkillEnablementRollbackPolicy.disabledSnapshot(
                    affectedSkillIDs: affectedSkillIDs,
                    disabledSkillIDs: disabledSkillIDs
                  ) == previousDisabledSkillIDs else {
                setError("An affected skill changed after this preview was created. Discard it and generate a new preview.", sessionID: preview.sessionID)
                return
            }
        }
        let originalJobs = selfEditJobs
        let originalPreviews = selfEditPreviews
        let originalEnabledExtensionIDs = enabledExtensionIDs
        let originalDisabledSkillIDs = disabledSkillIDs
        let previousEnabled = preview.previousEnabled ?? enabledExtensionIDs.contains(preview.manifest.id)
        var writtenSkillIDs: [String] = []
        do {
            let appliedManifestURL = try extensionStore.writeGeneratedExtension(preview.manifest)
            for skill in preview.manifest.skillPatches {
                _ = try skillStore.writeGeneratedSkill(skill, ownerExtensionID: preview.manifest.id)
                writtenSkillIDs.append(skill.id)
                disabledSkillIDs.remove(skill.id)
            }
            let appliedManifestData = try Data(contentsOf: appliedManifestURL)
            let appliedSkillSnapshots = preview.manifest.skillPatches.map { skillStore.snapshotSkill(id: $0.id) }
            let applyStatus = selfEditApplyStatus(for: preview.manifest)
            let record = LatticeExtensionJobRecord(
                sessionID: preview.sessionID,
                harnessThreadID: preview.harnessThreadID,
                request: preview.request,
                manifestID: preview.manifest.id,
                manifestName: preview.manifest.name,
                summary: preview.manifest.summary,
                previousManifestData: preview.previousManifestData,
                previousSkillSnapshots: preview.previousSkillSnapshots,
                previousDisabledSkillIDs: preview.previousDisabledSkillIDs,
                previousEnabled: previousEnabled,
                appliedManifestData: appliedManifestData,
                appliedSkillSnapshots: appliedSkillSnapshots,
                appliedEnabled: preview.manifest.hasRuntimePatches,
                status: preview.manifest.hasRuntimePatches ? .applied : .recorded,
                statusDetail: applyStatus
            )
            selfEditJobs = try extensionJobStore.record(record, in: selfEditJobs)
            selfEditPreviews = try extensionPreviewStore.remove(preview.id, from: selfEditPreviews)
            clearExpandedSkillPreviews(for: preview)
            if preview.manifest.hasRuntimePatches {
                enabledExtensionIDs.insert(preview.manifest.id)
            } else {
                enabledExtensionIDs.remove(preview.manifest.id)
            }
            UserDefaults.standard.set(Array(enabledExtensionIDs).sorted(), forKey: Self.enabledExtensionIDsKey)
            UserDefaults.standard.set(Array(disabledSkillIDs).sorted(), forKey: Self.disabledSkillIDsKey)
            refreshExtensions()
            appendSelfEditStatus(applyStatus, to: preview.sessionID)
            clearError()
        } catch {
            try? extensionStore.restoreExtension(manifestID: preview.manifest.id, previousManifestData: preview.previousManifestData)
            if preview.previousSkillSnapshots.isEmpty {
                for skillID in writtenSkillIDs {
                    _ = try? skillStore.deleteSkill(id: skillID, ownedByExtensionID: preview.manifest.id)
                }
            } else {
                for snapshot in preview.previousSkillSnapshots {
                    try? skillStore.restoreSkill(snapshot, removingCurrentIfOwnedBy: preview.manifest.id)
                }
            }
            try? extensionJobStore.save(originalJobs)
            try? extensionPreviewStore.save(originalPreviews)
            selfEditJobs = originalJobs
            selfEditPreviews = originalPreviews
            enabledExtensionIDs = originalEnabledExtensionIDs
            disabledSkillIDs = originalDisabledSkillIDs
            UserDefaults.standard.set(Array(enabledExtensionIDs).sorted(), forKey: Self.enabledExtensionIDsKey)
            UserDefaults.standard.set(Array(disabledSkillIDs).sorted(), forKey: Self.disabledSkillIDsKey)
            refreshExtensions()
            setError(error.localizedDescription, sessionID: preview.sessionID)
        }
    }

    func discardSelfEditPreview(_ preview: LatticeExtensionPreviewRecord) {
        do {
            selfEditPreviews = try extensionPreviewStore.remove(preview.id, from: selfEditPreviews)
            clearExpandedSkillPreviews(for: preview)
            appendSelfEditStatus("Discarded \(preview.manifest.name).", to: preview.sessionID)
            clearError()
        } catch {
            setError(error.localizedDescription, sessionID: preview.sessionID)
        }
    }

    func appendSelfEditStatus(_ text: String, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.append(.init(role: .system, text: text))
        sessions[index].lastUpdated = .now
        persist()
    }

    func selfEditApplyStatus(for manifest: LatticeExtensionManifest) -> String {
        LatticeSelfEditApplyStatusPolicy.status(for: manifest)
    }

    func validReasoningEffort(for session: LatticeSession) -> ReasoningEffort? {
        guard let effort = session.reasoningEffort else { return nil }
        return reasoningOptions(for: session.backend, harnessID: effectiveHarnessID(for: session)).contains(where: { $0.effort == effort }) ? effort : nil
    }

    func openExtensionsFolder() {
        do {
            try extensionStore.prepareDirectory()
            folderActionMessage = NSWorkspace.shared.open(extensionStore.rootURL)
                ? "Opened the Extensions folder."
                : "The Extensions folder could not be opened."
        } catch {
            folderActionMessage = "The Extensions folder could not be prepared: \(error.localizedDescription)"
        }
    }

    func openSkillsFolder() {
        do {
            try skillStore.prepareDirectory()
            folderActionMessage = NSWorkspace.shared.open(skillStore.rootURL)
                ? "Opened the Skills folder."
                : "The Skills folder could not be opened."
        } catch {
            folderActionMessage = "The Skills folder could not be prepared: \(error.localizedDescription)"
        }
    }

    func isExtensionEnabled(_ record: LatticeExtensionRecord) -> Bool {
        enabledExtensionIDs.contains(record.id)
    }

    func setExtension(_ record: LatticeExtensionRecord, enabled: Bool) {
        guard record.isValid, record.hasRuntimePatches else { return }
        if enabled { enabledExtensionIDs.insert(record.id) } else { enabledExtensionIDs.remove(record.id) }
        UserDefaults.standard.set(Array(enabledExtensionIDs).sorted(), forKey: Self.enabledExtensionIDsKey)
        refreshExtensions()
    }

    func requestDeleteExtension(_ record: LatticeExtensionRecord) {
        guard !record.id.hasPrefix("invalid:") else { return }
        pendingDeleteExtensionRecord = record
        showDeleteExtensionConfirmation = true
    }

    func confirmPendingExtensionDeletion() {
        guard let record = pendingDeleteExtensionRecord else { return }
        pendingDeleteExtensionRecord = nil
        showDeleteExtensionConfirmation = false
        deleteExtension(record)
    }

    func cancelPendingExtensionDeletion() {
        pendingDeleteExtensionRecord = nil
        showDeleteExtensionConfirmation = false
    }

    func deleteExtension(_ record: LatticeExtensionRecord) {
        guard !record.id.hasPrefix("invalid:") else { return }
        let originalEnabledExtensionIDs = enabledExtensionIDs
        let originalDisabledSkillIDs = disabledSkillIDs
        let originalManifestData = extensionStore.manifestData(for: record.id)
        let deletionBaseline = LatticeExtensionDeletionRollbackPolicy.baseline(
            manifestID: record.id,
            currentManifestData: originalManifestData,
            jobs: selfEditJobs
        )
        let affectedSkillIDs = Set(record.skillPatches.map(\.id))
        let restoredSkillIDs = Set(deletionBaseline?.previousSkillSnapshots.map(\.id) ?? [])
        let originalSkillSnapshots = affectedSkillIDs
            .union(restoredSkillIDs)
            .sorted()
            .map { skillStore.snapshotSkill(id: $0) }
        do {
            try extensionStore.restoreExtension(manifestID: record.id, previousManifestData: nil)
            for snapshot in deletionBaseline?.previousSkillSnapshots ?? [] {
                try skillStore.restoreSkill(snapshot, removingCurrentIfOwnedBy: record.id)
            }
            for skill in record.skillPatches where !restoredSkillIDs.contains(skill.id) {
                if try skillStore.deleteSkill(id: skill.id, ownedByExtensionID: record.id) {
                    disabledSkillIDs.remove(skill.id)
                }
            }
            if let previousDisabledSkillIDs = deletionBaseline?.previousDisabledSkillIDs {
                disabledSkillIDs = LatticeSkillEnablementRollbackPolicy.restoredDisabledIDs(
                    current: disabledSkillIDs,
                    affectedSkillIDs: affectedSkillIDs,
                    previousDisabledSkillIDs: Set(previousDisabledSkillIDs)
                )
            }
            enabledExtensionIDs.remove(record.id)
            UserDefaults.standard.set(Array(enabledExtensionIDs).sorted(), forKey: Self.enabledExtensionIDsKey)
            UserDefaults.standard.set(Array(disabledSkillIDs).sorted(), forKey: Self.disabledSkillIDsKey)
            refreshExtensions()
            clearError()
        } catch {
            try? extensionStore.restoreExtension(manifestID: record.id, previousManifestData: originalManifestData)
            for snapshot in originalSkillSnapshots {
                try? skillStore.restoreSkill(snapshot)
            }
            enabledExtensionIDs = originalEnabledExtensionIDs
            disabledSkillIDs = originalDisabledSkillIDs
            UserDefaults.standard.set(Array(enabledExtensionIDs).sorted(), forKey: Self.enabledExtensionIDsKey)
            UserDefaults.standard.set(Array(disabledSkillIDs).sorted(), forKey: Self.disabledSkillIDsKey)
            refreshExtensions()
            setError(error.localizedDescription)
        }
    }

    func isSkillEnabled(_ record: LatticeSkillRecord) -> Bool {
        LatticeSkillActivationPolicy.isEnabled(
            record,
            disabledSkillIDs: disabledSkillIDs,
            enabledExtensionIDs: enabledExtensionIDs
        )
    }

    func canToggleSkill(_ record: LatticeSkillRecord) -> Bool {
        record.isValid && LatticeSkillActivationPolicy.ownerIsEnabled(record, enabledExtensionIDs: enabledExtensionIDs)
    }

    func skillOwnerDisabledMessage(_ record: LatticeSkillRecord) -> String? {
        guard let ownerExtensionID = record.ownerExtensionID,
              !enabledExtensionIDs.contains(ownerExtensionID) else { return nil }
        let ownerName = extensions.first(where: { $0.id == ownerExtensionID })?.name ?? ownerExtensionID
        return "Enable \(ownerName) to use this skill."
    }

    func setSkill(_ record: LatticeSkillRecord, enabled: Bool) {
        guard canToggleSkill(record) else { return }
        if enabled { disabledSkillIDs.remove(record.id) } else { disabledSkillIDs.insert(record.id) }
        UserDefaults.standard.set(Array(disabledSkillIDs).sorted(), forKey: Self.disabledSkillIDsKey)
        refreshSkills()
    }

    func requestDeleteSkill(_ record: LatticeSkillRecord) {
        guard record.canDelete else { return }
        pendingDeleteSkillRecord = record
        showDeleteSkillConfirmation = true
    }

    func confirmPendingSkillDeletion() {
        guard let record = pendingDeleteSkillRecord else { return }
        pendingDeleteSkillRecord = nil
        showDeleteSkillConfirmation = false
        deleteSkill(record)
    }

    func cancelPendingSkillDeletion() {
        pendingDeleteSkillRecord = nil
        showDeleteSkillConfirmation = false
    }

    func deleteSkill(_ record: LatticeSkillRecord) {
        do {
            try skillStore.deleteSkill(id: record.id)
            disabledSkillIDs.remove(record.id)
            UserDefaults.standard.set(Array(disabledSkillIDs).sorted(), forKey: Self.disabledSkillIDsKey)
            refreshSkills()
            clearError()
        } catch {
            setError(error.localizedDescription)
        }
    }

    func rollbackSelfEditJob(_ job: LatticeExtensionJobRecord) {
        guard job.canRollback else { return }
        let affectedSkillIDs = Set((job.previousSkillSnapshots + job.appliedSkillSnapshots).map(\.id))
        if let appliedManifestData = job.appliedManifestData,
           extensionStore.manifestData(for: job.manifestID) != appliedManifestData {
            setError("This extension changed after the self-edit was applied. Rollback was stopped to protect the newer change.", sessionID: job.sessionID)
            return
        }
        if let appliedEnabled = job.appliedEnabled,
           enabledExtensionIDs.contains(job.manifestID) != appliedEnabled {
            setError("This extension was toggled after the self-edit was applied. Rollback was stopped to protect that newer choice.", sessionID: job.sessionID)
            return
        }
        if !job.appliedSkillSnapshots.isEmpty,
           job.appliedSkillSnapshots.map({ skillStore.snapshotSkill(id: $0.id) }) != job.appliedSkillSnapshots {
            setError("An affected skill changed after the self-edit was applied. Rollback was stopped to protect the newer change.", sessionID: job.sessionID)
            return
        }
        if job.previousDisabledSkillIDs != nil,
           !disabledSkillIDs.intersection(affectedSkillIDs).isEmpty {
            setError("An affected skill was disabled after the self-edit was applied. Rollback was stopped to protect that newer choice.", sessionID: job.sessionID)
            return
        }
        let currentManifestData = extensionStore.manifestData(for: job.manifestID)
        let currentSkillSnapshots = affectedSkillIDs.sorted().map { skillStore.snapshotSkill(id: $0) }
        let currentEnabledExtensionIDs = enabledExtensionIDs
        let currentDisabledSkillIDs = disabledSkillIDs
        do {
            try extensionStore.restoreExtension(manifestID: job.manifestID, previousManifestData: job.previousManifestData)
            for snapshot in job.previousSkillSnapshots {
                try skillStore.restoreSkill(snapshot, removingCurrentIfOwnedBy: job.manifestID)
            }
            if let previousDisabledSkillIDs = job.previousDisabledSkillIDs {
                disabledSkillIDs = LatticeSkillEnablementRollbackPolicy.restoredDisabledIDs(
                    current: disabledSkillIDs,
                    affectedSkillIDs: affectedSkillIDs,
                    previousDisabledSkillIDs: Set(previousDisabledSkillIDs)
                )
                UserDefaults.standard.set(Array(disabledSkillIDs).sorted(), forKey: Self.disabledSkillIDsKey)
            }
            if let previousEnabled = job.previousEnabled {
                if previousEnabled {
                    enabledExtensionIDs.insert(job.manifestID)
                } else {
                    enabledExtensionIDs.remove(job.manifestID)
                }
                UserDefaults.standard.set(Array(enabledExtensionIDs).sorted(), forKey: Self.enabledExtensionIDsKey)
            } else if job.previousManifestData == nil {
                enabledExtensionIDs.remove(job.manifestID)
                UserDefaults.standard.set(Array(enabledExtensionIDs).sorted(), forKey: Self.enabledExtensionIDsKey)
            }
            refreshExtensions()
            selfEditJobs = try extensionJobStore.markReverted(job.id, detail: "Rolled back \(job.manifestName).", in: selfEditJobs)
            clearError()
        } catch {
            try? extensionStore.restoreExtension(manifestID: job.manifestID, previousManifestData: currentManifestData)
            for snapshot in currentSkillSnapshots {
                try? skillStore.restoreSkill(snapshot, removingCurrentIfOwnedBy: job.manifestID)
            }
            enabledExtensionIDs = currentEnabledExtensionIDs
            disabledSkillIDs = currentDisabledSkillIDs
            UserDefaults.standard.set(Array(enabledExtensionIDs).sorted(), forKey: Self.enabledExtensionIDsKey)
            UserDefaults.standard.set(Array(disabledSkillIDs).sorted(), forKey: Self.disabledSkillIDsKey)
            refreshExtensions()
            setError(error.localizedDescription, sessionID: job.sessionID)
        }
    }

    func tintColor(for target: LatticeStyleTarget) -> Color? {
        LatticeStylePresentation.tintColor(for: target, patches: activeStylePatches)
    }

    func cornerRadius(for target: LatticeStyleTarget, default value: CGFloat) -> CGFloat {
        LatticeStylePresentation.cornerRadius(for: target, default: value, patches: activeStylePatches)
    }

    func copyText(for target: LatticeCopyTarget, fallback: String) -> String {
        LatticeStylePresentation.copyText(for: target, fallback: fallback, patches: activeCopyPatches)
    }

    func composerLayoutDensity() -> LatticeLayoutDensity {
        LatticeStylePresentation.composerLayoutDensity(patches: activeLayoutPatches)
    }

    func composerSpacing() -> CGFloat {
        LatticeStylePresentation.composerSpacing(patches: activeLayoutPatches)
    }

    func composerMaxWidth() -> CGFloat {
        LatticeStylePresentation.composerMaxWidth(patches: activeLayoutPatches)
    }

    func composerHorizontalPadding() -> CGFloat {
        LatticeStylePresentation.composerHorizontalPadding(patches: activeLayoutPatches)
    }

    func composerVerticalPadding() -> CGFloat {
        switch composerLayoutDensity() {
        case .compact: 9
        case .comfortable: 13
        case .spacious: 18
        }
    }

    func updateCodex() {
        runCLIUpdate(provider: "codex", progress: "Updating Codex…", beforeVersion: codexCLIVersion, versionAfterRefresh: { self.codexCLIVersion }) {
            await Self.runDetectedCLIUpdate(
                executableName: "codex",
                homebrewFormula: "codex",
                homebrewCask: "codex",
                npmPackage: "@openai/codex",
                pnpmPackage: "@openai/codex",
                selfUpdateArguments: ["update"]
            )
        }
    }

    func checkGrokUpdate() {
        guard beginCLIAction(provider: "grok", progress: "Checking for update…", estimatedSeconds: 15) else { return }
        Task {
            let info = await grok.updateStatus()
            grokCLIInfo = info
            grokUpdateStatus = info.statusText
            cliActionMessages["grok"] = info.updateAvailable == true ? info.statusText : ""
            finishCLIAction("grok")
        }
    }

    func updateGrok() {
        runCLIUpdate(provider: "grok", progress: "Updating Grok…", beforeVersion: grokCLIInfo.currentVersion, versionAfterRefresh: { self.grokCLIInfo.currentVersion }) {
            await Self.runCommand("grok", ["update"])
        }
    }

    func updateOpenCode() {
        runCLIUpdate(provider: "opencode", progress: "Updating OpenCode…", beforeVersion: openCodeCLIVersion, versionAfterRefresh: { self.openCodeCLIVersion }) {
            await Self.runDetectedCLIUpdate(
                executableName: "opencode",
                homebrewFormula: "opencode",
                homebrewCask: nil,
                npmPackage: "opencode-ai",
                pnpmPackage: "opencode-ai",
                selfUpdateArguments: ["upgrade"],
                installerURL: "https://opencode.ai/install"
            )
        }
    }

    func updateAntigravity() {
        runCLIUpdate(provider: "antigravity", progress: "Updating Antigravity…", beforeVersion: antigravityCLIVersion, versionAfterRefresh: { self.antigravityCLIVersion }) {
            await Self.runDetectedCLIUpdate(
                executableName: "agy",
                homebrewFormula: nil,
                homebrewCask: "antigravity-cli",
                npmPackage: nil,
                pnpmPackage: nil,
                selfUpdateArguments: nil
            )
        }
    }

    func updatePi() {
        requestRuntimeAction(.update, runtime: .pi)
    }

    func checkHermesUpdate() {
        guard beginCLIAction(provider: "hermes", progress: "Checking for update…", estimatedSeconds: 15) else { return }
        Task {
            let info = await Self.hermesUpdateCheck()
            hermesCLIInfo = info
            cliActionMessages["hermes"] = info.updateAvailable == true ? info.statusText : ""
            finishCLIAction("hermes")
        }
    }

    func updateHermes() {
        requestRuntimeAction(.update, runtime: .hermes)
    }

    func runCLIInstall(provider: String, progress: String, executableName: String, action: @escaping () async -> (status: Int32, output: Data)) {
        guard beginCLIAction(provider: provider, progress: progress, estimatedSeconds: 90) else { return }
        let runtime = LatticeRuntimeID(rawValue: provider)
        let wasUpdate = runtime.flatMap { runtimeLifecycleStates[$0]?.phase } == .updating
        let lifecycleAction: RuntimeLifecycleAction = wasUpdate ? .update : .firstUseInstall
        let previousVersion: String?
        if runtime == .pi { previousVersion = piCLIVersion }
        else if runtime == .hermes { previousVersion = hermesCLIInfo.currentVersion }
        else { previousVersion = nil }
        let task = Task {
            let result = await action()
            let cancelled = Task.isCancelled
            await refreshConnections(refreshProviderCatalogs: provider == "opencode")
            cliActionMessages[provider] = CLIActionStatusPolicy.installMessage(
                executableName: executableName,
                status: result.status,
                output: result.output,
                executableAvailableAfterRefresh: ExecutableDiscovery.locate(executableName) != nil
            )
            if let runtime {
                let available = ExecutableDiscovery.locate(executableName) != nil
                if !cancelled,
                   RuntimeOwnershipPolicy.shouldRecordOwnership(
                    after: lifecycleAction,
                    status: result.status,
                    executableAvailable: available
                   ) {
                    latticeManagedRuntimeIDs.insert(runtime)
                    UserDefaults.standard.set(latticeManagedRuntimeIDs.map(\.rawValue).sorted(), forKey: Self.managedRuntimeIDsKey)
                }
                runtimeLifecycleStates[runtime] = RuntimeLifecycleState(
                    runtime: runtime,
                    phase: cancelled ? (wasUpdate ? .updateInterrupted : .cancelled) : (available ? .completed : .failed),
                    detail: cancelled ? "Runtime setup was cancelled and the child process was terminated." : cliActionMessages[provider],
                    installedVersion: runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion,
                    previousVersion: wasUpdate ? previousVersion : nil
                )
                runtimeInstallTasks[runtime] = nil
            }
            finishCLIAction(provider)
        }
        if let runtime { runtimeInstallTasks[runtime] = task }
    }

    func cancelRunningRuntimeAction(_ runtime: LatticeRuntimeID) {
        guard let task = runtimeInstallTasks[runtime] else { return }
        runtimeLifecycleStates[runtime] = RuntimeLifecycleState(
            runtime: runtime,
            phase: .cancelling,
            detail: "Stopping the runtime installer…",
            installedVersion: runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
        )
        task.cancel()
    }

    func runCLIUpdate(
        provider: String,
        progress: String,
        beforeVersion: String?,
        versionAfterRefresh: @escaping () -> String?,
        action: @escaping () async -> (status: Int32, output: Data)
    ) {
        guard beginCLIAction(provider: provider, progress: progress, estimatedSeconds: 60) else { return }
        Task {
            let result = await action()
            await refreshConnections(refreshProviderCatalogs: provider == "opencode")
            let afterVersion = versionAfterRefresh()
            cliActionMessages[provider] = CLIActionStatusPolicy.updateMessage(
                status: result.status,
                output: result.output,
                beforeVersion: beforeVersion,
                afterVersion: afterVersion
            )
            finishCLIAction(provider)
        }
    }

    static func commandOutput(_ executable: String, _ arguments: [String]) async -> String? {
        let result = await runCommand(executable, arguments)
        guard result.status == 0 else { return nil }
        let value = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func hermesUpdateInfo() async -> CLIUpdateInfo {
        guard let output = await commandOutput("hermes", ["version"]) else { return CLIUpdateInfo(detail: "Not installed") }
        let lines = output.split(separator: "\n").map(String.init)
        let firstLine = lines.first ?? output
        let prefix = "Hermes Agent v"
        let version: String?
        if firstLine.hasPrefix(prefix) {
            version = firstLine.dropFirst(prefix.count).split(separator: " ").first.map(String.init)
        } else {
            version = firstLine.split(separator: " ").last.map(String.init)
        }
        let updateLine = lines.first { $0.localizedCaseInsensitiveContains("update available") }
        return CLIUpdateInfo(currentVersion: version, latestVersion: CLIVersionDisplayPolicy.normalizedVersion(updateLine), updateAvailable: updateLine != nil, detail: updateLine)
    }

    static func hermesUpdateCheck() async -> CLIUpdateInfo {
        let current = (await hermesUpdateInfo()).currentVersion
        guard let output = await commandOutput("hermes", ["update", "--check"]) else {
            return CLIUpdateInfo(currentVersion: current, detail: "Update check failed")
        }
        let lines = output.split(separator: "\n").map(String.init)
        let updateLine = lines.first { $0.localizedCaseInsensitiveContains("update available") }
        let upToDate = lines.contains { $0.localizedCaseInsensitiveContains("up to date") || $0.localizedCaseInsensitiveContains("already") }
        return CLIUpdateInfo(
            currentVersion: current,
            latestVersion: CLIVersionDisplayPolicy.normalizedVersion(updateLine),
            updateAvailable: updateLine != nil ? true : (upToDate ? false : nil),
            releaseNotes: CLIVersionDisplayPolicy.releaseNotes(from: output),
            detail: updateLine ?? lines.last
        )
    }

    static func runDetectedCLIUpdate(
        executableName: String,
        homebrewFormula: String?,
        homebrewCask: String?,
        npmPackage: String?,
        pnpmPackage: String?,
        selfUpdateArguments: [String]?,
        installerURL: String? = nil
    ) async -> (status: Int32, output: Data) {
        let source = await cliInstallSource(
            executableName: executableName,
            homebrewFormula: homebrewFormula,
            homebrewCask: homebrewCask,
            npmPackage: npmPackage,
            pnpmPackage: pnpmPackage
        )
        let directArguments = executableName == "opencode" ? selfUpdateArguments.map { $0 + ["--method", "curl"] } : selfUpdateArguments
        if let plan = CLIInstallResolver.updatePlan(
            executableName: executableName,
            source: source,
            homebrewFormula: homebrewFormula,
            homebrewCask: homebrewCask,
            npmPackage: npmPackage,
            pnpmPackage: pnpmPackage,
            selfUpdateArguments: selfUpdateArguments,
            directArguments: directArguments
        ) {
            let result = await runCommand(plan.executable, plan.arguments)
            if result.status == 0 { return result }
            if source == .direct {
                if let installerURL { return await runRemoteInstallerScript(installerURL) }
                return result
            }
            return result
        }

        if let selfUpdateArguments {
            let result = await runCommand(executableName, selfUpdateArguments)
            if result.status == 0 { return result }
        }

        if let homebrewCask, await isHomebrewCaskInstalled(homebrewCask) {
            return await runCommand("brew", ["upgrade", "--cask", homebrewCask])
        }

        if let homebrewFormula, await isHomebrewFormulaInstalled(homebrewFormula) {
            return await runCommand("brew", ["upgrade", homebrewFormula])
        }

        if let npmPackage, await isNPMGlobalPackageInstalled(npmPackage) {
            return await runCommand("npm", ["install", "-g", "\(npmPackage)@latest"])
        }

        if let pnpmPackage, await isPNPMGlobalPackageInstalled(pnpmPackage) {
            return await runCommand("pnpm", ["add", "-g", "\(pnpmPackage)@latest"])
        }

        if let installerURL {
            return await runRemoteInstallerScript(installerURL)
        }

        return (-1, Data("Could not identify the installer that owns \(executableName).".utf8))
    }

    static func cliInstallSource(
        executableName: String,
        homebrewFormula: String?,
        homebrewCask: String?,
        npmPackage: String?,
        pnpmPackage: String?
    ) async -> CLIInstallSource {
        let executablePath = ExecutableDiscovery.locate(executableName)?.path ?? ""
        async let homebrewPrefix = commandOutput("brew", ["--prefix"])
        async let npmPrefix = commandOutput("npm", ["config", "get", "prefix"])
        async let pnpmBin = commandOutput("pnpm", ["bin", "-g"])
        async let formulaInstalled: Bool = {
            guard let homebrewFormula else { return false }
            return await isHomebrewFormulaInstalled(homebrewFormula)
        }()
        async let caskInstalled: Bool = {
            guard let homebrewCask else { return false }
            return await isHomebrewCaskInstalled(homebrewCask)
        }()
        async let npmInstalled: Bool = {
            guard let npmPackage else { return false }
            return await isNPMGlobalPackageInstalled(npmPackage)
        }()
        async let pnpmInstalled: Bool = {
            guard let pnpmPackage else { return false }
            return await isPNPMGlobalPackageInstalled(pnpmPackage)
        }()
        let snapshot = await CLIInstallSnapshot(
            executablePath: executablePath,
            homebrewPrefix: homebrewPrefix,
            npmPrefix: npmPrefix,
            pnpmBin: pnpmBin,
            homebrewFormulaInstalled: formulaInstalled,
            homebrewCaskInstalled: caskInstalled,
            npmPackageInstalled: npmInstalled,
            pnpmPackageInstalled: pnpmInstalled
        )
        return CLIInstallResolver.source(for: snapshot, directPathMarkers: ["/.opencode/bin/", "/.local/bin/agy"])
    }

    static func pathLooksHomebrewManaged(_ path: String) async -> Bool {
        guard !path.isEmpty else { return false }
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") { return true }
        guard let prefix = await commandOutput("brew", ["--prefix"]) else { return false }
        return path.hasPrefix(prefix)
    }

    static func executablePathLooksNPMManaged(_ path: String) async -> Bool {
        guard !path.isEmpty, let prefix = await commandOutput("npm", ["config", "get", "prefix"]) else { return false }
        return path.hasPrefix(prefix)
    }

    static func executablePathLooksPNPMManaged(_ path: String) async -> Bool {
        guard !path.isEmpty, let bin = await commandOutput("pnpm", ["bin", "-g"]) else { return false }
        return path.hasPrefix(bin)
    }

    static func isHomebrewFormulaInstalled(_ name: String) async -> Bool {
        await runCommand("brew", ["list", "--formula", name]).status == 0
    }

    static func isHomebrewCaskInstalled(_ name: String) async -> Bool {
        await runCommand("brew", ["list", "--cask", name]).status == 0
    }

    static func isNPMGlobalPackageInstalled(_ name: String) async -> Bool {
        await runCommand("npm", ["list", "-g", "--depth=0", name]).status == 0
    }

    static func isPNPMGlobalPackageInstalled(_ name: String) async -> Bool {
        await runCommand("pnpm", ["list", "-g", "--depth=0", name]).status == 0
    }

    static func latestCLIVersion(
        executableName: String,
        homebrewFormula: String?,
        homebrewCask: String?,
        npmPackage: String?,
        pnpmPackage: String?,
        directPackage: String?
    ) async -> String? {
        let source = await cliInstallSource(
            executableName: executableName,
            homebrewFormula: homebrewFormula,
            homebrewCask: homebrewCask,
            npmPackage: npmPackage,
            pnpmPackage: pnpmPackage
        )
        switch source {
        case .homebrewCask:
            if let homebrewCask, await isHomebrewCaskInstalled(homebrewCask) {
                return await homebrewLatestCaskVersion(homebrewCask)
            }
        case .homebrewFormula:
            if let homebrewFormula, await isHomebrewFormulaInstalled(homebrewFormula) {
                return await homebrewLatestFormulaVersion(homebrewFormula)
            }
        case .npmGlobal:
            guard let npmPackage else { return nil }
            return await commandOutput("npm", ["view", npmPackage, "version"])
        case .pnpmGlobal:
            guard let pnpmPackage else { return nil }
            return await commandOutput("pnpm", ["view", pnpmPackage, "version"])
        case .direct, .selfUpdater:
            guard let directPackage else { return nil }
            return await commandOutput("npm", ["view", directPackage, "version"])
        case .unknown:
            break
        }
        if let homebrewCask, await isHomebrewCaskInstalled(homebrewCask) {
            return await homebrewLatestCaskVersion(homebrewCask)
        }
        if let homebrewFormula, await isHomebrewFormulaInstalled(homebrewFormula) {
            return await homebrewLatestFormulaVersion(homebrewFormula)
        }
        if let npmPackage, await isNPMGlobalPackageInstalled(npmPackage) {
            return await commandOutput("npm", ["view", npmPackage, "version"])
        }
        if let pnpmPackage, await isPNPMGlobalPackageInstalled(pnpmPackage) {
            return await commandOutput("pnpm", ["view", pnpmPackage, "version"])
        }
        if let directPackage {
            return await commandOutput("npm", ["view", directPackage, "version"])
        }
        return nil
    }

    static func homebrewInstalledFormulaVersion(_ name: String) async -> String? {
        guard let output = await commandOutput("brew", ["list", "--formula", "--versions", name]) else { return nil }
        let parts = output.split { $0.isWhitespace }.map(String.init)
        return parts.dropFirst().first
    }

    static func homebrewLatestFormulaVersion(_ name: String) async -> String? {
        guard let output = await commandOutput("brew", ["info", "--json=v2", name]) else { return nil }
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulae = root["formulae"] as? [[String: Any]],
              let versions = formulae.first?["versions"] as? [String: Any],
              let stable = versions["stable"] as? String,
              !stable.isEmpty else { return nil }
        return stable
    }

    static func homebrewLatestCaskVersion(_ name: String) async -> String? {
        guard let output = await commandOutput("brew", ["info", "--json=v2", "--cask", name]) else { return nil }
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]],
              let raw = casks.first?["version"] as? String,
              !raw.isEmpty else { return nil }
        return raw.split(separator: ",").first.map(String.init) ?? raw
    }

    static func runRemoteInstallerScript(_ urlString: String) async -> (status: Int32, output: Data) {
        guard let url = URL(string: urlString) else { return (-1, Data("Invalid installer URL.".utf8)) }
        if let message = RemoteInstallerScriptPolicy.validationMessage(for: url) { return (-1, Data(message.utf8)) }
        do {
            let download = try await RemoteInstallerScriptDownloader().download(from: url)
            guard let expectedSHA256Hex = RemoteInstallerScriptPolicy.pinnedSHA256Hex(for: download.finalURL) else {
                return (-1, Data("Provider installer redirected to an endpoint without a pinned signature.".utf8))
            }
            let evaluation = RemoteInstallerScriptPolicy.evaluateDownload(
                data: download.data,
                contentType: download.contentType,
                expectedSHA256Hex: expectedSHA256Hex
            )
            if let message = evaluation.contentMessage { return (-1, Data(message.utf8)) }
            if let message = RemoteInstallerScriptPolicy.executionMessage(for: evaluation.trust) {
                return (-1, Data(message.utf8))
            }
            let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-installer-\(UUID().uuidString).sh")
            try download.data.write(to: scriptURL, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: scriptURL) }
            let syntax = await runCommand("bash", ["-n", scriptURL.path])
            guard syntax.status == 0 else {
                return (-1, syntax.output.isEmpty ? Data("Downloaded installer failed shell syntax validation.".utf8) : syntax.output)
            }
            return await runCommand("bash", [scriptURL.path])
        } catch let error as RemoteInstallerScriptDownloadError {
            return (-1, Data(error.localizedDescription.utf8))
        } catch {
            return (-1, Data("Installer download failed: \(error.localizedDescription)".utf8))
        }
    }

    static func runAntigravityLogin() async -> (status: Int32, output: Data) {
        guard let executable = ExecutableDiscovery.locate("agy") else {
            return (-1, Data("Antigravity CLI is not installed.".utf8))
        }
        let result = await BoundedSubprocess.run(.init(
            executableURL: URL(fileURLWithPath: "/usr/bin/script"),
            arguments: ["-q", "/dev/null", executable.path],
            deadline: 180
        ))
        switch result.outcome {
        case .exited:
            return (result.exitStatus ?? -1, result.combinedOutput)
        case .timedOut:
            return (-1, Data("Antigravity login timed out after 180 seconds.".utf8))
        case .cancelled:
            return (-1, Data("Antigravity login was cancelled.".utf8))
        case .launchFailed:
            return (-1, Data((result.launchErrorDescription ?? "Antigravity login failed to launch.").utf8))
        case .outputLimitExceeded:
            return (-1, Data("Antigravity login output exceeded Lattice's safety limit.".utf8))
        case .completed:
            return (-1, Data("Antigravity login ended before credentials were available.".utf8))
        }
    }

    static func runCommand(
        _ executable: String,
        _ arguments: [String],
        discardOutput: Bool = false,
        deadline: TimeInterval = 60
    ) async -> (status: Int32, output: Data) {
        guard let executableURL = ExecutableDiscovery.locate(executable) else { return (-1, Data()) }
        let result = await BoundedSubprocess.run(.init(
            executableURL: executableURL,
            arguments: arguments,
            deadline: deadline,
            maximumOutputBytes: discardOutput ? 0 : 2_000_000
        ))
        switch result.outcome {
        case .exited, .completed:
            return (result.exitStatus ?? 0, discardOutput ? Data() : result.combinedOutput)
        case .timedOut:
            return (-1, Data("Command timed out after \(Int(deadline)) seconds.".utf8))
        case .cancelled:
            return (-1, Data("Command was cancelled.".utf8))
        case .outputLimitExceeded:
            return (-1, Data("Command output exceeded Lattice's safety limit.".utf8))
        case .launchFailed:
            return (-1, Data((result.launchErrorDescription ?? "Command failed to launch.").utf8))
        }
    }

    func saveOpenCodeAPIKey() {
        let value = openCodeAPIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        switch KeychainStore.saveResult(value, account: OpenCodeCredentialPolicy.keychainAccount) {
        case .failure(let error):
            let availability = KeychainStore.presence(account: OpenCodeCredentialPolicy.keychainAccount)
            let resolution = CredentialPresenceReconciler.resolve(
                availability,
                previouslyRecorded: openCodeAPIKeySaved
            )
            openCodeAPIKeySaved = resolution.recorded
            openCodeCredentialAvailability = availability
            cliActionMessages["opencode"] = error.message
        case .success:
            openCodeAPIKeySaved = true
            openCodeCredentialAvailability = .present
            validatedPiOpenCodeModels.removeAll()
            validatedHermesOpenCodeModels.removeAll()
            openCodeAPIKeyDraft = ""
            cliActionMessages["opencode"] = "API key saved in Keychain. Enable Code, Work, or both explicitly."
            Task { await refreshConnections(refreshProviderCatalogs: true) }
        }
    }

    func isOpenCodeCredentialEnabled(for mode: ConversationMode) -> Bool {
        openCodeCredentialEnabledModes.contains(mode)
    }

    func setOpenCodeCredentialEnabled(_ enabled: Bool, for mode: ConversationMode) {
        guard mode == .code || mode == .work else { return }
        guard !enabled || openCodeAPIKeySaved else {
            cliActionMessages["opencode"] = "Save the OpenCode key before enabling it for \(mode.displayName)."
            return
        }
        if enabled { openCodeCredentialEnabledModes.insert(mode) }
        else {
            openCodeCredentialEnabledModes.remove(mode)
            if mode == .code { validatedPiOpenCodeModels.removeAll() }
            if mode == .work { validatedHermesOpenCodeModels.removeAll() }
        }
        UserDefaults.standard.set(
            openCodeCredentialEnabledModes.map(\.rawValue).sorted(),
            forKey: Self.openCodeCredentialModesKey
        )
        cliActionMessages["opencode"] = enabled
            ? "OpenCode credential enabled for \(mode.displayName)."
            : "OpenCode credential disabled for \(mode.displayName)."
    }

    /// Compatibility-only bridge for an existing direct OpenCode chat. New
    /// Pi/Hermes routes receive the Keychain value through child environment.
    func enableLegacyDirectOpenCodeCredential() {
        guard selectedSessionUsesLegacyDirectOpenCode else {
            cliActionMessages["opencode"] = "The compatibility credential bridge is available only inside a selected legacy direct OpenCode chat."
            return
        }
        switch OpenCodeAuthBridge.syncGoAPIKeyFromKeychainResult() {
        case .success:
            cliActionMessages["opencode"] = "Credential copied to OpenCode for legacy direct chats."
        case .failure(let error):
            cliActionMessages["opencode"] = error.message
        }
    }

    func clearOpenCodeAPIKey() {
        let availability = KeychainStore.remove(account: OpenCodeCredentialPolicy.keychainAccount)
        let resolution = CredentialPresenceReconciler.resolve(
            availability,
            previouslyRecorded: openCodeAPIKeySaved
        )
        openCodeCredentialAvailability = availability
        openCodeAPIKeySaved = resolution.recorded
        guard resolution.shouldInvalidateConsent else {
            cliActionMessages["opencode"] = "Keychain removal could not complete. Unlock or authorize Keychain, then try again."
            persistConnectionState()
            return
        }
        openCodeCredentialEnabledModes.removeAll()
        validatedPiOpenCodeModels.removeAll()
        validatedHermesOpenCodeModels.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.openCodeCredentialModesKey)
        openCodeAPIKeyDraft = ""
        persistConnectionState()
        Task { await refreshConnections() }
    }

    /// Called when Lattice regains focus after a provider login, logout, runtime
    /// install, or Keychain unlock. Generation checks prevent older probes from
    /// publishing after this observation begins.
    func refreshConnectionsAfterExternalStateChange() {
        requestAutomaticConnectionRefresh(refreshProviderCatalogs: true)
    }

    func requestAutomaticConnectionRefresh(refreshProviderCatalogs: Bool) {
        let now = Date.now
        guard now.timeIntervalSince(lastAutomaticConnectionRefreshRequest) >= 1 else { return }
        lastAutomaticConnectionRefreshRequest = now
        Task { await refreshConnections(refreshProviderCatalogs: refreshProviderCatalogs) }
    }

    func hydratePersistedConnectionState() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedConnectionStateKey) else { return }
        switch PersistedConnectionStatePolicy.hydrate(data, now: .now) {
        case .rejected:
            UserDefaults.standard.removeObject(forKey: Self.persistedConnectionStateKey)
        case .stale(let cached):
            // Presence is secret-free and useful if Keychain is temporarily locked.
            // All readiness/authentication observations are intentionally discarded.
            openCodeAPIKeySaved = cached.openCodeCredentialRecorded
        case .fresh(let cached):
            openCodeAPIKeySaved = cached.openCodeCredentialRecorded
            codexAuthenticated = cached.providers["codex"]?.authenticated ?? false
            grokAuthenticated = cached.providers["grok"]?.authenticated ?? false
            openCodeAuthenticated = cached.providers["opencode"]?.authenticated ?? false
            antigravityAuthenticated = cached.providers["antigravity"]?.authenticated ?? false
            antigravityInstalled = cached.providers["antigravity"]?.installed ?? false
            piInstalled = cached.providers["pi"]?.installed ?? false
            hermesInstalled = cached.providers["hermes"]?.installed ?? false
            ollamaInstalled = cached.providers["ollama"]?.installed ?? false
            // Hydrate map + legacy fields with the same fail-closed ready formula (never runnable from cache).
            let hydrated = ProviderRuntimeSnapshotStore.hydratePresence(from: cached.providers)
            providerConnections.replaceAll(hydrated)
            ollamaReady = false
            codexReady = false
            grokReady = false
            openCodeReady = false
        }
    }

    func persistConnectionState() {
        let state = PersistedConnectionState(
            observedAt: .now,
            providers: [
                "codex": .init(installed: codex.isInstalled, authenticated: codexAuthenticated, catalogStatus: codexCatalogStatus, runnableModelCount: visibleCodexModels.count),
                "grok": .init(installed: grok.isInstalled, authenticated: grokAuthenticated, catalogStatus: grokCatalogStatus, runnableModelCount: runnableGrokModels.count),
                "opencode": .init(installed: openCode.isInstalled, authenticated: openCodeAuthenticated, catalogStatus: openCodeCatalogStatus, runnableModelCount: runnableOpenCodeModels.count),
                "antigravity": .init(installed: antigravityInstalled, authenticated: antigravityAuthenticated, catalogStatus: antigravityModels.isEmpty ? .empty : .loaded, runnableModelCount: antigravityModels.count),
                "pi": .init(installed: piInstalled, authenticated: false, catalogStatus: piModelIDs.isEmpty ? .empty : .loaded, runnableModelCount: piModelIDs.count),
                "hermes": .init(installed: hermesInstalled, authenticated: false, catalogStatus: hermesCatalogStatus, runnableModelCount: hermesModels.count),
                "ollama": .init(installed: ollamaInstalled, authenticated: ollamaReady, catalogStatus: ollamaCatalogStatus, runnableModelCount: ollamaModels.count)
            ],
            openCodeCredentialRecorded: openCodeAPIKeySaved
        )
        guard let data = PersistedConnectionStatePolicy.encode(state) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistedConnectionStateKey)
    }

    func invalidateRuntimeAuthenticationValidations() {
        validatedPiCodexModels.removeAll()
        validatedPiOpenCodeModels.removeAll()
        validatedHermesOpenCodeModels.removeAll()
        validatedHermesProviders.removeAll()
    }

    func installModel(_ recommendation: LocalModelRecommendation) {
        guard installingModelTag == nil else { return }
        guard ollamaInstalled else {
            installStatus = "Install Ollama first."
            return
        }
        guard ollamaReady else {
            installStatus = "Start Ollama first."
            return
        }
        guard recommendation.canInstall(on: hardware) else {
            installStatus = "Model exceeds the safe memory budget."
            return
        }
        installingModelTag = recommendation.ollamaTag; installStatus = "Starting…"
        Task {
            for await event in modelInstaller.pull(recommendation.ollamaTag) {
                switch event {
                case .output(let text): installStatus = text
                case .completed:
                    installingModelTag = nil; installStatus = nil; await refreshLocalModels()
                    setBackend(.ollama(model: recommendation.ollamaTag))
                case .failed(let message): installingModelTag = nil; installStatus = message
                case .cancelled: installingModelTag = nil; installStatus = nil
                }
            }
        }
    }

    func cancelModelInstall() { modelInstaller.cancel() }

    func canDeleteLocalModel(named model: String) -> Bool {
        ollamaReady
            && ollamaCatalogStatus == .loaded
            && ollamaModels.contains(where: { $0.name == model })
            && installingModelTag == nil
            && deletingLocalModelName == nil
            && !sessions.contains(where: { session in
                session.isStreaming && session.backend == .ollama(model: model)
            })
    }

    func requestDeleteLocalModel(named model: String) {
        guard canDeleteLocalModel(named: model) else {
            localModelStatus = "This model cannot be deleted while it is unavailable, refreshing, or running a response."
            return
        }
        pendingDeleteLocalModelName = model
        showDeleteLocalModelConfirmation = true
    }

    func cancelPendingLocalModelDeletion() {
        showDeleteLocalModelConfirmation = false
        pendingDeleteLocalModelName = nil
    }

    func confirmPendingLocalModelDeletion() {
        guard let model = pendingDeleteLocalModelName, canDeleteLocalModel(named: model) else {
            cancelPendingLocalModelDeletion()
            return
        }
        showDeleteLocalModelConfirmation = false
        pendingDeleteLocalModelName = nil
        deletingLocalModelName = model
        localModelStatus = "Deleting \(model)…"
        Task {
            await ollama.unload(model: model)
            let result = await ollama.deleteModel(named: model)
            deletingLocalModelName = nil
            switch result {
            case .deleted:
                localModelStatus = "Deleted \(model). Existing chats keep their history, but cannot run this route until the model is installed again."
                await refreshLocalModels()
            case .failed(let message):
                localModelStatus = message
            }
        }
    }

    func validBackend(_ backend: ChatBackend) -> ChatBackend {
        BackendAvailabilityPolicy.normalize(backend, using: BackendAvailabilitySnapshot(
            codexModels: visibleCodexModels,
            grokModels: runnableGrokModels,
            openCodeModels: runnableOpenCodeModels,
            antigravityModels: visibleAntigravityModels,
            codexReady: codexReady,
            grokReady: grokReady,
            openCodeReady: openCodeReady,
            antigravityReady: antigravityAuthenticated && !visibleAntigravityModels.isEmpty,
            codexCatalogKnown: codexCatalogStatus.isResolved,
            grokCatalogKnown: grokCatalogStatus.isResolved,
            openCodeCatalogKnown: openCodeCatalogStatus.isResolved,
            appleIntelligenceReady: appleIntelligenceReady,
            ollamaModelNames: ollamaCatalogStatus == .loaded ? ollamaModels.map(\.name) : [],
            codexInstalled: codex.isInstalled
        ))
    }

    func validBackend(_ backend: ChatBackend, privacyMode: SessionPrivacyMode) -> ChatBackend {
        let valid = validBackend(backend)
        guard privacyMode == .localOnly else { return valid }
        if valid.isLocal { return valid }
        if backend.isLocal { return localBackendFallback() }
        return localBackendFallback()
    }

    func localBackendFallback() -> ChatBackend {
        if appleIntelligenceReady { return .appleIntelligence }
        if ollamaCatalogStatus == .loaded, let model = ollamaModels.first?.name { return .ollama(model: model) }
        return .ollama(model: "")
    }

    func normalizeBackendsAfterCatalogRefresh() {
        let preferredCodex = codexReady ? (visibleCodexModels.first(where: \.isDefault) ?? visibleCodexModels.first) : nil
        var didChangeSessions = false
        if let preferredCodex, case .codex(let model) = defaultBackend, shouldReplaceStaleCodexModel(model, preferred: preferredCodex.id) {
            defaultBackend = .codex(model: preferredCodex.id)
            saveDefaultBackend()
            syncExecutionRoute(from: defaultBackend)
        } else {
            let valid = validBackend(defaultBackend)
            if valid != defaultBackend {
                defaultBackend = valid
                saveDefaultBackend()
                syncExecutionRoute(from: valid)
            }
        }
        for index in sessions.indices where !sessions[index].isStreaming && !sessions[index].messages.contains(where: { $0.role == .user }) {
            let priorBackend = sessions[index].backend
            let priorRoute = sessions[index].executionRoute
            if sessions[index].privacyMode == .localOnly {
                let valid = validBackend(sessions[index].backend, privacyMode: .localOnly)
                if valid != sessions[index].backend {
                    sessions[index].backend = valid
                    let route = RouteRuntimeMap.writeRoute(backend: valid, mode: .local)
                    sessions[index].executionRoute = route
                    sessions[index].harnessID = route.runtimeID
                    sessions[index].reasoningEffort = defaultReasoning(for: valid, harnessID: route.runtimeID)
                    sessions[index].harnessThreadID = nil
                    didChangeSessions = true
                }
            } else if let preferredCodex, case .codex(let model) = sessions[index].backend, shouldReplaceStaleCodexModel(model, preferred: preferredCodex.id) {
                let backend = ChatBackend.codex(model: preferredCodex.id)
                sessions[index].backend = backend
                let route = RouteRuntimeMap.writeRoute(backend: backend, mode: priorRoute.mode)
                sessions[index].executionRoute = route
                sessions[index].harnessID = route.runtimeID
                sessions[index].reasoningEffort = defaultReasoning(for: backend, harnessID: route.runtimeID)
                sessions[index].harnessThreadID = nil
                didChangeSessions = true
            } else {
                let valid = validBackend(sessions[index].backend)
                if valid != sessions[index].backend {
                    sessions[index].backend = valid
                    let route = RouteRuntimeMap.writeRoute(backend: valid, mode: priorRoute.mode)
                    sessions[index].executionRoute = route
                    sessions[index].harnessID = route.runtimeID
                    sessions[index].reasoningEffort = defaultReasoning(for: valid, harnessID: route.runtimeID)
                    sessions[index].harnessThreadID = nil
                    didChangeSessions = true
                }
            }
            // Keep declared routes in lockstep with backend when catalog rewrites model IDs.
            if sessions[index].backend != priorBackend || sessions[index].executionRoute != priorRoute {
                didChangeSessions = true
            }
        }
        if didChangeSessions { persist() }
    }

    func normalizeExecutionRouteAfterCatalogRefresh() {
        let currentRoute = EngineHarnessSelection(engineID: selectedRouteEngineID, harnessID: selectedRouteHarnessID)
        let normalizedRoute = ExecutionRoutePolicy.normalize(
            currentRoute,
            fallbackEngineID: Self.engineID(for: defaultBackend),
            fallbackHarnessID: Self.defaultHarnessID(for: defaultBackend)
        ) ?? currentRoute

        if isRouteHarnessCompatible(engineID: normalizedRoute.engineID, harnessID: normalizedRoute.harnessID), backendForRouteEngine(normalizedRoute.engineID, harnessID: normalizedRoute.harnessID) != nil {
            if normalizedRoute != currentRoute {
                selectedRouteEngineID = normalizedRoute.engineID
                selectedRouteHarnessID = normalizedRoute.harnessID
            }
            return
        }

        syncExecutionRoute(from: defaultBackend)
    }

    func shouldReplaceStaleCodexModel(_ model: String, preferred: String) -> Bool {
        guard model != preferred else { return false }
        if !visibleCodexModels.contains(where: { $0.id == model }) { return true }
        return model.localizedCaseInsensitiveContains("5.4") && preferred.localizedCaseInsensitiveContains("5.5")
    }

    static func loadDefaultBackend() -> ChatBackend? {
        guard let data = UserDefaults.standard.data(forKey: defaultBackendKey) else { return nil }
        return try? JSONDecoder().decode(ChatBackend.self, from: data)
    }

    static func storedSchedulerLimit(forKey key: String, fallback: Int) -> Int {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return min(max(UserDefaults.standard.integer(forKey: key), 1), 8)
    }

    static func defaultWorkspacePath(processDirectory: String) -> String {
        if processDirectory != "/" { return processDirectory }
        return defaultAppSupportWorkspacePath()
    }

    static func isImplicitDeveloperWorkspace(_ path: String?) -> Bool {
        guard let path else { return false }
        let desktop = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let candidates = ["Lattice"].map { desktop.appendingPathComponent($0).standardizedFileURL }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        return candidates.contains(standardized)
    }

    static func defaultAppSupportWorkspacePath() -> String {
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        let workspace = LatticeApplicationSupport.productRootURL().appendingPathComponent("Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace.path
    }

    static func ollamaAppURL() -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Ollama.app"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Applications/Ollama.app")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func saveDefaultBackend() {
        guard let data = try? JSONEncoder().encode(defaultBackend) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultBackendKey)
    }

    func syncExecutionRoute(from backend: ChatBackend) {
        selectedRouteEngineID = Self.engineID(for: backend)
        selectedRouteHarnessID = Self.defaultHarnessID(for: backend)
    }

    static func engineID(for backend: ChatBackend) -> String {
        switch backend {
        case .codex: "codex"
        case .grok: "grok"
        case .openCode: "opencode"
        case .appleIntelligence: "apple"
        case .ollama: "ollama"
        case .antigravity: "antigravity"
        }
    }

    static func defaultHarnessID(for backend: ChatBackend) -> String {
        // Prefer declared Wave-1 runtimes (e.g. codex code → pi) over legacy direct harness IDs.
        RouteRuntimeMap.writeRoute(backend: backend).runtimeID
    }

    func isRouteHarnessCompatible(engineID: String, harnessID: String) -> Bool {
        guard ExecutionRoutePolicy.compatibleHarnessIDs(for: engineID).contains(harnessID) else { return false }
        switch harnessID {
        case "pi":
            return piInstalled && candidateBackends(for: engineID).contains { piRoute(for: $0) != nil }
        case "hermes":
            return hermesInstalled && candidateBackends(for: engineID).contains { hermesMatch(for: $0) != nil }
        default:
            return true
        }
    }

    func backendForRouteEngine(_ engineID: String, harnessID: String? = nil) -> ChatBackend? {
        if let harnessID {
            return candidateBackends(for: engineID).first { backend in
                if harnessID == "pi" { return piRoute(for: backend) != nil }
                if harnessID == "hermes" { return hermesMatch(for: backend) != nil }
                return true
            }
        }
        return candidateBackends(for: engineID).first
    }

    func candidateBackends(for engineID: String) -> [ChatBackend] {
        switch engineID {
        case "codex":
            return visibleCodexModels.sorted { $0.isDefault && !$1.isDefault }.map { .codex(model: $0.id) }
        case "grok":
            return runnableGrokModels.sorted { $0.isDefault && !$1.isDefault }.map { .grok(model: $0.id) }
        case "opencode":
            return runnableOpenCodeModels.sorted { $0.isDefault && !$1.isDefault }.map { .openCode(model: $0.id) }
        case "antigravity":
            guard antigravityAuthenticated else { return [] }
            return visibleAntigravityModels.sorted { $0.isDefault && !$1.isDefault }.map { .antigravity(model: $0.id) }
        case "apple":
            return appleIntelligenceReady ? [.appleIntelligence] : []
        case "ollama":
            return ollamaCatalogStatus == .loaded ? ollamaModels.map { .ollama(model: $0.name) } : []
        default:
            return []
        }
    }

    func effectiveHarnessID(for session: LatticeSession) -> String {
        // ExecutionRoute is sole runtime authority; harnessID is decode/migration only.
        RouteRuntimeMap.effectiveRuntimeID(for: session)
    }

    func piRoute(for backend: ChatBackend) -> (provider: String, model: String)? {
        let provider: String; let model: String
        switch backend {
        case .codex(let value): provider = "openai-codex"; model = value
        case .openCode(let value):
            let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            provider = parts[0]; model = parts[1]
        default: return nil
        }
        return piModelIDs.contains("\(provider)/\(model)") ? (provider, model) : nil
    }

    func hermesMatch(for backend: ChatBackend) -> HarnessModel? {
        guard case .openCode(let model) = backend else { return nil }
        return HermesACPHarness.bestMatch(for: model, in: hermesModels)
    }

}
