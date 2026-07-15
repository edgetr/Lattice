import Foundation
import Combine
import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers
import LatticeCore

@MainActor
extension AppState {
    // MARK: - Persistence recovery

    func togglePersistenceRecoveryDetails(for issueID: String) {
        if expandedPersistenceRecoveryDetailIDs.contains(issueID) {
            expandedPersistenceRecoveryDetailIDs.remove(issueID)
        } else {
            expandedPersistenceRecoveryDetailIDs.insert(issueID)
        }
    }

    func copyPersistenceRecoveryDetails(_ issue: DurableStoreIssue) {
        let payload = """
        Store: \(issue.storeName)
        Path: \(issue.filePath)
        Problem: \(issue.summary)
        Kind: \(issue.kind.rawValue)

        \(issue.technicalDetails)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        persistenceRecoveryStatusMessage = "Technical details copied to the clipboard."
    }

    func revealPersistenceStoreInFinder(_ issue: DurableStoreIssue) {
        let url = issue.fileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
        persistenceRecoveryStatusMessage = "Revealed \(issue.storeName) in Finder."
    }

    func exportPersistenceStoreCopy(_ issue: DurableStoreIssue) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.title = "Export Copy of \(issue.storeName)"
        panel.nameFieldStringValue = "\(issue.fileURL.lastPathComponent).export"
        panel.message = "Exports a byte-for-byte copy. The original recovery file is left untouched."
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try DurableStoreRecovery.exportCopy(of: issue.fileURL, to: destination)
            persistenceRecoveryStatusMessage = "Exported a copy to \(destination.path)."
        } catch {
            persistenceRecoveryStatusMessage = error.localizedDescription
        }
    }

    func createPersistenceStoreBackup(_ issue: DurableStoreIssue) {
        do {
            let result = try DurableStoreRecovery.preserveCopy(of: issue.fileURL, kind: .backup)
            var message = "Backup created at \(result.preservedURL.path)."
            if let note = result.note { message += " \(note)" }
            // Backup is non-destructive; the store remains in recovery until retry/reset succeeds.
            persistenceRecoveryStatusMessage = message
        } catch {
            persistenceRecoveryStatusMessage = error.localizedDescription
        }
    }

    func retryPersistenceStoreRecovery(_ issue: DurableStoreIssue) {
        switch issue.storeID {
        case SessionPersistence.storeID:
            switch persistence.loadResult() {
            case .missing:
                // Unblock before applying empty state so future saves work immediately.
                resolvePersistenceRecovery(storeID: issue.storeID, gate: persistence.writeGate)
                sessions = []
                resetAllConversationScrollState()
                selectedSessionID = nil
                rebuildThreadActivityLanes()
                persistenceRecoveryStatusMessage = "Session store is missing. Lattice will start without saved chats."
            case .loaded(let loaded):
                // Unblock before migration autosave inside applyRecoveredSessions.
                resolvePersistenceRecovery(storeID: issue.storeID, gate: persistence.writeGate)
                applyRecoveredSessions(loaded)
                persistenceRecoveryStatusMessage = "Session store loaded successfully."
            case .failed(let updated):
                replacePersistenceRecoveryIssue(updated)
                persistenceRecoveryStatusMessage = "\(updated.storeName) still cannot be loaded (\(updated.kind.displayName.lowercased())). Original left untouched."
            }
        case LatticeExtensionJobStore.storeID:
            switch extensionJobStore.loadResult() {
            case .missing:
                resolvePersistenceRecovery(storeID: issue.storeID, gate: extensionJobStore.writeGate)
                selfEditJobs = []
                persistenceRecoveryStatusMessage = "Self-edit history store is missing. Starting without history."
            case .loaded(let jobs):
                resolvePersistenceRecovery(storeID: issue.storeID, gate: extensionJobStore.writeGate)
                selfEditJobs = jobs
                persistenceRecoveryStatusMessage = "Self-edit history store loaded successfully."
            case .failed(let updated):
                replacePersistenceRecoveryIssue(updated)
                persistenceRecoveryStatusMessage = "\(updated.storeName) still cannot be loaded (\(updated.kind.displayName.lowercased())). Original left untouched."
            }
        case LatticeExtensionPreviewStore.storeID:
            switch extensionPreviewStore.loadResult() {
            case .missing:
                resolvePersistenceRecovery(storeID: issue.storeID, gate: extensionPreviewStore.writeGate)
                selfEditPreviews = []
                persistenceRecoveryStatusMessage = "Self-edit preview store is missing. Starting without previews."
            case .loaded(let records):
                resolvePersistenceRecovery(storeID: issue.storeID, gate: extensionPreviewStore.writeGate)
                selfEditPreviews = records
                persistenceRecoveryStatusMessage = "Self-edit preview store loaded successfully."
            case .failed(let updated):
                replacePersistenceRecoveryIssue(updated)
                persistenceRecoveryStatusMessage = "\(updated.storeName) still cannot be loaded (\(updated.kind.displayName.lowercased())). Original left untouched."
            }
        default:
            persistenceRecoveryStatusMessage = "Unknown store \(issue.storeID)."
        }
    }

    func requestPersistenceStoreReset(_ issue: DurableStoreIssue) {
        pendingPersistenceResetIssueID = issue.id
        showPersistenceResetConfirmation = true
    }

    func cancelPersistenceStoreReset() {
        pendingPersistenceResetIssueID = nil
        showPersistenceResetConfirmation = false
    }

    func confirmPersistenceStoreReset() {
        guard let issue = pendingPersistenceResetIssue else {
            cancelPersistenceStoreReset()
            return
        }
        cancelPersistenceStoreReset()
        do {
            let result = try DurableStoreRecovery.resetReplacingWithEmptyArray(at: issue.fileURL, expected: issue)
            switch issue.storeID {
            case SessionPersistence.storeID:
                resolvePersistenceRecovery(storeID: issue.storeID, gate: persistence.writeGate)
                sessions = []
                resetAllConversationScrollState()
                selectedSessionID = nil
                rebuildThreadActivityLanes()
            case LatticeExtensionJobStore.storeID:
                resolvePersistenceRecovery(storeID: issue.storeID, gate: extensionJobStore.writeGate)
                selfEditJobs = []
            case LatticeExtensionPreviewStore.storeID:
                resolvePersistenceRecovery(storeID: issue.storeID, gate: extensionPreviewStore.writeGate)
                selfEditPreviews = []
            default:
                break
            }
            var message = "Reset complete. Original preserved at \(result.preservedURL.path)."
            if let note = result.note { message += " \(note)" }
            persistenceRecoveryStatusMessage = message
        } catch {
            persistenceRecoveryStatusMessage = error.localizedDescription
        }
    }

    func applyRecoveredSessions(_ loaded: [LatticeSession]) {
        var loadedSessions = loaded
        var migratedSessions = false
        let cwd = selectedWorkspacePath
        for index in loadedSessions.indices where loadedSessions[index].workspacePath == "/" || (loadedSessions[index].workspacePath == NSHomeDirectory() && loadedSessions[index].totalMessageCount == 0) || (Self.isImplicitDeveloperWorkspace(loadedSessions[index].workspacePath) && loadedSessions[index].totalMessageCount == 0) {
            loadedSessions[index].workspacePath = cwd
            migratedSessions = true
        }
        for index in loadedSessions.indices where loadedSessions[index].intent == nil && Self.isLegacySelfEditSession(loadedSessions[index]) {
            loadedSessions[index].intent = .selfEdit
            migratedSessions = true
        }
        resetAllConversationScrollState()
        sessions = loadedSessions
        selectedSessionID = LatticeSessionListOrdering.sorted(sessions).first?.id
        rebuildThreadActivityLanes()
        if let first = sessions.first, let path = first.workspacePath, !Self.isImplicitDeveloperWorkspace(path) {
            selectedWorkspacePath = path
        }
        if migratedSessions {
            // Coordinator-aware: gate-blocked is silent; real write failures surface as save failures.
            _ = sessionSaveCoordinator.saveNow(loadedSessions)
            sessionSaveFailure = sessionSaveCoordinator.currentFailure
        }
    }

    func resolvePersistenceRecovery(storeID: String, gate: DurableStoreWriteGate) {
        gate.unblock()
        persistenceRecoveryIssues.removeAll { $0.storeID == storeID }
        expandedPersistenceRecoveryDetailIDs.remove(storeID)
    }

    func rebuildThreadActivityLanes() {
        var rebuilt = ThreadActivityLaneStore(selectedSessionID: selectedSessionID)
        for session in sessions where !session.queuedFollowUps.isEmpty {
            rebuilt.apply(.queued(session.queuedFollowUps.count), to: session.id)
        }
        threadActivityLanes = rebuilt
        refreshSchedulerLanes()
    }

    func replacePersistenceRecoveryIssue(_ issue: DurableStoreIssue) {
        if let index = persistenceRecoveryIssues.firstIndex(where: { $0.storeID == issue.storeID }) {
            persistenceRecoveryIssues[index] = issue
        } else {
            persistenceRecoveryIssues.append(issue)
        }
    }

    /// Immediate durable write at a safe boundary. Cancels/absorbs any pending debounced draft write.
    @discardableResult
    func persist() -> SessionSaveAttemptResult {
        refreshSearchIndexForLoadedSessions()
        // Coordinator enforces the load-recovery write gate and reports real save failures.
        let result = sessionSaveCoordinator.saveNow(sessions)
        // Keep published failure in sync for synchronous MainActor paths (observer may be async).
        sessionSaveFailure = sessionSaveCoordinator.currentFailure
        if result == .saved {
            expandedSessionSaveFailureDetails = false
            synchronizeTranscriptReferencesAfterSuccessfulSave()
        }
        return result
    }

    func prepareTranscriptSelection(selectedID: UUID?) {
        let previousRequest = activeTranscriptHydrationRequest
        transcriptHydrationTask?.cancel()
        transcriptHydrationTask = nil
        activeTranscriptHydrationRequest = nil
        transcriptLoadingSessionID = nil
        if let previousRequest {
            Task { await transcriptHydrationCoordinator.cancel(previousRequest) }
        }

        guard let selectedID,
              let selectedIndex = sessions.firstIndex(where: { $0.id == selectedID }) else {
            return
        }
        if sessions[selectedIndex].isTranscriptLoaded {
            finishTranscriptAccess(sessionID: selectedID)
            return
        }
        guard let storage = sessions[selectedIndex].transcriptStorage else { return }

        let snapshot = sessions[selectedIndex]
        let persistence = persistence
        let request = TranscriptHydrationRequest(sessionID: selectedID, storage: storage)
        activeTranscriptHydrationRequest = request
        transcriptLoadingSessionID = selectedID
        transcriptHydrationTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await transcriptHydrationCoordinator.hydrate(request) {
                persistence.hydrationResult(for: snapshot)
            }
            guard !Task.isCancelled else { return }
            applyTranscriptHydrationOutcome(outcome)
        }
    }

    func applyTranscriptHydrationOutcome(_ outcome: TranscriptHydrationOutcome) {
        switch outcome {
        case .cancelled:
            return
        case .failed(let request, let issue):
            guard selectedSessionID == request.sessionID,
                  sessions.first(where: { $0.id == request.sessionID })?.transcriptStorage == request.storage else { return }
            transcriptLoadingSessionID = nil
            activeTranscriptHydrationRequest = nil
            persistence.writeGate.block()
            replacePersistenceRecoveryIssue(issue)
            setError("This chat's stored conversation content could not be loaded. The original files were left untouched for recovery.", sessionID: request.sessionID)
        case .loaded(let request, let content):
            guard let index = sessions.firstIndex(where: { $0.id == request.sessionID }) else { return }
            transcriptLoadingSessionID = nil
            activeTranscriptHydrationRequest = nil
            // A live or dirty in-memory transcript always wins over a late disk result.
            guard TranscriptHydrationApplyPolicy.shouldApply(
                request: request,
                selectedSessionID: selectedSessionID,
                currentSession: sessions[index]
            ) else { return }
            sessions[index].messages = content.messages
            sessions[index].isTranscriptLoaded = true
            sessions[index].isTranscriptDirty = false
            if !sessions[index].isArtifactsDirty {
                sessions[index].artifacts = content.artifacts
                sessions[index].isArtifactsLoaded = true
                sessions[index].isArtifactsDirty = false
            }
            finishTranscriptAccess(sessionID: request.sessionID)
        }
    }

    func finishTranscriptAccess(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        materializedTranscriptLRU.recordAccess(sessionID)
        _ = transcriptRenderWindows.activate(sessionID: sessionID, messageCount: sessions[index].messages.count)

        let protectedIDs = Set(sessions.lazy.filter {
            $0.id == self.selectedSessionID || $0.isStreaming || $0.isTranscriptDirty || $0.transcriptStorage == nil || $0.isArtifactsDirty || ($0.isArtifactsLoaded && !$0.artifacts.isEmpty && $0.artifactStorage == nil)
        }.map(\.id))
        for id in materializedTranscriptLRU.evictionCandidates(protectedIDs: protectedIDs) {
            guard let victimIndex = sessions.firstIndex(where: { $0.id == id }) else {
                materializedTranscriptLRU.remove(id)
                continue
            }
            sessions[victimIndex].messages = []
            sessions[victimIndex].isTranscriptLoaded = false
            sessions[victimIndex].isTranscriptDirty = false
            if !sessions[victimIndex].isArtifactsDirty {
                sessions[victimIndex].artifacts = []
                sessions[victimIndex].isArtifactsLoaded = false
            }
            transcriptRenderWindows.invalidate(sessionID: id)
            materializedTranscriptLRU.remove(id)
        }
    }

    func refreshSearchIndexForLoadedSessions() {
        sessionSearchIndex.retainValidEntries(for: sessions)
        for session in sessions where session.isTranscriptLoaded {
            sessionSearchIndex.update(session: session)
        }
    }

    func synchronizeTranscriptReferencesAfterSuccessfulSave() {
        for index in sessions.indices where sessions[index].isTranscriptLoaded {
            sessions[index].transcriptStorage = try? SessionPersistence.storageReference(
                sessionID: sessions[index].id,
                messages: sessions[index].messages
            )
            sessions[index].isTranscriptDirty = false
            guard sessions[index].isArtifactsLoaded else { continue }
            if sessions[index].artifacts.isEmpty {
                sessions[index].artifactStorage = nil
            } else if let reference = try? SessionPersistence.artifactStorageReference(
                sessionID: sessions[index].id,
                artifacts: sessions[index].artifacts
            ) {
                sessions[index].artifactStorage = reference
            }
            sessions[index].isArtifactsDirty = false
        }
    }

    /// Load `text` into the shared composer without treating it as a user edit of the ordinary draft.
    func applyComposerDraft(_ text: String) {
        isApplyingComposerDraft = true
        draft = text
        isApplyingComposerDraft = false
    }

    func syncOrdinaryDraftToSelectedSessionIfNeeded() {
        guard !isApplyingComposerDraft else { return }
        // Never persist transient edited-message text as the ordinary session draft.
        guard editingMessageContext == nil else { return }
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        guard sessions[index].draft != draft else { return }
        sessions[index].draft = draft
        scheduleDraftPersist()
    }

    /// Write the current ordinary composer text onto the selected session without scheduling a debounced save.
    /// Used by termination/retry so the flush snapshot includes keystrokes that have not yet been mirrored.
    func forceSyncOrdinaryDraftToSelectedSession() {
        guard !isApplyingComposerDraft else { return }
        guard editingMessageContext == nil else { return }
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].draft != draft {
            sessions[index].draft = draft
        }
    }

    func scheduleDraftPersist() {
        // Coalesced 250 ms draft durability via the save coordinator.
        sessionSaveCoordinator.scheduleDraftSnapshot(sessions)
    }

    func scheduleSelectionPersist() {
        // Thread switching can happen repeatedly while scanning a session list;
        // coalescing avoids synchronous JSON serialization on the main actor.
        sessionSaveCoordinator.scheduleDebounced(sessions)
    }

    func scheduleStreamingPersist() {
        // Partial assistant text and progress must survive a crash without rewriting the full
        // session archive for every token or provider progress notification.
        sessionSaveCoordinator.scheduleStreamingSnapshot(sessions)
    }

    /// Pure-policy selection apply: flush previous ordinary draft, restore/cancel edit without didSet races, load next draft.
    func applyComposerSessionSelection(from previousID: UUID?, to nextID: UUID?) {
        let edit = editingMessageContext.map {
            MessageEditDraftState(context: $0, preservedComposerDraft: preservedComposerDraftBeforeEdit)
        }
        let storedDraftForNext = nextID.flatMap { id in sessions.first(where: { $0.id == id })?.draft } ?? ""
        let transition = ComposerSessionDraftTransition.selecting(
            from: previousID,
            to: nextID,
            composerText: draft,
            edit: edit,
            storedDraftForNext: storedDraftForNext
        )

        if let previousID,
           let previousDraft = transition.previousSessionDraft,
           let index = sessions.firstIndex(where: { $0.id == previousID }) {
            sessions[index].draft = previousDraft
        }

        if transition.clearsEditState {
            editingMessageContext = nil
            preservedComposerDraftBeforeEdit = ""
        }

        applyComposerDraft(transition.composerDraft)
        // Selection is a high-frequency interaction. Coalesce the full-store
        // write so switching threads stays responsive while the latest draft
        // remains durable within the same bounded save window used for typing.
        scheduleSelectionPersist()
    }

    func upsertSessionAction(_ action: SessionAction, at sessionIndex: Int) {
        SessionActionTrail.upsert(action, in: &sessions[sessionIndex].actions)
        sessions[sessionIndex].lastUpdated = .now
        if action.status == .waiting {
            persist()
        } else {
            scheduleStreamingPersist()
        }
    }

    func updateSessionAction(id actionID: UUID, status: SessionAction.Status, at sessionIndex: Int) {
        guard SessionActionTrail.update(id: actionID, status: status, in: &sessions[sessionIndex].actions) else { return }
        sessions[sessionIndex].lastUpdated = .now
        if status == .running {
            scheduleStreamingPersist()
        } else {
            persist()
        }
    }

    func updateSessionAction(id actionID: UUID, status: SessionAction.Status, sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        updateSessionAction(id: actionID, status: status, at: sessionIndex)
    }

    func finishPendingActions(
        status: SessionAction.Status,
        at sessionIndex: Int,
        approvalOutcome: ApprovalProvenance.Outcome? = nil,
        providerAcknowledgement: ApprovalProvenance.ProviderAcknowledgement? = nil
    ) {
        guard let messageID = sessions[sessionIndex].messages.last(where: { $0.role == .assistant })?.id else { return }
        let outcome = approvalOutcome ?? (status == .failed ? .failed : .cancelled)
        let acknowledgement = providerAcknowledgement ?? (status == .failed ? .unavailable : .cancelled)
        finalizePendingApprovalProvenance(
            at: sessionIndex,
            outcome: outcome,
            providerAcknowledgement: acknowledgement
        )
        if SessionActionTrail.finishPending(for: messageID, as: status, in: &sessions[sessionIndex].actions) > 0 { persist() }
    }

    func finishCompletedTurnActions(at sessionIndex: Int) {
        guard let messageID = sessions[sessionIndex].messages.last(where: { $0.role == .assistant })?.id else { return }
        finalizePendingApprovalProvenance(
            at: sessionIndex,
            outcome: .cancelled,
            providerAcknowledgement: .cancelled
        )
        if SessionActionTrail.finishCompletedTurn(for: messageID, in: &sessions[sessionIndex].actions) > 0 { persist() }
    }

    func finalizePendingApprovalProvenance(
        at sessionIndex: Int,
        outcome: ApprovalProvenance.Outcome,
        providerAcknowledgement: ApprovalProvenance.ProviderAcknowledgement
    ) {
        for actionIndex in sessions[sessionIndex].actions.indices {
            guard sessions[sessionIndex].actions[actionIndex].kind == .approval,
                  [.running, .waiting].contains(sessions[sessionIndex].actions[actionIndex].status),
                  var provenance = sessions[sessionIndex].actions[actionIndex].approvalProvenance else { continue }
            provenance.outcome = outcome
            provenance.providerAcknowledgement = providerAcknowledgement
            provenance.updatedAt = .now
            sessions[sessionIndex].actions[actionIndex].approvalProvenance = provenance
        }
    }

    func setActivity(_ items: [ActivityItem], sessionID: UUID) {
        reduceRunUI(.setActivity(items), for: sessionID)
    }

    func upsertActivity(_ item: ActivityItem, sessionID: UUID) {
        reduceRunUI(.upsertActivity(item), for: sessionID)
    }

    func clearActivity(for sessionID: UUID? = nil) {
        guard let sessionID = sessionID ?? selectedSessionID else { return }
        reduceRunUI(.clearActivity, for: sessionID)
    }

    func setActiveComposerState(_ state: MorphingControlState, sessionID: UUID) {
        reduceRunUI(.setComposerState(state), for: sessionID)
    }

    func clearActiveComposerState(for sessionID: UUID? = nil) {
        guard let sessionID = sessionID ?? selectedSessionID else { return }
        reduceRunUI(.setComposerState(.expanded), for: sessionID)
    }

    func setError(_ message: String, sessionID: UUID? = nil) {
        if let sessionID {
            reduceRunUI(.setError(message), for: sessionID)
        } else {
            globalErrorMessage = message
        }
    }

    func clearError() {
        globalErrorMessage = nil
        if let selectedSessionID {
            reduceRunUI(.clearError, for: selectedSessionID)
        }
    }

    static func activityIcon(for kind: ToolRequest.Kind) -> String {
        switch kind {
        case .read: "brain"
        case .write: "pencil"
        case .command: "terminal"
        case .network: "bolt.horizontal"
        case .automation: "cursorarrow.motionlines"
        case .credential: "key"
        case .destructive: "exclamationmark.triangle"
        case .unknown: "questionmark.circle"
        }
    }

    func startResourceMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in guard let self else { return }; Task { await self.unloadActiveLocalModel(reason: "Unloaded for memory pressure") } }
        source.resume(); memoryPressureSource = source

        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical else { return }
                Task { await self.unloadActiveLocalModel(reason: "Unloaded for thermal pressure") }
            }
            .store(in: &cancellables)
    }

    func scheduleIdleUnloadIfNeeded(for backend: ChatBackend) {
        guard case .ollama(let model) = backend else { return }
        scheduleLocalModelIdleUnload(model: model)
    }

    func scheduleLocalModelIdleUnload(model: String) {
        cancelLocalModelIdleUnload()
        guard localModelIdleUnloadMinutes > 0 else {
            localModelStatus = "Idle unload disabled"
            return
        }
        let minutes = localModelIdleUnloadMinutes
        localModelStatus = "Unloads after \(minutes)m idle"
        let seconds = minutes * 60
        localModelIdleUnloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.unloadLocalModel(model, reason: "Unloaded after \(minutes)m idle")
        }
    }

    func cancelLocalModelIdleUnload() {
        localModelIdleUnloadTask?.cancel()
        localModelIdleUnloadTask = nil
    }

    func unloadLocalModel(_ model: String, reason: String) async {
        await ollama.unload(model: model)
        localModelStatus = reason
        localModelIdleUnloadTask = nil
    }

    func unloadActiveLocalModel(reason: String) async {
        cancelLocalModelIdleUnload()
        await ollama.unloadActive()
        localModelStatus = reason
    }

}
