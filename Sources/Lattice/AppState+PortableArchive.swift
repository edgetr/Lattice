import Foundation
import Combine
import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers
import LatticeCore

@MainActor
extension AppState {
    // MARK: - Portable chat export / import

    var canExportSelectedSession: Bool {
        selectedSession?.isStreaming == false
    }

    var canImportChat: Bool {
        !needsPersistenceRecovery
    }

    func requestExportSelectedSession() {
        guard let id = selectedSessionID else { return }
        requestExportSession(id)
    }

    func requestExportSession(_ id: UUID) {
        guard sessions.first(where: { $0.id == id })?.isStreaming == false else { return }
        exportChatSessionID = id
        exportChatFormat = .jsonArchive
        exportChatIncludeQueuedFollowUps = false
        exportChatStatusMessage = nil
        showExportChatSheet = true
    }

    func cancelExportChatSheet() {
        showExportChatSheet = false
        exportChatSessionID = nil
        exportChatStatusMessage = nil
    }

    /// Runs NSSavePanel after the export options sheet confirms format/queued inclusion.
    func confirmExportChatOptions() {
        guard let id = exportChatSessionID,
              var session = sessions.first(where: { $0.id == id }) else {
            cancelExportChatSheet()
            return
        }
        do {
            try persistence.materializeTranscript(in: &session)
        } catch {
            cancelExportChatSheet()
            presentImportError("Export failed because the stored transcript could not be loaded. Existing chats were not changed.")
            return
        }
        let format = exportChatFormat
        let includeQueued = exportChatIncludeQueuedFollowUps
        showExportChatSheet = false
        exportChatSessionID = nil

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowsOtherFileTypes = false
        panel.title = "Export Chat"
        panel.message = format == .jsonArchive
            ? "Saves a versioned Lattice JSON archive suitable for safe re-import. Ordinary unsent drafts are never included."
            : "Saves readable Markdown. Markdown cannot be imported. Ordinary unsent drafts are never included."
        panel.nameFieldStringValue = SessionPortableArchiveExporter.suggestedFileName(for: session, format: format)
        panel.prompt = "Export"
        switch format {
        case .jsonArchive:
            panel.allowedContentTypes = [UTType.json]
        case .markdown:
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        }
        // NSSavePanel asks the user before replacing an existing file.
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let options = SessionPortableArchive.ExportOptions(
                includeQueuedFollowUps: includeQueued,
                format: format
            )
            let data = try SessionPortableArchiveExporter.exportData(from: session, options: options)
            try data.write(to: url, options: .atomic)
            exportChatStatusMessage = "Exported “\(session.title)” to \(url.lastPathComponent)."
        } catch {
            // Export failure must not mutate sessions.
            presentImportError("Export failed: \(error.localizedDescription). Existing chats were not changed.")
        }
    }

    func requestImportChat() {
        guard canImportChat else {
            presentImportError("Resolve chat store recovery before importing.")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Import Chat"
        panel.message = "Choose a Lattice `.lattice.json` archive. Markdown exports cannot be imported. Existing chats are never overwritten."
        panel.prompt = "Review"
        panel.allowedContentTypes = [UTType.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        prepareImport(from: url)
    }

    func prepareImport(from url: URL) {
        do {
            let plan = try SessionPortableArchiveImporter.prepareImport(
                fileURL: url,
                existingSessions: sessions
            )
            pendingImportPlan = plan
            showImportChatPreview = true
        } catch let error as SessionPortableArchive.ArchiveError {
            presentImportError(error.localizedDescription + (error.recoverySuggestion.map { " \($0)" } ?? ""))
        } catch {
            presentImportError("Import failed: \(error.localizedDescription). Existing chats were not changed.")
        }
    }

    func cancelImportChatPreview() {
        showImportChatPreview = false
        pendingImportPlan = nil
    }

    /// Confirms a non-mutating preview: inserts a new session only after explicit user confirmation.
    /// On save failure, rolls back in-memory mutation so existing sessions stay unchanged.
    func confirmImportChatPreview() {
        guard let plan = pendingImportPlan else {
            cancelImportChatPreview()
            return
        }
        cancelImportChatPreview()

        let previousSessions = sessions
        let previousSelected = selectedSessionID
        let commit = SessionPortableArchiveImporter.commit(
            plan: plan,
            into: sessions,
            selectedSessionID: selectedSessionID
        )
        // Apply memory mutation only together with a durable save attempt.
        sessions = commit.sessions
        // Show the imported chat without starting a provider run or auto-sending queued content.
        selectedSessionID = commit.importedSessionID
        if let imported = sessions.first(where: { $0.id == commit.importedSessionID }), !imported.queuedFollowUps.isEmpty {
            threadActivityLanes.apply(.queued(imported.queuedFollowUps.count), to: imported.id)
        }
        selectedSection = .conversations
        clearError()

        switch sessionSaveCoordinator.saveNow(sessions) {
        case .saved:
            exportChatStatusMessage = plan.preview.isDuplicate
                ? "Imported a new chat (duplicate content fingerprint warning). Provider was not started."
                : "Imported a new chat. Provider was not started."
            sessionSaveFailure = sessionSaveCoordinator.currentFailure
        case .blockedByWriteGate:
            sessions = previousSessions
            threadActivityLanes.remove(commit.importedSessionID)
            selectedSessionID = previousSelected
            presentImportError("Chat store recovery is active, so import was cancelled. Existing chats were not changed.")
        case .failed(let failure), .coalescedFailure(let failure):
            sessions = previousSessions
            threadActivityLanes.remove(commit.importedSessionID)
            selectedSessionID = previousSelected
            sessionSaveFailure = failure
            presentImportError("Could not save the imported chat (\(failure.kind.displayName)). Existing chats were not changed. \(failure.summary)")
        }
    }

    func presentImportError(_ message: String) {
        importChatErrorMessage = message
        showImportChatError = true
    }

    func confirmPendingChatDeletion() {
        guard let id = pendingDeleteSessionID else { return }
        pendingDeleteSessionID = nil
        showDeleteChatConfirmation = false
        deleteSession(id)
    }

    func cancelPendingChatDeletion() {
        pendingDeleteSessionID = nil
        showDeleteChatConfirmation = false
    }

    func copyMessage(_ message: ChatMessage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        copiedMessageID = message.id
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run {
                if self?.copiedMessageID == message.id { self?.copiedMessageID = nil }
            }
        }
    }

    func togglePinnedMessage(_ message: ChatMessage) {
        guard let id = selectedSessionID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == id }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: { $0.id == message.id }),
              !sessions[sessionIndex].messages[messageIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        sessions[sessionIndex].messages[messageIndex].isPinned.toggle()
        sessions[sessionIndex].lastUpdated = .now
        persist()
    }

    func canBranchFromMessage(_ message: ChatMessage) -> Bool {
        guard let session = selectedSession,
              !session.isStreaming else { return false }
        return session.messages.contains(where: { $0.id == message.id })
    }

    func branchFromMessage(_ message: ChatMessage) {
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              let branch = SessionTranscriptMutation.branchFromMessage(messageID: message.id, in: sessions[index]) else { return }
        sessions.insert(branch, at: 0)
        // Branch starts with zero pending new-content and fresh tail-follow, independent of the source.
        conversationScrollStates[branch.id] = ConversationScrollPolicy.freshBranchState()
        publishConversationJumpAffordance(for: branch.id)
        selectedSessionID = branch.id
        selectedSection = .conversations
        clearError()
        persist()
    }

    /// Store a measured scroll-policy result and publish jump affordance only when it changes.
    func applyConversationScrollState(_ state: ConversationScrollSessionState, for sessionID: UUID) {
        conversationScrollStates[sessionID] = state
        publishConversationJumpAffordance(for: sessionID)
    }

    func clearConversationScrollState(for sessionID: UUID) {
        conversationScrollStates.removeValue(forKey: sessionID)
        conversationOutgoingActionSequence.removeValue(forKey: sessionID)
        runUIStates.removeValue(forKey: sessionID)
        if conversationJumpAffordances[sessionID] != nil {
            conversationJumpAffordances.removeValue(forKey: sessionID)
        }
    }

    func resetAllConversationScrollState() {
        conversationScrollStates.removeAll()
        conversationOutgoingActionSequence.removeAll()
        conversationJumpAffordances.removeAll()
        runUIStates.removeAll()
        globalErrorMessage = nil
    }

    func publishConversationJumpAffordance(for sessionID: UUID) {
        let state = conversationScrollStates[sessionID] ?? .fresh
        let next = ConversationScrollPolicy.jumpAffordance(for: state)
        let previous = conversationJumpAffordances[sessionID] ?? .hidden
        guard previous != next else { return }
        if next == .hidden {
            conversationJumpAffordances.removeValue(forKey: sessionID)
        } else {
            conversationJumpAffordances[sessionID] = next
        }
    }

    func requestDeleteMessage(_ message: ChatMessage) {
        guard let sessionID = selectedSessionID,
              let session = sessions.first(where: { $0.id == sessionID }),
              !session.isStreaming,
              session.messages.contains(where: { $0.id == message.id }) else { return }
        pendingDeleteMessageContext = MessageDeletionContext(sessionID: sessionID, messageID: message.id)
        showDeleteMessageConfirmation = true
    }

    func confirmPendingMessageDeletion() {
        guard let context = pendingDeleteMessageContext,
              let sessionIndex = sessions.firstIndex(where: { $0.id == context.sessionID }) else {
            cancelPendingMessageDeletion()
            return
        }

        pendingDeleteMessageContext = nil
        showDeleteMessageConfirmation = false
        guard SessionTranscriptMutation.deleteMessageAndFollowing(
            messageID: context.messageID,
            in: &sessions[sessionIndex]
        ) else { return }

        if let edit = editingMessageContext,
           edit.sessionID == context.sessionID,
           !sessions[sessionIndex].messages.contains(where: { $0.id == edit.messageID }) {
            cancelEditingMessage()
        }
        if let copiedMessageID,
           !sessions[sessionIndex].messages.contains(where: { $0.id == copiedMessageID }) {
            self.copiedMessageID = nil
        }
        if let updated = try? extensionPreviewStore.removePreviews(for: context.sessionID, from: selfEditPreviews) {
            selfEditPreviews = updated
        }
        harnessPermissionNotices[context.sessionID] = nil
        clearActivity(for: context.sessionID)
        clearError()
        persist()
    }

    func cancelPendingMessageDeletion() {
        pendingDeleteMessageContext = nil
        showDeleteMessageConfirmation = false
    }

    func beginEditingMessage(_ message: ChatMessage) {
        guard message.role == .user,
              let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].messages.contains(where: { $0.id == message.id }) else { return }
        if sessions[index].isStreaming { stop(sessionID: id) }
        let existing = editingMessageContext.map {
            MessageEditDraftState(context: $0, preservedComposerDraft: preservedComposerDraftBeforeEdit)
        }
        let transition = MessageEditDraftState.begin(
            sessionID: id,
            messageID: message.id,
            messageText: message.text,
            currentDraft: draft,
            existing: existing
        )
        // Install edit state before mutating `draft` so ordinary write-back is skipped.
        editingMessageContext = transition.state.context
        preservedComposerDraftBeforeEdit = transition.state.preservedComposerDraft
        // Keep the durable ordinary draft; never replace it with transient edit text.
        sessions[index].draft = transition.state.preservedComposerDraft
        applyComposerDraft(transition.draft)
        composerState = .expanded
        overlayControlState = .expanded
    }

    func cancelEditingMessage() {
        let existing = editingMessageContext.map {
            MessageEditDraftState(context: $0, preservedComposerDraft: preservedComposerDraftBeforeEdit)
        }
        // Clear edit mode first so restoring the ordinary draft persists to the session.
        editingMessageContext = nil
        preservedComposerDraftBeforeEdit = ""
        draft = MessageEditDraftState.cancel(existing)
        composerState = .expanded
        overlayControlState = .expanded
    }

    func sendDraft() {
        if editingMessageID == nil, let command = appCommandCompletion(for: draft) {
            insertAppCommand(command)
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if editingMessageID == nil, handleSelfEditReviewDecision(text) {
            draft = ComposerSessionDraftTransition.clearingOrdinaryDraft()
            return
        }
        if let prompt = LatticeSelfEditCommand.prompt(in: text), prompt.isEmpty {
            // Failed validation preserves the ordinary draft.
            setError("Type what you want Lattice to change after /self-edit.", sessionID: selectedSessionID)
            composerState = .expanded
            overlayControlState = .expanded
            return
        }
        guard canSendDraft else {
            // Failed validation preserves the ordinary draft.
            setError(activeRouteStatusText ?? "Choose a connected model.", sessionID: selectedSessionID)
            return
        }
        if let session = selectedSession,
           !ensureUnsafeProviderRouteAcknowledged(for: session) {
            return
        }
        if selectedSession?.isStreaming == true {
            // Keep the composer intact unless the context-bound outbox entry is durably saved.
            if queueFollowUp(text) {
                draft = ComposerSessionDraftTransition.clearingOrdinaryDraft()
            }
            return
        }
        if editingMessageID != nil {
            sendEditedDraft(text)
            return
        }
        draft = ComposerSessionDraftTransition.clearingOrdinaryDraft()
        send(text)
    }

    func insertAppCommand(_ command: LatticeAppCommand) {
        draft = command.replacementText ?? "\(command.invocation) "
        composerState = .expanded
        overlayControlState = .expanded
        overlayMode = .prompt
    }

    func appCommandSuggestions(for draft: String) -> [LatticeAppCommand] {
        LatticeAppCommandCatalog.suggestions(for: draft, commands: appCommands)
    }

    func appCommandCompletion(for draft: String) -> LatticeAppCommand? {
        LatticeAppCommandCatalog.completion(for: draft, commands: appCommands)
    }

    var appCommands: [LatticeAppCommand] {
        LatticeAppCommandCatalog.all + activeSkillCommands + activePromptTemplates.map(\.command)
    }

    var activeSkillCommands: [LatticeAppCommand] {
        skills
            .filter { $0.isValid && isSkillEnabled($0) }
            .map(LatticeSkillPromptBuilder.command(for:))
    }

    var effectiveDisabledSkillIDs: Set<String> {
        LatticeSkillActivationPolicy.effectiveDisabledSkillIDs(
            records: skills,
            disabledSkillIDs: disabledSkillIDs,
            enabledExtensionIDs: enabledExtensionIDs
        )
    }

}
