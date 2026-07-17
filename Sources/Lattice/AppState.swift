import Foundation
import Combine
import AppKit
import SwiftUI
import Darwin
import UniformTypeIdentifiers
import LatticeCore

enum WorkspaceSection: String, CaseIterable, Identifiable {
    case conversations = "Chats"
    case projects = "Projects"
    case models = "Models"
    case connections = "Connections"
    case extensions = "Extensions & Skills"
    var id: Self { self }
    var persistenceID: String {
        switch self {
        case .conversations: "conversations"
        case .projects: "projects"
        case .models: "models"
        case .connections: "connections"
        case .extensions: "extensions"
        }
    }
    init?(persistenceID: String) {
        switch persistenceID {
        case "conversations": self = .conversations
        case "projects": self = .projects
        case "models": self = .models
        case "connections": self = .connections
        case "extensions": self = .extensions
        default: return nil
        }
    }
    var displayName: String { self == .projects ? "Workspace" : rawValue }
    var icon: String {
        switch self {
        case .conversations: "bubble.left.and.bubble.right"
        case .projects: "folder"
        case .models: "cpu"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .extensions: "puzzlepiece.extension"
        }
    }
}


typealias ActivityItem = RunUIActivity

struct HarnessPermissionNotice: Identifiable {
    let id = UUID()
    let sessionID: UUID
    let harnessID: String
    let providerName: String
    let request: ApprovalRequest
}

struct UnsafeProviderRouteAcknowledgement: Identifiable {
    let id: String
    let sessionID: UUID
    let routeKey: String
    let providerName: String
    let modelName: String
    let detail: String
}

struct ExecutionRouteOption: Identifiable, Equatable {
    let engineID: String
    let harnessID: String
    let title: String
    var id: String { "\(engineID):\(harnessID)" }
}

struct ComposerModelOption: Identifiable, Equatable {
    let route: ExecutionRoute
    let backend: ChatBackend?
    let providerTitle: String
    let title: String
    let reason: String?
    var reasoningSummary: String? = nil

    var id: String { route.id }
    var isAvailable: Bool { backend != nil && reason == nil }
}

struct PreparedSubmission {
    let userText: String
    let runText: String
    let startsSelfEdit: Bool
}

struct MessageDeletionContext: Equatable {
    let sessionID: UUID
    let messageID: UUID
}

@MainActor
final class AppState: ObservableObject {
    @Published var selectedSection: WorkspaceSection = .conversations
    @Published var selectedSessionID: UUID? {
        didSet {
            guard oldValue != selectedSessionID else { return }
            applyComposerSessionSelection(from: oldValue, to: selectedSessionID)
            prepareTranscriptSelection(selectedID: selectedSessionID)
            if selectedSessionID != nil {
                isTransientNewChat = false
                composerSelectionMode = selectedSession?.executionRoute.mode
                composerSelectionBackend = selectedSession?.backend
            } else {
                composerSelectionMode = nil
                composerSelectionBackend = nil
            }
            threadActivityLanes.select(selectedSessionID)
            refreshSelectedCheckpointReview()
            rebindWorkLoopSurfacesAfterSelectionChange()
        }
    }
    var sessions: [LatticeSession] {
        get { sessionCatalog.sessions }
        set { sessionCatalog.sessions = newValue }
    }
    @Published var transcriptLoadingSessionID: UUID?
    @Published var draft = "" {
        didSet {
            syncOrdinaryDraftToSelectedSessionIfNeeded()
        }
    }
    @Published var searchText = ""
    @Published var showInspector = false
    @Published var preferredInspectorSurface: InspectorSurface = .details
    var lastAutoPromotedReviewRunID: UUID?
    @Published var checkpointReviewStates: [UUID: WorkspaceCheckpointReviewState] = [:]
    @Published var showCommandPalette = false
    @Published var showsOnboarding: Bool
    @Published var onboardingStep: LatticeOnboardingStep = .welcome
    @Published var commandPaletteSearch = ""
    @Published var commandPaletteSelectedID: String?
    var conversationScrollStates: [UUID: ConversationScrollSessionState] = [:]
    @Published var conversationOutgoingActionSequence: [UUID: Int] = [:]
    @Published var conversationJumpAffordances: [UUID: ConversationJumpAffordance] = [:]
    var conversationScrollPosition = ScrollPosition(idType: String.self)
    @Published var workOriginJumpTarget: UUID?
    @Published var workQuestionAnswers: [UUID: String] = [:]
    @Published var showDeleteChatConfirmation = false
    @Published var pendingDeleteSessionID: UUID?
    @Published var showExportChatSheet = false
    @Published var exportChatSessionID: UUID?
    @Published var exportChatFormat: SessionPortableArchive.ExportFormat = .jsonArchive
    @Published var exportChatIncludeQueuedFollowUps = false
    @Published var exportChatStatusMessage: String?
    @Published var showImportChatPreview = false
    @Published var pendingImportPlan: SessionArchiveImportPlan?
    @Published var importChatErrorMessage: String?
    @Published var showImportChatError = false
    @Published var showDeleteMessageConfirmation = false
    @Published var pendingDeleteMessageContext: MessageDeletionContext?
    @Published var showDeleteExtensionConfirmation = false
    @Published var pendingDeleteExtensionRecord: LatticeExtensionRecord?
    @Published var showDeleteSkillConfirmation = false
    @Published var pendingDeleteSkillRecord: LatticeSkillRecord?
    @Published var isOverlayVisible = false
    @Published var policy: ExecutionPolicy = .ask
    @Published var privacyMode: SessionPrivacyMode = .cloudAllowed
    @Published var harnessPermissionNotices: [UUID: HarnessPermissionNotice] = [:]
    @Published var providerSessionHealth: [UUID: ProviderSessionLifecycleEvent] = [:]
    @Published var pendingUnsafeProviderRouteAcknowledgement: UnsafeProviderRouteAcknowledgement?
    @Published var editingMessageContext: MessageEditContext?
    var preservedComposerDraftBeforeEdit: String = ""
    @Published var copiedMessageID: UUID?
    @Published var defaultBackend: ChatBackend
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    var lastMeasuredWorkspaceWidth: CGFloat = 0
    let connectionRefreshGeneration = RefreshGenerationController()
    let localModelRefreshGeneration = RefreshGenerationController()
    var lastAutoAppliedColumnVisibility: NavigationSplitViewVisibility?
    var respectsUserColumnChoice = false
    @Published var selectedWorkspacePath: String
    @Published var workspaceActionMessage: String?
    let workspaceTools = WorkspaceToolsController()
    let providerConnections = ProviderConnectionStore()
    let composer = ComposerController()
    let sessionCatalog = SessionCatalogStore()
    let runOrchestrator = RunOrchestrator()
    var isTransientNewChat: Bool {
        get { composer.isTransientNewChat }
        set { composer.setTransientNewChat(newValue) }
    }
    var composerSelectionMode: ConversationMode? {
        get { composer.selectionMode }
        set { composer.setSelection(mode: newValue, backend: composer.selectionBackend) }
    }
    var composerSelectionBackend: ChatBackend? {
        get { composer.selectionBackend }
        set { composer.setSelection(mode: composer.selectionMode, backend: newValue) }
    }
    var composerRoutePopoverPresented: Bool {
        get { composer.routePopoverPresented }
        set { composer.routePopoverPresented = newValue }
    }
    var composerModelSearchText: String {
        get { composer.modelSearchText }
        set { composer.modelSearchText = newValue }
    }
    @Published var includeScreenshotContext = false
    @Published var captureLifecycle = CaptureLifecycleState()
    @Published var codeInstructionAddOn: String
    @Published var workInstructionAddOn: String
    @Published var trustedWorkspacePaths: Set<String>
    @Published var installingModelTag: String?
    @Published var installStatus: String?
    @Published var showDeleteLocalModelConfirmation = false
    @Published var pendingDeleteLocalModelName: String?
    @Published var deletingLocalModelName: String?
    @Published var localModelIdleUnloadMinutes: Int
    @Published var localModelStatus: String?
    @Published var openCodeAPIKeyDraft = ""
    @Published var openCodeAPIKeySaved = false
    @Published var openCodeCredentialAvailability: CredentialStoreAvailability = .unavailable
    @Published var openCodeCredentialEnabledModes: Set<ConversationMode> = []
    @Published var validatedPiCodexModels: Set<String> = []
    @Published var validatedPiOpenCodeModels: Set<String> = []
    @Published var validatedHermesOpenCodeModels: Set<String> = []
    @Published var validatedHermesProviders: Set<String> = []
    @Published var pendingRuntimeConfirmation: RuntimeConfirmationRequest?
    @Published var runtimeLifecycleStates: [LatticeRuntimeID: RuntimeLifecycleState] = [:]
    @Published var latticeManagedRuntimeIDs: Set<LatticeRuntimeID> = []
    @Published var disabledModelIDs: Set<String>
    @Published var expandedProviderModelIDs: Set<String> = []
    @Published var providerModelDisclosureStates: [String: ProviderModelDisclosureState] = [:]
    @Published var cliBusyProviders: Set<String> = []
    @Published var cliActionMessages: [String: String] = [:]
    @Published var runtimeAuthenticationPhases: [LatticeRuntimeID: HarnessReadinessAuthenticationPhase] = [:]
    @Published var isRefreshingConnections = false
    @Published var connectionRefreshAction = ControlActionState()
    @Published var localModelRefreshAction = ControlActionState()
    @Published var cliActionStartedAt: [String: Date] = [:]
    @Published var cliActionEstimatedSeconds: [String: TimeInterval] = [:]
    @Published var pendingCLIInstallProvider: String?
    @Published var extensions: [LatticeExtensionRecord] = []
    @Published var skills: [LatticeSkillRecord] = []
    @Published var selfEditJobs: [LatticeExtensionJobRecord] = []
    @Published var folderActionMessage: String?
    @Published var selfEditPreviews: [LatticeExtensionPreviewRecord] = []
    let selfEditDrafts = SelfEditDraftStore()
    @Published var persistenceRecoveryIssues: [DurableStoreIssue] = []
    @Published var expandedPersistenceRecoveryDetailIDs: Set<String> = []
    @Published var persistenceRecoveryStatusMessage: String?
    @Published var showPersistenceResetConfirmation = false
    @Published var pendingPersistenceResetIssueID: String?
    @Published var sessionSaveFailure: SessionSaveFailure?
    @Published var expandedSessionSaveFailureDetails = false
    @Published var enabledExtensionIDs: Set<String>
    @Published var disabledSkillIDs: Set<String>
    @Published var activeStylePatches: [LatticeStylePatch] = []
    @Published var activeLayoutPatches: [LatticeLayoutPatch] = []
    @Published var activeCopyPatches: [LatticeCopyPatch] = []
    @Published var activePromptTemplates: [LatticePromptTemplate] = []
    @Published var selfMap = LatticeSelfMap()
    var showOverlayAction: (() -> Void)?
    var openWorkspaceAction: (() -> Void)?

    let hardware = HardwareProfile.current()
    var codex = CodexExecHarness()
    var grok = StructuredCLIHarness(kind: .grok)
    var grokACP = ACPHarness(profile: .grok)
    var openCode = StructuredCLIHarness(kind: .openCode)
    var openCodeACP = ACPHarness(profile: .openCode)
    var antigravity = AntigravityCLIHarness()
    var pi = PiRPCHarness()
    var hermes = ACPHarness()
    let executionCoordinator: any LatticeExecutionCoordinating
    let checkpointClient: WorkspaceCheckpointClient
    var runtimeInstallTasks: [LatticeRuntimeID: Task<Void, Never>] = [:]
    let appleIntelligence = AppleIntelligenceClient()
    let ollama = OllamaClient()
    let modelInstaller = OllamaModelInstaller()
    let extensionStore = LatticeExtensionStore()
    let skillStore = LatticeSkillStore()
    let extensionJobStore = LatticeExtensionJobStore()
    let extensionPreviewStore = LatticeExtensionPreviewStore()
    let policyEngine = DeterministicPolicyEngine()
    let persistence = SessionPersistence()
    var sessionProjectionCache = SessionProjectionCache()
    let sessionSaveCoordinator: SessionSaveCoordinator
    var sessionSearchIndex = SessionSearchIndex()
    var transcriptRenderWindows = TranscriptRenderWindowCache()
    let transcriptHydrationCoordinator = TranscriptHydrationCoordinator()
    var transcriptHydrationTask: Task<Void, Never>?
    var activeTranscriptHydrationRequest: TranscriptHydrationRequest?
    var materializedTranscriptLRU = TranscriptHydrationLRU(maximumCount: 3)
    var memoryPressureSource: DispatchSourceMemoryPressure?
    var localModelIdleUnloadTask: Task<Void, Never>?
    var extensionDirectorySource: DispatchSourceFileSystemObject?
    var extensionDirectoryFileDescriptor: CInt = -1
    var cancellables: Set<AnyCancellable> = []
    let captureStorage = CaptureStorage.applicationSupportStore()
    let screenshotCaptureService = ScreenshotCaptureService()
    var pendingApprovalResponses: [UUID: (notice: HarnessPermissionNotice, option: ApprovalOption)] = [:]
    var lastAutomaticConnectionRefreshRequest = Date.distantPast
    @Published var threadActivityLanes = ThreadActivityLaneStore()
    @Published var schedulerGlobalLimit = 4
    @Published var schedulerWorkspaceLimit = 2
    @Published var globalErrorMessage: String?
    var acknowledgedUnsafeProviderRouteKeys: Set<String> = []
    var isApplyingComposerDraft = false
    static let idleUnloadKey = "localModelIdleUnloadMinutes"
    static let defaultBackendKey = "defaultBackend"
    static let enabledExtensionIDsKey = "enabledExtensionIDs"
    static let knownExtensionIDsKey = "knownExtensionIDs"
    static let disabledSkillIDsKey = "disabledSkillIDs"
    static let onboardingCompletedVersionKey = "onboardingCompletedVersion"
    static let onboardingVersion = 1
    static let codeInstructionAddOnKey = "codeInstructionAddOn"
    static let workInstructionAddOnKey = "workInstructionAddOn"
    static let trustedWorkspacePathsKey = "trustedWorkspacePaths"
    static let openCodeCredentialModesKey = "openCodeCredentialEnabledModes"
    static let managedRuntimeIDsKey = "latticeManagedRuntimeIDs"
    static let persistedConnectionStateKey = "persistedConnectionState.v1"
    static let schedulerMetadataKey = "agentTaskScheduler.metadata.v1"
    static let schedulerGlobalLimitKey = "agentTaskScheduler.globalLimit"
    static let schedulerWorkspaceLimitKey = "agentTaskScheduler.workspaceLimit"

    var executionRuntimes: LatticeExecutionRuntimes {
        LatticeExecutionRuntimes(
            codex: codex,
            grok: grokACP,
            openCode: openCodeACP,
            antigravity: antigravity,
            pi: pi,
            hermes: hermes,
            appleIntelligence: appleIntelligence,
            ollama: ollama
        )
    }

    var needsPersistenceRecovery: Bool { !persistenceRecoveryIssues.isEmpty }

    var needsSessionSaveFailureAttention: Bool { sessionSaveFailure != nil }

    var pendingPersistenceResetIssue: DurableStoreIssue? {
        guard let id = pendingPersistenceResetIssueID else { return nil }
        return persistenceRecoveryIssues.first { $0.id == id }
    }

    func showOnboardingGuide() {
        onboardingStep = .welcome
        showsOnboarding = true
    }

    func finishOnboarding() {
        UserDefaults.standard.set(Self.onboardingVersion, forKey: Self.onboardingCompletedVersionKey)
        showsOnboarding = false
    }

    func skipOnboarding() {
        finishOnboarding()
    }

    func openConnectionsFromOnboarding() {
        selectedSection = .connections
        finishOnboarding()
        openWorkspaceAction?()
    }

    init(
        executionCoordinator: (any LatticeExecutionCoordinating)? = nil,
        checkpointService: WorkspaceCheckpointService? = nil
    ) {
        self.executionCoordinator = executionCoordinator ?? DefaultLatticeExecutionCoordinator()
        self.checkpointClient = WorkspaceCheckpointClient(
            service: checkpointService ?? WorkspaceCheckpointService(store: .defaultStore())
        )
        sessionSaveCoordinator = SessionSaveCoordinator(persistence: persistence)
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        LatticeApplicationSupport.migrateLegacyUserDefaultsIfNeeded()
        let processDirectory = FileManager.default.currentDirectoryPath
        let cwd = Self.defaultWorkspacePath(processDirectory: processDirectory)
        var recoveryIssues: [DurableStoreIssue] = []
        var loadedSessions: [LatticeSession] = []
        var migratedSessions = false
        var sessionStoreInRecovery = false

        switch persistence.loadLazyResult() {
        case .missing:
            loadedSessions = []
        case .loaded(let snapshot):
            loadedSessions = snapshot.sessions
            sessionSearchIndex = snapshot.searchIndex
            migratedSessions = snapshot.usesLegacyMonolithicStore
            for index in loadedSessions.indices where loadedSessions[index].workspacePath == "/" || (loadedSessions[index].workspacePath == NSHomeDirectory() && loadedSessions[index].totalMessageCount == 0) || (Self.isImplicitDeveloperWorkspace(loadedSessions[index].workspacePath) && loadedSessions[index].totalMessageCount == 0) {
                loadedSessions[index].workspacePath = cwd; migratedSessions = true
            }
            for index in loadedSessions.indices where loadedSessions[index].intent == nil && Self.isLegacySelfEditSession(loadedSessions[index]) {
                loadedSessions[index].intent = .selfEdit
                migratedSessions = true
            }
            for index in loadedSessions.indices {
                let before = loadedSessions[index].queuedFollowUps
                SessionInputOutboxPolicy.recoverAfterRestart(&loadedSessions[index].queuedFollowUps)
                if loadedSessions[index].queuedFollowUps != before { migratedSessions = true }
            }
        case .failed(let issue):
            sessionStoreInRecovery = true
            recoveryIssues.append(issue)
            // Block the write gate without calling instance methods — `self` is not fully
            // initialized yet. `block()` is safe here: no concurrent save can be in flight.
            if !persistence.writeGate.tryBlock() {
                persistence.writeGate.block()
            }
            loadedSessions = []
        }

        let protectedCaptureIDs = Set(
            loadedSessions
                .flatMap(\.attachments)
                .filter(\.isLatticeManagedCapture)
                .map(\.id)
        )
        _ = try? captureStorage.cleanup(protectedCaptureIDs: protectedCaptureIDs)
        for sessionIndex in loadedSessions.indices {
            for attachmentIndex in loadedSessions[sessionIndex].attachments.indices {
                let attachment = loadedSessions[sessionIndex].attachments[attachmentIndex]
                if attachment.isLatticeManagedCapture,
                   !FileManager.default.fileExists(atPath: attachment.path) {
                    loadedSessions[sessionIndex].attachments[attachmentIndex].isMissing = true
                }
            }
        }
        sessionCatalog.replaceAll(loadedSessions)
        showsOnboarding = UserDefaults.standard.integer(forKey: Self.onboardingCompletedVersionKey) < Self.onboardingVersion
        disabledModelIDs = Set(UserDefaults.standard.stringArray(forKey: "disabledModelIDs") ?? [])
        enabledExtensionIDs = Set(UserDefaults.standard.stringArray(forKey: Self.enabledExtensionIDsKey) ?? [])
        disabledSkillIDs = Set(UserDefaults.standard.stringArray(forKey: Self.disabledSkillIDsKey) ?? [])
        let savedIdleUnload = UserDefaults.standard.integer(forKey: Self.idleUnloadKey)
        localModelIdleUnloadMinutes = savedIdleUnload == 0 && UserDefaults.standard.object(forKey: Self.idleUnloadKey) == nil ? 5 : savedIdleUnload
        selectedWorkspacePath = cwd
        codeInstructionAddOn = UserDefaults.standard.string(forKey: Self.codeInstructionAddOnKey) ?? ""
        workInstructionAddOn = UserDefaults.standard.string(forKey: Self.workInstructionAddOnKey) ?? ""
        trustedWorkspacePaths = Set(UserDefaults.standard.stringArray(forKey: Self.trustedWorkspacePathsKey) ?? [])
        openCodeCredentialEnabledModes = Set(
            (UserDefaults.standard.stringArray(forKey: Self.openCodeCredentialModesKey) ?? [])
                .compactMap(ConversationMode.init(rawValue:))
        )
        latticeManagedRuntimeIDs = Set(
            (UserDefaults.standard.stringArray(forKey: Self.managedRuntimeIDsKey) ?? [])
                .compactMap(LatticeRuntimeID.init(rawValue:))
        )
        let initialDefaultBackend = BackendAvailabilityPolicy.initialSelection(
            persisted: Self.loadDefaultBackend()
        )
        defaultBackend = initialDefaultBackend
        selectedSessionID = LatticeSessionListOrdering.sorted(sessions).first?.id
        schedulerGlobalLimit = Self.storedSchedulerLimit(forKey: Self.schedulerGlobalLimitKey, fallback: 4)
        schedulerWorkspaceLimit = Self.storedSchedulerLimit(forKey: Self.schedulerWorkspaceLimitKey, fallback: 2)
        var restoredSchedulerLimits = taskScheduler.limits
        restoredSchedulerLimits.global = schedulerGlobalLimit
        restoredSchedulerLimits.perWorkspace = schedulerWorkspaceLimit
        _ = taskScheduler.updateLimits(restoredSchedulerLimits)
        recoverSchedulerMetadata()
        rebuildThreadActivityLanes()
        composerSelectionMode = selectedSession?.executionRoute.mode
        runOrchestrator.app = self
        workspaceTools.workspacePathProvider = { [weak self] in
            guard let self else { return "" }
            return self.activeWorkspacePathForTools
        }
        workspaceTools.onWorkspaceActionMessage = { [weak self] message in
            self?.workspaceActionMessage = message
        }
        // Forward nested tool updates into AppState for existing view bindings.
        workspaceTools.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        selfEditDrafts.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        providerConnections.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        composer.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        sessionCatalog.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        runOrchestrator.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        composerSelectionBackend = selectedSession?.backend
        // Property observers do not run for assignments made during initialization, so load the
        // restored selection's durable draft explicitly for the workspace and overlay composers.
        draft = ComposerSessionDraftTransition.initialComposerDraft(
            selectedID: selectedSessionID,
            storedDraftForSelected: selectedSessionID.flatMap { selectedID in
                sessions.first(where: { $0.id == selectedID })?.draft
            }
        )
        if let first = sessions.first, let path = first.workspacePath, !Self.isImplicitDeveloperWorkspace(path) {
            selectedWorkspacePath = path
        }
        // Never autosave/migrate over a store that failed its initial load.
        // Migration save goes through the coordinator so real write failures are visible (not load recovery).
        if migratedSessions && !sessionStoreInRecovery {
            _ = sessionSaveCoordinator.saveNow(loadedSessions)
        }
        prepareSelfEditWorkspace()
        refreshExtensions()
        switch extensionJobStore.loadResult() {
        case .missing:
            selfEditJobs = []
        case .loaded(let jobs):
            selfEditJobs = jobs
        case .failed(let issue):
            recoveryIssues.append(issue)
            requestPersistenceGateBlock(extensionJobStore.writeGate)
            selfEditJobs = []
        }
        switch extensionPreviewStore.loadResult() {
        case .missing:
            selfEditPreviews = []
        case .loaded(let records):
            selfEditPreviews = records
        case .failed(let issue):
            recoveryIssues.append(issue)
            requestPersistenceGateBlock(extensionPreviewStore.writeGate)
            selfEditPreviews = []
        }
        persistenceRecoveryIssues = recoveryIssues
        // Observer after stored properties are ready; hop to MainActor for @Published updates from debounced tasks.
        sessionSaveCoordinator.setFailureObserver { [weak self] failure in
            Task { @MainActor in
                guard let self else { return }
                // Read the coordinator's current value instead of trusting a queued callback;
                // a later retry may already have succeeded before this MainActor hop runs.
                self.sessionSaveFailure = self.sessionSaveCoordinator.currentFailure
                if self.sessionSaveFailure == nil {
                    self.expandedSessionSaveFailureDetails = false
                }
            }
        }
        // Surface any migration save failure that occurred before the observer was attached.
        if sessionSaveFailure == nil, let pending = sessionSaveCoordinator.currentFailure {
            sessionSaveFailure = pending
        }
        hydratePersistedConnectionState()
        startExtensionMonitoring()
        startResourceMonitoring()
        requestAutomaticConnectionRefresh(refreshProviderCatalogs: false)
        prepareTranscriptSelection(selectedID: selectedSessionID)
    }

    /// Crash-safe termination flush: sync the selected session's ordinary draft, then write the latest snapshot.
    /// Cancels any pending 250 ms debounced draft write and persists exact in-memory content.
    @discardableResult
    func flushPersistenceForLifecycleBoundary() -> SessionSaveAttemptResult {
        forceSyncOrdinaryDraftToSelectedSession()
        let result = sessionSaveCoordinator.flush(sessions)
        sessionSaveFailure = sessionSaveCoordinator.currentFailure
        if sessionSaveFailure == nil {
            expandedSessionSaveFailureDetails = false
        }
        return result
    }

    /// Retry a failed session save using the latest in-memory sessions/draft snapshot (never the stale failed snapshot).
    func retrySessionSave() {
        forceSyncOrdinaryDraftToSelectedSession()
        _ = sessionSaveCoordinator.retry(sessions)
        // Ensure published state matches coordinator after a synchronous retry on MainActor.
        sessionSaveFailure = sessionSaveCoordinator.currentFailure
        if sessionSaveFailure == nil {
            expandedSessionSaveFailureDetails = false
        }
    }

    func copySessionSaveFailureDetails() {
        guard let failure = sessionSaveFailure else { return }
        let payload = """
        Store: \(failure.storeName)
        Path: \(failure.filePath)
        Problem: \(failure.summary)
        Kind: \(failure.kind.rawValue)

        \(failure.technicalDetails)
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }

    func dismissSessionSaveFailureDetails() {
        expandedSessionSaveFailureDetails = false
    }

    var selectedSession: LatticeSession? {
        guard let id = selectedSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    var selectedCheckpointReview: WorkspaceCheckpointReviewState? {
        guard let selectedSessionID else { return nil }
        return checkpointReviewStates[selectedSessionID]
    }

    func refreshSelectedCheckpointReview() {
        guard let sessionID = selectedSessionID,
              selectedSession?.executionRoute.mode == .code else { return }
        // Never clobber a live capture/revert cycle with a durable-store reload.
        if let existing = checkpointReviewStates[sessionID],
           existing.activity == .capturingBefore
            || existing.activity == .running
            || existing.activity == .capturingAfter
            || existing.isPreparingRevert
            || existing.isApplyingRevert {
            return
        }
        let client = checkpointClient
        Task { [weak self] in
            do {
                let checkpoints = try await client.checkpoints(sessionID: sessionID)
                let grouped = Dictionary(grouping: checkpoints, by: { $0.ownership.runID })
                guard let latest = grouped.values
                    .sorted(by: { ($0.map(\.createdAt).max() ?? .distantPast) > ($1.map(\.createdAt).max() ?? .distantPast) })
                    .first,
                    let representative = latest.max(by: { $0.createdAt < $1.createdAt }) else { return }
                // Re-check after the await so a run started during reload is preserved.
                if let existing = self?.checkpointReviewStates[sessionID],
                   existing.activity == .capturingBefore
                    || existing.activity == .running
                    || existing.activity == .capturingAfter
                    || existing.isPreparingRevert
                    || existing.isApplyingRevert {
                    return
                }
                let before = latest.first(where: { $0.boundary == .beforeRun })
                let after = latest.first(where: { $0.boundary == .afterRun })
                let restoredActivity: WorkspaceCheckpointActivity = {
                    if before?.status == .captured, after?.status == .captured {
                        return .ready
                    }
                    if before?.status == .failed || after?.status == .failed {
                        return .failed
                    }
                    if before != nil || after != nil {
                        return .failed
                    }
                    return .idle
                }()
                var restored = WorkspaceCheckpointReviewState(
                    sessionID: sessionID,
                    runID: representative.ownership.runID,
                    worktreePath: representative.ownership.worktreePath,
                    activity: restoredActivity,
                    beforeCheckpoint: before,
                    afterCheckpoint: after,
                    issue: (after ?? before)?.failureSummary
                )
                if let before, let after,
                   before.status == .captured, after.status == .captured {
                    restored.changes = try? await client.changes(
                        beforeCheckpointID: before.id,
                        afterCheckpointID: after.id
                    )
                    restored.notes = (try? await client.reviewNotes(checkpointID: after.id)) ?? []
                    if restored.changes == nil {
                        restored.activity = .failed
                        restored.issue = restored.issue ?? "Could not load the review diff for this checkpoint pair."
                    }
                }
                guard self?.selectedSessionID == sessionID else { return }
                if let existing = self?.checkpointReviewStates[sessionID],
                   existing.activity == .capturingBefore
                    || existing.activity == .running
                    || existing.activity == .capturingAfter
                    || existing.isPreparingRevert
                    || existing.isApplyingRevert {
                    return
                }
                self?.checkpointReviewStates[sessionID] = restored
            } catch {
                guard self?.selectedSessionID == sessionID else { return }
                if let existing = self?.checkpointReviewStates[sessionID],
                   existing.activity == .capturingBefore
                    || existing.activity == .running
                    || existing.activity == .capturingAfter
                    || existing.isPreparingRevert
                    || existing.isApplyingRevert {
                    return
                }
                self?.checkpointReviewStates[sessionID] = WorkspaceCheckpointReviewState(
                    sessionID: sessionID,
                    runID: UUID(),
                    worktreePath: self?.selectedSession?.workspacePath ?? "",
                    activity: .failed,
                    issue: self?.checkpointMessage(for: error)
                )
            }
        }
    }

    func addSelectedCheckpointReviewNote(
        path: String,
        body: String,
        kind: WorkspaceReviewNoteKind,
        lineRange: WorkspaceReviewLineRange?,
        hunkHeader: String?,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        guard let sessionID = selectedSessionID,
              let checkpointID = checkpointReviewStates[sessionID]?.afterCheckpoint?.id else {
            completion(false)
            return
        }
        let client = checkpointClient
        Task { [weak self] in
            do {
                let note = try await client.addReviewNote(
                    checkpointID: checkpointID,
                    path: path,
                    body: body,
                    kind: kind,
                    lineRange: lineRange,
                    hunkHeader: hunkHeader
                )
                guard self?.checkpointReviewStates[sessionID]?.afterCheckpoint?.id == checkpointID else {
                    completion(false)
                    return
                }
                self?.checkpointReviewStates[sessionID]?.notes.append(note)
                self?.checkpointReviewStates[sessionID]?.issue = nil
                completion(true)
            } catch {
                self?.checkpointReviewStates[sessionID]?.issue = self?.checkpointMessage(for: error)
                completion(false)
            }
        }
    }

    func previewSelectedCheckpointRevert() {
        guard let sessionID = selectedSessionID,
              let checkpointID = checkpointReviewStates[sessionID]?.afterCheckpoint?.id,
              checkpointReviewStates[sessionID]?.ownsCompletePair == true,
              checkpointReviewStates[sessionID]?.isPreparingRevert != true,
              checkpointReviewStates[sessionID]?.isApplyingRevert != true,
              selectedSession?.isStreaming != true else { return }
        checkpointReviewStates[sessionID]?.isPreparingRevert = true
        checkpointReviewStates[sessionID]?.revertPreview = nil
        checkpointReviewStates[sessionID]?.revertStatus = nil
        let client = checkpointClient
        Task { [weak self] in
            do {
                let preview = try await client.previewRevert(afterCheckpointID: checkpointID)
                guard self?.checkpointReviewStates[sessionID]?.afterCheckpoint?.id == checkpointID else { return }
                self?.checkpointReviewStates[sessionID]?.revertPreview = preview
            } catch {
                self?.checkpointReviewStates[sessionID]?.revertStatus = self?.checkpointMessage(for: error)
            }
            self?.checkpointReviewStates[sessionID]?.isPreparingRevert = false
        }
    }

    func confirmSelectedCheckpointRevert() {
        guard let sessionID = selectedSessionID,
              let preview = checkpointReviewStates[sessionID]?.revertPreview,
              checkpointReviewStates[sessionID]?.isApplyingRevert != true,
              selectedSession?.isStreaming != true else { return }
        checkpointReviewStates[sessionID]?.isApplyingRevert = true
        checkpointReviewStates[sessionID]?.revertStatus = nil
        let client = checkpointClient
        Task { [weak self] in
            do {
                let result = try await client.confirmRevert(
                    afterCheckpointID: preview.afterCheckpointID,
                    confirmationToken: preview.confirmationToken
                )
                guard self?.checkpointReviewStates[sessionID]?.revertPreview?.confirmationToken == preview.confirmationToken else { return }
                self?.checkpointReviewStates[sessionID]?.revertStatus = result.summary
                self?.checkpointReviewStates[sessionID]?.revertPreview = nil
            } catch {
                self?.checkpointReviewStates[sessionID]?.revertStatus = self?.checkpointMessage(for: error)
            }
            self?.checkpointReviewStates[sessionID]?.isApplyingRevert = false
        }
    }

    func checkpointMessage(for error: Error) -> String {
        (error as? WorkspaceCheckpointError)?.message ?? error.localizedDescription
    }

    var isSelectedTranscriptLoading: Bool {
        selectedSessionID != nil && transcriptLoadingSessionID == selectedSessionID
    }

    var filteredSessions: [LatticeSession] {
        let allIDs = Set(sessions.map(\.id))
        var candidates = sessionSearchIndex.candidateSessionIDs(for: searchText, allSessionIDs: allIDs)
        // Loaded transcripts may have unsaved edits/appends. Exact matching overrides the
        // persisted derived index so search never lags behind the canonical in-memory session.
        for session in sessions where session.isTranscriptLoaded {
            if session.matchesSearch(searchText) {
                candidates.insert(session.id)
            } else {
                candidates.remove(session.id)
            }
        }
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        return sessionProjectionCache.orderedSessionIDs(for: sessions).compactMap { id in
            guard candidates.contains(id) else { return nil }
            return sessionsByID[id]
        }
    }

    func visibleMessages(for session: LatticeSession) -> [ChatMessage] {
        let window = transcriptRenderWindows.activate(sessionID: session.id, messageCount: session.messages.count)
        return Array(session.messages[window.range])
    }

    func hiddenEarlierMessageCount(for session: LatticeSession) -> Int {
        transcriptRenderWindows.window(for: session.id, messageCount: session.messages.count).hiddenEarlierCount
    }

    func loadEarlierMessages(for sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        _ = transcriptRenderWindows.loadEarlier(sessionID: sessionID, messageCount: session.messages.count)
        objectWillChange.send()
    }

    var canNavigateSessionList: Bool {
        navigableSessions.count > 1
    }

    /// Fast, keyboard-friendly thread switching using the same ordering and
    /// search scope as the visible chat list. Selection itself is synchronous;
    /// draft persistence is coalesced by the selection boundary below.
    func selectAdjacentSession(offset: Int) {
        guard offset != 0 else { return }
        let ordered = navigableSessions
        guard !ordered.isEmpty else { return }
        guard let selectedSessionID,
              let currentIndex = ordered.firstIndex(where: { $0.id == selectedSessionID }) else {
            self.selectedSessionID = ordered[0].id
            return
        }
        let nextIndex = currentIndex + offset
        guard ordered.indices.contains(nextIndex) else { return }
        self.selectedSessionID = ordered[nextIndex].id
    }

    var navigableSessions: [LatticeSession] {
        filteredSessions
    }

    var selectedSessionUsesLegacyDirectOpenCode: Bool {
        selectedSession.map { LegacyOpenCodeBridgePolicy.allows($0.executionRoute) } ?? false
    }

    /// Truthful controls for the selected chat's harness route and execution policy.
    /// Live provider tools do not pass through `LocalToolBroker` today.
    var selectedRouteCapability: RouteCapability? {
        guard let session = selectedSession else { return nil }
        return RouteCapability.resolve(
            harnessID: effectiveHarnessID(for: session),
            policy: session.policy
        )
    }

    /// Live, non-persisted harness disclosure for the selected chat.
    var selectedHarnessCapabilities: HarnessCapabilitySnapshot? {
        guard let session = selectedSession else { return nil }
        let credentialEnabled: Bool? = OpenCodeCredentialPolicy.allowsKeychainCredential(for: session.executionRoute)
            ? openCodeAPIKeySaved && openCodeCredentialEnabledModes.contains(session.executionRoute.mode)
            : nil
        return HarnessCapabilitySnapshot.resolve(
            route: session.executionRoute,
            policy: session.policy,
            readiness: routeReadinessSnapshot(for: session.executionRoute),
            hasProviderSession: session.harnessThreadID != nil,
            isRunning: session.isStreaming,
            routeCredentialEnabled: credentialEnabled
        )
    }

    var editingMessageID: UUID? { editingMessageContext?.messageID }

    var activeBackend: ChatBackend { selectedSession?.backend ?? composerSelectionBackend ?? defaultBackend }
    var activePrivacyMode: SessionPrivacyMode { selectedSession?.privacyMode ?? privacyMode }
    var activeHarnessID: String {
        if let session = selectedSession { return effectiveHarnessID(for: session) }
        if let mode = composerSelectionMode, let backend = composerSelectionBackend,
           let route = ExecutionRouteResolver.resolve(mode: mode, backend: backend) {
            return route.runtimeID
        }
        return selectedRouteHarnessID
    }
    var activeConversationMode: ConversationMode? {
        if selectedSession != nil, !isSelectedSessionRouteLocked {
            return composerSelectionMode
        }
        return selectedSession?.executionRoute.mode ?? composerSelectionMode
    }
    var activeComposerBackend: ChatBackend? {
        if selectedSession != nil, !isSelectedSessionRouteLocked {
            return composerSelectionBackend
        }
        return selectedSession?.backend ?? composerSelectionBackend
    }
    var isComposerRouteLocked: Bool {
        isSelectedSessionRouteLocked
    }
    var overlayMode: OverlayMode {
        get { selectedRunUIState?.overlayMode ?? .idle }
        set { updateSelectedRunUI { $0.overlayMode = newValue } }
    }
    var activity: [ActivityItem] { selectedRunUIState?.activity ?? [] }
    var errorMessage: String? { selectedRunUIState?.errorMessage ?? globalErrorMessage }
    var composerState: MorphingControlState {
        get { selectedRunUIState?.composerState ?? .expanded }
        set { updateSelectedRunUI { $0.composerState = newValue } }
    }
    var overlayControlState: MorphingControlState {
        get { selectedRunUIState?.overlayControlState ?? .expanded }
        set { updateSelectedRunUI { $0.overlayControlState = newValue } }
    }
    var availableExecutionRoutes: [ExecutionRouteOption] {
        let engineID = selectedSession.map { Self.engineID(for: $0.backend) } ?? selectedRouteEngineID
        return ExecutionRoutePolicy.compatibleHarnessIDs(for: engineID)
            .sorted()
            .filter { harnessID in
                // New Code chats are Pi-first; direct Codex/OpenCode harnesses
                // remain visible only for already-materialized legacy chats.
                guard harnessID == "codex" || harnessID == "opencode" else { return true }
                return (selectedSession?.totalMessageCount ?? 0) > 0
            }
            .filter { isRouteHarnessCompatible(engineID: engineID, harnessID: $0) }
            .compactMap { harnessID in
                let title: String
                switch harnessID {
                case "codex": title = "Codex"
                case "opencode": title = "OpenCode"
                case "grok": title = "Grok"
                case "antigravity": title = "Antigravity"
                case "pi": title = LatticeAgentExecutable.productDisplayName
                case "hermes": title = "Hermes"
                default: title = "Lattice"
                }
                return ExecutionRouteOption(engineID: engineID, harnessID: harnessID, title: title)
            }
    }
    var activeReasoningOptions: [ReasoningOption] { reasoningOptions(for: activeBackend, harnessID: activeHarnessID) }
    var activeReasoningEffort: ReasoningEffort? { selectedSession?.reasoningEffort ?? defaultReasoning(for: activeBackend, harnessID: activeHarnessID) }
    var isSelectedSessionRouteLocked: Bool {
        selectedSession.map { $0.totalMessageCount > 0 || !$0.isTranscriptLoaded } == true
    }

    var composerModeOptions: [(mode: ConversationMode, icon: String, detail: String)] {
        [
            (.code, "hammer", "Build, debug, and ship"),
            (.work, "briefcase", "Research, browse, and act"),
            (.local, "lock.shield", "Private models on this Mac")
        ]
    }

    func composerModelOptions(for mode: ConversationMode) -> [ComposerModelOption] {
        var options: [ComposerModelOption] = []
        var seenRouteIDs = Set<String>()

        func append(providerID: String, providerTitle: String, modelID: String, title: String) {
            guard let backend = backend(for: providerID, modelID: modelID),
                  let route = ExecutionRouteResolver.resolve(mode: mode, providerID: providerID, modelID: modelID) else { return }
            guard seenRouteIDs.insert(route.id).inserted else { return }
            let reason: String?
            if !isModelEnabled(backend.id) {
                reason = "Hidden in Connections"
            } else if mode == .code,
                      let resolution = piFirstCodeResolution(for: route, routeLocked: false) {
                reason = resolution.isRunnable ? nil : resolution.blockingReason
            } else {
                reason = composerUnavailableReason(for: backend, route: route)
            }
            let reasoning = reasoningOptions(for: backend, harnessID: route.runtimeID)
                .map(\.effort.displayName)
            options.append(ComposerModelOption(
                route: route,
                backend: backend,
                providerTitle: providerTitle,
                title: title,
                reason: reason,
                reasoningSummary: reasoning.isEmpty ? nil : "Reasoning · " + reasoning.joined(separator: ", ")
            ))
        }

        switch mode {
        case .code:
            for identifier in piModelIDs.sorted() where identifier.hasPrefix("openai-codex/") {
                let model = String(identifier.dropFirst("openai-codex/".count))
                append(providerID: "codex", providerTitle: "Codex", modelID: model, title: model)
            }
            // Provider-owned catalogs are included even when Pi has no catalog
            // or is unavailable. The selected preferred route is materialized
            // to a marked direct fallback at prompt admission when runnable.
            for model in visibleCodexModels {
                append(providerID: "codex", providerTitle: "Codex", modelID: model.id, title: model.name)
            }
            for identifier in piModelIDs.sorted() where identifier.hasPrefix("opencode-go/") || identifier.hasPrefix("opencode-zen/") {
                append(providerID: "opencode", providerTitle: "OpenCode", modelID: identifier, title: identifier.split(separator: "/", maxSplits: 1).last.map(String.init) ?? identifier)
            }
            for model in visibleOpenCodeModels {
                append(providerID: "opencode", providerTitle: "OpenCode", modelID: model.id, title: model.name)
            }
            for model in grokModels { append(providerID: "grok", providerTitle: "Grok", modelID: model.id, title: model.name) }
            for model in antigravityModels { append(providerID: "antigravity", providerTitle: "Antigravity", modelID: model.id, title: model.name) }
        case .work:
            for model in hermesModels {
                if model.id.hasPrefix("openai-codex:") {
                    append(providerID: "codex", providerTitle: "Codex", modelID: model.id, title: model.name)
                } else if model.id.hasPrefix("xai-oauth:") || model.id.hasPrefix("xai:") {
                    append(providerID: "grok", providerTitle: "Grok", modelID: model.id, title: model.name)
                } else if model.id.hasPrefix("opencode-go:") || model.id.hasPrefix("opencode-zen:") {
                    append(providerID: "opencode", providerTitle: "OpenCode", modelID: model.id, title: model.name)
                }
            }
        case .local:
            break
        }

        if mode != .local {
            for entry in ExecutionRouteResolver.catalog().entries(for: mode)
            where !options.contains(where: { $0.route.providerID == entry.route.providerID }) {
                let providerTitle: String = switch entry.route.providerID {
                case "codex": "Codex"
                case "grok": "Grok"
                case "opencode": "OpenCode"
                default: "Antigravity"
                }
                options.append(ComposerModelOption(
                    route: entry.route,
                    backend: nil,
                    providerTitle: providerTitle,
                    title: "No models reported",
                    reason: mode == .work
                        ? workRouteReadinessDetail(providerID: entry.route.providerID)
                        : codeRouteReadinessDetail(providerID: entry.route.providerID)
                ))
            }
        }

        if mode == .local {
            let appleRoute = ExecutionRouteResolver.resolve(mode: .local, providerID: "apple")
            if let appleRoute {
                options.append(ComposerModelOption(
                    route: appleRoute,
                    backend: .appleIntelligence,
                    providerTitle: "On this Mac",
                    title: "Apple Intelligence",
                    reason: appleIntelligenceReady ? nil : appleIntelligenceStatus
                ))
            }
            let localModels = ollamaModels.map { model in
                let backend = ChatBackend.ollama(model: model.name)
                let route = ExecutionRouteResolver.resolve(mode: .local, providerID: "ollama", modelID: model.name)
                let reason = isModelEnabled(backend.id) ? route.flatMap { composerUnavailableReason(for: backend, route: $0) } : "Hidden in Connections"
                return route.map { ComposerModelOption(route: $0, backend: backend, providerTitle: "Ollama", title: model.name, reason: reason) }
            }.compactMap { $0 }
            if localModels.isEmpty {
                let template = ExecutionRouteResolver.catalog().entries(for: .local).first { $0.route.providerID == "ollama" }
                if let template {
                    options.append(ComposerModelOption(route: template.route, backend: nil, providerTitle: "Ollama", title: "No local models reported", reason: ollamaReadinessDetail))
                }
            } else {
                options.append(contentsOf: localModels)
            }
        }

        return options.sorted { lhs, rhs in
            if lhs.providerTitle != rhs.providerTitle { return lhs.providerTitle < rhs.providerTitle }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func selectComposerMode(_ mode: ConversationMode) {
        guard !isComposerRouteLocked else { return }
        composerSelectionMode = mode
        composerSelectionBackend = nil
        if selectedSessionID == nil {
            isTransientNewChat = true
        }
    }

    func selectComposerModel(_ option: ComposerModelOption) {
        guard !isComposerRouteLocked, option.isAvailable, let backend = option.backend else { return }
        guard let index = selectedSessionID.flatMap({ id in sessions.firstIndex { $0.id == id } }) else {
            composerSelectionMode = option.route.mode
            composerSelectionBackend = backend
            isTransientNewChat = true
            return
        }
        guard sessions[index].isTranscriptLoaded,
              sessions[index].totalMessageCount == 0 else { return }
        let previousSession = sessions[index]
        let previousComposerMode = composerSelectionMode
        let previousComposerBackend = composerSelectionBackend
        sessions[index].backend = backend
        sessions[index].executionRoute = option.route
        sessions[index].harnessID = option.route.runtimeID
        sessions[index].reasoningEffort = defaultReasoning(for: backend, harnessID: option.route.runtimeID)
        sessions[index].harnessThreadID = nil
        composerSelectionMode = option.route.mode
        composerSelectionBackend = backend
        if persist() != .saved {
            sessions[index] = previousSession
            composerSelectionMode = previousComposerMode
            composerSelectionBackend = previousComposerBackend
        }
    }

    func openConnectionsFromComposer() {
        selectedSection = .connections
        openWorkspaceAction?()
    }

    @discardableResult
    func setInstructionAddOn(_ value: String, for mode: ConversationMode) -> Bool {
        guard mode != .local, value.utf8.count <= LatticeInstructionEnvelope.maximumUserAddOnBytes else {
            setError("Mode instructions must be 8 KiB or less and must not contain credentials.", sessionID: selectedSessionID)
            return false
        }
        switch mode {
        case .code:
            codeInstructionAddOn = value
            UserDefaults.standard.set(value, forKey: Self.codeInstructionAddOnKey)
        case .work:
            workInstructionAddOn = value
            UserDefaults.standard.set(value, forKey: Self.workInstructionAddOnKey)
        case .local:
            return false
        }
        return true
    }

    func setSelectedWorkspaceInstructionTrust(_ trusted: Bool) {
        guard let workspace = selectedSession?.workspacePath ?? Optional(selectedWorkspacePath),
              let canonical = try? HarnessSandbox.canonicalDirectory(URL(fileURLWithPath: workspace)).path else { return }
        if trusted { trustedWorkspacePaths.insert(canonical) }
        else { trustedWorkspacePaths.remove(canonical) }
        UserDefaults.standard.set(Array(trustedWorkspacePaths).sorted(), forKey: Self.trustedWorkspacePathsKey)
        objectWillChange.send()
    }

    var selectedWorkspaceInstructionsTrusted: Bool {
        guard let workspace = selectedSession?.workspacePath ?? Optional(selectedWorkspacePath),
              let canonical = try? HarnessSandbox.canonicalDirectory(URL(fileURLWithPath: workspace)).path else { return false }
        return trustedWorkspacePaths.contains(canonical)
    }

    var selectedAppliedInstructionFileNames: [String] {
        guard let session = selectedSession else { return [] }
        return appliedInstructionFileNames(for: workspaceURL(for: session, isExtensionSelfEdit: false), trusted: selectedWorkspaceInstructionsTrusted)
    }
    var attachments: [ContextAttachment] { selectedSession?.attachments ?? [] }
    var selectedContextBudgetEstimate: LatticeContextBudgetEstimate? {
        selectedSession.map { contextBudgetEstimate(for: $0) }
    }

    var selectedContextBudgetBreakdown: LatticeContextBudgetBreakdown? {
        selectedSession.map {
            LatticeContextBudgetEstimator.breakdown(session: $0, draft: draft)
        }
    }
    var visibleCodexModels: [ProviderModel] { codexModels.filter { isModelEnabled("codex:\($0.id)") } }
    var hasConnectedProviderCatalog: Bool {
        codexReady || codex.isInstalled || grokReady || grok.isInstalled || openCodeReady || openCode.isInstalled || antigravityAuthenticated || antigravityInstalled || !codexModels.isEmpty || !grokModels.isEmpty || !openCodeModels.isEmpty || !antigravityModels.isEmpty
    }

    var hasProviderCatalogProblem: Bool {
        ["codex", "grok", "opencode", "antigravity"].compactMap { cliActionMessages[$0] }.contains { CLIActionStatusPolicy.messageIndicatesProblem($0) }
    }

    var providerCatalogProblemMessage: String? {
        ["codex", "grok", "opencode", "antigravity"].compactMap { cliActionMessages[$0] }.first(where: { CLIActionStatusPolicy.messageIndicatesProblem($0) })
    }
    var visibleGrokModels: [ProviderModel] { grokModels.filter { isModelEnabled("grok:\($0.id)") } }
    var visibleOpenCodeModels: [ProviderModel] { openCodeModels.filter { isModelEnabled("opencode:\($0.id)") } }
    var visibleAntigravityModels: [ProviderModel] { antigravityModels.filter { isModelEnabled("antigravity:\($0.id)") } }
    var codexCatalogReady: Bool { codexReady && !codexModels.isEmpty }
    var antigravityCatalogReady: Bool { antigravityAuthenticated && !visibleAntigravityModels.isEmpty }

    func setProviderModelsExpanded(_ providerID: String, expanded: Bool) {
        if expanded { expandedProviderModelIDs.insert(providerID) }
        else { expandedProviderModelIDs.remove(providerID) }
    }
    func providerModelDisclosureState(for providerID: String) -> ProviderModelDisclosureState {
        providerModelDisclosureStates[providerID] ?? ProviderModelDisclosureState()
    }
    func setProviderModelDisclosureExpanded(_ providerID: String, expanded: Bool) {
        var disclosure = providerModelDisclosureState(for: providerID)
        disclosure.isExpanded = expanded
        providerModelDisclosureStates[providerID] = disclosure
    }
    func setProviderModelSearchQuery(_ providerID: String, query: String) {
        var disclosure = providerModelDisclosureState(for: providerID)
        disclosure.query = query
        providerModelDisclosureStates[providerID] = disclosure
    }
    var runnableGrokModels: [ProviderModel] { visibleGrokModels.filter { ACPHarness.bestMatch(for: $0.id, in: grokACPModels) != nil } }
    var runnableOpenCodeModels: [ProviderModel] { visibleOpenCodeModels.filter { ACPHarness.bestMatch(for: $0.id, in: openCodeACPModels) != nil } }
    var localModelIdleUnloadLabel: String { localModelIdleUnloadMinutes == 0 ? "Off" : "\(localModelIdleUnloadMinutes)m" }
    var codexReadinessCopy: ProviderReadinessCopy {
        ProviderReadinessPresentationPolicy.copy(
            providerName: "Codex",
            readiness: ProviderReadinessSnapshot(installed: codex.isInstalled, authenticated: codexAuthenticated, catalogStatus: codexCatalogStatus, runnableModelCount: visibleCodexModels.count)
        )
    }
    var grokReadinessCopy: ProviderReadinessCopy {
        ProviderReadinessPresentationPolicy.copy(
            providerName: "Grok",
            readiness: ProviderReadinessSnapshot(installed: grok.isInstalled, authenticated: grokAuthenticated, catalogStatus: grokCatalogStatus, runnableModelCount: runnableGrokModels.count),
            readyDetail: "Available · ACP"
        )
    }
    var openCodeReadinessCopy: ProviderReadinessCopy {
        ProviderReadinessPresentationPolicy.copy(
            providerName: "OpenCode",
            readiness: ProviderReadinessSnapshot(installed: openCode.isInstalled, authenticated: openCodeAuthenticated, catalogStatus: openCodeCatalogStatus, runnableModelCount: runnableOpenCodeModels.count),
            readyDetail: "Available · ACP"
        )
    }
    var piCLIInfo: CLIUpdateInfo {
        CLIUpdateInfo(
            currentVersion: piCLIVersion,
            latestVersion: piLatestCLIVersion,
            updateAvailable: CLIVersionDisplayPolicy.isUpdateAvailable(currentVersion: piCLIVersion, latestVersion: piLatestCLIVersion)
        )
    }

    var canSendDraft: Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard !isSelectedTranscriptLoading else { return false }
        if let session = selectedSession,
           (!session.isTranscriptLoaded || !session.isArtifactsLoaded) {
            return false
        }
        guard imageAttachmentSendBlockReason == nil else { return false }
        if !isSelectedSessionRouteLocked {
            guard let mode = composerSelectionMode,
                  let backend = composerSelectionBackend,
                  let route = ExecutionRouteResolver.resolve(mode: mode, backend: backend),
                  composerUnavailableReason(for: backend, route: route) == nil else { return false }
            if selectedSession == nil, !isTransientNewChat { return false }
        }
        if editingMessageID == nil, appCommandCompletion(for: draft) != nil { return true }
        if editingMessageID == nil,
           LatticeSelfEditReviewDecision.parse(text) != nil,
           let sessionID = selectedSessionID,
           !visibleSelfEditPreviews(for: sessionID).isEmpty,
           selectedSession?.isStreaming != true {
            return true
        }
        if LatticeSelfEditCommand.prompt(in: text) == "" { return true }
        if selectedSession?.isStreaming == true { return editingMessageID == nil }
        if selectedSession == nil { return true }
        return selectedSession.map(canRunSession(_:)) != false
    }
    var canStopSelectedSession: Bool {
        selectedSession?.isStreaming == true
    }
    var composerSubmitDisabledHelp: String? {
        guard !canSendDraft else { return nil }
        if isSelectedTranscriptLoading {
            return "Wait for this chat's transcript to finish loading"
        }
        if let session = selectedSession,
           (!session.isTranscriptLoaded || !session.isArtifactsLoaded) {
            return needsPersistenceRecovery
                ? "Resolve chat-store recovery before sending"
                : "Wait for this chat's conversation content to load"
        }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selectedSession?.isStreaming == true
                ? "Type a follow-up to queue"
                : "Type a message to send"
        }
        if let imageAttachmentSendBlockReason { return imageAttachmentSendBlockReason }
        if selectedSession?.isStreaming == true, editingMessageID != nil {
            return "Finish editing before queuing a follow-up"
        }
        if !isSelectedSessionRouteLocked {
            return composerSelectionMode == nil || composerSelectionBackend == nil
                ? "Choose a mode and model"
                : "Selected model is unavailable"
        }
        return activeRouteStatusText ?? "Send is unavailable"
    }

    var imageAttachmentSendBlockReason: String? {
        let images = attachments.filter { !$0.isMissing && $0.isImage }
        guard !images.isEmpty else { return nil }
        guard case .codex(let modelID)? = activeComposerBackend,
              let model = codexModels.first(where: { $0.id == modelID }) else {
            return "This route does not advertise image attachment transport. Remove the image or choose an image-capable route."
        }
        if case .blocked(let reason) = AttachmentTransportPolicy.evaluate(attachments: images, model: model) {
            return reason
        }
        return "Image attachments are prepared, but this Lattice build does not yet transport image bytes to Codex. Remove the image to send."
    }
    var canContinueSelectedSession: Bool {
        guard editingMessageID == nil,
              let session = selectedSession,
              session.isTranscriptLoaded,
              session.isArtifactsLoaded,
              LatticeContinuationPolicy.canContinue(session) else { return false }
        return canRunSession(session)
    }
    var canRetrySelectedSession: Bool {
        guard let session = selectedSession,
              !session.isStreaming,
              session.isTranscriptLoaded,
              session.isArtifactsLoaded,
              retryableRequests[session.id] != nil else { return false }
        return canRunSession(session)
    }
    func retrySelectedSession() {
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isStreaming,
              let request = retryableRequests[id],
              requireLoadedSessionContent(for: id, at: index) else { return }
        guard canRunSession(sessions[index]) else {
            setError(routeUnavailableMessage(for: sessions[index]) ?? "Choose a connected model.", sessionID: id)
            return
        }
        let previousSession = sessions[index]
        let previousSubmittedRequest = submittedRequests[id]
        let previousRetryableRequest = retryableRequests[id]
        sessions[index].messages.append(.init(role: .assistant, text: ""))
        submittedRequests[id] = request
        retryableRequests[id] = nil
        guard startRun(for: id, at: index, submittedText: request) else {
            sessions[index] = previousSession
            submittedRequests[id] = previousSubmittedRequest
            retryableRequests[id] = previousRetryableRequest
            return
        }
    }

    func workProjection(for session: LatticeSession) -> WorkProjection.Snapshot {
        let liveApprovalIDs = harnessPermissionNotices[session.id].map { Set([$0.request.id]) } ?? []
        let retryable = Set(session.actions.compactMap { action in
            action.status == .failed && originatingUserMessage(for: action, in: session) != nil
                ? action.id
                : nil
        })
        return WorkProjection.project(
            mode: session.executionRoute.mode,
            actions: session.actions,
            liveApprovalIDs: liveApprovalIDs,
            retryableActionIDs: retryable
        )
    }

    func confirmWorkTask(actionID: UUID) {
        guard let sessionID = selectedSessionID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              !sessions[sessionIndex].isStreaming,
              requireLoadedSessionContent(for: sessionID, at: sessionIndex),
              let actionIndex = sessions[sessionIndex].actions.firstIndex(where: { $0.id == actionID }),
              let updated = WorkProjection.applyingTaskMark(.confirmed, to: sessions[sessionIndex].actions[actionIndex]) else { return }
        let previousSession = sessions[sessionIndex]
        sessions[sessionIndex].actions[actionIndex] = updated
        sessions[sessionIndex].lastUpdated = .now
        if persist() != .saved {
            sessions[sessionIndex] = previousSession
        }
    }

    func answerWorkQuestion(actionID: UUID, answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let sessionID = selectedSessionID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              !sessions[sessionIndex].isStreaming,
              let actionIndex = sessions[sessionIndex].actions.firstIndex(where: { $0.id == actionID }),
              sessions[sessionIndex].actions[actionIndex].work?.kind == .question,
              sessions[sessionIndex].actions[actionIndex].work?.ownership == .userOwned,
              sessions[sessionIndex].actions[actionIndex].status == .waiting,
              let submission = prepareSubmission(trimmed) else { return }
        let previousSession = sessions[sessionIndex]
        let answerMessageID = UUID()
        guard let updated = WorkProjection.applyingAnswer(
            messageID: answerMessageID,
            to: sessions[sessionIndex].actions[actionIndex]
        ) else { return }
        sessions[sessionIndex].actions[actionIndex] = updated
        sessions[sessionIndex].lastUpdated = .now
        // Admit the answer message and its answered-work marker in the same
        // durable run boundary. A rejected launch restores the waiting item.
        guard startPreparedSubmission(
            submission,
            for: sessionID,
            at: sessionIndex,
            sourceOutboxID: answerMessageID
        ) else {
            sessions[sessionIndex] = previousSession
            return
        }
    }

    func retryWorkItem(actionID: UUID) {
        guard let sessionID = selectedSessionID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              !sessions[sessionIndex].isStreaming,
              requireLoadedSessionContent(for: sessionID, at: sessionIndex),
              let action = sessions[sessionIndex].actions.first(where: { $0.id == actionID && $0.status == .failed }),
              let request = originatingUserMessage(for: action, in: sessions[sessionIndex])?.text,
              let submission = prepareSubmission(request) else { return }
        _ = startPreparedSubmission(submission, for: sessionID, at: sessionIndex)
    }

    func openWorkArtifact(actionID: UUID) {
        guard let artifact = resolvedWorkArtifact(actionID: actionID) else { return }
        guard WorkArtifactAccessPolicy.canOpen(locator: artifact.locator, workspace: artifact.workspace) else {
            setError("This artifact is reveal-only because it is outside the workspace or is not a safe document type.", sessionID: selectedSessionID)
            return
        }
        guard FileManager.default.fileExists(atPath: artifact.url.path) else {
            setError("The artifact is no longer available at its recorded path.", sessionID: selectedSessionID)
            return
        }
        if !NSWorkspace.shared.open(artifact.url) {
            setError("The artifact could not be opened.", sessionID: selectedSessionID)
        }
    }

    func revealWorkArtifact(actionID: UUID) {
        guard let artifact = resolvedWorkArtifact(actionID: actionID) else { return }
        if FileManager.default.fileExists(atPath: artifact.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
            return
        }
        let parent = artifact.url.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: parent.path) {
            _ = NSWorkspace.shared.open(parent)
        } else {
            setError("The artifact and its parent folder are no longer available.", sessionID: selectedSessionID)
        }
    }

    func resolvedWorkArtifact(actionID: UUID) -> (locator: String, url: URL, workspace: URL)? {
        guard let session = selectedSession,
              let action = session.actions.first(where: { $0.id == actionID }),
              action.work?.kind == .artifact,
              let locator = action.work?.artifactLocator else { return nil }
        let workspace = URL(fileURLWithPath: session.workspacePath ?? selectedWorkspacePath).standardizedFileURL
        guard let url = WorkArtifactAccessPolicy.resolvedFileURL(locator: locator, workspace: workspace) else {
            setError("The recorded artifact path is invalid.", sessionID: session.id)
            return nil
        }
        return (locator, url, workspace)
    }

    func originatingUserMessage(for action: SessionAction, in session: LatticeSession) -> ChatMessage? {
        let originID = action.work?.originMessageID ?? action.messageID
        guard let originIndex = session.messages.firstIndex(where: { $0.id == originID }) else { return nil }
        return session.messages[...originIndex].last(where: { $0.role == .user && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }
    var canDeleteSelectedSession: Bool {
        guard let session = selectedSession else { return false }
        return !session.isStreaming
    }
    var activeRouteStatusText: String? {
        guard let session = selectedSession, !session.isStreaming else { return nil }
        if PiFirstCodeRoutingPolicy.isDeclaredProviderFallback(session.executionRoute),
           canRunSession(session) {
            return "Provider fallback · Lattice Agent unavailable"
        }
        return routeUnavailableMessage(for: session)
    }
    func visibleErrorMessage(for sessionID: UUID) -> String? {
        runUIStates[sessionID]?.errorMessage ?? globalErrorMessage
    }
    func visibleActivity(for sessionID: UUID) -> [ActivityItem] {
        runUIStates[sessionID]?.activity ?? []
    }
    func computerFramePresentation(for sessionID: UUID) -> ComputerFrameViewerPresentation {
        ComputerFramePresentationPolicy.presentation(
            for: computerFrameAccumulators[sessionID] ?? ComputerFrameAccumulator()
        )
    }
    func visibleComposerState(for sessionID: UUID) -> MorphingControlState {
        runUIStates[sessionID]?.composerState ?? .expanded
    }
    func threadActivityLane(for sessionID: UUID) -> ThreadActivityLane {
        threadActivityLanes.lane(for: sessionID)
    }

    func focusThreadAttention(_ sessionID: UUID) {
        selectedSection = .conversations
        selectedSessionID = sessionID
        threadActivityLanes.apply(.attentionHandled, to: sessionID)
    }

    func cancelThreadActivity(_ sessionID: UUID) {
        stop(sessionID: sessionID)
    }

    func setThreadPriority(_ priority: AgentTaskPriority, sessionID: UUID) {
        threadActivityLanes.apply(.priorityChanged(priority), to: sessionID)
        handleSchedulerAdmissions(taskScheduler.reprioritize(sessionID, to: priority))
        refreshSchedulerLanes()
        persistSchedulerMetadata()
    }

    func setSchedulerGlobalLimit(_ value: Int) {
        let value = min(max(value, 1), 8)
        guard schedulerGlobalLimit != value else { return }
        schedulerGlobalLimit = value
        UserDefaults.standard.set(value, forKey: Self.schedulerGlobalLimitKey)
        var limits = taskScheduler.limits
        limits.global = value
        handleSchedulerAdmissions(taskScheduler.updateLimits(limits))
    }

    func setSchedulerWorkspaceLimit(_ value: Int) {
        let value = min(max(value, 1), 8)
        guard schedulerWorkspaceLimit != value else { return }
        schedulerWorkspaceLimit = value
        UserDefaults.standard.set(value, forKey: Self.schedulerWorkspaceLimitKey)
        var limits = taskScheduler.limits
        limits.perWorkspace = value
        handleSchedulerAdmissions(taskScheduler.updateLimits(limits))
    }

    func setVisibleComposerState(_ state: MorphingControlState, for sessionID: UUID?) {
        guard let sessionID else {
            guard materializeTransientSession(), let materializedID = selectedSessionID else { return }
            reduceRunUI(.setComposerState(state), for: materializedID)
            return
        }
        reduceRunUI(.setComposerState(state), for: sessionID)
    }

    var selectedRunUIState: RunUIState? {
        selectedSessionID.flatMap { runUIStates[$0] }
    }

    func updateSelectedRunUI(_ update: (inout RunUIState) -> Void) {
        guard let sessionID = selectedSessionID else { return }
        var state = runUIStates[sessionID] ?? RunUIState()
        update(&state)
        runUIStates[sessionID] = state
    }

    func reduceRunUI(_ action: RunUIAction, for sessionID: UUID) {
        var state = runUIStates[sessionID] ?? RunUIState()
        RunUIReducer.reduce(action, into: &state)
        runUIStates[sessionID] = state
    }

    func contextBudgetEstimate(for session: LatticeSession) -> LatticeContextBudgetEstimate {
        // Always count the ordinary session draft — never transient edited-message text.
        let ordinaryDraft = ordinaryComposerDraft(for: session)
        let tokenLimit = contextTokenLimit(for: session)
        if session.id == selectedSessionID,
           editingMessageID == nil,
           let submission = preparedSubmissionPreview(ordinaryDraft) {
            let additionalContext = backendAdditionalContext(
                for: session,
                submittedText: submission.runText,
                forceSelfEdit: submission.startsSelfEdit
            )
            return LatticeContextBudgetEstimator.estimateBackendPayload(
                session: session,
                submittedText: submission.runText,
                additionalContext: additionalContext,
                tokenLimit: tokenLimit
            )
        }
        return LatticeContextBudgetEstimator.estimate(session: session, draft: ordinaryDraft, tokenLimit: tokenLimit)
    }

    /// Ordinary unsent draft for budget/display. Selected-chat edit text is excluded.
    func ordinaryComposerDraft(for session: LatticeSession) -> String {
        if session.id == selectedSessionID {
            if editingMessageContext != nil {
                return preservedComposerDraftBeforeEdit
            }
            return draft
        }
        return session.draft
    }

    func contextTokenLimit(for session: LatticeSession) -> Int {
        LatticeContextBudgetEstimator.tokenLimit(
            for: session.backend,
            codexModels: codexModels,
            grokModels: grokModels,
            openCodeModels: openCodeModels
        )
    }

    // MARK: - Workspace split columns

    /// Suggested split columns for the measured workspace width.
    /// Preserves three columns when there is room; collapses the section sidebar when narrow.
    func suggestedColumnVisibility(for width: CGFloat) -> NavigationSplitViewVisibility {
        switch LatticeWorkspaceLayoutPolicy.suggestedColumnMode(forWidth: Double(width)) {
        case .all:
            return .all
        case .doubleColumn:
            return .doubleColumn
        }
    }

    /// Records workspace width and adapts columns at breakpoints without fighting user choice.
    func noteWorkspaceWidth(_ width: CGFloat) {
        let previousWidth = lastMeasuredWorkspaceWidth
        lastMeasuredWorkspaceWidth = width

        // Resume automatic behavior only when a resize actually crosses back into the
        // comfortable-wide range. Repeated geometry updates at a wide width must not
        // overwrite a deliberate two-column choice.
        if previousWidth > 0,
           !LatticeWorkspaceLayoutPolicy.shouldResumeAutomaticColumnManagement(width: Double(previousWidth)),
           LatticeWorkspaceLayoutPolicy.shouldResumeAutomaticColumnManagement(width: Double(width)) {
            respectsUserColumnChoice = false
        }
        applyAdaptiveColumnVisibilityIfNeeded()
    }

    /// Marks deliberate split-view toggles so resize adaptation will not immediately undo them.
    func noteColumnVisibilityChanged(to newValue: NavigationSplitViewVisibility) {
        if let lastAuto = lastAutoAppliedColumnVisibility, newValue == lastAuto {
            return
        }
        // Ignore pre-measure noise; only treat deviations from the width-based suggestion as user intent.
        guard lastMeasuredWorkspaceWidth > 0 else { return }
        if newValue != suggestedColumnVisibility(for: lastMeasuredWorkspaceWidth) {
            respectsUserColumnChoice = true
        }
    }

    /// Adapts columns at width breakpoints. Does not override a deliberate user column choice until width is comfortable again.
    func applyAdaptiveColumnVisibilityIfNeeded() {
        guard selectedSection == .conversations, lastMeasuredWorkspaceWidth > 0 else { return }

        guard !respectsUserColumnChoice else { return }

        let suggested = suggestedColumnVisibility(for: lastMeasuredWorkspaceWidth)
        guard columnVisibility != suggested else {
            lastAutoAppliedColumnVisibility = suggested
            return
        }
        lastAutoAppliedColumnVisibility = suggested
        columnVisibility = suggested
    }

    func openCommandPalette() {
        prepareCommandPalettePresentation()
        showCommandPalette = true
    }

    /// Overlay header command-palette trigger: one intentional workspace handoff, then a
    /// single palette presentation so search focus lands in the frontmost workspace window.
    /// Does not open a second workspace window or leave the overlay competing for focus.
    func openCommandPaletteFromOverlay(
        handoffToWorkspace: (@escaping () -> Void) -> Void
    ) {
        let route = LatticeCommandPaletteRouting.route(isOverlayVisible: isOverlayVisible)
        prepareCommandPalettePresentation()
        switch route {
        case .presentInPlace:
            showCommandPalette = true
        case .handoffToWorkspaceThenPresent:
            // Present only from the handoff completion, after the workspace is actually key.
            guard LatticeCommandPaletteRouting.shouldDeferPresentation(for: route) else {
                showCommandPalette = true
                return
            }
            handoffToWorkspace { [weak self] in
                guard let self else { return }
                // Re-clamp after handoff in case enabled actions changed while the overlay dismissed.
                self.commandPaletteSelectedID = LatticeCommandPaletteSelection.clampedSelection(
                    selectedID: self.commandPaletteSelectedID,
                    in: self.filteredCommandPaletteItems()
                )
                self.showCommandPalette = true
            }
        }
    }

    func prepareCommandPalettePresentation() {
        commandPaletteSearch = ""
        commandPaletteSelectedID = LatticeCommandPaletteSelection.clampedSelection(
            selectedID: nil,
            in: filteredCommandPaletteItems()
        )
    }

    func closeCommandPalette() {
        showCommandPalette = false
        commandPaletteSearch = ""
        commandPaletteSelectedID = nil
    }

    func clampCommandPaletteSelection() {
        commandPaletteSelectedID = LatticeCommandPaletteSelection.clampedSelection(
            selectedID: commandPaletteSelectedID,
            in: filteredCommandPaletteItems()
        )
    }

    /// Hover and click update the same shared selection keyboard navigation uses. Disabled rows are ignored.
    func selectCommandPaletteItem(_ id: String) {
        guard let next = LatticeCommandPaletteSelection.selectionAfterHover(
            hoveredID: id,
            in: filteredCommandPaletteItems()
        ) else { return }
        commandPaletteSelectedID = next
    }

    func moveCommandPaletteSelection(delta: Int) {
        commandPaletteSelectedID = LatticeCommandPaletteSelection.movedSelection(
            selectedID: commandPaletteSelectedID,
            in: filteredCommandPaletteItems(),
            delta: delta
        )
    }

    func performSelectedCommandPaletteItem() {
        // Gate on palette visibility so overlapping Return handlers cannot double-run.
        guard showCommandPalette else { return }
        let items = filteredCommandPaletteItems()
        if let item = LatticeCommandPaletteSelection.executableSelection(selectedID: commandPaletteSelectedID, in: items) {
            performCommandPaletteItem(item.id)
            return
        }
        performFirstCommandPaletteMatch()
    }

    var commandPaletteItems: [LatticeCommandPaletteItem] {
        commandPaletteChatItems + commandPaletteCommandItems
    }

    var commandPaletteChatItems: [LatticeCommandPaletteItem] {
        LatticeCommandPaletteChatNavigation.items(
            sessions: sessions,
            activityLanes: threadActivityLanes,
            selectedSessionID: selectedSessionID
        )
    }

    var commandPaletteCommandItems: [LatticeCommandPaletteItem] {
        let routeIssue = selectedSession.flatMap(routeUnavailableMessage(for:))
        return [
            .init(id: "new-chat", title: "New Chat", detail: "Start a fresh conversation", keywords: ["session", "conversation", "chat"]),
            .init(
                id: "send-message",
                title: selectedSession?.isStreaming == true ? "Queue Follow-up" : "Send Message",
                detail: selectedSession?.isStreaming == true ? "Queue the current draft behind the running response" : "Send the current composer draft",
                keywords: ["composer", "prompt", "submit"],
                isEnabled: canSendDraft,
                disabledReason: draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Composer is empty" : (routeIssue ?? "Unavailable")
            ),
            .init(
                id: "stop",
                title: "Stop Current Response",
                detail: "Cancel the active provider run",
                keywords: ["cancel", "interrupt", "halt"],
                isEnabled: canStopSelectedSession,
                disabledReason: "No response is running"
            ),
            .init(
                id: "continue",
                title: "Continue Response",
                detail: "Ask the selected chat to continue from its last assistant response",
                keywords: ["resume", "more", "follow up"],
                isEnabled: canContinueSelectedSession,
                disabledReason: routeIssue ?? "The last visible message is not a completed assistant response"
            ),
            .init(id: "open-overlay", title: "Show Overlay", detail: "Open the fast global Lattice overlay", keywords: ["panel", "quick", "floating"], isEnabled: showOverlayAction != nil, disabledReason: "Overlay is not ready"),
            .init(id: "show-chats", title: "Show Chats", detail: "Go to conversations", keywords: ["sessions", "history", "recents"]),
            .init(id: "show-projects", title: "Show Workspace", detail: "Open the current workspace surface", keywords: ["workspace", "project", "folder"]),
            .init(id: "show-models", title: "Show Models", detail: "Review available and recommended models", keywords: ["provider", "local", "ollama", "codex", "grok", "opencode"]),
            .init(id: "show-connections", title: "Show Connections", detail: "Manage provider installs, sign-in, and updates", keywords: ["login", "install", "update", "auth"]),
            .init(id: "show-extensions", title: "Show Extensions & Skills", detail: "Review Lattice customizations, shared skills, and rollback history", keywords: ["self edit", "customization", "plugins", "skills"]),
            .init(
                id: "toggle-inspector",
                title: showInspector ? "Hide Inspector" : "Show Inspector",
                detail: "Toggle chat details, model, policy, and context",
                keywords: ["details", "sidebar", "context", "policy"],
                isEnabled: selectedSection == .conversations,
                disabledReason: "Inspector is available on chats"
            ),
            .init(id: "choose-workspace", title: "Choose Workspace…", detail: "Select the project folder for new or empty chats", keywords: ["project", "folder", "path"]),
            .init(
                id: "refresh-connections",
                title: "Check Connections",
                detail: "Check provider sign-in, runtimes, and models",
                keywords: ["models", "providers", "refresh", "sync"],
                isEnabled: canRequestConnectionRefresh,
                disabledReason: connectionRefreshDisabledReason ?? "Connection checks are unavailable"
            ),
            .init(id: "open-extensions-folder", title: "Open Extensions Folder", detail: "Show the user-owned Lattice modification layer", keywords: ["self edit", "customization", "application support"]),
            .init(id: "open-skills-folder", title: "Open Skills Folder", detail: "Show Lattice’s shared SKILL.md folder for imported and generated skills", keywords: ["skills", "skill.md", "agents", "customization", "application support"]),
            .init(id: "policy-ask", title: "Set Policy: Ask", detail: "Ask before material changes and external control", keywords: ["permission", "safe", "approval"]),
            .init(id: "policy-smart", title: "Set Policy: Smart", detail: "Allow clearly safe scoped work and ask on risk", keywords: ["permission", "approval", "automatic"]),
            .init(id: "policy-accept-edits", title: "Set Policy: Accept Edits", detail: "Auto-allow workspace file writes/edits after a reported permission request; bash and out-of-workspace still ask", keywords: ["permission", "approval", "accept", "edits"]),
            .init(id: "policy-yolo", title: "Set Policy: YOLO", detail: "Use the explicit high-trust policy for this session", keywords: ["permission", "approval", "danger"]),
            .init(id: "privacy-cloud", title: "Set Privacy: Cloud Allowed", detail: "Allow connected providers and local models for this session", keywords: ["privacy", "provider", "remote", "cloud"]),
            .init(id: "privacy-local", title: "Set Privacy: Local Only", detail: "Block cloud providers and keep routing on Apple Intelligence or Ollama", keywords: ["privacy", "local", "private", "offline", "no cloud"]),
            .init(
                id: "export-chat",
                title: "Export Chat…",
                detail: "Export the selected chat as a portable JSON archive or readable Markdown",
                keywords: ["export", "archive", "portable", "markdown", "json", "backup", "save chat"],
                isEnabled: canExportSelectedSession,
                disabledReason: "Select a chat to export"
            ),
            .init(
                id: "import-chat",
                title: "Import Chat…",
                detail: "Import a Lattice JSON archive as a new chat after preview confirmation",
                keywords: ["import", "archive", "portable", "json", "restore", "open archive"],
                isEnabled: canImportChat,
                disabledReason: needsPersistenceRecovery ? "Resolve chat store recovery first" : "Import is unavailable"
            )
        ]
    }

    func filteredCommandPaletteItems() -> [LatticeCommandPaletteItem] {
        LatticeCommandPaletteChatNavigation.visibleItems(
            chats: commandPaletteChatItems,
            commands: commandPaletteCommandItems,
            query: commandPaletteSearch
        )
    }

    func performFirstCommandPaletteMatch() {
        guard let item = filteredCommandPaletteItems().first(where: \.isEnabled) else { return }
        performCommandPaletteItem(item.id)
    }

    func performCommandPaletteItem(_ id: String) {
        // Closing first means a second submit/click in the same event cycle is a no-op.
        guard showCommandPalette else { return }
        guard let item = commandPaletteItems.first(where: { $0.id == id }), item.isEnabled else { return }
        closeCommandPalette()
        if case .chat(let sessionID) = item.kind {
            openSessionFromWorkspace(sessionID)
            return
        }
        switch id {
        case "new-chat":
            newSession()
        case "send-message":
            sendDraft()
        case "stop":
            stop()
        case "continue":
            continueSelectedResponse()
        case "open-overlay":
            overlayMode = .prompt
            showOverlayAction?()
        case "show-chats":
            selectedSection = .conversations
        case "show-projects":
            selectedSection = .projects
        case "show-models":
            selectedSection = .models
        case "show-connections":
            selectedSection = .connections
        case "show-extensions":
            selectedSection = .extensions
        case "toggle-inspector":
            if selectedSection == .conversations { showInspector.toggle() }
        case "choose-workspace":
            chooseWorkspace()
        case "refresh-connections":
            requestConnectionRefresh()
        case "open-extensions-folder":
            openExtensionsFolder()
        case "open-skills-folder":
            openSkillsFolder()
        case "policy-ask":
            setSessionPolicy(.ask)
        case "policy-smart":
            setSessionPolicy(.smart)
        case "policy-accept-edits":
            setSessionPolicy(.acceptEdits)
        case "policy-yolo":
            setSessionPolicy(.yolo)
        case "privacy-cloud":
            setSessionPrivacyMode(.cloudAllowed)
        case "privacy-local":
            setSessionPrivacyMode(.localOnly)
        case "export-chat":
            requestExportSelectedSession()
        case "import-chat":
            requestImportChat()
        default:
            break
        }
    }

    func isModelEnabled(_ id: String) -> Bool { !disabledModelIDs.contains(id) }
    func setModelEnabled(_ id: String, enabled: Bool) {
        let components = id.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return }
        disabledModelIDs = ProviderModelConfigurationPolicy.updatedDisabledModelIDs(
            disabledModelIDs,
            providerID: components[0],
            modelID: components[1],
            enabled: enabled
        )
        UserDefaults.standard.set(Array(disabledModelIDs).sorted(), forKey: "disabledModelIDs")
        normalizeBackendsAfterCatalogRefresh()
    }

    func selectedModelIDs(for providerID: String) -> Set<String> {
        let candidates = sessions.map(\.backend) + [defaultBackend, composerSelectionBackend].compactMap { $0 }
        return Set(candidates.compactMap { backend in
            switch (providerID, backend) {
            case ("codex", .codex(let model)),
                 ("grok", .grok(let model)),
                 ("opencode", .openCode(let model)),
                 ("antigravity", .antigravity(let model)):
                return model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : model
            default:
                return nil
            }
        })
    }

    func newSession() {
        selectedSessionID = nil
        isTransientNewChat = true
        composerSelectionMode = nil
        composerSelectionBackend = nil
        draft = ""
        selectedSection = .conversations
        clearError()
    }

    var canStartLocalOnlyChat: Bool {
        appleIntelligenceReady || (ollamaReady && ollamaCatalogStatus == .loaded && !ollamaModels.isEmpty)
    }

    func startLocalOnlyChatFromSelected() {
        guard canStartLocalOnlyChat else {
            setError("Local-only mode needs Apple Intelligence or a running Ollama model. Open Connections to make one available.", sessionID: selectedSessionID)
            return
        }
        let backend = localBackendFallback()
        let route = RouteRuntimeMap.writeRoute(backend: backend, mode: .local)
        let harnessID = route.runtimeID
        let source = selectedSession
        let session = LatticeSession(
            title: "New local chat",
            backend: backend,
            executionRoute: route,
            harnessID: harnessID,
            reasoningEffort: defaultReasoning(for: backend, harnessID: harnessID),
            workspacePath: source?.workspacePath ?? selectedWorkspacePath,
            policy: source?.policy ?? policy,
            privacyMode: .localOnly
        )
        sessions.insert(session, at: 0)
        guard persist() == .saved else {
            sessions.removeAll { $0.id == session.id }
            refreshSearchIndexForLoadedSessions()
            return
        }
        selectedSessionID = session.id
        selectedSection = .conversations
        clearError()
    }

    func useBackendInChat(_ backend: ChatBackend) {
        guard canUseBackendInNewChat(backend) else {
            let message = backendUnavailableMessage(for: backend) ?? "Choose a connected model."
            setError(message, sessionID: selectedSessionID)
            return
        }
        let canReuseSelectedChat = selectedSessionID.flatMap { id in
            sessions.first(where: { $0.id == id }).map { session in
                !session.isStreaming
                    && session.isTranscriptLoaded
                    && session.totalMessageCount == 0
            }
        } ?? false
        setBackend(backend)
        if canReuseSelectedChat {
            selectedSection = .conversations
            clearError()
        } else {
            newSession()
        }
    }

    /// Starts a distinct chat from a model catalog action. Unlike route switching,
    /// this never repurposes the currently selected empty chat.
    func startNewChat(with backend: ChatBackend) {
        guard canUseBackendInNewChat(backend) else {
            setError(backendUnavailableMessage(for: backend) ?? "Choose an available model.", sessionID: selectedSessionID)
            return
        }
        let source = selectedSession
        let route = RouteRuntimeMap.writeRoute(
            backend: backend,
            mode: composerSelectionMode ?? source?.executionRoute.mode
        )
        let harnessID = route.runtimeID
        let session = LatticeSession(
            title: "New chat",
            backend: backend,
            executionRoute: route,
            harnessID: harnessID,
            reasoningEffort: defaultReasoning(for: backend, harnessID: harnessID),
            workspacePath: source?.workspacePath ?? selectedWorkspacePath,
            policy: source?.policy ?? policy,
            privacyMode: source?.privacyMode ?? activePrivacyMode
        )
        sessions.insert(session, at: 0)
        guard persist() == .saved else {
            sessions.removeAll { $0.id == session.id }
            refreshSearchIndexForLoadedSessions()
            return
        }
        selectedSessionID = session.id
        selectedSection = .conversations
        clearError()
    }

    func deleteSession(_ id: UUID) {
        let isStreaming = sessions.first(where: { $0.id == id })?.isStreaming == true
        switch SessionDeletionPolicy.decision(forStreamingTarget: id, isStreaming: isStreaming) {
        case .deleteIdle:
            break
        case .cancelTargetThenDelete(let targetSessionID):
            // Always cancel the target by its own id — never stop a different selected session.
            stop(sessionID: targetSessionID)
        case .rejectStreamingWithoutCancel:
            return
        }

        // Remove the durable self-edit preview before deleting the session. If preview
        // persistence is unavailable, keep the chat visible so the UI never presents a
        // session whose pending preview was silently left behind on disk.
        let previousPreviews = selfEditPreviews
        let previewsForSession = previousPreviews.contains { $0.sessionID == id }
        var updatedPreviews = previousPreviews
        if previewsForSession {
            do {
                updatedPreviews = try extensionPreviewStore.removePreviews(for: id, from: previousPreviews)
            } catch {
                setError("Could not delete the chat's pending self-edit preview: \(error.localizedDescription)", sessionID: id)
                return
            }
        }

        let previousSessions = sessions
        sessions.removeAll { $0.id == id }
        selfEditPreviews = updatedPreviews
        guard persist() == .saved else {
            sessions = previousSessions
            selfEditPreviews = previousPreviews
            if previewsForSession {
                do {
                    try extensionPreviewStore.save(previousPreviews)
                } catch {
                    setError("The chat was kept, but its pending self-edit preview could not be restored: \(error.localizedDescription)", sessionID: id)
                }
            }
            refreshSearchIndexForLoadedSessions()
            return
        }
        if let edit = editingMessageContext, edit.sessionID == id {
            cancelEditingMessage()
        }
        threadActivityLanes.remove(id)
        submittedRequests[id] = nil
        retryableRequests[id] = nil
        providerSessionHealth[id] = nil
        checkpointReviewStates[id] = nil
        clearConversationScrollState(for: id)
        selectedSessionID = LatticeSessionListOrdering.sorted(sessions).first?.id
    }

    func togglePinnedSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let previousSession = sessions[index]
        sessions[index].isPinned.toggle()
        sessions[index].lastUpdated = .now
        if persist() != .saved {
            sessions[index] = previousSession
        }
    }

    func requestDeleteSelectedSession() {
        guard let id = selectedSessionID else { return }
        requestDeleteSession(id)
    }

    func requestDeleteSession(_ id: UUID) {
        guard sessions.first(where: { $0.id == id })?.isStreaming != true else { return }
        pendingDeleteSessionID = id
        showDeleteChatConfirmation = true
    }

}

/// Bridges cooperative cancel into `Task.detached` work that does not inherit Task cancellation.
final class WorkLoopCancelToken: @unchecked Sendable {
    let lock = NSLock()
    var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}
