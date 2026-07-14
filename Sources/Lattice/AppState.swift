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

private struct PreparedSubmission {
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
            if selectedSessionID != nil {
                isTransientNewChat = false
                composerSelectionMode = selectedSession?.executionRoute.mode
                composerSelectionBackend = selectedSession?.backend
            } else {
                composerSelectionMode = nil
                composerSelectionBackend = nil
            }
            applyComposerSessionSelection(from: oldValue, to: selectedSessionID)
        }
    }
    @Published var sessions: [LatticeSession]
    /// Shared composer text bound by workspace and overlay. Ordinary text syncs to the selected session's durable `draft`; edit text does not.
    @Published var draft = "" {
        didSet {
            syncOrdinaryDraftToSelectedSessionIfNeeded()
        }
    }
    @Published var searchText = ""
    @Published var showInspector = false
    @Published var showCommandPalette = false
    @Published var showsOnboarding: Bool
    @Published var onboardingStep: LatticeOnboardingStep = .welcome
    @Published var commandPaletteSearch = ""
    @Published var commandPaletteSelectedID: String?
    /// Per-session measured conversation scroll anchors. Not published — geometry samples must not re-render the workspace.
    var conversationScrollStates: [UUID: ConversationScrollSessionState] = [:]
    /// Monotonic UI signal for successful sends, edits, continues, and queued follow-ups.
    @Published var conversationOutgoingActionSequence: [UUID: Int] = [:]
    /// Published only when pending new-content count / jump visibility changes — never per geometry sample.
    @Published private(set) var conversationJumpAffordances: [UUID: ConversationJumpAffordance] = [:]
    /// Shared UI command channel. User-driven binding updates stay quiet; explicit corrections
    /// notify once from ConversationView so normal scrolling does not re-render the workspace.
    var conversationScrollPosition = ScrollPosition(idType: String.self)
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
    @Published private(set) var pendingUnsafeProviderRouteAcknowledgement: UnsafeProviderRouteAcknowledgement?
    @Published var editingMessageContext: MessageEditContext?
    /// Composer draft present before the current edit began; restored when edit mode exits without a successful send.
    private var preservedComposerDraftBeforeEdit: String = ""
    @Published var copiedMessageID: UUID?
    @Published var defaultBackend: ChatBackend
    @Published var ollamaModels: [OllamaModel] = []
    @Published var ollamaCatalogStatus: ProviderCatalogStatus = .unknown
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
    /// Last measured conversations workspace width; used only for split-column adaptation.
    private var lastMeasuredWorkspaceWidth: CGFloat = 0
    private let connectionRefreshGeneration = RefreshGenerationController()
    private let localModelRefreshGeneration = RefreshGenerationController()
    /// Visibility last written by adaptive layout; used to distinguish user-driven toggles.
    private var lastAutoAppliedColumnVisibility: NavigationSplitViewVisibility?
    /// When true, do not auto-change columns until the window is comfortably wide again.
    private var respectsUserColumnChoice = false
    @Published var selectedWorkspacePath: String
    /// New Chat setup lives in memory until first send. No placeholder session or route is persisted.
    @Published private(set) var isTransientNewChat = false
    @Published private(set) var composerSelectionMode: ConversationMode?
    @Published private(set) var composerSelectionBackend: ChatBackend?
    @Published var composerRoutePopoverPresented = false
    @Published var composerModelSearchText = ""
    @Published private(set) var codeInstructionAddOn: String
    @Published private(set) var workInstructionAddOn: String
    @Published private(set) var trustedWorkspacePaths: Set<String>
    @Published var installingModelTag: String?
    @Published var installStatus: String?
    @Published var showDeleteLocalModelConfirmation = false
    @Published var pendingDeleteLocalModelName: String?
    @Published private(set) var deletingLocalModelName: String?
    @Published var localModelIdleUnloadMinutes: Int
    @Published var localModelStatus: String?
    @Published var codexReady = false
    @Published var codexAuthenticated = false
    @Published var codexCatalogStatus: ProviderCatalogStatus = .unknown
    @Published private(set) var codexProtocolUnavailableReason: String?
    @Published var codexModels: [ProviderModel] = []
    @Published var codexUsage: ProviderUsage?
    @Published var codexCLIVersion: String?
    @Published var codexLatestCLIVersion: String?
    @Published var grokReady = false
    @Published var grokAuthenticated = false
    @Published var grokCatalogStatus: ProviderCatalogStatus = .unknown
    @Published var grokModels: [ProviderModel] = []
    var grokACPModels: [HarnessModel] = []
    @Published var grokCLIInfo = CLIUpdateInfo()
    @Published var openCodeReady = false
    @Published var openCodeAuthenticated = false
    @Published var openCodeCatalogStatus: ProviderCatalogStatus = .unknown
    @Published var openCodeModels: [ProviderModel] = []
    var openCodeACPModels: [HarnessModel] = []
    @Published var openCodeCLIVersion: String?
    @Published var openCodeLatestCLIVersion: String?
    @Published var openCodeAPIKeyDraft = ""
    @Published var openCodeAPIKeySaved = false
    @Published private(set) var openCodeCredentialEnabledModes: Set<ConversationMode> = []
    @Published private(set) var validatedPiCodexModels: Set<String> = []
    @Published private(set) var validatedPiOpenCodeModels: Set<String> = []
    @Published private(set) var validatedHermesOpenCodeModels: Set<String> = []
    @Published private(set) var validatedHermesProviders: Set<String> = []
    @Published var pendingRuntimeConfirmation: RuntimeConfirmationRequest?
    @Published private(set) var runtimeLifecycleStates: [LatticeRuntimeID: RuntimeLifecycleState] = [:]
    @Published private(set) var latticeManagedRuntimeIDs: Set<LatticeRuntimeID> = []
    @Published var disabledModelIDs: Set<String>
    @Published var expandedProviderModelIDs: Set<String> = []
    @Published var cliBusyProviders: Set<String> = []
    @Published var cliActionMessages: [String: String] = [:]
    @Published private(set) var isRefreshingConnections = false
    @Published var cliActionStartedAt: [String: Date] = [:]
    @Published var cliActionEstimatedSeconds: [String: TimeInterval] = [:]
    @Published var pendingCLIInstallProvider: String?
    @Published var antigravityInstalled = false
    @Published var antigravityAuthenticated = false
    @Published var antigravityModels: [ProviderModel] = []
    @Published var antigravityCLIVersion: String?
    @Published var antigravityLatestCLIVersion: String?
    @Published var piInstalled = false
    @Published var piCLIVersion: String?
    @Published var piLatestCLIVersion: String?
    @Published var piModelIDs: Set<String> = []
    @Published var hermesInstalled = false
    @Published var hermesCatalogStatus: ProviderCatalogStatus = .unknown
    @Published var hermesCLIInfo = CLIUpdateInfo()
    @Published var hermesModels: [HarnessModel] = []
    @Published var appleIntelligenceReady = false
    @Published var appleIntelligenceStatus = "Checking…"
    @Published var ollamaInstalled = false
    @Published var ollamaReady = false
    @Published var grokUpdateStatus = ""
    @Published var extensions: [LatticeExtensionRecord] = []
    @Published var skills: [LatticeSkillRecord] = []
    @Published var selfEditJobs: [LatticeExtensionJobRecord] = []
    @Published var selfEditPreviews: [LatticeExtensionPreviewRecord] = []
    @Published var expandedSelfEditSkillPreviewIDs: Set<String> = []
    @Published var expandedSelfEditReviewIDs: Set<UUID> = []
    @Published var editableSelfEditManifestDrafts: [UUID: EditableSelfEditManifestDraft] = [:]
    @Published var editableSelfEditSkillDrafts: [String: EditableSelfEditSkillDraft] = [:]
    @Published var editableSelfEditStylePatchDrafts: [String: EditableSelfEditStylePatchDraft] = [:]
    @Published var editableSelfEditLayoutPatchDrafts: [String: EditableSelfEditLayoutPatchDraft] = [:]
    @Published var editableSelfEditCopyPatchDrafts: [String: EditableSelfEditCopyPatchDraft] = [:]
    @Published var editableSelfEditPromptTemplateDrafts: [String: EditableSelfEditPromptTemplateDraft] = [:]
    @Published var editableSelfEditOperationPreviewDrafts: [String: EditableSelfEditOperationPreviewDraft] = [:]
    /// Durable store load failures that require explicit, non-destructive recovery before saves resume.
    @Published var persistenceRecoveryIssues: [DurableStoreIssue] = []
    @Published var expandedPersistenceRecoveryDetailIDs: Set<String> = []
    @Published var persistenceRecoveryStatusMessage: String?
    @Published var showPersistenceResetConfirmation = false
    @Published var pendingPersistenceResetIssueID: String?
    /// Runtime session *save* failure (disk full, permission, write failure). Separate from load recovery.
    /// In-memory sessions/draft remain; Retry writes the latest snapshot. No reset/quarantine of readable data.
    @Published var sessionSaveFailure: SessionSaveFailure?
    @Published var expandedSessionSaveFailureDetails = false
    @Published var enabledExtensionIDs: Set<String>
    @Published var disabledSkillIDs: Set<String>
    @Published var activeStylePatches: [LatticeStylePatch] = []
    @Published var activeLayoutPatches: [LatticeLayoutPatch] = []
    @Published var activeCopyPatches: [LatticeCopyPatch] = []
    @Published var activePromptTemplates: [LatticePromptTemplate] = []
    @Published var selfMap = LatticeSelfMap()
    @Published var selectedRouteEngineID: String
    @Published var selectedRouteHarnessID: String
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
    private let executionCoordinator: any LatticeExecutionCoordinating
    private var runtimeInstallTasks: [LatticeRuntimeID: Task<Void, Never>] = [:]
    let appleIntelligence = AppleIntelligenceClient()
    let ollama = OllamaClient()
    let modelInstaller = OllamaModelInstaller()
    let extensionStore = LatticeExtensionStore()
    let skillStore = LatticeSkillStore()
    let extensionJobStore = LatticeExtensionJobStore()
    let extensionPreviewStore = LatticeExtensionPreviewStore()
    let policyEngine = DeterministicPolicyEngine()
    private let persistence = SessionPersistence()
    private let sessionSaveCoordinator: SessionSaveCoordinator
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var localModelIdleUnloadTask: Task<Void, Never>?
    private var extensionDirectorySource: DispatchSourceFileSystemObject?
    private var extensionDirectoryFileDescriptor: CInt = -1
    private var cancellables: Set<AnyCancellable> = []
    private var submittedRequests: [UUID: String] = [:]
    private var retryableRequests: [UUID: String] = [:]
    private var selfEditRunIDs: Set<UUID> = []
    private var activeRunIDs: [UUID: UUID] = [:]
    @Published private var runUIStates: [UUID: RunUIState] = [:]
    @Published private var globalErrorMessage: String?
    /// Deliberately in-memory: provider tool bypass consent expires when Lattice exits.
    private var acknowledgedUnsafeProviderRouteKeys: Set<String> = []
    /// Suppresses draft→session write-back while loading a session's draft into the composer.
    private var isApplyingComposerDraft = false
    private static let idleUnloadKey = "localModelIdleUnloadMinutes"
    private static let defaultBackendKey = "defaultBackend"
    private static let enabledExtensionIDsKey = "enabledExtensionIDs"
    private static let knownExtensionIDsKey = "knownExtensionIDs"
    private static let disabledSkillIDsKey = "disabledSkillIDs"
    private static let onboardingCompletedVersionKey = "onboardingCompletedVersion"
    private static let onboardingVersion = 1
    private static let codeInstructionAddOnKey = "codeInstructionAddOn"
    private static let workInstructionAddOnKey = "workInstructionAddOn"
    private static let trustedWorkspacePathsKey = "trustedWorkspacePaths"
    private static let openCodeCredentialModesKey = "openCodeCredentialEnabledModes"
    private static let managedRuntimeIDsKey = "latticeManagedRuntimeIDs"

    private var executionRuntimes: LatticeExecutionRuntimes {
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

    init(executionCoordinator: (any LatticeExecutionCoordinating)? = nil) {
        self.executionCoordinator = executionCoordinator ?? DefaultLatticeExecutionCoordinator()
        sessionSaveCoordinator = SessionSaveCoordinator(persistence: persistence)
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        LatticeApplicationSupport.migrateLegacyUserDefaultsIfNeeded()
        let processDirectory = FileManager.default.currentDirectoryPath
        let cwd = Self.defaultWorkspacePath(processDirectory: processDirectory)
        var recoveryIssues: [DurableStoreIssue] = []
        var loadedSessions: [LatticeSession] = []
        var migratedSessions = false
        var sessionStoreInRecovery = false

        switch persistence.loadResult() {
        case .missing:
            loadedSessions = []
        case .loaded(let decoded):
            loadedSessions = decoded
            for index in loadedSessions.indices where loadedSessions[index].workspacePath == "/" || (loadedSessions[index].workspacePath == NSHomeDirectory() && loadedSessions[index].messages.isEmpty) || (Self.isImplicitDeveloperWorkspace(loadedSessions[index].workspacePath) && loadedSessions[index].messages.isEmpty) {
                loadedSessions[index].workspacePath = cwd; migratedSessions = true
            }
            for index in loadedSessions.indices where loadedSessions[index].intent == nil && Self.isLegacySelfEditSession(loadedSessions[index]) {
                loadedSessions[index].intent = .selfEdit
                migratedSessions = true
            }
        case .failed(let issue):
            sessionStoreInRecovery = true
            recoveryIssues.append(issue)
            persistence.writeGate.block()
            loadedSessions = []
        }

        sessions = loadedSessions
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
        selectedRouteEngineID = Self.engineID(for: initialDefaultBackend)
        selectedRouteHarnessID = Self.defaultHarnessID(for: initialDefaultBackend)
        selectedSessionID = LatticeSessionListOrdering.sorted(sessions).first?.id
        composerSelectionMode = selectedSession?.executionRoute.mode
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
            extensionJobStore.writeGate.block()
            selfEditJobs = []
        }
        switch extensionPreviewStore.loadResult() {
        case .missing:
            selfEditPreviews = []
        case .loaded(let records):
            selfEditPreviews = records
        case .failed(let issue):
            recoveryIssues.append(issue)
            extensionPreviewStore.writeGate.block()
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
        startExtensionMonitoring()
        startResourceMonitoring()
        Task { await refreshConnections() }
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

    private var navigableSessions: [LatticeSession] {
        LatticeSessionListOrdering.sorted(sessions.filter { $0.matchesSearch(searchText) })
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

    var editingMessageID: UUID? { editingMessageContext?.messageID }

    var activeBackend: ChatBackend { selectedSession?.backend ?? composerSelectionBackend ?? defaultBackend }
    var activePrivacyMode: SessionPrivacyMode { selectedSession?.privacyMode ?? privacyMode }
    var activeHarnessID: String { selectedSession.map(effectiveHarnessID(for:)) ?? selectedRouteHarnessID }
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
            .filter { isRouteHarnessCompatible(engineID: engineID, harnessID: $0) }
            .compactMap { harnessID in
                let title: String
                switch harnessID {
                case "codex": title = "Codex"
                case "opencode": title = "OpenCode"
                case "grok": title = "Grok"
                case "antigravity": title = "Antigravity"
                case "pi": title = "Pi"
                case "hermes": title = "Hermes"
                default: title = "Lattice"
                }
                return ExecutionRouteOption(engineID: engineID, harnessID: harnessID, title: title)
            }
    }
    var activeReasoningOptions: [ReasoningOption] { reasoningOptions(for: activeBackend, harnessID: activeHarnessID) }
    var activeReasoningEffort: ReasoningEffort? { selectedSession?.reasoningEffort ?? defaultReasoning(for: activeBackend, harnessID: activeHarnessID) }
    var isSelectedSessionRouteLocked: Bool {
        selectedSession?.messages.contains(where: { $0.role == .user }) == true
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

        func append(providerID: String, providerTitle: String, modelID: String, title: String) {
            guard let backend = backend(for: providerID, modelID: modelID),
                  let route = ExecutionRouteResolver.resolve(mode: mode, providerID: providerID, modelID: modelID) else { return }
            let reason = isModelEnabled(backend.id) ? composerUnavailableReason(for: backend, route: route) : "Hidden in Connections"
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
            for identifier in piModelIDs.sorted() where identifier.hasPrefix("opencode-go/") || identifier.hasPrefix("opencode-zen/") {
                append(providerID: "opencode", providerTitle: "OpenCode", modelID: identifier, title: identifier.split(separator: "/", maxSplits: 1).last.map(String.init) ?? identifier)
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
        guard !sessions[index].messages.contains(where: { $0.role == .user }) else { return }
        sessions[index].backend = backend
        sessions[index].executionRoute = option.route
        sessions[index].harnessID = option.route.runtimeID
        sessions[index].reasoningEffort = defaultReasoning(for: backend, harnessID: option.route.runtimeID)
        sessions[index].harnessThreadID = nil
        composerSelectionMode = option.route.mode
        composerSelectionBackend = backend
        persist()
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
            readyDetail: "Ready · ACP"
        )
    }
    var openCodeReadinessCopy: ProviderReadinessCopy {
        ProviderReadinessPresentationPolicy.copy(
            providerName: "OpenCode",
            readiness: ProviderReadinessSnapshot(installed: openCode.isInstalled, authenticated: openCodeAuthenticated, catalogStatus: openCodeCatalogStatus, runnableModelCount: runnableOpenCodeModels.count),
            readyDetail: "Ready · ACP"
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
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return selectedSession?.isStreaming == true
                ? "Type a follow-up to queue"
                : "Type a message to send"
        }
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
    var canContinueSelectedSession: Bool {
        guard editingMessageID == nil,
              let session = selectedSession,
              LatticeContinuationPolicy.canContinue(session) else { return false }
        return canRunSession(session)
    }
    var canRetrySelectedSession: Bool {
        guard let session = selectedSession, !session.isStreaming, retryableRequests[session.id] != nil else { return false }
        return canRunSession(session)
    }
    func retrySelectedSession() {
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isStreaming,
              let request = retryableRequests[id] else { return }
        guard canRunSession(sessions[index]) else {
            setError(routeUnavailableMessage(for: sessions[index]) ?? "Choose a connected model.", sessionID: id)
            return
        }
        sessions[index].messages.append(.init(role: .assistant, text: ""))
        submittedRequests[id] = request
        retryableRequests[id] = nil
        startRun(for: id, at: index, submittedText: request)
    }
    var canDeleteSelectedSession: Bool {
        guard let session = selectedSession else { return false }
        return !session.isStreaming
    }
    var activeRouteStatusText: String? {
        guard let session = selectedSession, !session.isStreaming else { return nil }
        return routeUnavailableMessage(for: session)
    }
    func visibleErrorMessage(for sessionID: UUID) -> String? {
        runUIStates[sessionID]?.errorMessage ?? globalErrorMessage
    }
    func visibleActivity(for sessionID: UUID) -> [ActivityItem] {
        runUIStates[sessionID]?.activity ?? []
    }
    func visibleComposerState(for sessionID: UUID) -> MorphingControlState {
        runUIStates[sessionID]?.composerState ?? .expanded
    }
    func setVisibleComposerState(_ state: MorphingControlState, for sessionID: UUID?) {
        guard let sessionID else { return }
        reduceRunUI(.setComposerState(state), for: sessionID)
    }

    private var selectedRunUIState: RunUIState? {
        selectedSessionID.flatMap { runUIStates[$0] }
    }

    private func updateSelectedRunUI(_ update: (inout RunUIState) -> Void) {
        guard let sessionID = selectedSessionID else { return }
        var state = runUIStates[sessionID] ?? RunUIState()
        update(&state)
        runUIStates[sessionID] = state
    }

    private func reduceRunUI(_ action: RunUIAction, for sessionID: UUID) {
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
    private func ordinaryComposerDraft(for session: LatticeSession) -> String {
        if session.id == selectedSessionID {
            if editingMessageContext != nil {
                return preservedComposerDraftBeforeEdit
            }
            return draft
        }
        return session.draft
    }

    private func contextTokenLimit(for session: LatticeSession) -> Int {
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
                    in: self.commandPaletteItems
                )
                self.showCommandPalette = true
            }
        }
    }

    private func prepareCommandPalettePresentation() {
        commandPaletteSearch = ""
        commandPaletteSelectedID = LatticeCommandPaletteSelection.clampedSelection(
            selectedID: nil,
            in: commandPaletteItems
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
            .init(id: "refresh-connections", title: "Refresh Connections", detail: "Refresh provider readiness and model catalogs", keywords: ["models", "providers", "sync"]),
            .init(id: "open-extensions-folder", title: "Open Extensions Folder", detail: "Show the user-owned Lattice modification layer", keywords: ["self edit", "customization", "application support"]),
            .init(id: "open-skills-folder", title: "Open Skills Folder", detail: "Show Lattice’s shared SKILL.md folder for imported and generated skills", keywords: ["skills", "skill.md", "agents", "customization", "application support"]),
            .init(id: "policy-ask", title: "Set Policy: Ask", detail: "Ask before material changes and external control", keywords: ["permission", "safe", "approval"]),
            .init(id: "policy-smart", title: "Set Policy: Smart", detail: "Allow clearly safe scoped work and ask on risk", keywords: ["permission", "approval", "automatic"]),
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
        LatticeCommandPaletteMatcher.filtered(commandPaletteItems, query: commandPaletteSearch)
    }

    func performFirstCommandPaletteMatch() {
        guard let item = LatticeCommandPaletteMatcher.firstEnabled(in: commandPaletteItems, query: commandPaletteSearch) else { return }
        performCommandPaletteItem(item.id)
    }

    func performCommandPaletteItem(_ id: String) {
        // Closing first means a second submit/click in the same event cycle is a no-op.
        guard showCommandPalette else { return }
        guard commandPaletteItems.first(where: { $0.id == id })?.isEnabled == true else { return }
        closeCommandPalette()
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
            Task { await refreshConnections(refreshProviderCatalogs: true) }
        case "open-extensions-folder":
            openExtensionsFolder()
        case "open-skills-folder":
            openSkillsFolder()
        case "policy-ask":
            setSessionPolicy(.ask)
        case "policy-smart":
            setSessionPolicy(.smart)
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
        if enabled { disabledModelIDs.remove(id) } else { disabledModelIDs.insert(id) }
        UserDefaults.standard.set(Array(disabledModelIDs).sorted(), forKey: "disabledModelIDs")
        normalizeBackendsAfterCatalogRefresh()
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
        let harnessID = Self.defaultHarnessID(for: backend)
        let source = selectedSession
        let session = LatticeSession(
            title: "New local chat",
            backend: backend,
            harnessID: harnessID,
            reasoningEffort: defaultReasoning(for: backend, harnessID: harnessID),
            workspacePath: source?.workspacePath ?? selectedWorkspacePath,
            policy: source?.policy ?? policy,
            privacyMode: .localOnly
        )
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        selectedSection = .conversations
        clearError()
        persist()
    }

    func useBackendInChat(_ backend: ChatBackend) {
        guard canUseBackendInNewChat(backend) else {
            let message = backendUnavailableMessage(for: backend) ?? "Choose a connected model."
            setError(message, sessionID: selectedSessionID)
            return
        }
        let canReuseSelectedChat = selectedSessionID.flatMap { id in
            sessions.first(where: { $0.id == id }).map { session in
                !session.isStreaming && !session.messages.contains(where: { $0.role == .user })
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
        let harnessID = Self.defaultHarnessID(for: backend)
        let session = LatticeSession(
            title: "New chat",
            backend: backend,
            harnessID: harnessID,
            reasoningEffort: defaultReasoning(for: backend, harnessID: harnessID),
            workspacePath: source?.workspacePath ?? selectedWorkspacePath,
            policy: source?.policy ?? policy,
            privacyMode: source?.privacyMode ?? activePrivacyMode
        )
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        selectedSection = .conversations
        clearError()
        persist()
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
        if let edit = editingMessageContext, edit.sessionID == id {
            cancelEditingMessage()
        }
        if let updated = try? extensionPreviewStore.removePreviews(for: id, from: selfEditPreviews) {
            selfEditPreviews = updated
        }
        sessions.removeAll { $0.id == id }
        submittedRequests[id] = nil
        retryableRequests[id] = nil
        clearConversationScrollState(for: id)
        selectedSessionID = LatticeSessionListOrdering.sorted(sessions).first?.id
        persist()
    }

    func togglePinnedSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[index].isPinned.toggle()
        sessions[index].lastUpdated = .now
        persist()
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
              let session = sessions.first(where: { $0.id == id }) else {
            cancelExportChatSheet()
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
            selectedSessionID = previousSelected
            presentImportError("Chat store recovery is active, so import was cancelled. Existing chats were not changed.")
        case .failed(let failure), .coalescedFailure(let failure):
            sessions = previousSessions
            selectedSessionID = previousSelected
            sessionSaveFailure = failure
            presentImportError("Could not save the imported chat (\(failure.kind.displayName)). Existing chats were not changed. \(failure.summary)")
        }
    }

    private func presentImportError(_ message: String) {
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

    private func resetAllConversationScrollState() {
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
            // Capture text first, then clear/persist only this chat's ordinary draft.
            draft = ComposerSessionDraftTransition.clearingOrdinaryDraft()
            queueFollowUp(text)
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

    private var appCommands: [LatticeAppCommand] {
        LatticeAppCommandCatalog.all + activeSkillCommands + activePromptTemplates.map(\.command)
    }

    private var activeSkillCommands: [LatticeAppCommand] {
        skills
            .filter { $0.isValid && isSkillEnabled($0) }
            .map(LatticeSkillPromptBuilder.command(for:))
    }

    private var effectiveDisabledSkillIDs: Set<String> {
        LatticeSkillActivationPolicy.effectiveDisabledSkillIDs(
            records: skills,
            disabledSkillIDs: disabledSkillIDs,
            enabledExtensionIDs: enabledExtensionIDs
        )
    }

    func send(_ text: String) {
        if handleSelfEditReviewDecision(text) { return }
        guard let submission = prepareSubmission(text) else { return }
        if selectedSessionID == nil {
            guard materializeTransientSession() else {
                setError("Choose a mode and model before sending.", sessionID: nil)
                return
            }
        }
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].isStreaming else { return }
        startPreparedSubmission(submission, for: id, at: index)
    }

    @discardableResult
    private func materializeTransientSession() -> Bool {
        guard isTransientNewChat,
              let mode = composerSelectionMode,
              let backend = composerSelectionBackend,
              let route = ExecutionRouteResolver.resolve(mode: mode, backend: backend),
              composerUnavailableReason(for: backend, route: route) == nil else { return false }
        let session = LatticeSession(
            title: "New chat",
            backend: backend,
            executionRoute: route,
            harnessID: route.runtimeID,
            reasoningEffort: defaultReasoning(for: backend, harnessID: route.runtimeID),
            workspacePath: selectedWorkspacePath,
            policy: policy,
            privacyMode: activePrivacyMode,
            draft: draft
        )
        sessions.insert(session, at: 0)
        isTransientNewChat = false
        selectedSessionID = session.id
        selectedSection = .conversations
        clearError()
        persist()
        return true
    }

    @discardableResult
    private func handleSelfEditReviewDecision(_ text: String) -> Bool {
        guard let decision = LatticeSelfEditReviewDecision.parse(text),
              let sessionID = selectedSessionID,
              let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }),
              !sessions[sessionIndex].isStreaming,
              let preview = visibleSelfEditPreviews(for: sessionID).first else { return false }
        markConversationOutgoingAction(for: sessionID)
        sessions[sessionIndex].messages.append(.init(role: .user, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
        sessions[sessionIndex].lastUpdated = .now
        persist()
        switch decision {
        case .accept:
            acceptSelfEditPreview(preview)
        case .discard:
            discardSelfEditPreview(preview)
        }
        return true
    }

    func continueSelectedResponse() {
        guard let session = selectedSession,
              LatticeContinuationPolicy.canContinue(session) else { return }
        guard canRunSession(session) else {
            setError(routeUnavailableMessage(for: session) ?? "Choose a connected model.", sessionID: session.id)
            composerState = .expanded
            overlayControlState = .expanded
            return
        }
        send(LatticeContinuationPolicy.prompt)
    }

    @discardableResult
    private func startPreparedSubmission(_ submission: PreparedSubmission, for id: UUID, at index: Int) -> Bool {
        normalizeSessionBackendBeforeRun(at: index)
        guard canRunSession(sessions[index]) else {
            setError(routeUnavailableMessage(for: sessions[index]) ?? "Choose a connected model.", sessionID: id)
            composerState = .expanded
            overlayControlState = .expanded
            return false
        }
        guard ensureUnsafeProviderRouteAcknowledged(for: sessions[index]) else { return false }
        markConversationOutgoingAction(for: id)
        if submission.startsSelfEdit {
            sessions[index].intent = .selfEdit
            if sessions[index].title == "New chat" { sessions[index].title = Self.selfEditTitle(for: submission.userText) }
        } else if sessions[index].title == "New chat" {
            sessions[index].title = String(submission.userText.prefix(48))
        }
        sessions[index].messages.append(.init(role: .user, text: submission.userText))
        sessions[index].messages.append(.init(role: .assistant, text: ""))
        submittedRequests[id] = submission.runText
        retryableRequests[id] = nil
        startRun(for: id, at: index, submittedText: submission.runText)
        return true
    }

    private func sendEditedDraft(_ text: String) {
        guard let edit = editingMessageContext,
              let id = selectedSessionID,
              edit.belongs(to: id),
              let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isStreaming,
              let messageIndex = sessions[index].messages.firstIndex(where: { $0.id == edit.messageID && $0.role == .user }) else { return }
        guard let submission = prepareSubmission(text) else { return }
        normalizeSessionBackendBeforeRun(at: index)
        guard canRunSession(sessions[index]) else {
            setError("Choose a connected model.", sessionID: id)
            composerState = .expanded
            overlayControlState = .expanded
            return
        }
        guard ensureUnsafeProviderRouteAcknowledged(for: sessions[index]) else { return }
        markConversationOutgoingAction(for: id)
        sessions[index].messages[messageIndex].text = submission.userText
        sessions[index].messages.removeSubrange(sessions[index].messages.index(after: messageIndex)..<sessions[index].messages.endIndex)
        let survivingMessageIDs = Set(sessions[index].messages.map(\.id))
        SessionActionTrail.prune(in: &sessions[index].actions, keepingMessageIDs: survivingMessageIDs)
        sessions[index].messages.append(.init(role: .assistant, text: ""))
        sessions[index].harnessThreadID = nil
        sessions[index].lastUpdated = .now
        if submission.startsSelfEdit {
            sessions[index].intent = .selfEdit
        } else if messageIndex == sessions[index].messages.startIndex {
            sessions[index].intent = nil
        }
        if messageIndex == sessions[index].messages.startIndex {
            sessions[index].title = sessions[index].intent == .selfEdit ? Self.selfEditTitle(for: submission.userText) : String(submission.userText.prefix(48))
        }
        let existing = MessageEditDraftState(context: edit, preservedComposerDraft: preservedComposerDraftBeforeEdit)
        // Clear edit mode first, then restore the pre-edit ordinary draft (still unsent).
        editingMessageContext = nil
        preservedComposerDraftBeforeEdit = ""
        draft = MessageEditDraftState.complete(existing)
        submittedRequests[id] = submission.runText
        retryableRequests[id] = nil
        startRun(for: id, at: index, submittedText: submission.runText)
    }

    private func queueFollowUp(_ text: String) {
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              sessions[index].isStreaming else { return }
        sessions[index].queuedFollowUps.append(.init(text: text))
        sessions[index].lastUpdated = .now
        clearError()
        persist()
    }

    private func markConversationOutgoingAction(for sessionID: UUID) {
        conversationOutgoingActionSequence[sessionID, default: 0] += 1
    }

    func removeQueuedFollowUp(_ queuedID: UUID) {
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              let queuedIndex = sessions[index].queuedFollowUps.firstIndex(where: { $0.id == queuedID }) else { return }
        sessions[index].queuedFollowUps.remove(at: queuedIndex)
        sessions[index].lastUpdated = .now
        persist()
    }

    func sendQueuedFollowUp(_ queuedID: UUID) {
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isStreaming,
              let queuedIndex = sessions[index].queuedFollowUps.firstIndex(where: { $0.id == queuedID }) else { return }
        let followUp = sessions[index].queuedFollowUps.remove(at: queuedIndex)
        guard let submission = prepareSubmission(followUp.text) else {
            sessions[index].lastUpdated = .now
            persist()
            return
        }
        if !startPreparedSubmission(submission, for: id, at: index) {
            if let refreshedIndex = sessions.firstIndex(where: { $0.id == id }) {
                sessions[refreshedIndex].queuedFollowUps.insert(followUp, at: min(queuedIndex, sessions[refreshedIndex].queuedFollowUps.count))
                sessions[refreshedIndex].lastUpdated = .now
                persist()
            }
        }
    }

    @discardableResult
    private func runNextQueuedFollowUpIfPossible(for id: UUID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }),
              !sessions[index].isStreaming,
              let followUp = sessions[index].queuedFollowUps.first else { return false }
        sessions[index].queuedFollowUps.removeFirst()
        guard let submission = prepareSubmission(followUp.text) else {
            sessions[index].lastUpdated = .now
            persist()
            return runNextQueuedFollowUpIfPossible(for: id)
        }
        if startPreparedSubmission(submission, for: id, at: index) {
            return true
        }
        if let refreshedIndex = sessions.firstIndex(where: { $0.id == id }) {
            sessions[refreshedIndex].queuedFollowUps.insert(followUp, at: 0)
            sessions[refreshedIndex].lastUpdated = .now
            persist()
        }
        return false
    }

    private func workspaceInstructionsAreTrusted(for workspace: URL) -> Bool {
        guard let canonical = try? HarnessSandbox.canonicalDirectory(workspace).path else { return false }
        return trustedWorkspacePaths.contains(canonical)
    }

    private func appliedInstructionFileNames(for workspace: URL, trusted: Bool) -> [String] {
        guard trusted else { return [] }
        return LatticeInstructionEnvelope.documentedWorkspaceInstructionNames.filter { name in
            let url = workspace.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    }

    private func instructionEnvelope(for session: LatticeSession, workspace: URL, allowFileModification: Bool) throws -> LatticeInstructionEnvelope {
        let trusted = workspaceInstructionsAreTrusted(for: workspace)
        return try .default(
            mode: session.executionRoute.mode,
            workspace: workspace,
            allowFileModification: allowFileModification,
            workspaceInstructionsTrusted: trusted,
            trustedWorkspaceInstructionNames: appliedInstructionFileNames(for: workspace, trusted: trusted),
            codeUserAddOn: codeInstructionAddOn,
            workUserAddOn: workInstructionAddOn
        )
    }

    private func trustedWorkspaceInstructionText(for workspace: URL, names: [String]) -> String {
        let maximumBytesPerFile = 32 * 1024
        return names.compactMap { name -> String? in
            let url = workspace.appendingPathComponent(name)
            guard WorkspacePathScope.isScoped(url.path, under: workspace),
                  let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maximumBytesPerFile + 1),
                  data.count <= maximumBytesPerFile,
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return "Trusted workspace instruction " + name + ":\n" + text
        }.joined(separator: "\n\n")
    }

    private func hermesProvider(for route: ExecutionRoute) -> String? {
        guard route.mode == .work, route.runtimeID == "hermes", let model = route.modelID,
              let separator = model.firstIndex(of: ":") else { return nil }
        let provider = String(model[..<separator]).lowercased()
        let allowed: Set<String>
        switch route.providerID {
        case "codex": allowed = [LatticeHermesProvider.openAICodex.rawValue]
        case "grok": allowed = [LatticeHermesProvider.xAIOAuth.rawValue, LatticeHermesProvider.xAI.rawValue]
        case "opencode": allowed = [LatticeHermesProvider.openCodeGo.rawValue, LatticeHermesProvider.openCodeZen.rawValue]
        default: return nil
        }
        return allowed.contains(provider) ? provider : nil
    }

    private func startRun(for id: UUID, at index: Int, submittedText: String) {
        // Defense in depth: every provider stream launch stays behind the same
        // acknowledgement check, even if a future caller skips send validation.
        guard ensureUnsafeProviderRouteAcknowledged(for: sessions[index]) else {
            sessions[index].isStreaming = false
            setError("Provider route blocked until its unsafe-route acknowledgement is accepted.", sessionID: id)
            return
        }
        sessions[index].isStreaming = true
        sessions[index].lastUpdated = .now
        globalErrorMessage = nil
        reduceRunUI(.started, for: id)
        persist()

        let session = sessions[index]
        let isExtensionSelfEdit = isExtensionSelfEditThread(session, submittedText: submittedText)
        if isExtensionSelfEdit { selfEditRunIDs.insert(id) }
        else { selfEditRunIDs.remove(id) }
        let workspace = workspaceURL(for: session, isExtensionSelfEdit: isExtensionSelfEdit)
        let reasoningEffort = validReasoningEffort(for: session)
        let additionalContext = backendAdditionalContext(for: session, submittedText: submittedText)
        let tokenLimit = contextTokenLimit(for: session)
        let stream: AsyncStream<AgentEvent>
        let harnessID = effectiveHarnessID(for: session)
        let usesPromptDrivenBackend: Bool = {
            if harnessID == "pi" || harnessID == "hermes" { return true }
            switch session.backend {
            case .codex, .grok, .openCode:
                return true
            case .appleIntelligence, .ollama:
                return false
            case .antigravity:
                return false
            }
        }()
        let contextPlan = LatticeContextHandoffPlanner.plan(
            session: session,
            submittedText: submittedText,
            additionalContext: additionalContext,
            tokenLimit: tokenLimit,
            existingHarnessThreadID: usesPromptDrivenBackend ? session.harnessThreadID : "structured-message-list",
            managementMode: usesPromptDrivenBackend ? .providerManagedSession : .latticeManagedVisibleTranscript
        )
        let supportsACPRecovery = ["grok", "opencode", "hermes"].contains(harnessID)
        let hasPersistedACPSession = supportsACPRecovery && session.harnessThreadID != nil
        let recoveryPlan = hasPersistedACPSession
            ? LatticeContextHandoffPlanner.plan(
                session: session,
                submittedText: submittedText,
                additionalContext: additionalContext,
                tokenLimit: tokenLimit,
                existingHarnessThreadID: nil,
                managementMode: .providerManagedSession
            )
            : contextPlan
        let recoveryPrompt = hasPersistedACPSession ? recoveryPlan.prompt : nil
        let recoveryUsesVisibleTranscriptHandoff = hasPersistedACPSession && recoveryPlan.usesVisibleTranscriptHandoff
        let recoveryDeliveryIssue = hasPersistedACPSession ? recoveryPlan.deliveryIssue : nil
        let prompt = contextPlan.prompt
        let routeThreadID: String? = contextPlan.resetsHarnessSession ? nil : session.harnessThreadID
        if contextPlan.resetsHarnessSession {
            sessions[index].harnessThreadID = nil
            persist()
        }
        if let statusDetail = contextPlan.statusDetail {
            setActivity([.init(icon: contextPlan.didCompact ? "arrow.triangle.2.circlepath" : "doc.text.magnifyingglass", title: contextPlan.didCompact ? "Context compacted" : "Context handoff", detail: statusDetail)], sessionID: id)
        }
        if let deliveryIssue = contextPlan.deliveryIssue {
            let runID = UUID()
            activeRunIDs[id] = runID
            let failedStream = AsyncStream<AgentEvent> { continuation in
                continuation.yield(.failed(deliveryIssue))
                continuation.finish()
            }
            Task { for await event in failedStream { apply(event, to: id, runID: runID) } }
            return
        }
        let envelope = try? instructionEnvelope(for: session, workspace: workspace, allowFileModification: !isExtensionSelfEdit)
        let trustedInstructions = envelope.map {
            trustedWorkspaceInstructionText(for: workspace, names: $0.trustedWorkspaceInstructionNames)
        } ?? ""
        let developerInstructions = envelope.map {
            [$0.renderedSystemInstructions, trustedInstructions].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        let openCodeAPIKey = OpenCodeCredentialPolicy.allowsKeychainCredential(
            for: session.executionRoute,
            enabledModes: openCodeCredentialEnabledModes
        )
            ? KeychainStore.read(account: OpenCodeCredentialPolicy.keychainAccount)
            : nil
        let appleTranscript: String? = session.backend == .appleIntelligence
            ? LatticeBackendMessageBuilder.transcript(session: session, submittedText: submittedText, additionalContext: additionalContext, contextPlan: contextPlan)
            : nil
        let ollamaMessages: [ChatMessage]? = {
            guard case .ollama(let model) = session.backend else { return nil }
            cancelLocalModelIdleUnload()
            localModelStatus = "Loaded \(model)"
            return LatticeBackendMessageBuilder.structuredMessages(session: session, submittedText: submittedText, additionalContext: additionalContext, contextPlan: contextPlan)
        }()
        stream = executionCoordinator.stream(
            LatticeExecutionLaunch(
                sessionID: id,
                route: session.executionRoute,
                legacyHarnessID: harnessID,
                backend: session.backend,
                prompt: prompt,
                threadID: routeThreadID,
                workspace: workspace,
                reasoningEffort: reasoningEffort,
                policy: isExtensionSelfEdit ? .ask : session.policy,
                allowFileModification: !isExtensionSelfEdit,
                workspaceWrite: isExtensionSelfEdit ? SelfEditProviderLaunchPolicy.codexWorkspaceWrite : false,
                recoveryPrompt: recoveryPrompt,
                recoveryUsesVisibleTranscriptHandoff: recoveryUsesVisibleTranscriptHandoff,
                recoveryDeliveryIssue: recoveryDeliveryIssue,
                instructionEnvelope: envelope,
                developerInstructions: developerInstructions,
                hermesProvider: hermesProvider(for: session.executionRoute),
                hermesSystemIdentity: developerInstructions,
                openCodeAPIKey: openCodeAPIKey,
                appleTranscript: appleTranscript,
                ollamaMessages: ollamaMessages,
                localModelKeepAliveSeconds: localModelIdleUnloadMinutes * 60
            ),
            runtimes: executionRuntimes
        )
        let runID = UUID()
        activeRunIDs[id] = runID
        Task { for await event in stream { apply(event, to: id, runID: runID) } }
    }

    private func normalizeSessionBackendBeforeRun(at index: Int) {
        guard !sessions[index].messages.contains(where: { $0.role == .user }) else { return }
        // New mode routes are explicit user choices. Never normalize them back
        // through the legacy backend selector or switch their runtime implicitly.
        if ExecutionRouteResolver.isDeclared(sessions[index].executionRoute) { return }
        let backend = sessions[index].backend
        let valid = validBackend(backend, privacyMode: sessions[index].privacyMode)
        guard valid != backend else { return }
        sessions[index].backend = valid
        sessions[index].harnessID = Self.defaultHarnessID(for: valid)
        sessions[index].reasoningEffort = defaultReasoning(for: valid, harnessID: sessions[index].harnessID)
        sessions[index].harnessThreadID = nil
        defaultBackend = valid
        saveDefaultBackend()
        syncExecutionRoute(from: valid)
    }

    private func canRunSession(_ session: LatticeSession) -> Bool {
        if ExecutionRouteResolver.isDeclared(session.executionRoute) {
            if session.privacyMode == .localOnly && session.executionRoute.mode != .local { return false }
            return canRunDeclaredRoute(session.executionRoute)
        }
        let harnessID = effectiveHarnessID(for: session)
        let routeLocked = session.messages.contains(where: { $0.role == .user }) || session.harnessThreadID != nil
        if session.privacyMode == .localOnly && !session.backend.isLocal && routeLocked {
            return false
        }
        if routeLocked {
            return canContinueLockedRoute(session.backend, harnessID: harnessID)
        }
        return canRunBackend(validBackend(session.backend, privacyMode: session.privacyMode), harnessID: harnessID)
    }

    private func canRunDeclaredRoute(_ route: ExecutionRoute) -> Bool {
        routeReadiness(for: route).isRunnable
    }

    func routeReadiness(for route: ExecutionRoute) -> ExecutionRouteReadiness {
        guard ExecutionRouteResolver.isDeclared(route) else {
            return .failed("This route is available only for a legacy chat.")
        }

        let runtimePresent: Bool
        let authenticationValidated: Bool
        let modelValidated: Bool
        let sandboxAvailable: Bool

        switch (route.mode, route.providerID, route.runtimeID) {
        case (.code, "codex", "pi"), (.code, "opencode", "pi"):
            runtimePresent = piInstalled
            let providerModel = PiRPCHarness.providerModel(for: route)
            modelValidated = providerModel.map { piModelIDs.contains($0.provider + "/" + $0.model) } ?? false
            authenticationValidated = route.providerID == "codex"
                ? route.modelID.map { validatedPiCodexModels.contains($0) } ?? false
                : openCodeAPIKeySaved
                    && openCodeCredentialEnabledModes.contains(.code)
                    && (route.modelID.map { validatedPiOpenCodeModels.contains($0) } ?? false)
            sandboxAvailable = FileManager.default.isExecutableFile(atPath: HarnessSandbox.systemExecutableURL.path)
        case (.code, "grok", "grok"):
            runtimePresent = grok.isInstalled
            authenticationValidated = grokAuthenticated
            modelValidated = route.modelID.map { ACPHarness.bestMatch(for: $0, in: grokACPModels) != nil } ?? false
            sandboxAvailable = FileManager.default.isExecutableFile(atPath: HarnessSandbox.systemExecutableURL.path)
        case (.code, "antigravity", "antigravity"):
            runtimePresent = antigravityInstalled
            authenticationValidated = antigravityAuthenticated
            modelValidated = route.modelID.map { model in visibleAntigravityModels.contains(where: { $0.id == model }) } ?? false
            sandboxAvailable = FileManager.default.isExecutableFile(atPath: HarnessSandbox.systemExecutableURL.path)
        case (.work, _, "hermes"):
            runtimePresent = hermesInstalled
            let provider = hermesProvider(for: route)
            authenticationValidated = route.providerID == "opencode"
                ? openCodeAPIKeySaved
                    && openCodeCredentialEnabledModes.contains(.work)
                    && (route.modelID.map { validatedHermesOpenCodeModels.contains($0) } ?? false)
                : provider.map { validatedHermesProviders.contains($0) } ?? false
            modelValidated = route.modelID.map { HermesACPHarness.exactMatch(for: $0, in: hermesModels) != nil } ?? false
            sandboxAvailable = FileManager.default.isExecutableFile(atPath: HarnessSandbox.systemExecutableURL.path)
        case (.local, "apple", "lattice"):
            runtimePresent = appleIntelligenceReady
            authenticationValidated = true
            modelValidated = appleIntelligenceReady
            sandboxAvailable = true
        case (.local, "ollama", "lattice"):
            runtimePresent = ollamaReady
            authenticationValidated = true
            modelValidated = route.modelID.map { model in
                ollamaCatalogStatus == .loaded && ollamaModels.contains(where: { $0.name == model })
            } ?? false
            sandboxAvailable = true
        default:
            return .failed("The selected mode, provider, and runtime are incompatible.")
        }

        return RouteReadinessEvaluator.evaluate(
            route: route,
            requirements: RouteReadinessRequirements(
                runtimePresent: runtimePresent,
                authenticationValidated: authenticationValidated,
                modelValidated: modelValidated,
                sandboxAvailable: sandboxAvailable
            ),
            validating: cliBusyProviders.contains(route.runtimeID) || cliBusyProviders.contains("\(route.runtimeID)-\(route.providerID)")
        ).readiness
    }

    func modeReadiness(_ mode: ConversationMode, providerID: String) -> ExecutionRouteReadiness {
        let routes = composerModelOptions(for: mode)
            .filter { $0.route.providerID == providerID && $0.route.modelID != nil }
            .map(\.route)
        let states = routes.map(routeReadiness(for:))
        if states.contains(where: { $0.isRunnable }) { return .runnable }
        if let state = states.first { return state }

        switch (mode, providerID) {
        case (.code, "codex"), (.code, "opencode"):
            return piInstalled ? .authenticationRequired : .missingRuntime
        case (.work, _):
            return hermesInstalled ? .authenticationRequired : .missingRuntime
        case (.code, "grok"):
            return grok.isInstalled ? .authenticationRequired : .missingRuntime
        case (.code, "antigravity"):
            return antigravityInstalled ? .authenticationRequired : .missingRuntime
        default:
            return .failed("No compatible model was discovered.")
        }
    }

    private func canContinueLockedRoute(_ backend: ChatBackend, harnessID: String?) -> Bool {
        if harnessID == "pi" { return piInstalled && piRoute(for: backend) != nil }
        if harnessID == "hermes" { return hermesInstalled && hermesMatch(for: backend) != nil }
        switch backend {
        case .codex(let model):
            return codexReady && codexModels.contains(where: { $0.id == model })
        case .grok(let model):
            return grokReady && ACPHarness.bestMatch(for: model, in: grokACPModels) != nil
        case .openCode(let model):
            return openCodeReady && ACPHarness.bestMatch(for: model, in: openCodeACPModels) != nil
        case .appleIntelligence:
            return appleIntelligenceReady
        case .ollama(let model):
            return ollamaReady
                && ollamaCatalogStatus == .loaded
                && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ollamaModels.contains(where: { $0.name == model })
        case .antigravity(let model):
            return antigravityAuthenticated && visibleAntigravityModels.contains(where: { $0.id == model })
        }
    }

    func canUseBackendInNewChat(_ backend: ChatBackend) -> Bool {
        if !SessionPrivacyPolicy.allows(backend, in: activePrivacyMode) { return false }
        guard validBackend(backend, privacyMode: activePrivacyMode) == backend else { return false }
        return canRunBackend(backend, harnessID: Self.defaultHarnessID(for: backend))
    }

    private var antigravityReadinessDetail: String {
        guard antigravityInstalled else { return "Not installed" }
        guard antigravityAuthenticated else { return "Sign in required" }
        guard !antigravityModels.isEmpty else { return "No models reported" }
        return "Connected"
    }

    private func codeRouteReadinessDetail(providerID: String) -> String {
        switch providerID {
        case "codex":
            if !piInstalled { return "Set up the Pi Code runtime in Connections" }
            return piModelIDs.isEmpty ? "Pi did not report Codex models" : "No compatible Codex models reported"
        case "opencode":
            if !piInstalled { return "Set up the Pi Code runtime in Connections" }
            if !openCodeAPIKeySaved { return "Save an OpenCode key in Connections" }
            if !openCodeCredentialEnabledModes.contains(.code) { return "Enable the OpenCode key for Code" }
            return piModelIDs.isEmpty ? "Pi did not report OpenCode models" : "No compatible OpenCode models reported"
        case "grok": return grokReadinessCopy.detail
        case "antigravity": return antigravityReadinessDetail
        default: return "Route unavailable"
        }
    }

    private func workRouteReadinessDetail(providerID: String) -> String {
        guard hermesInstalled else { return "Set up the Hermes Work runtime in Connections" }
        switch hermesCatalogStatus {
        case .unknown: return "Hermes model catalog has not been checked"
        case .loading: return "Loading Hermes models"
        case .failed: return "Hermes model catalog unavailable"
        case .empty: return "Hermes reported no models"
        case .loaded: break
        }
        switch providerID {
        case "codex":
            guard validatedHermesProviders.contains(LatticeHermesProvider.openAICodex.rawValue) else { return "Validate Hermes Codex authentication" }
        case "grok":
            guard validatedHermesProviders.contains(LatticeHermesProvider.xAIOAuth.rawValue) else { return "Validate Hermes Grok authentication" }
        case "opencode":
            guard openCodeAPIKeySaved, openCodeCredentialEnabledModes.contains(.work) else { return "Enable the OpenCode key for Work" }
        default:
            return "Unsupported Work provider"
        }
        return "No compatible models reported for this Work provider"
    }

    private var ollamaReadinessDetail: String {
        guard ollamaInstalled else { return "Not installed" }
        guard ollamaReady else { return "Start Ollama" }
        switch ollamaCatalogStatus {
        case .unknown: return "Local model catalog not checked"
        case .loading: return "Loading local model catalog"
        case .failed: return "Local model catalog unavailable"
        case .empty, .loaded: return "No installed local models"
        }
    }

    private func backend(for providerID: String, modelID: String) -> ChatBackend? {
        switch providerID {
        case "codex": .codex(model: modelID)
        case "grok": .grok(model: modelID)
        case "opencode": .openCode(model: modelID)
        case "antigravity": .antigravity(model: modelID)
        case "ollama": .ollama(model: modelID)
        default: nil
        }
    }

    private func composerUnavailableReason(for backend: ChatBackend, route: ExecutionRoute) -> String? {
        if let blocked = SessionPrivacyPolicy.blockedMessage(for: backend, in: activePrivacyMode) {
            return blocked
        }
        guard validBackend(backend, privacyMode: activePrivacyMode) == backend else {
            return backendUnavailableMessage(for: backend) ?? "Unavailable"
        }
        let routeIsRunnable = ExecutionRouteResolver.isDeclared(route)
            ? canRunDeclaredRoute(route)
            : canRunBackend(backend, harnessID: route.runtimeID)
        guard routeIsRunnable else {
            return routeUnavailableMessage(for: LatticeSession(
                title: "New chat",
                backend: backend,
                executionRoute: route,
                harnessID: route.runtimeID,
                privacyMode: activePrivacyMode
            )) ?? "Unavailable"
        }
        return nil
    }

    func backendUnavailableMessage(for backend: ChatBackend) -> String? {
        if let message = SessionPrivacyPolicy.blockedMessage(for: backend, in: activePrivacyMode) {
            return message
        }
        if case .ollama(let model) = backend {
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose a local model." }
            if !ollamaInstalled { return "Ollama is not installed." }
            if !ollamaReady { return "Start Ollama before using this local model." }
            if ollamaCatalogStatus == .loading { return "Ollama is refreshing its local model catalog." }
            if ollamaCatalogStatus == .failed { return "Ollama's local model catalog is unavailable. Refresh Connections before continuing." }
        }
        if validBackend(backend, privacyMode: activePrivacyMode) != backend {
            switch backend {
            case .codex(let model):
                return visibleCodexModels.contains(where: { $0.id == model })
                    ? "Codex cannot run \(model) through the current connection."
                    : "Codex no longer exposes \(model), or it is hidden in Connections."
            case .grok(let model):
                return visibleGrokModels.contains(where: { $0.id == model })
                    ? "Grok cannot run \(model) through its current ACP connection."
                    : "Grok no longer exposes \(model), or it is hidden in Connections."
            case .openCode(let model):
                return visibleOpenCodeModels.contains(where: { $0.id == model })
                    ? "OpenCode cannot run \(model) through its current ACP connection."
                    : "OpenCode no longer exposes \(model), or it is hidden in Connections."
            case .ollama(let model):
                return "The local model \(model) is not installed."
            case .appleIntelligence:
                return appleIntelligenceStatus
            case .antigravity:
                return antigravityInstalled ? "Sign in to Antigravity and choose an available model." : "Install the Antigravity CLI first."
            }
        }
        if canRunBackend(backend, harnessID: Self.defaultHarnessID(for: backend)) {
            return nil
        }
        return routeUnavailableMessage(for: LatticeSession(title: "New chat", backend: backend, harnessID: Self.defaultHarnessID(for: backend), privacyMode: activePrivacyMode))
    }

    private func canRunBackend(_ backend: ChatBackend, harnessID: String? = nil) -> Bool {
        if harnessID == "pi" { return piInstalled && piRoute(for: backend) != nil }
        if harnessID == "hermes" { return hermesInstalled && hermesMatch(for: backend) != nil }
        switch backend {
        case .codex(let model):
            return codexReady && codexModels.contains(where: { $0.id == model })
        case .grok(let model):
            return grokReady && ACPHarness.bestMatch(for: model, in: grokACPModels) != nil
        case .openCode(let model):
            return openCodeReady && ACPHarness.bestMatch(for: model, in: openCodeACPModels) != nil
        case .appleIntelligence:
            return appleIntelligenceReady
        case .ollama(let model):
            return ollamaReady
                && ollamaCatalogStatus == .loaded
                && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && ollamaModels.contains(where: { $0.name == model })
        case .antigravity(let model):
            return antigravityAuthenticated && visibleAntigravityModels.contains(where: { $0.id == model })
        }
    }

    private func routeUnavailableMessage(for session: LatticeSession) -> String? {
        let harnessID = effectiveHarnessID(for: session)
        if let message = SessionPrivacyPolicy.blockedMessage(for: session.backend, in: session.privacyMode) {
            return message
        }
        if canRunSession(session) { return nil }
        if ExecutionRouteResolver.isDeclared(session.executionRoute) {
            switch session.executionRoute.runtimeID {
            case "pi":
                if !piInstalled { return "Set up the Pi Code runtime in Connections." }
                return "Pi authentication or exact model validation is required for this Code route."
            case "hermes":
                if !hermesInstalled { return "Set up the Hermes Work runtime in Connections." }
                return "Hermes authentication or exact model validation is required for this Work route."
            case "grok": return grokReadinessCopy.detail
            case "antigravity": return antigravityReadinessDetail
            case "lattice": break
            default: return "The selected runtime is unavailable."
            }
        }
        if harnessID == "pi" {
            return piInstalled ? "Pi cannot run this locked provider/model route." : "Pi is not installed."
        }
        if harnessID == "hermes" {
            return hermesInstalled ? "Hermes does not expose this locked model." : "Hermes is not installed."
        }
        switch session.backend {
        case .codex(let model):
            if !codex.isInstalled { return "Codex is not installed." }
            if !codexAuthenticated { return "Codex sign-in is required before this chat can continue." }
            if let codexProtocolUnavailableReason { return codexProtocolUnavailableReason }
            if !codexReady { return "Codex is not ready. Refresh Connections before continuing." }
            if codexModels.isEmpty { return "Codex has not reported a model catalog. Refresh Connections before continuing." }
            if !codexModels.contains(where: { $0.id == model }) {
                return "Codex no longer exposes \(model). Start a new chat to choose another model."
            }
        case .grok(let model):
            if !grok.isInstalled { return "Grok is not installed." }
            if !grokReady { return "Grok sign-in or ACP setup is required before this chat can continue." }
            if ACPHarness.bestMatch(for: model, in: grokACPModels) == nil {
                return "Grok no longer exposes \(model). Start a new chat to choose another model."
            }
        case .openCode(let model):
            if !openCodeACP.isInstalled { return "OpenCode is not installed." }
            if !openCodeReady { return "OpenCode sign-in or ACP setup is required before this chat can continue." }
            if ACPHarness.bestMatch(for: model, in: openCodeACPModels) == nil {
                return "OpenCode no longer exposes \(model). Start a new chat to choose another model."
            }
        case .appleIntelligence:
            return appleIntelligenceStatus
        case .ollama(let model):
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose a local model." }
            if !ollamaInstalled { return "Ollama is not installed." }
            if !ollamaReady { return "Start Ollama before this chat can continue." }
            if ollamaCatalogStatus == .loading { return "Ollama is refreshing its local model catalog." }
            if ollamaCatalogStatus == .failed { return "Ollama's local model catalog is unavailable. Refresh Connections before continuing." }
            if !ollamaModels.contains(where: { $0.name == model }) {
                return "The local model \(model) is not installed."
            }
        case .antigravity(let model):
            if !antigravityInstalled { return "Antigravity CLI is not installed." }
            if !antigravityAuthenticated { return "Sign in to Antigravity before this chat can continue." }
            if visibleAntigravityModels.isEmpty { return "Antigravity has not reported a model catalog. Refresh Connections before continuing." }
            if !visibleAntigravityModels.contains(where: { $0.id == model }) {
                return "Antigravity no longer exposes \(model). Start a new chat to choose another model."
            }
        }
        return "Choose a connected model."
    }

    private func ensureUnsafeProviderRouteAcknowledged(for session: LatticeSession) -> Bool {
        let engineID = Self.engineID(for: session.backend)
        let harnessID = effectiveHarnessID(for: session)
        guard ProviderRouteSafetyPolicy.requiresAcknowledgement(engineID: engineID, harnessID: harnessID) else {
            return true
        }
        let routeKey = ProviderRouteSafetyPolicy.routeKey(engineID: engineID, harnessID: harnessID)
        guard !acknowledgedUnsafeProviderRouteKeys.contains(routeKey) else { return true }
        let providerName: String
        switch harnessID {
        case "pi": providerName = "Pi"
        case "hermes": providerName = "Hermes"
        default: providerName = session.backend.harnessName
        }
        pendingUnsafeProviderRouteAcknowledgement = UnsafeProviderRouteAcknowledgement(
            id: routeKey,
            sessionID: session.id,
            routeKey: routeKey,
            providerName: providerName,
            modelName: session.backend.displayName,
            detail: ProviderRouteSafetyPolicy.acknowledgementDetail(providerName: providerName)
        )
        return false
    }

    func acknowledgeUnsafeProviderRoute() {
        guard let pending = pendingUnsafeProviderRouteAcknowledgement else { return }
        acknowledgedUnsafeProviderRouteKeys.insert(pending.routeKey)
        pendingUnsafeProviderRouteAcknowledgement = nil
    }

    func dismissUnsafeProviderRouteAcknowledgement() {
        pendingUnsafeProviderRouteAcknowledgement = nil
    }

    func stop() {
        guard let id = selectedSessionID else { return }
        stop(sessionID: id)
    }

    /// Cancel a specific session's run/harness by id without requiring it to be selected.
    func stop(sessionID id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        if let request = submittedRequests[id] { retryableRequests[id] = request }
        activeRunIDs[id] = nil
        finishPendingActions(status: .cancelled, at: index)
        sessions[index].isStreaming = false
        if sessions[index].messages.last?.role == .assistant, sessions[index].messages.last?.text.isEmpty == true {
            sessions[index].messages.removeLast()
        }
        reduceRunUI(.cancelled, for: id)
        harnessPermissionNotices[id] = nil
        persist()
        cancelHarnessProcess(for: session, sessionID: id)
    }

    private func cancelHarnessProcess(for session: LatticeSession, sessionID id: UUID) {
        executionCoordinator.cancel(
            sessionID: id,
            route: session.executionRoute,
            legacyHarnessID: effectiveHarnessID(for: session),
            backend: session.backend,
            runtimes: executionRuntimes
        )
    }

    func harnessPermissionNotice(for sessionID: UUID) -> HarnessPermissionNotice? {
        harnessPermissionNotices[sessionID]
    }

    func availableHarnessPermissionOptions(for notice: HarnessPermissionNotice) -> [ApprovalOption] {
        let policy = sessions.first(where: { $0.id == notice.sessionID })?.policy ?? .ask
        return ApprovalOptionPolicy.visibleOptions(notice.request.options, under: policy)
    }

    func respondToHarnessPermission(_ notice: HarnessPermissionNotice, option: ApprovalOption) {
        let policy = sessions.first(where: { $0.id == notice.sessionID })?.policy ?? .ask
        guard ApprovalOptionPolicy.isVisible(option, under: policy) else {
            setError("That permission choice is not available in \(policy.rawValue) mode.", sessionID: notice.sessionID)
            return
        }
        guard sessions.contains(where: { $0.id == notice.sessionID && $0.isStreaming }) else {
            setError("This permission request is no longer active.", sessionID: notice.sessionID)
            harnessPermissionNotices[notice.sessionID] = nil
            if let sessionIndex = sessions.firstIndex(where: { $0.id == notice.sessionID }) {
                updateApprovalProvenance(
                    id: notice.request.id,
                    sessionIndex: sessionIndex,
                    actor: .user,
                    selectedOptionKind: option.kind,
                    outcome: .stale,
                    providerAcknowledgement: .rejectedByHarness
                )
            }
            updateSessionAction(id: notice.request.id, status: .cancelled, sessionID: notice.sessionID)
            return
        }
        guard forwardHarnessPermission(notice, optionID: option.id) else {
            setError("This permission request is no longer active.", sessionID: notice.sessionID)
            harnessPermissionNotices[notice.sessionID] = nil
            if let sessionIndex = sessions.firstIndex(where: { $0.id == notice.sessionID }) {
                updateApprovalProvenance(
                    id: notice.request.id,
                    sessionIndex: sessionIndex,
                    actor: .user,
                    selectedOptionKind: option.kind,
                    outcome: .stale,
                    providerAcknowledgement: .rejectedByHarness
                )
            }
            updateSessionAction(id: notice.request.id, status: .cancelled, sessionID: notice.sessionID)
            return
        }
        harnessPermissionNotices[notice.sessionID] = nil
        if let sessionIndex = sessions.firstIndex(where: { $0.id == notice.sessionID }) {
            updateApprovalProvenance(
                id: notice.request.id,
                sessionIndex: sessionIndex,
                actor: .user,
                selectedOptionKind: option.kind,
                outcome: .forwarded,
                providerAcknowledgement: .acceptedByHarness
            )
        }
        updateSessionAction(id: notice.request.id, status: option.isAllow ? .allowed : .denied, sessionID: notice.sessionID)
        setActivity([
            .init(
                icon: option.isAllow ? "checkmark.shield" : "xmark.shield",
                title: option.name,
                detail: notice.request.title
            )
        ], sessionID: notice.sessionID)
        reduceRunUI(.permissionResolved, for: notice.sessionID)
    }

    private func forwardHarnessPermission(_ notice: HarnessPermissionNotice, optionID: String?) -> Bool {
        switch notice.harnessID {
        case "codex": codex.respondToPermission(sessionID: notice.sessionID, requestID: notice.request.id, optionID: optionID)
        case "grok": grokACP.respondToPermission(sessionID: notice.sessionID, requestID: notice.request.id, optionID: optionID)
        case "opencode": openCodeACP.respondToPermission(sessionID: notice.sessionID, requestID: notice.request.id, optionID: optionID)
        case "pi": pi.respondToPermission(sessionID: notice.sessionID, requestID: notice.request.id, optionID: optionID)
        case "hermes": hermes.respondToPermission(sessionID: notice.sessionID, requestID: notice.request.id, optionID: optionID)
        default: false
        }
    }

    func setBackend(_ backend: ChatBackend, shouldSyncExecutionRoute: Bool = true) {
        if !SessionPrivacyPolicy.allows(backend, in: activePrivacyMode) {
            let message = backendUnavailableMessage(for: backend) ?? SessionPrivacyPolicy.cloudBlockedMessage
            setError(message, sessionID: selectedSessionID)
            return
        }
        if shouldSyncExecutionRoute, !canUseBackendInNewChat(backend) {
            let message = backendUnavailableMessage(for: backend) ?? "Choose a connected model."
            setError(message, sessionID: selectedSessionID)
            return
        }
        let previous = activeBackend
        defaultBackend = backend
        saveDefaultBackend()
        if shouldSyncExecutionRoute { syncExecutionRoute(from: backend) }
        if let id = selectedSessionID,
           let index = sessions.firstIndex(where: { $0.id == id }),
           !sessions[index].isStreaming,
           !sessions[index].messages.contains(where: { $0.role == .user }) {
            sessions[index].backend = backend
            sessions[index].harnessID = shouldSyncExecutionRoute ? Self.defaultHarnessID(for: backend) : selectedRouteHarnessID
            let sessionHarnessID = shouldSyncExecutionRoute ? Self.defaultHarnessID(for: backend) : selectedRouteHarnessID
            sessions[index].executionRoute = ExecutionRoute.legacy(for: backend, harnessID: sessionHarnessID)
            sessions[index].reasoningEffort = defaultReasoning(for: backend, harnessID: sessionHarnessID)
            sessions[index].harnessThreadID = nil
            persist()
        }
        if case .ollama(let model) = previous, previous != backend {
            Task { await unloadLocalModel(model, reason: "Unloaded after model switch") }
        }
        if case .ollama(let model) = backend {
            localModelStatus = "Ready: \(model)"
            scheduleLocalModelIdleUnload(model: model)
        }
    }

    func setExecutionRoute(engineID: String, harnessID: String) {
        let route = ExecutionRoutePolicy.normalize(
            EngineHarnessSelection(engineID: engineID, harnessID: harnessID),
            fallbackEngineID: Self.engineID(for: defaultBackend),
            fallbackHarnessID: Self.defaultHarnessID(for: defaultBackend)
        ) ?? EngineHarnessSelection(engineID: engineID, harnessID: harnessID)
        guard isRouteHarnessCompatible(engineID: route.engineID, harnessID: route.harnessID),
              let backend = backendForRouteEngine(route.engineID, harnessID: route.harnessID) else { return }
        if !SessionPrivacyPolicy.allows(backend, in: activePrivacyMode) {
            setError(SessionPrivacyPolicy.cloudBlockedMessage, sessionID: selectedSessionID)
            return
        }
        selectedRouteEngineID = route.engineID
        selectedRouteHarnessID = route.harnessID
        setBackend(backend, shouldSyncExecutionRoute: false)
    }

    func setLocalModelIdleUnloadMinutes(_ minutes: Int) {
        localModelIdleUnloadMinutes = max(0, min(minutes, 60))
        UserDefaults.standard.set(localModelIdleUnloadMinutes, forKey: Self.idleUnloadKey)
        if case .ollama(let model) = activeBackend { scheduleLocalModelIdleUnload(model: model) }
    }

    func setReasoningEffort(_ effort: ReasoningEffort) {
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].isStreaming else { return }
        guard reasoningOptions(for: sessions[index].backend, harnessID: effectiveHarnessID(for: sessions[index])).contains(where: { $0.effort == effort }) else { return }
        sessions[index].reasoningEffort = effort; persist()
    }

    func setSessionPolicy(_ value: ExecutionPolicy) {
        policy = value
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].isStreaming else { return }
        sessions[index].policy = value
        persist()
    }

    func setSessionPrivacyMode(_ value: SessionPrivacyMode) {
        privacyMode = value
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].isStreaming else { return }
        sessions[index].privacyMode = value
        if value == .localOnly,
           !sessions[index].messages.contains(where: { $0.role == .user }),
           !sessions[index].backend.isLocal {
            let local = localBackendFallback()
            sessions[index].backend = local
            sessions[index].harnessID = Self.defaultHarnessID(for: local)
            sessions[index].reasoningEffort = defaultReasoning(for: local, harnessID: sessions[index].harnessID)
            sessions[index].harnessThreadID = nil
            syncExecutionRoute(from: local)
        }
        persist()
    }

    func reasoningOptions(for backend: ChatBackend) -> [ReasoningOption] {
        reasoningOptions(for: backend, harnessID: nil)
    }

    private func reasoningOptions(for backend: ChatBackend, harnessID: String?) -> [ReasoningOption] {
        ReasoningCapabilityPolicy.options(
            for: backend,
            harnessID: harnessID,
            codexModels: codexModels,
            grokModels: grokModels,
            openCodeModels: openCodeModels
        )
    }

    func defaultReasoning(for backend: ChatBackend) -> ReasoningEffort? {
        defaultReasoning(for: backend, harnessID: nil)
    }

    private func defaultReasoning(for backend: ChatBackend, harnessID: String?) -> ReasoningEffort? {
        ReasoningCapabilityPolicy.defaultEffort(
            for: backend,
            harnessID: harnessID,
            codexModels: codexModels,
            grokModels: grokModels,
            openCodeModels: openCodeModels
        )
    }

    func chooseAttachments() {
        guard selectedSessionID != nil else {
            setError("Choose a mode and model before adding attachments.", sessionID: nil)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { composerState = .expanded; overlayControlState = .expanded; overlayMode = .prompt; return }
        addAttachments(panel.urls)
    }

    func addAttachments(_ urls: [URL]) {
        guard let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }) else {
            composerState = .expanded; overlayControlState = .expanded; overlayMode = .prompt
            return
        }
        let existing = Set(sessions[index].attachments.map(\.path))
        let additions = urls
            .filter(\.isFileURL)
            .map { $0.standardizedFileURL.path }
            .filter { !existing.contains($0) }
            .map { ContextAttachment(path: $0) }
        sessions[index].attachments.append(contentsOf: additions)
        composerState = .expanded; overlayControlState = .expanded; overlayMode = .prompt
        persist()
    }

    func removeAttachment(_ id: UUID) {
        guard let sessionID = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].attachments.removeAll { $0.id == id }; persist()
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedWorkspacePath = url.path
        if let id = selectedSessionID, let index = sessions.firstIndex(where: { $0.id == id }), sessions[index].messages.isEmpty {
            sessions[index].workspacePath = url.path; persist()
        }
    }

    /// Reveals the current workspace folder in Finder. No-ops when the path is empty/whitespace.
    /// If the folder is missing, opens an existing parent when possible; never mutates the filesystem.
    func revealSelectedWorkspaceInFinder() {
        let trimmed = selectedWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path, FileManager.default.fileExists(atPath: parent.path) {
            NSWorkspace.shared.open(parent)
        }
    }

    /// Copies the current workspace path to the pasteboard. No-ops when empty/whitespace; does not touch the filesystem.
    func copySelectedWorkspacePath() {
        let trimmed = selectedWorkspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(trimmed, forType: .string)
    }

    /// Opens an existing chat from the Workspace surface. Does not create sessions.
    func openSessionFromWorkspace(_ id: UUID) {
        guard sessions.contains(where: { $0.id == id }) else { return }
        selectedSessionID = id
        selectedSection = .conversations
    }

    func refreshLocalModels(normalizeAfterRefresh: Bool = true) async {
        let generation = localModelRefreshGeneration.begin()
        let previousCatalogStatus = ollamaCatalogStatus
        ollamaCatalogStatus = .loading
        defer {
            if Task.isCancelled,
               localModelRefreshGeneration.isCurrent(generation),
               ollamaCatalogStatus == .loading {
                ollamaCatalogStatus = previousCatalogStatus
            }
        }
        let catalog = await ollama.modelsResult()
        guard !Task.isCancelled, localModelRefreshGeneration.isCurrent(generation) else { return }
        ollamaCatalogStatus = catalog.status
        if catalog.status != .failed { ollamaModels = catalog.models }
        if normalizeAfterRefresh {
            normalizeBackendsAfterCatalogRefresh()
            normalizeExecutionRouteAfterCatalogRefresh()
        }
    }

    func refreshConnections(refreshProviderCatalogs: Bool = false) async {
        let generation = connectionRefreshGeneration.begin()
        let localGeneration = localModelRefreshGeneration.begin()
        // Authentication probes are observations of a specific runtime/profile
        // state. Every refresh invalidates them so revoked or changed login state
        // cannot remain runnable from a stale in-memory success.
        invalidateRuntimeAuthenticationValidations()
        let previousCatalogStatuses = (
            codex: codexCatalogStatus,
            grok: grokCatalogStatus,
            openCode: openCodeCatalogStatus,
            hermes: hermesCatalogStatus,
            ollama: ollamaCatalogStatus
        )
        isRefreshingConnections = true
        defer {
            if connectionRefreshGeneration.isCurrent(generation) {
                if Task.isCancelled {
                    if codexCatalogStatus == .loading { codexCatalogStatus = previousCatalogStatuses.codex }
                    if grokCatalogStatus == .loading { grokCatalogStatus = previousCatalogStatuses.grok }
                    if openCodeCatalogStatus == .loading { openCodeCatalogStatus = previousCatalogStatuses.openCode }
                    if hermesCatalogStatus == .loading { hermesCatalogStatus = previousCatalogStatuses.hermes }
                    if ollamaCatalogStatus == .loading,
                       localModelRefreshGeneration.isCurrent(localGeneration) {
                        ollamaCatalogStatus = previousCatalogStatuses.ollama
                    }
                }
                isRefreshingConnections = false
            }
        }
        async let codexRefresh: Void = refreshCodexConnection(generation: generation)
        async let grokRefresh: Void = refreshGrokConnection(generation: generation)
        async let openCodeRefresh: Void = refreshOpenCodeConnection(refreshCatalog: refreshProviderCatalogs, generation: generation)
        async let antigravityRefresh: Void = refreshAntigravityConnection(generation: generation)
        async let piRefresh: Void = refreshPiConnection(generation: generation)
        async let hermesRefresh: Void = refreshHermesConnection(generation: generation)
        async let localRefresh: Void = refreshLocalConnection(generation: generation, localGeneration: localGeneration)
        _ = await (codexRefresh, grokRefresh, openCodeRefresh, antigravityRefresh, piRefresh, hermesRefresh, localRefresh)
        guard canApplyCatalogRefresh(generation) else { return }
        normalizeBackendsAfterCatalogRefresh()
        normalizeExecutionRouteAfterCatalogRefresh()
    }

    private func canApplyCatalogRefresh(_ generation: UInt64) -> Bool {
        !Task.isCancelled && connectionRefreshGeneration.isCurrent(generation)
    }

    private func refreshCodexConnection(generation: UInt64) async {
        let executable = ExecutableDiscovery.locate("codex")
        guard canApplyCatalogRefresh(generation) else { return }
        if codex.isInstalled != (executable != nil) { codex = CodexExecHarness(executableURL: executable) }
        codexCatalogStatus = .loading
        async let codexAuth = codex.isAuthenticated()
        async let codexData = codex.providerSnapshot()
        async let codexVersion = codex.cliVersion()
        async let codexLatest = Self.latestCLIVersion(executableName: "codex", homebrewFormula: "codex", homebrewCask: "codex", npmPackage: "@openai/codex", pnpmPackage: "@openai/codex", directPackage: "@openai/codex")
        let auth = await codexAuth
        let snapshot = await codexData
        let version = await codexVersion
        let latest = await codexLatest
        guard canApplyCatalogRefresh(generation) else { return }
        codexAuthenticated = auth
        codexCatalogStatus = snapshot.catalogStatus
        codexProtocolUnavailableReason = snapshot.unavailableReason
        codexModels = snapshot.models
        codexReady = ProviderReadinessSnapshot(installed: codex.isInstalled, authenticated: auth, catalogStatus: snapshot.catalogStatus, runnableModelCount: visibleCodexModels.count).isRunnable
        codexUsage = snapshot.usage
        codexCLIVersion = version
        codexLatestCLIVersion = latest
    }

    private func refreshGrokConnection(generation: UInt64) async {
        let executable = ExecutableDiscovery.locate("grok")
        guard canApplyCatalogRefresh(generation) else { return }
        if grok.isInstalled != (executable != nil) { grok = StructuredCLIHarness(kind: .grok, executableURL: executable) }
        if grokACP.isInstalled != (executable != nil) { grokACP = ACPHarness(profile: .grok, executableURL: executable) }
        grokCatalogStatus = .loading
        async let grokAuth = grok.isAuthenticated()
        async let grokCatalog = grok.modelsResult()
        async let grokACPCatalog = grokACP.modelsResult(workspace: URL(fileURLWithPath: selectedWorkspacePath))
        async let grokUpdate = grok.updateStatus()
        let auth = await grokAuth
        let cliCatalog = await grokCatalog
        let acpCatalog = await grokACPCatalog
        let update = await grokUpdate
        guard canApplyCatalogRefresh(generation) else { return }
        grokAuthenticated = auth
        grokACPModels = acpCatalog.models
        grokCatalogStatus = ProviderCatalogStatus.combined(cliCatalog.status, acpCatalog.status)
        grokModels = cliCatalog.models.isEmpty ? acpCatalog.models.map { ProviderModel(id: $0.id, name: $0.name) } : cliCatalog.models
        grokReady = ProviderReadinessSnapshot(installed: grok.isInstalled, authenticated: auth, catalogStatus: grokCatalogStatus, runnableModelCount: runnableGrokModels.count).isRunnable
        grokCLIInfo = update
        grokUpdateStatus = grokCLIInfo.statusText
    }

    private func refreshOpenCodeConnection(refreshCatalog: Bool = false, generation: UInt64) async {
        let executable = ExecutableDiscovery.locate("opencode")
        guard canApplyCatalogRefresh(generation) else { return }
        if openCode.isInstalled != (executable != nil) { openCode = StructuredCLIHarness(kind: .openCode, executableURL: executable) }
        if openCodeACP.isInstalled != (executable != nil) { openCodeACP = ACPHarness(profile: .openCode, executableURL: executable) }
        openCodeCatalogStatus = .loading
        async let openCodeAuth = openCode.isAuthenticated()
        async let openCodeCatalog = openCode.modelsResult(refreshCache: refreshCatalog)
        async let openCodeACPCatalog = openCodeACP.modelsResult(workspace: URL(fileURLWithPath: selectedWorkspacePath))
        async let openCodeVersion = openCode.cliVersion()
        async let openCodeInstalledVersion = Self.homebrewInstalledFormulaVersion("opencode")
        async let openCodeLatest = Self.latestCLIVersion(executableName: "opencode", homebrewFormula: "opencode", homebrewCask: nil, npmPackage: "opencode-ai", pnpmPackage: "opencode-ai", directPackage: "opencode-ai")
        let auth = await openCodeAuth
        let catalog = await openCodeCatalog
        let acpCatalog = await openCodeACPCatalog
        let detectedVersion = await openCodeVersion
        let installedVersion = await openCodeInstalledVersion
        let latest = await openCodeLatest
        let apiKeySaved = KeychainStore.hasValue(account: OpenCodeCredentialPolicy.keychainAccount)
        guard canApplyCatalogRefresh(generation) else { return }
        openCodeAPIKeySaved = apiKeySaved
        // Direct OpenCode authentication remains a compatibility route. A
        // Lattice Keychain credential is separately consented for Pi/Hermes.
        openCodeAuthenticated = auth
        openCodeACPModels = acpCatalog.models
        openCodeCatalogStatus = ProviderCatalogStatus.combined(catalog.status, acpCatalog.status)
        openCodeModels = catalog.models
        openCodeReady = ProviderReadinessSnapshot(installed: openCode.isInstalled, authenticated: openCodeAuthenticated, catalogStatus: openCodeCatalogStatus, runnableModelCount: runnableOpenCodeModels.count).isRunnable
        openCodeCLIVersion = detectedVersion ?? installedVersion
        openCodeLatestCLIVersion = latest
    }

    private func refreshAntigravityConnection(generation: UInt64) async {
        let executable = ExecutableDiscovery.locate("agy")
        guard canApplyCatalogRefresh(generation) else { return }
        if antigravity.isInstalled != (executable != nil) {
            antigravity = AntigravityCLIHarness(executableURL: executable)
        }
        async let antigravityVersion = Self.commandOutput("agy", ["--version"])
        async let antigravityLatest = Self.latestCLIVersion(executableName: "agy", homebrewFormula: nil, homebrewCask: "antigravity-cli", npmPackage: nil, pnpmPackage: nil, directPackage: "@google/antigravity-cli")
        async let antigravityCatalog = antigravity.models()
        let version = await antigravityVersion
        let latest = await antigravityLatest
        let models = await antigravityCatalog
        // A successful provider-owned catalog command is the authentication
        // probe. Never read Antigravity's OAuth token file in Lattice.
        let authenticated = executable != nil && !models.isEmpty
        guard canApplyCatalogRefresh(generation) else { return }
        antigravityInstalled = executable != nil
        antigravityAuthenticated = authenticated
        antigravityModels = models
        antigravityCLIVersion = CLIVersionDisplayPolicy.normalizedVersion(version)
        antigravityLatestCLIVersion = latest
    }

    private func refreshPiConnection(generation: UInt64) async {
        let executable = ExecutableDiscovery.locate("pi")
        guard canApplyCatalogRefresh(generation) else { return }
        if pi.isInstalled != (executable != nil) { pi = PiRPCHarness(executableURL: executable) }
        async let piVersion = Self.commandOutput("pi", ["--version"])
        async let piCatalog = pi.modelCatalog()
        async let piLatest = Self.latestCLIVersion(executableName: "pi", homebrewFormula: "pi", homebrewCask: nil, npmPackage: "@earendil-works/pi-coding-agent", pnpmPackage: "@earendil-works/pi-coding-agent", directPackage: "@earendil-works/pi-coding-agent")
        let version = await piVersion
        let catalog = await piCatalog
        let latest = await piLatest
        guard canApplyCatalogRefresh(generation) else { return }
        piInstalled = executable != nil
        piCLIVersion = version
        piModelIDs = catalog
        piLatestCLIVersion = latest
    }

    private func refreshHermesConnection(generation: UInt64) async {
        let executable = ExecutableDiscovery.locate("hermes")
        guard canApplyCatalogRefresh(generation) else { return }
        if hermes.isInstalled != (executable != nil) { hermes = ACPHarness(executableURL: executable) }
        hermesCatalogStatus = .loading
        async let hermesInfo = Self.hermesUpdateInfo()
        async let hermesCatalog = hermes.modelsResult(workspace: URL(fileURLWithPath: selectedWorkspacePath))
        let catalog = await hermesCatalog
        let info = await hermesInfo
        guard canApplyCatalogRefresh(generation) else { return }
        hermesInstalled = executable != nil
        hermesCatalogStatus = catalog.status
        hermesModels = catalog.models
        hermesCLIInfo = info
    }

    private func refreshLocalConnection(generation: UInt64, localGeneration: UInt64) async {
        guard canApplyCatalogRefresh(generation),
              localModelRefreshGeneration.isCurrent(localGeneration) else { return }
        ollamaCatalogStatus = .loading
        async let local = ollama.isAvailable()
        async let models = ollama.modelsResult()
        let localReady = await local
        let localCatalog = await models
        let localInstalled = ExecutableDiscovery.locate("ollama") != nil || Self.ollamaAppURL() != nil
        let intelligenceReady = appleIntelligence.isAvailable
        let intelligenceStatus = appleIntelligence.statusDescription
        guard canApplyCatalogRefresh(generation),
              localModelRefreshGeneration.isCurrent(localGeneration) else { return }
        appleIntelligenceReady = intelligenceReady
        appleIntelligenceStatus = intelligenceStatus
        ollamaInstalled = localInstalled
        ollamaReady = localReady
        ollamaCatalogStatus = localCatalog.status
        if localCatalog.status != .failed { ollamaModels = localCatalog.models }
    }

    func connectCodex() {
        guard beginCLIAction(provider: "codex", progress: "Finish signing in to Codex…") else { return }
        Task {
            let commandSucceeded = await codex.login()
            await refreshConnections()
            finishCLISignIn(provider: "codex", providerName: "Codex", commandSucceeded: commandSucceeded, readyAfterRefresh: codexReady)
        }
    }

    func connectGrok() {
        guard beginCLIAction(provider: "grok", progress: "Finish signing in to Grok…") else { return }
        Task {
            let commandSucceeded = await grok.login()
            await refreshConnections()
            finishCLISignIn(provider: "grok", providerName: "Grok", commandSucceeded: commandSucceeded, readyAfterRefresh: grokReady)
        }
    }
    func connectOpenCode() {
        guard beginCLIAction(provider: "opencode", progress: "Finish signing in to OpenCode…") else { return }
        Task {
            let commandSucceeded = await openCode.login()
            await refreshConnections(refreshProviderCatalogs: true)
            finishCLISignIn(provider: "opencode", providerName: "OpenCode", commandSucceeded: commandSucceeded, readyAfterRefresh: openCodeReady)
        }
    }

    private func beginCLIAction(provider: String, progress: String, estimatedSeconds: TimeInterval = 180) -> Bool {
        guard !cliBusyProviders.contains(provider) else { return false }
        cliBusyProviders.insert(provider)
        cliActionMessages[provider] = progress
        cliActionStartedAt[provider] = .now
        cliActionEstimatedSeconds[provider] = estimatedSeconds
        return true
    }

    private func finishCLIAction(_ provider: String) {
        cliBusyProviders.remove(provider)
        cliActionStartedAt[provider] = nil
        cliActionEstimatedSeconds[provider] = nil
    }

    func cliProgressText(_ provider: String, at now: Date = .now) -> String {
        guard isCLIBusy(provider) else { return "" }
        let message = cliActionMessages[provider] ?? "Working…"
        guard let startedAt = cliActionStartedAt[provider],
              let estimate = cliActionEstimatedSeconds[provider] else { return message }
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        let remaining = max(0, estimate - elapsed)
        if remaining < 1 { return "\(message) · Finishing…" }
        let seconds = Int(remaining.rounded(.up))
        let time = seconds >= 60 ? "~\(seconds / 60)m \(seconds % 60)s remaining" : "~\(seconds)s remaining"
        return "\(message) · \(time)"
    }

    private func finishCLISignIn(provider: String, providerName: String, commandSucceeded: Bool, readyAfterRefresh: Bool) {
        cliActionMessages[provider] = CLIActionStatusPolicy.signInMessage(
            providerName: providerName,
            commandSucceeded: commandSucceeded,
            readyAfterRefresh: readyAfterRefresh
        )
        finishCLIAction(provider)
    }
    func connectAntigravity() {
        guard antigravityInstalled,
              beginCLIAction(provider: "antigravity", progress: "Finish signing in in your browser…") else { return }
        Task {
            let result = await Self.runAntigravityLogin()
            await refreshConnections()
            if antigravityAuthenticated {
                cliActionMessages["antigravity"] = ""
            } else {
                cliActionMessages["antigravity"] = CLIActionStatusPolicy.failureMessage(prefix: "Sign in failed", output: result.output)
            }
            finishCLIAction("antigravity")
        }
    }
    func installCodex() {
        requestCLIInstall("codex")
    }
    private func performCodexInstall() {
        runCLIInstall(provider: "codex", progress: "Installing Codex…", executableName: "codex") {
            guard let plan = CLIInstallResolver.codexInstallPlan(
                homebrewAvailable: ExecutableDiscovery.locate("brew") != nil,
                npmAvailable: ExecutableDiscovery.locate("npm") != nil,
                pnpmAvailable: ExecutableDiscovery.locate("pnpm") != nil
            ) else {
                return (-1, Data("Homebrew or Node.js with npm or pnpm is required to install Codex from Lattice.".utf8))
            }
            return await Self.runCommand(plan.executable, plan.arguments)
        }
    }
    func installGrok() {
        requestCLIInstall("grok")
    }
    private func performGrokInstall() {
        runCLIInstall(provider: "grok", progress: "Installing Grok…", executableName: "grok") {
            await Self.runRemoteInstallerScript("https://x.ai/cli/install.sh")
        }
    }
    func installOpenCode() {
        requestCLIInstall("opencode")
    }
    private func performOpenCodeInstall() {
        runCLIInstall(provider: "opencode", progress: "Installing OpenCode…", executableName: "opencode") {
            if ExecutableDiscovery.locate("npm") != nil || ExecutableDiscovery.locate("pnpm") != nil {
                guard let plan = CLIInstallResolver.packageInstallPlan(
                    npmPackage: "opencode-ai",
                    npmAvailable: ExecutableDiscovery.locate("npm") != nil,
                    pnpmAvailable: ExecutableDiscovery.locate("pnpm") != nil
                ) else { return (-1, Data("Could not resolve the OpenCode package installer.".utf8)) }
                return await Self.runCommand(plan.executable, plan.arguments)
            }
            if ExecutableDiscovery.locate("brew") != nil {
                return await Self.runCommand("brew", ["install", "anomalyco/tap/opencode"])
            }
            return await Self.runRemoteInstallerScript("https://opencode.ai/install")
        }
    }
    func installPi() {
        requestRuntimeAction(.firstUseInstall, runtime: .pi)
    }
    private func performPiInstall() {
        runCLIInstall(provider: "pi", progress: "Installing Pi 0.80.6…", executableName: "pi") {
            let reference = RuntimeInstallDescriptor.pi.installReference
            if ExecutableDiscovery.locate("npm") != nil {
                let integrity = await Self.runCommand("npm", ["view", reference, "dist.integrity", "--json"], deadline: 30)
                let reported = String(decoding: integrity.output, as: UTF8.self)
                guard integrity.status == 0,
                      let expected = RuntimeInstallDescriptor.pi.registryIntegrity,
                      RuntimeArtifactVerification.registryIntegrityMatches(reported: reported, expected: expected) else {
                    return (-1, Data("Pi registry integrity did not match Lattice's pinned release metadata.".utf8))
                }
                return await Self.runCommand("npm", ["install", "-g", "--ignore-scripts", reference], deadline: 180)
            }
            if ExecutableDiscovery.locate("pnpm") != nil {
                let integrity = await Self.runCommand("pnpm", ["view", reference, "dist.integrity", "--json"], deadline: 30)
                let reported = String(decoding: integrity.output, as: UTF8.self)
                guard integrity.status == 0,
                      let expected = RuntimeInstallDescriptor.pi.registryIntegrity,
                      RuntimeArtifactVerification.registryIntegrityMatches(reported: reported, expected: expected) else {
                    return (-1, Data("Pi registry integrity did not match Lattice's pinned release metadata.".utf8))
                }
                return await Self.runCommand("pnpm", ["add", "-g", "--ignore-scripts", reference], deadline: 180)
            }
            return (-1, Data("Node.js with npm or pnpm is required for the pinned Pi installation.".utf8))
        }
    }
    func installHermes() {
        requestRuntimeAction(.firstUseInstall, runtime: .hermes)
    }
    func installAntigravity() {
        requestCLIInstall("antigravity")
    }

    func requestCLIInstall(_ provider: String) {
        guard !cliBusyProviders.contains(provider) else { return }
        pendingCLIInstallProvider = provider
    }

    func cancelCLIInstall() {
        pendingCLIInstallProvider = nil
    }

    func requestRuntimeAction(_ action: RuntimeLifecycleAction, runtime: LatticeRuntimeID) {
        guard !cliBusyProviders.contains(runtime.rawValue) else { return }
        pendingRuntimeConfirmation = RuntimeConfirmationRequest(runtime: runtime, action: action)
        runtimeLifecycleStates[runtime] = RuntimeLifecycleState(
            runtime: runtime,
            phase: .awaitingConfirmation,
            detail: "Waiting for confirmation.",
            installedVersion: runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
        )
    }

    func cancelRuntimeAction() {
        guard let request = pendingRuntimeConfirmation else { return }
        pendingRuntimeConfirmation = nil
        runtimeLifecycleStates[request.runtime] = RuntimeLifecycleState(
            runtime: request.runtime,
            phase: .cancelled,
            detail: "No changes were made.",
            installedVersion: request.runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
        )
    }

    func confirmRuntimeAction() {
        guard let request = pendingRuntimeConfirmation else { return }
        pendingRuntimeConfirmation = nil
        switch request.action {
        case .firstUseInstall, .update:
            runtimeLifecycleStates[request.runtime] = RuntimeLifecycleState(
                runtime: request.runtime,
                phase: request.action == .update ? .updating : .installing,
                detail: "Using the exact pinned source shown in the confirmation.",
                installedVersion: request.runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
            )
            if request.runtime == .pi { performPiInstall() }
            else { performHermesInstall() }
        case .uninstall:
            performRuntimeUninstall(request.runtime)
        case .rollback:
            runtimeLifecycleStates[request.runtime] = RuntimeLifecycleState(
                runtime: request.runtime,
                phase: .failed,
                detail: "No previously installed Lattice runtime version is recorded for rollback.",
                installedVersion: request.runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
            )
        case .cancel, .interruptUpdate:
            runtimeLifecycleStates[request.runtime] = RuntimeLifecycleState(
                runtime: request.runtime,
                phase: request.action == .interruptUpdate ? .updateInterrupted : .cancelled,
                detail: "No additional runtime change was started.",
                installedVersion: request.runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
            )
        }
    }

    private func performRuntimeUninstall(_ runtime: LatticeRuntimeID) {
        guard RuntimeOwnershipPolicy.canUninstall(runtime, managedRuntimeIDs: latticeManagedRuntimeIDs) else {
            runtimeLifecycleStates[runtime] = RuntimeLifecycleState(
                runtime: runtime,
                phase: .failed,
                detail: "This runtime was not installed by Lattice, so Lattice will not remove it.",
                installedVersion: runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion
            )
            return
        }
        let provider = runtime.rawValue
        guard beginCLIAction(provider: provider, progress: "Removing \(runtime.displayName)…", estimatedSeconds: 60) else { return }
        runtimeLifecycleStates[runtime] = RuntimeLifecycleState(runtime: runtime, phase: .uninstalling)
        Task {
            let result: (status: Int32, output: Data)
            switch runtime {
            case .pi:
                if ExecutableDiscovery.locate("npm") != nil {
                    result = await Self.runCommand("npm", ["uninstall", "-g", "@earendil-works/pi-coding-agent"], deadline: 120)
                } else if ExecutableDiscovery.locate("pnpm") != nil {
                    result = await Self.runCommand("pnpm", ["remove", "-g", "@earendil-works/pi-coding-agent"], deadline: 120)
                } else {
                    result = (-1, Data("npm or pnpm is required to remove Pi.".utf8))
                }
            case .hermes:
                result = ExecutableDiscovery.locate("uv") == nil
                    ? (-1, Data("uv is required to remove the Lattice-installed Hermes tool.".utf8))
                    : await Self.runCommand("uv", ["tool", "uninstall", "hermes-agent"], deadline: 120)
            }
            await refreshConnections(refreshProviderCatalogs: true)
            let removed = ExecutableDiscovery.locate(runtime.executableName) == nil
            let detail = removed
                ? "Removed. Lattice-owned profile data remains available for rollback until you remove it manually."
                : CLIActionStatusPolicy.failureMessage(prefix: "Removal incomplete", output: result.output)
            runtimeLifecycleStates[runtime] = RuntimeLifecycleState(
                runtime: runtime,
                phase: removed ? .completed : .failed,
                detail: detail,
                installedVersion: removed ? nil : (runtime == .pi ? piCLIVersion : hermesCLIInfo.currentVersion)
            )
            if removed {
                latticeManagedRuntimeIDs.remove(runtime)
                UserDefaults.standard.set(latticeManagedRuntimeIDs.map(\.rawValue).sorted(), forKey: Self.managedRuntimeIDsKey)
            }
            cliActionMessages[provider] = detail
            finishCLIAction(provider)
        }
    }

    func confirmCLIInstall() {
        guard let provider = pendingCLIInstallProvider else { return }
        pendingCLIInstallProvider = nil
        switch provider {
        case "codex": performCodexInstall()
        case "grok": performGrokInstall()
        case "opencode": performOpenCodeInstall()
        case "antigravity": performAntigravityInstall()
        default: break
        }
    }

    private func performHermesInstall() {
        runCLIInstall(provider: "hermes", progress: "Installing pinned Hermes…", executableName: "hermes") {
            guard ExecutableDiscovery.locate("uv") != nil else {
                return (-1, Data("uv is required to install the pinned Hermes source revision.".utf8))
            }
            return await Self.runCommand(
                "uv",
                ["tool", "install", "--force", RuntimeInstallDescriptor.hermes.installReference],
                deadline: 300
            )
        }
    }

    private func performAntigravityInstall() {
        runCLIInstall(provider: "antigravity", progress: "Installing Antigravity…", executableName: "agy") {
            guard ExecutableDiscovery.locate("brew") != nil else {
                return (-1, Data("Homebrew is required to install the official Antigravity CLI cask.".utf8))
            }
            return await Self.runCommand("brew", ["install", "--cask", "antigravity-cli"])
        }
    }
    func connectHermes() {
        openHermesAuthentication()
    }

    func openPiAuthentication() {
        guard piInstalled, let executable = ExecutableDiscovery.locate("pi") else {
            cliActionMessages["pi"] = "Install Pi before signing in."
            return
        }
        validatedPiCodexModels.removeAll()
        let profile = PiRPCHarness().sharedProfileDirectory
        guard openRuntimeTerminal(
            name: "pi-login",
            executable: executable,
            arguments: [],
            environment: ["PI_CODING_AGENT_DIR": profile.path]
        ) else {
            cliActionMessages["pi"] = "Lattice could not open the isolated Pi login terminal."
            return
        }
        cliActionMessages["pi"] = "In Pi, run /login and choose ChatGPT. Return here, then Validate."
    }

    func validatePiAuthentication(providerID: String) {
        guard piInstalled,
              !isRefreshingConnections,
              !cliBusyProviders.contains("pi-\(providerID)") else { return }
        let candidates = piModelIDs.sorted().compactMap { identifier -> (provider: String, model: String)? in
            if providerID == "codex", identifier.hasPrefix("openai-codex/") {
                return ("codex", String(identifier.dropFirst("openai-codex/".count)))
            }
            if providerID == "opencode",
               identifier.hasPrefix("opencode-go/") || identifier.hasPrefix("opencode-zen/") {
                return ("opencode", identifier)
            }
            return nil
        }
        guard let candidate = candidates.first else {
            cliActionMessages["pi"] = "Pi did not report a compatible \(providerID) model."
            return
        }
        let actionID = "pi-\(providerID)"
        guard beginCLIAction(provider: actionID, progress: "Validating Pi \(providerID)…", estimatedSeconds: 30) else { return }
        let refreshGeneration = connectionRefreshGeneration.current()
        Task {
            let key = providerID == "opencode" && openCodeCredentialEnabledModes.contains(.code)
                ? KeychainStore.read(account: OpenCodeCredentialPolicy.keychainAccount)
                : nil
            let valid = await pi.validateIsolatedAuthentication(
                provider: candidate.provider,
                model: candidate.model,
                openCodeAPIKey: key
            )
            guard connectionRefreshGeneration.isCurrent(refreshGeneration), !isRefreshingConnections else {
                finishCLIAction(actionID)
                return
            }
            if valid {
                if providerID == "codex" {
                    validatedPiCodexModels = Set(candidates.map(\.model))
                } else {
                    validatedPiOpenCodeModels = Set(candidates.map(\.model))
                }
                cliActionMessages["pi"] = "Pi \(providerID) authentication validated."
            } else {
                if providerID == "codex" { validatedPiCodexModels.removeAll() }
                else { validatedPiOpenCodeModels.removeAll() }
                cliActionMessages["pi"] = "Pi could not validate \(providerID). Check the isolated login or enabled key, then try again."
            }
            finishCLIAction(actionID)
        }
    }

    func openHermesAuthentication() {
        guard hermesInstalled, let executable = ExecutableDiscovery.locate("hermes") else {
            cliActionMessages["hermes"] = "Install Hermes before signing in."
            return
        }
        validatedHermesProviders.removeAll()
        validatedHermesOpenCodeModels.removeAll()
        let profile = LatticeHermesProfile().homeURL
        guard openRuntimeTerminal(
            name: "hermes-model",
            executable: executable,
            arguments: ["model"],
            environment: ["HOME": profile.path, "HERMES_HOME": profile.path]
        ) else {
            cliActionMessages["hermes"] = "Lattice could not open the isolated Hermes model setup terminal."
            return
        }
        cliActionMessages["hermes"] = "Choose and authenticate the Work provider in Hermes, then validate it here."
    }

    func validateHermesAuthentication(providerID: String) {
        let provider: String
        switch providerID {
        case "codex": provider = LatticeHermesProvider.openAICodex.rawValue
        case "grok": provider = LatticeHermesProvider.xAIOAuth.rawValue
        default:
            cliActionMessages["hermes"] = "OpenCode uses the explicitly enabled Keychain credential."
            return
        }
        let actionID = "hermes-\(providerID)"
        guard hermesInstalled,
              !isRefreshingConnections,
              beginCLIAction(provider: actionID, progress: "Validating Hermes \(providerID)…", estimatedSeconds: 20) else { return }
        let refreshGeneration = connectionRefreshGeneration.current()
        Task {
            let valid = await hermes.validateHermesAuthentication(provider: provider)
            guard connectionRefreshGeneration.isCurrent(refreshGeneration), !isRefreshingConnections else {
                finishCLIAction(actionID)
                return
            }
            if valid { validatedHermesProviders.insert(provider) }
            else { validatedHermesProviders.remove(provider) }
            cliActionMessages["hermes"] = valid
                ? "Hermes \(providerID) authentication validated."
                : "Hermes did not report an authenticated \(providerID) session in its isolated profile."
            finishCLIAction(actionID)
        }
    }

    func validateHermesOpenCodeAuthentication() {
        let candidates = hermesModels.filter {
            $0.id.hasPrefix("opencode-go:") || $0.id.hasPrefix("opencode-zen:")
        }
        guard hermesInstalled,
              !isRefreshingConnections,
              openCodeAPIKeySaved,
              openCodeCredentialEnabledModes.contains(.work),
              let candidate = candidates.first,
              let route = ExecutionRouteResolver.resolve(
                mode: .work,
                providerID: "opencode",
                modelID: candidate.id
              ),
              let provider = hermesProvider(for: route),
              let key = KeychainStore.read(account: OpenCodeCredentialPolicy.keychainAccount),
              beginCLIAction(provider: "hermes-opencode", progress: "Validating Hermes OpenCode…", estimatedSeconds: 30) else {
            cliActionMessages["hermes"] = "Enable the saved OpenCode key for Work and discover a Hermes OpenCode model first."
            return
        }
        let refreshGeneration = connectionRefreshGeneration.current()
        Task {
            let result = await hermes.modelsResult(
                workspace: URL(fileURLWithPath: selectedWorkspacePath),
                provider: provider,
                model: candidate.id,
                systemIdentity: LatticeProductInstructions.current,
                opencodeAPIKey: key
            )
            let valid = result.status == .loaded
                && HermesACPHarness.exactMatch(for: candidate.id, in: result.models) != nil
            guard connectionRefreshGeneration.isCurrent(refreshGeneration), !isRefreshingConnections else {
                finishCLIAction("hermes-opencode")
                return
            }
            if valid { validatedHermesOpenCodeModels = Set(candidates.map(\.id)) }
            else { validatedHermesOpenCodeModels.removeAll() }
            cliActionMessages["hermes"] = valid
                ? "Hermes OpenCode credential and model catalog validated for Work."
                : "Hermes could not validate the OpenCode Work route."
            finishCLIAction("hermes-opencode")
        }
    }

    private func openRuntimeTerminal(
        name: String,
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) -> Bool {
        let directory = LatticeApplicationSupport.productRootURL()
            .appendingPathComponent("RuntimeLaunchers", isDirectory: true)
        let scriptURL = directory.appendingPathComponent("\(name).command")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let exports = environment.sorted(by: { $0.key < $1.key }).map { key, value in
                "export \(key)=\(Self.shellQuote(value))"
            }
            let command = (["exec", Self.shellQuote(executable.path)] + arguments.map(Self.shellQuote)).joined(separator: " ")
            let body = (["#!/bin/zsh", "set -eu"] + exports + [command, ""]).joined(separator: "\n")
            try Data(body.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
            return NSWorkspace.shared.open(scriptURL)
        } catch {
            return false
        }
    }

    nonisolated private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    func installOllama() { NSWorkspace.shared.open(URL(string: "https://ollama.com/download/mac")!) }
    func openOllama() {
        guard let appURL = Self.ollamaAppURL() else { installOllama(); return }
        NSWorkspace.shared.open(appURL)
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await refreshConnections()
        }
    }
    func isCLIBusy(_ provider: String) -> Bool { cliBusyProviders.contains(provider) }
    func cliActionMessage(_ provider: String) -> String? { cliActionMessages[provider] }

    func refreshExtensions() {
        prepareSelfEditWorkspace()
        refreshSkills()
        let loaded = extensionStore.load()
        let known = Set(UserDefaults.standard.stringArray(forKey: Self.knownExtensionIDsKey) ?? [])
        let refreshedEnablement = LatticeExtensionEnablementPolicy.refresh(
            records: loaded,
            storedEnabledIDs: enabledExtensionIDs,
            knownIDs: known
        )
        extensions = loaded
        enabledExtensionIDs = refreshedEnablement.enabledIDs
        UserDefaults.standard.set(Array(refreshedEnablement.knownIDs).sorted(), forKey: Self.knownExtensionIDsKey)
        UserDefaults.standard.set(Array(enabledExtensionIDs).sorted(), forKey: Self.enabledExtensionIDsKey)
        activeStylePatches = loaded
            .filter { enabledExtensionIDs.contains($0.id) && $0.isValid && $0.hasRuntimePatches }
            .flatMap(\.stylePatches)
        activeLayoutPatches = loaded
            .filter { enabledExtensionIDs.contains($0.id) && $0.isValid && $0.hasRuntimePatches }
            .flatMap(\.layoutPatches)
        activeCopyPatches = loaded
            .filter { enabledExtensionIDs.contains($0.id) && $0.isValid && $0.hasRuntimePatches }
            .flatMap(\.copyPatches)
        activePromptTemplates = loaded
            .filter { enabledExtensionIDs.contains($0.id) && $0.isValid && $0.hasRuntimePatches }
            .flatMap(\.promptTemplates)
    }

    func refreshSkills() {
        do {
            try skillStore.importGlobalSkills()
            skills = skillStore.load()
            disabledSkillIDs = disabledSkillIDs.intersection(Set(skills.map(\.id)))
            UserDefaults.standard.set(Array(disabledSkillIDs).sorted(), forKey: Self.disabledSkillIDsKey)
        } catch {
            skills = skillStore.load()
            setError(error.localizedDescription)
        }
    }

    private func startExtensionMonitoring() {
        try? extensionStore.prepareDirectory()
        if extensionDirectoryFileDescriptor >= 0 { close(extensionDirectoryFileDescriptor) }
        extensionDirectoryFileDescriptor = open(extensionStore.rootURL.path, O_EVTONLY)
        guard extensionDirectoryFileDescriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: extensionDirectoryFileDescriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.refreshExtensions()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self, self.extensionDirectoryFileDescriptor >= 0 else { return }
            close(self.extensionDirectoryFileDescriptor)
            self.extensionDirectoryFileDescriptor = -1
        }
        source.resume()
        extensionDirectorySource = source
    }

    private func workspaceURL(for session: LatticeSession, isExtensionSelfEdit: Bool) -> URL {
        if isExtensionSelfEdit {
            prepareSelfEditWorkspace()
            return extensionStore.rootURL
        }
        return URL(fileURLWithPath: session.workspacePath ?? selectedWorkspacePath)
    }

    private func prepareSelfEditWorkspace() {
        do {
            try extensionStore.prepareDirectory()
            try skillStore.prepareDirectory()
            try writeSelfEditGuide()
            try writeSelfMap()
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func writeSelfEditGuide() throws {
        let guideURL = extensionStore.rootURL.appendingPathComponent("LATTICE_SELF_EDIT.md")
        // Prefer lattice guide name; leave any legacy NISA_SELF_EDIT.md in place for manual reference only.
        let guide = """
        # Lattice self-edit workspace

        This folder is Lattice's user-owned modification layer. Shipped builds must create or update extensions here instead of editing the installed app bundle or requiring a source checkout.

        ## Editable surfaces

        Read `lattice-self-map.json` for the current app surface map.

        ## Extension manifest

        Create one folder per change. Each folder must contain `lattice-extension.json`.

        Minimal manifest:

        ```json
        {
          "schemaVersion": 1,
          "id": "letters-numbers-dots-underscores-or-hyphens",
          "name": "Short user-facing name",
          "version": "1.0.0",
          "summary": "What this changes",
          "permissions": ["editUI"],
          "uiTargets": ["overlay", "composer", "chat", "sidebar"],
          "stylePatches": [
            { "target": "overlay", "tintHex": "#FFFFFF", "accentHex": "#FF7AA2", "cornerRadius": 18 }
          ],
          "layoutPatches": [
            { "target": "composer", "density": "compact" }
          ],
          "copyPatches": [
            { "target": "askButton", "text": "Ask softly" }
          ],
          "promptTemplates": [
            {
              "invocation": "/summarize",
              "title": "Summarize",
              "detail": "Insert a concise summarization prompt",
              "prompt": "Summarize the selected context in five bullets."
            }
          ],
          "skillPatches": [
            {
              "id": "subagents",
              "title": "Subagents",
              "summary": "Use parallel helper agents for independent subtasks.",
              "markdown": \(Self.subagentsSkillMarkdownJSONString)
            }
          ],
          "operationPreviews": [
            {
              "targetSurfaceID": "extensions",
              "operation": "addSkill",
              "summary": "Add a reusable subagents skill.",
              "detail": "Executable when backed by a skill patch."
            }
          ]
        }
        ```

        Valid `stylePatches.target` values are `overlay`, `composer`, `search`, `card`, and `all`.
        Valid `layoutPatches.target` is currently `composer`; valid `layoutPatches.density` values are `compact`, `comfortable`, and `spacious`. Composer relayout previews are executable when backed by a composer layout patch.
        Valid `copyPatches.target` values are `askButton`, `promptPlaceholder`, and `emptyChatTitle`.
        Valid `promptTemplates.invocation` values start with slash and use letters, numbers, hyphens, or underscores. Prompt templates are real runtime slash commands.
        Valid `skillPatches.id` values are lowercase letters, numbers, hyphens, and underscores, and cannot be `self-edit`. Skill patches write real `SKILL.md` files into Lattice's shared skills folder. Generated skill frontmatter `name` must exactly match `skillPatches.id`, and `description` must explain when the skill should be used.
        Valid `operationPreviews.operation` values come from `lattice-self-map.json`. `restyle`, `relayout`, `rewriteCopy`, `addControl`, and `addSkill` previews are executable only when backed by matching `stylePatches`, `layoutPatches`, `copyPatches`, `promptTemplates`, or `skillPatches`; model recommendation, harness route, and automation previews remain recorded-only.
        Every operation preview requires `editUI`; `addAutomation` also requires `automation`.

        Lattice watches this folder and refreshes valid enabled extensions and skills automatically.
        """
        guard let data = guide.data(using: .utf8) else { return }
        try writeIfChanged(data, to: guideURL)
    }

    private static var subagentsSkillMarkdownJSONString: String {
        let data = try? JSONEncoder().encode(LatticeGeneratedSkillTemplate.subagentsMarkdown)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private func writeSelfMap() throws {
        let mapURL = extensionStore.rootURL.appendingPathComponent("lattice-self-map.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(LatticeSelfMap())
        try writeIfChanged(data, to: mapURL)
    }

    private func writeIfChanged(_ data: Data, to url: URL) throws {
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try data.write(to: url, options: .atomic)
    }

    private func preparedSubmissionPreview(_ text: String) -> PreparedSubmission? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let prompt = LatticeSelfEditCommand.prompt(in: trimmed) {
            guard !prompt.isEmpty else { return nil }
            return PreparedSubmission(userText: prompt, runText: prompt, startsSelfEdit: true)
        }
        if let skillInvocation = LatticeSkillPromptBuilder.invocation(in: trimmed, records: skills, disabledSkillIDs: effectiveDisabledSkillIDs) {
            return PreparedSubmission(
                userText: trimmed,
                runText: LatticeSkillPromptBuilder.prompt(for: skillInvocation),
                startsSelfEdit: false
            )
        }
        return PreparedSubmission(userText: trimmed, runText: trimmed, startsSelfEdit: false)
    }

    private func prepareSubmission(_ text: String) -> PreparedSubmission? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prompt = LatticeSelfEditCommand.prompt(in: trimmed) {
            guard !prompt.isEmpty else {
                setError("Type what you want Lattice to change after /self-edit.", sessionID: selectedSessionID)
                composerState = .expanded
                overlayControlState = .expanded
                return nil
            }
        }
        return preparedSubmissionPreview(trimmed)
    }

    private func isExtensionSelfEditThread(_ session: LatticeSession, submittedText: String) -> Bool {
        session.intent == .selfEdit || LatticeSelfEditCommand.prompt(in: submittedText) != nil
    }

    private func backendAdditionalContext(for session: LatticeSession, submittedText: String, forceSelfEdit: Bool = false) -> String {
        let isExtensionSelfEdit = forceSelfEdit || isExtensionSelfEditThread(session, submittedText: submittedText)
        let liveAttachmentPaths = session.attachments.filter { !$0.isMissing }.map(\.path)
        let attachmentContext = liveAttachmentPaths.isEmpty
            ? ""
            : "\n\nAttached paths:\n" + liveAttachmentPaths.joined(separator: "\n")
        let taskContext: String
        if session.executionRoute.runtimeID == "pi" || session.executionRoute.runtimeID == "hermes" || session.executionRoute.mode == .local {
            taskContext = ""
        } else {
            let guidance = session.executionRoute.runtimeID == "codex"
                ? LatticeProductInstructions.current
                : LatticeProductInstructions.taskContext(for: session.executionRoute.mode)
            taskContext = "\n\nLattice task context (visible task guidance; not a system prompt):\n" + guidance
        }
        return taskContext
            + selfEditContext(for: submittedText, isExtensionSelfEdit: isExtensionSelfEdit, sessionID: session.id)
            + attachmentContext
    }

    private static func selfEditTitle(for prompt: String) -> String {
        "Lattice self-edit: \(prompt.prefix(32))"
    }

    private static func isLegacySelfEditSession(_ session: LatticeSession) -> Bool {
        session.title.range(of: "Lattice self-edit", options: [.caseInsensitive, .anchored]) != nil
        || session.messages.contains { message in
            message.role == .user && legacyLooksLikeSelfEditRequest(message.text)
        }
    }

    private static func legacyLooksLikeSelfEditRequest(_ text: String) -> Bool {
        let normalized = text.lowercased()
        let mentionsLattice = normalized.contains("lattice") || normalized.contains("this app") || normalized.contains("the app")
        let looksLikeSelfEdit = [
            "self edit", "self-edit", "change", "make", "restyle", "glassy",
            "liquid glass", "overlay", "sidebar", "chat", "composer", "color",
            "pink", "green", "ui", "interface", "text bubble", "message bubble"
        ].contains { normalized.contains($0) }
        return mentionsLattice && looksLikeSelfEdit
    }

    private func selfEditContext(for text: String, isExtensionSelfEdit: Bool, sessionID: UUID) -> String {
        guard isExtensionSelfEdit else { return "" }
        let root = extensionStore.rootURL.path
        let skillsRoot = skillStore.rootURL.path
        let pendingManifestContext: String = {
            guard let preview = visibleSelfEditPreviews(for: sessionID).first,
                  let data = try? JSONEncoder().encode(preview.manifest),
                  let json = String(data: data, encoding: .utf8) else { return "" }
            return """

            - This chat already has a pending review. Treat the user's message as a request to revise that proposal. Return one complete replacement manifest with the same id, preserve every unchanged patch, and alter only what the user requested. Do not apply or discard it yourself.
            - Current pending manifest:
              <lattice-current-pending-manifest>
              \(json)
              </lattice-current-pending-manifest>
            """
        }()
        return """


Lattice self-edit rules:
- This is a user-facing customization request. Do not edit source files or the installed app bundle.
- Prefer a user-owned Lattice modification under: \(root)
- Skill requests should create skillPatches. Lattice writes those to the shared skills folder: \(skillsRoot)
- Do not use tools, search files, inspect source code, or write files. Lattice applies the manifest itself.
- Return exactly one manifest wrapped in <lattice-extension-manifest> and </lattice-extension-manifest>, with no other text.
- Use this complete manifest schema:
  <lattice-extension-manifest>
  {
    "schemaVersion": 1,
    "id": "letters-numbers-dots-underscores-or-hyphens",
    "name": "Short user-facing name",
    "version": "1.0.0",
    "summary": "What this changes",
    "permissions": ["editUI"],
    "uiTargets": ["overlay", "composer", "chat", "sidebar", "models", "connections"],
    "stylePatches": [
      { "target": "overlay|composer|search|card|all", "tintHex": "#RRGGBB", "accentHex": "#RRGGBB", "cornerRadius": 18 }
    ],
    "layoutPatches": [
      { "target": "composer", "density": "compact|comfortable|spacious" }
    ],
    "copyPatches": [
      { "target": "askButton|promptPlaceholder|emptyChatTitle", "text": "One-line replacement copy" }
    ],
    "promptTemplates": [
      {
        "invocation": "/letters-numbers-hyphens-or_underscores",
        "title": "Short template title",
        "detail": "Short user-facing explanation",
        "prompt": "Prompt text to insert into the composer when selected."
      }
    ],
    "skillPatches": [
      {
        "id": "subagents",
        "title": "Subagents",
        "summary": "Use parallel helper agents for independent subtasks.",
        "markdown": \(Self.subagentsSkillMarkdownJSONString)
      }
    ],
    "operationPreviews": [
      {
        "targetSurfaceID": "surface id from lattice-self-map.json",
        "operation": "restyle|relayout|rewriteCopy|addControl|addModelRecommendation|addHarnessRoute|addSkill|addAutomation",
        "summary": "Short preview of the requested operation",
        "detail": "Optional detail. State when this is recorded-only."
      }
    ]
  }
  </lattice-extension-manifest>
- Choose a stable lowercase id. Include only requested changes. Valid targets are overlay, composer, search, card, and all.
- Use stylePatches for real runtime styling changes, layoutPatches for real composer density changes, copyPatches for real copy changes, and promptTemplates for real slash-command prompt templates.
- Use skillPatches for real reusable skill creation. Do not create a skill with id `self-edit`; `/self-edit` is Lattice's app-customization command. Generated SKILL.md must be substantive, not a short generic prompt: include YAML frontmatter with only name and description, make frontmatter name exactly match the skill id, then Quick start, Workflow, Guardrails, and Verification sections. Quick start must give concrete trigger/use guidance; Workflow must include at least three numbered decision steps with edge cases and failure recovery; Guardrails must state concrete safety, scope, and permission limits; Verification must require evidence-producing checks. Keep it focused and under 500 lines, but at least 600 characters. If the user says something like "/self-edit Add a skill to use subagents better", create a complete subagents workflow rather than a few sentences, and include an addSkill operation preview targeting "extensions".
- Use operationPreviews to summarize the user's requested operation. The manifest summary and operation summaries must explain in plain language what applying the review will change, what it will not change, and any important consequence needed for a decision without reading the full manifest. restyle previews are executable only when backed by matching stylePatches; relayout previews are executable only when backed by composer layoutPatches; rewriteCopy previews are executable only when backed by copyPatches; addControl previews are executable only when backed by promptTemplates; addSkill previews are executable only when backed by skillPatches. addModelRecommendation, addHarnessRoute, and addAutomation are recorded-only until Lattice implements those runtimes.
- Every operation preview requires the editUI permission. addAutomation previews also require the automation permission.
- Prompt template invocations must start with slash, cannot replace /self-edit, and may only contain letters, numbers, hyphens, or underscores after the slash.
- For an undo or revert, reuse the prior manifest id and return it with empty uiTargets, stylePatches, copyPatches, promptTemplates, skillPatches, and operationPreviews.
- The response is machine-consumed. Do not add Markdown fences, explanations, status text, or future-tense commentary.
\(pendingManifestContext)
"""
    }

    private func prepareGeneratedExtensionPreview(at index: Int, request: String?) -> Bool {
        guard let response = sessions[index].messages.last?.text else {
            setError("The model did not return a Lattice modification manifest.", sessionID: sessions[index].id)
            return false
        }
        let manifest: LatticeExtensionManifest
        do {
            manifest = try LatticeExtensionManifestEnvelope.decode(from: response)
        } catch {
            setError(error.localizedDescription, sessionID: sessions[index].id)
            return false
        }
        let validation = extensionStore.validate(manifest)
        let generatedSkillValidation = LatticeSelfEditGeneratedSkillValidationPolicy.validationMessages(for: manifest)
        let combinedValidation = validation + generatedSkillValidation
        guard combinedValidation.isEmpty else {
            setError(combinedValidation.joined(separator: " "), sessionID: sessions[index].id)
            return false
        }
        do {
            let previousManifestData = extensionStore.manifestData(for: manifest.id)
            let previousManifest = previousManifestData.flatMap { try? JSONDecoder().decode(LatticeExtensionManifest.self, from: $0) }
            let review = LatticeExtensionChangeReviewBuilder.review(current: manifest, previous: previousManifest)
            guard review.hasChanges else {
                setError("The proposed Lattice change does not change anything. Ask for a revision or discard it.", sessionID: sessions[index].id)
                return false
            }
            let previousSkillSnapshots = manifest.skillPatches.map { skillStore.snapshotSkill(id: $0.id) }
            let affectedSkillIDs = Set(manifest.skillPatches.map(\.id))
            let previousDisabledSkillIDs = LatticeSkillEnablementRollbackPolicy.disabledSnapshot(
                affectedSkillIDs: affectedSkillIDs,
                disabledSkillIDs: disabledSkillIDs
            )
            let previousEnabled = enabledExtensionIDs.contains(manifest.id)
            let preview = LatticeExtensionPreviewRecord(
                sessionID: sessions[index].id,
                harnessThreadID: sessions[index].harnessThreadID,
                request: request ?? "Lattice self-edit",
                manifest: manifest,
                previousManifestData: previousManifestData,
                previousSkillSnapshots: previousSkillSnapshots,
                previousDisabledSkillIDs: previousDisabledSkillIDs,
                previousEnabled: previousEnabled
            )
            selfEditPreviews = try extensionPreviewStore.record(preview, in: selfEditPreviews)
            sessions[index].messages[sessions[index].messages.count - 1].text = LatticeSelfEditReviewCopy.readyStatus
            return true
        } catch {
            setError(error.localizedDescription, sessionID: sessions[index].id)
            return false
        }
    }

    func visibleSelfEditPreviews(for sessionID: UUID) -> [LatticeExtensionPreviewRecord] {
        selfEditPreviews.filter { $0.sessionID == sessionID }
    }

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
                tintHex: optionalPatchString(draft.tintHex),
                accentHex: optionalPatchString(draft.accentHex),
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

    private func updateEditableSelfEditStylePatchDraft(previewID: UUID, index: Int, patch: LatticeStylePatch, mutate: (inout EditableSelfEditStylePatchDraft) -> Void) {
        let key = selfEditStylePatchKey(previewID: previewID, index: index)
        var draft = editableSelfEditStylePatchDraft(previewID: previewID, index: index, patch: patch)
        mutate(&draft)
        editableSelfEditStylePatchDrafts[key] = draft
    }

    private func optionalPatchString(_ value: String) -> String? {
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

    private func validateEditedSelfEditPreview(_ updatedPreview: LatticeExtensionPreviewRecord, original: LatticeExtensionPreviewRecord) -> Bool {
        let validation = extensionStore.validate(updatedPreview.manifest)
            + LatticeSelfEditGeneratedSkillValidationPolicy.validationMessages(for: updatedPreview.manifest)
        guard validation.isEmpty else {
            setError(validation.joined(separator: " "), sessionID: original.sessionID)
            return false
        }
        return true
    }

    private func clearExpandedSkillPreviews(for preview: LatticeExtensionPreviewRecord) {
        let prefix = "\(preview.id.uuidString)::"
        expandedSelfEditSkillPreviewIDs = expandedSelfEditSkillPreviewIDs.filter { !$0.hasPrefix(prefix) }
        editableSelfEditSkillDrafts = editableSelfEditSkillDrafts.filter { !$0.key.hasPrefix(prefix) }
        editableSelfEditStylePatchDrafts = editableSelfEditStylePatchDrafts.filter { !$0.key.hasPrefix(prefix) }
        editableSelfEditLayoutPatchDrafts = editableSelfEditLayoutPatchDrafts.filter { !$0.key.hasPrefix(prefix) }
        editableSelfEditCopyPatchDrafts = editableSelfEditCopyPatchDrafts.filter { !$0.key.hasPrefix(prefix) }
        editableSelfEditPromptTemplateDrafts = editableSelfEditPromptTemplateDrafts.filter { !$0.key.hasPrefix(prefix) }
        editableSelfEditOperationPreviewDrafts = editableSelfEditOperationPreviewDrafts.filter { !$0.key.hasPrefix(prefix) }
        editableSelfEditManifestDrafts.removeValue(forKey: preview.id)
        expandedSelfEditReviewIDs.remove(preview.id)
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

    private func materializedSelfEditPreview(_ preview: LatticeExtensionPreviewRecord) throws -> LatticeExtensionPreviewRecord {
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
                tintHex: optionalPatchString(draft.tintHex),
                accentHex: optionalPatchString(draft.accentHex),
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

    private func appendSelfEditStatus(_ text: String, to sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[index].messages.append(.init(role: .system, text: text))
        sessions[index].lastUpdated = .now
        persist()
    }

    private func selfEditApplyStatus(for manifest: LatticeExtensionManifest) -> String {
        LatticeSelfEditApplyStatusPolicy.status(for: manifest)
    }

    private func validReasoningEffort(for session: LatticeSession) -> ReasoningEffort? {
        guard let effort = session.reasoningEffort else { return nil }
        return reasoningOptions(for: session.backend, harnessID: effectiveHarnessID(for: session)).contains(where: { $0.effort == effort }) ? effort : nil
    }

    func openExtensionsFolder() {
        try? extensionStore.prepareDirectory()
        NSWorkspace.shared.open(extensionStore.rootURL)
    }

    func openSkillsFolder() {
        try? skillStore.prepareDirectory()
        NSWorkspace.shared.open(skillStore.rootURL)
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

    private func deleteExtension(_ record: LatticeExtensionRecord) {
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

    private func deleteSkill(_ record: LatticeSkillRecord) {
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
        stylePatch(for: target)?.tintHex.flatMap(Color.init(latticeHex:))
    }

    func cornerRadius(for target: LatticeStyleTarget, default value: CGFloat) -> CGFloat {
        CGFloat(stylePatch(for: target)?.cornerRadius ?? Double(value))
    }

    private func stylePatch(for target: LatticeStyleTarget) -> LatticeStylePatch? {
        activeStylePatches.reversed().first { $0.target == target || $0.target == .all }
    }

    func copyText(for target: LatticeCopyTarget, fallback: String) -> String {
        activeCopyPatches.reversed().first { $0.target == target }?.text ?? fallback
    }

    func composerLayoutDensity() -> LatticeLayoutDensity {
        activeLayoutPatches.reversed().first { $0.target == .composer }?.density ?? .comfortable
    }

    func composerSpacing() -> CGFloat {
        switch composerLayoutDensity() {
        case .compact: 6
        case .comfortable: 9
        case .spacious: 13
        }
    }

    func composerMaxWidth() -> CGFloat {
        switch composerLayoutDensity() {
        case .compact: 680
        case .comfortable: 760
        case .spacious: 840
        }
    }

    func composerHorizontalPadding() -> CGFloat {
        switch composerLayoutDensity() {
        case .compact: 18
        case .comfortable: 28
        case .spacious: 36
        }
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

    private func runCLIInstall(provider: String, progress: String, executableName: String, action: @escaping () async -> (status: Int32, output: Data)) {
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

    private func runCLIUpdate(
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

    private static func commandOutput(_ executable: String, _ arguments: [String]) async -> String? {
        let result = await runCommand(executable, arguments)
        guard result.status == 0 else { return nil }
        let value = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func hermesUpdateInfo() async -> CLIUpdateInfo {
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

    private static func hermesUpdateCheck() async -> CLIUpdateInfo {
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

    private static func runDetectedCLIUpdate(
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

    private static func cliInstallSource(
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

    private static func pathLooksHomebrewManaged(_ path: String) async -> Bool {
        guard !path.isEmpty else { return false }
        if path.hasPrefix("/opt/homebrew/") || path.hasPrefix("/usr/local/") { return true }
        guard let prefix = await commandOutput("brew", ["--prefix"]) else { return false }
        return path.hasPrefix(prefix)
    }

    private static func executablePathLooksNPMManaged(_ path: String) async -> Bool {
        guard !path.isEmpty, let prefix = await commandOutput("npm", ["config", "get", "prefix"]) else { return false }
        return path.hasPrefix(prefix)
    }

    private static func executablePathLooksPNPMManaged(_ path: String) async -> Bool {
        guard !path.isEmpty, let bin = await commandOutput("pnpm", ["bin", "-g"]) else { return false }
        return path.hasPrefix(bin)
    }

    private static func isHomebrewFormulaInstalled(_ name: String) async -> Bool {
        await runCommand("brew", ["list", "--formula", name]).status == 0
    }

    private static func isHomebrewCaskInstalled(_ name: String) async -> Bool {
        await runCommand("brew", ["list", "--cask", name]).status == 0
    }

    private static func isNPMGlobalPackageInstalled(_ name: String) async -> Bool {
        await runCommand("npm", ["list", "-g", "--depth=0", name]).status == 0
    }

    private static func isPNPMGlobalPackageInstalled(_ name: String) async -> Bool {
        await runCommand("pnpm", ["list", "-g", "--depth=0", name]).status == 0
    }

    private static func latestCLIVersion(
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

    private static func homebrewInstalledFormulaVersion(_ name: String) async -> String? {
        guard let output = await commandOutput("brew", ["list", "--formula", "--versions", name]) else { return nil }
        let parts = output.split { $0.isWhitespace }.map(String.init)
        return parts.dropFirst().first
    }

    private static func homebrewLatestFormulaVersion(_ name: String) async -> String? {
        guard let output = await commandOutput("brew", ["info", "--json=v2", name]) else { return nil }
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let formulae = root["formulae"] as? [[String: Any]],
              let versions = formulae.first?["versions"] as? [String: Any],
              let stable = versions["stable"] as? String,
              !stable.isEmpty else { return nil }
        return stable
    }

    private static func homebrewLatestCaskVersion(_ name: String) async -> String? {
        guard let output = await commandOutput("brew", ["info", "--json=v2", "--cask", name]) else { return nil }
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let casks = root["casks"] as? [[String: Any]],
              let raw = casks.first?["version"] as? String,
              !raw.isEmpty else { return nil }
        return raw.split(separator: ",").first.map(String.init) ?? raw
    }

    private static func runRemoteInstallerScript(_ urlString: String) async -> (status: Int32, output: Data) {
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

    private static func runAntigravityLogin() async -> (status: Int32, output: Data) {
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

    private static func runCommand(
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
            openCodeAPIKeySaved = false
            cliActionMessages["opencode"] = error.message
        case .success:
            openCodeAPIKeySaved = true
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
        KeychainStore.delete(account: OpenCodeCredentialPolicy.keychainAccount)
        openCodeAPIKeySaved = false
        openCodeCredentialEnabledModes.removeAll()
        validatedPiOpenCodeModels.removeAll()
        validatedHermesOpenCodeModels.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.openCodeCredentialModesKey)
        openCodeAPIKeyDraft = ""
        Task { await refreshConnections() }
    }

    private func invalidateRuntimeAuthenticationValidations() {
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

    private func validBackend(_ backend: ChatBackend) -> ChatBackend {
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

    private func validBackend(_ backend: ChatBackend, privacyMode: SessionPrivacyMode) -> ChatBackend {
        let valid = validBackend(backend)
        guard privacyMode == .localOnly else { return valid }
        if valid.isLocal { return valid }
        if backend.isLocal { return localBackendFallback() }
        return localBackendFallback()
    }

    private func localBackendFallback() -> ChatBackend {
        if appleIntelligenceReady { return .appleIntelligence }
        if ollamaCatalogStatus == .loaded, let model = ollamaModels.first?.name { return .ollama(model: model) }
        return .ollama(model: "")
    }

    private func normalizeBackendsAfterCatalogRefresh() {
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
            if sessions[index].privacyMode == .localOnly {
                let valid = validBackend(sessions[index].backend, privacyMode: .localOnly)
                if valid != sessions[index].backend {
                    sessions[index].backend = valid
                    sessions[index].harnessID = Self.defaultHarnessID(for: valid)
                    sessions[index].reasoningEffort = defaultReasoning(for: valid, harnessID: sessions[index].harnessID)
                    sessions[index].harnessThreadID = nil
                    didChangeSessions = true
                }
            } else if let preferredCodex, case .codex(let model) = sessions[index].backend, shouldReplaceStaleCodexModel(model, preferred: preferredCodex.id) {
                sessions[index].backend = .codex(model: preferredCodex.id)
                sessions[index].harnessID = Self.defaultHarnessID(for: sessions[index].backend)
                sessions[index].reasoningEffort = defaultReasoning(for: sessions[index].backend, harnessID: sessions[index].harnessID)
                sessions[index].harnessThreadID = nil
                didChangeSessions = true
            } else {
                let valid = validBackend(sessions[index].backend)
                if valid != sessions[index].backend {
                    sessions[index].backend = valid
                    sessions[index].harnessID = Self.defaultHarnessID(for: valid)
                    sessions[index].reasoningEffort = defaultReasoning(for: valid, harnessID: sessions[index].harnessID)
                    sessions[index].harnessThreadID = nil
                    didChangeSessions = true
                }
            }
        }
        if didChangeSessions { persist() }
    }

    private func normalizeExecutionRouteAfterCatalogRefresh() {
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

    private func shouldReplaceStaleCodexModel(_ model: String, preferred: String) -> Bool {
        guard model != preferred else { return false }
        if !visibleCodexModels.contains(where: { $0.id == model }) { return true }
        return model.localizedCaseInsensitiveContains("5.4") && preferred.localizedCaseInsensitiveContains("5.5")
    }

    private static func loadDefaultBackend() -> ChatBackend? {
        guard let data = UserDefaults.standard.data(forKey: defaultBackendKey) else { return nil }
        return try? JSONDecoder().decode(ChatBackend.self, from: data)
    }

    private static func defaultWorkspacePath(processDirectory: String) -> String {
        if processDirectory != "/" { return processDirectory }
        return defaultAppSupportWorkspacePath()
    }

    private static func isImplicitDeveloperWorkspace(_ path: String?) -> Bool {
        guard let path else { return false }
        let desktop = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop")
        let candidates = ["Lattice"].map { desktop.appendingPathComponent($0).standardizedFileURL }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL
        return candidates.contains(standardized)
    }

    private static func defaultAppSupportWorkspacePath() -> String {
        LatticeApplicationSupport.migrateLegacyProductDataIfNeeded()
        let workspace = LatticeApplicationSupport.productRootURL().appendingPathComponent("Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        return workspace.path
    }

    private static func ollamaAppURL() -> URL? {
        let candidates = [
            URL(fileURLWithPath: "/Applications/Ollama.app"),
            URL(fileURLWithPath: "\(NSHomeDirectory())/Applications/Ollama.app")
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func saveDefaultBackend() {
        guard let data = try? JSONEncoder().encode(defaultBackend) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultBackendKey)
    }

    private func syncExecutionRoute(from backend: ChatBackend) {
        selectedRouteEngineID = Self.engineID(for: backend)
        selectedRouteHarnessID = Self.defaultHarnessID(for: backend)
    }

    private static func engineID(for backend: ChatBackend) -> String {
        switch backend {
        case .codex: "codex"
        case .grok: "grok"
        case .openCode: "opencode"
        case .appleIntelligence: "apple"
        case .ollama: "ollama"
        case .antigravity: "antigravity"
        }
    }

    private static func defaultHarnessID(for backend: ChatBackend) -> String {
        switch backend {
        case .codex: "codex"
        case .grok: "grok"
        case .openCode: "opencode"
        case .appleIntelligence, .ollama: "lattice"
        case .antigravity: "antigravity"
        }
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

    private func backendForRouteEngine(_ engineID: String, harnessID: String? = nil) -> ChatBackend? {
        if let harnessID {
            return candidateBackends(for: engineID).first { backend in
                if harnessID == "pi" { return piRoute(for: backend) != nil }
                if harnessID == "hermes" { return hermesMatch(for: backend) != nil }
                return true
            }
        }
        return candidateBackends(for: engineID).first
    }

    private func candidateBackends(for engineID: String) -> [ChatBackend] {
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

    private func effectiveHarnessID(for session: LatticeSession) -> String {
        session.harnessID ?? Self.defaultHarnessID(for: session.backend)
    }

    private func piRoute(for backend: ChatBackend) -> (provider: String, model: String)? {
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

    private func hermesMatch(for backend: ChatBackend) -> HarnessModel? {
        guard case .openCode(let model) = backend else { return nil }
        return HermesACPHarness.bestMatch(for: model, in: hermesModels)
    }

    private func apply(_ event: AgentEvent, to id: UUID, runID: UUID) {
        guard activeRunIDs[id] == runID else { return }
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let backend = sessions[index].backend
        switch event {
        case .sessionStarted: break
        case .harnessSessionStarted(let threadID):
            sessions[index].harnessThreadID = threadID
            persist()
        case .harnessSessionRecovery(let detail):
            sessions[index].harnessThreadID = nil
            setActivity([.init(icon: "arrow.triangle.2.circlepath", title: "Provider session recovery", detail: detail)], sessionID: id)
            persist()
        case .assistantDelta(let delta):
            guard sessions[index].isStreaming,
                  sessions[index].messages.last?.role == .assistant else { return }
            sessions[index].messages[sessions[index].messages.count - 1].text += delta
            sessions[index].lastUpdated = .now
            scheduleStreamingPersist()
        case .plan(let actionID, let title, let steps):
            guard let messageID = sessions[index].messages.last(where: { $0.role == .assistant })?.id else { return }
            upsertSessionAction(.init(
                id: actionID,
                messageID: messageID,
                kind: .plan,
                title: title,
                detail: steps.joined(separator: "\n"),
                status: .running
            ), at: index)
        case .reasoningSummary(let actionID, let delta):
            guard let messageID = sessions[index].messages.last(where: { $0.role == .assistant })?.id else { return }
            if SessionActionTrail.appendDetail(id: actionID, delta: delta, in: &sessions[index].actions) {
                sessions[index].lastUpdated = .now
                scheduleStreamingPersist()
            } else {
                upsertSessionAction(.init(
                    id: actionID,
                    messageID: messageID,
                    kind: .reasoning,
                    title: "Reasoning summary",
                    detail: delta,
                    status: .running
                ), at: index)
            }
        case .toolRequested(let request):
            guard let messageID = sessions[index].messages.last(where: { $0.role == .assistant })?.id else { return }
            upsertSessionAction(.init(
                id: request.id,
                messageID: messageID,
                kind: .tool,
                toolKind: request.kind,
                title: request.title,
                detail: request.detail,
                status: .running,
                workspaceScoped: request.workspaceScoped
            ), at: index)
        case .toolProgress(let toolID, _, let detail):
            updateSessionAction(id: toolID, status: detail == "Failed" ? .failed : (detail == "Cancelled" ? .cancelled : (detail == "Completed" ? .completed : .running)), at: index)
        case .permissionRequested(let request):
            let harnessID = effectiveHarnessID(for: sessions[index])
            let notice = HarnessPermissionNotice(
                sessionID: id,
                harnessID: harnessID,
                providerName: harnessID == "codex" ? "Codex" : (harnessID == "grok" ? "Grok" : (harnessID == "opencode" ? "OpenCode" : (harnessID == "pi" ? "Pi" : "Hermes"))),
                request: request
            )
            let automaticDecision = request.toolRequest.map { policyEngine.evaluate($0, under: sessions[index].policy) }
            let policyReason: String = {
                switch automaticDecision {
                case .allow(let reason), .requireApproval(let reason), .deny(let reason): return reason
                case nil: return "The provider requested an explicit permission decision."
                }
            }()
            if let messageID = sessions[index].messages.last(where: { $0.role == .assistant })?.id {
                upsertSessionAction(.init(
                    id: request.id,
                    messageID: messageID,
                    kind: .approval,
                    toolKind: request.toolRequest?.kind,
                    title: request.title,
                    detail: request.detail,
                    status: .waiting,
                    workspaceScoped: request.toolRequest?.workspaceScoped ?? false,
                    approvalProvenance: .init(
                        harnessID: harnessID,
                        providerName: notice.providerName,
                        requestID: request.id,
                        requestedOptionKinds: request.options.map(\.kind),
                        toolKind: request.toolRequest?.kind,
                        workspaceScoped: request.toolRequest?.workspaceScoped ?? false,
                        policy: sessions[index].policy,
                        policyReason: policyReason,
                        actor: .user
                    )
                ), at: index)
            }
            let automaticResolution = AutomaticPermissionResolutionPolicy.resolve(
                decision: automaticDecision,
                policy: sessions[index].policy,
                options: request.options
            )
            switch automaticResolution {
            case .forward(let optionID, let allowed):
                guard forwardHarnessPermission(notice, optionID: optionID) else {
                    harnessPermissionNotices[id] = nil
                    updateApprovalProvenance(
                        id: request.id,
                        sessionIndex: index,
                        actor: .automatic,
                        selectedOptionKind: request.options.first(where: { $0.id == optionID })?.kind,
                        outcome: .failed,
                        providerAcknowledgement: .rejectedByHarness
                    )
                    updateSessionAction(id: request.id, status: allowed ? .cancelled : .denied, at: index)
                    sessions[index].isStreaming = false
                    activeRunIDs[id] = nil
                    reduceRunUI(.failed("The provider rejected Lattice's automatic permission decision."), for: id)
                    cancelHarnessProcess(for: sessions[index], sessionID: id)
                    persist()
                    return
                }
                updateApprovalProvenance(
                    id: request.id,
                    sessionIndex: index,
                    actor: .automatic,
                    selectedOptionKind: request.options.first(where: { $0.id == optionID })?.kind,
                    outcome: .forwarded,
                    providerAcknowledgement: .acceptedByHarness
                )
                updateSessionAction(id: request.id, status: allowed ? .allowed : .denied, at: index)
                setActivity([.init(icon: allowed ? "checkmark.shield" : "xmark.shield", title: allowed ? "Allowed by \(sessions[index].policy.rawValue.capitalized) mode" : "Blocked by policy", detail: request.title)], sessionID: id)
                reduceRunUI(.permissionResolved, for: id)
            case .denyFailClosed(let reason):
                let cancellationForwarded = forwardHarnessPermission(notice, optionID: nil)
                harnessPermissionNotices[id] = nil
                updateApprovalProvenance(
                    id: request.id,
                    sessionIndex: index,
                    actor: .automatic,
                    outcome: cancellationForwarded ? .forwarded : .failed,
                    providerAcknowledgement: cancellationForwarded ? .acceptedByHarness : .unavailable
                )
                updateSessionAction(id: request.id, status: .denied, at: index)
                sessions[index].isStreaming = false
                activeRunIDs[id] = nil
                reduceRunUI(.failed("Blocked by Lattice policy: \(reason)"), for: id)
                cancelHarnessProcess(for: sessions[index], sessionID: id)
                persist()
            case .requestUser:
                harnessPermissionNotices[id] = notice
                setActivity([.init(icon: "hand.raised.fill", title: request.title, detail: "Waiting for your decision")], sessionID: id)
                reduceRunUI(.permissionRequested, for: id)
            }
        case .metric: break
        case .providerDiagnostic(let diagnostic):
            upsertActivity(.init(icon: "exclamationmark.triangle", title: diagnostic.title, detail: diagnostic.detail), sessionID: id)
            if let action = ProviderDiagnosticRetentionPolicy.action(
                for: diagnostic,
                assistantMessageID: sessions[index].messages.last(where: { $0.role == .assistant })?.id
            ) {
                upsertSessionAction(action, at: index)
                persist()
            }
        case .completed:
            activeRunIDs[id] = nil
            harnessPermissionNotices[id] = nil
            finishCompletedTurnActions(at: index)
            sessions[index].isStreaming = false
            reduceRunUI(.completed, for: id)
            let request = submittedRequests[id]
            if selfEditRunIDs.remove(id) != nil {
                _ = prepareGeneratedExtensionPreview(at: index, request: request)
            }
            submittedRequests[id] = nil
            retryableRequests[id] = nil
            if runNextQueuedFollowUpIfPossible(for: id) { return }
            persist()
            scheduleIdleUnloadIfNeeded(for: backend)
        case .cancelled:
            activeRunIDs[id] = nil
            harnessPermissionNotices[id] = nil
            selfEditRunIDs.remove(id)
            finishPendingActions(status: .cancelled, at: index)
            sessions[index].isStreaming = false
            if let request = submittedRequests[id] { retryableRequests[id] = request }
            submittedRequests[id] = nil
            reduceRunUI(.cancelled, for: id)
            persist()
            scheduleIdleUnloadIfNeeded(for: backend)
        case .failed(let message):
            activeRunIDs[id] = nil
            harnessPermissionNotices[id] = nil
            selfEditRunIDs.remove(id)
            if let request = submittedRequests[id] { retryableRequests[id] = request }
            submittedRequests[id] = nil
            let timedOut = message == "Permission request timed out."
            finishPendingActions(
                status: .failed,
                at: index,
                approvalOutcome: timedOut ? .timedOut : .failed,
                providerAcknowledgement: timedOut ? .timedOut : .unavailable
            )
            sessions[index].isStreaming = false
            reduceRunUI(.failed(message), for: id)
            if sessions[index].messages.last?.text.isEmpty == true { sessions[index].messages.removeLast() }
            persist()
            scheduleIdleUnloadIfNeeded(for: backend)
        }
    }

    private func updateApprovalProvenance(
        id: UUID,
        sessionIndex: Int,
        actor: ApprovalProvenance.Actor? = nil,
        selectedOptionKind: String? = nil,
        outcome: ApprovalProvenance.Outcome? = nil,
        providerAcknowledgement: ApprovalProvenance.ProviderAcknowledgement? = nil
    ) {
        guard let actionIndex = sessions[sessionIndex].actions.firstIndex(where: { $0.id == id }),
              var provenance = sessions[sessionIndex].actions[actionIndex].approvalProvenance else { return }
        if let actor { provenance.actor = actor }
        if let selectedOptionKind { provenance.selectedOptionKind = selectedOptionKind }
        if let outcome { provenance.outcome = outcome }
        if let providerAcknowledgement { provenance.providerAcknowledgement = providerAcknowledgement }
        provenance.updatedAt = .now
        sessions[sessionIndex].actions[actionIndex].approvalProvenance = provenance
        sessions[sessionIndex].lastUpdated = .now
    }

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

    private func applyRecoveredSessions(_ loaded: [LatticeSession]) {
        var loadedSessions = loaded
        var migratedSessions = false
        let cwd = selectedWorkspacePath
        for index in loadedSessions.indices where loadedSessions[index].workspacePath == "/" || (loadedSessions[index].workspacePath == NSHomeDirectory() && loadedSessions[index].messages.isEmpty) || (Self.isImplicitDeveloperWorkspace(loadedSessions[index].workspacePath) && loadedSessions[index].messages.isEmpty) {
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
        if let first = sessions.first, let path = first.workspacePath, !Self.isImplicitDeveloperWorkspace(path) {
            selectedWorkspacePath = path
        }
        if migratedSessions {
            // Coordinator-aware: gate-blocked is silent; real write failures surface as save failures.
            _ = sessionSaveCoordinator.saveNow(loadedSessions)
            sessionSaveFailure = sessionSaveCoordinator.currentFailure
        }
    }

    private func resolvePersistenceRecovery(storeID: String, gate: DurableStoreWriteGate) {
        gate.unblock()
        persistenceRecoveryIssues.removeAll { $0.storeID == storeID }
        expandedPersistenceRecoveryDetailIDs.remove(storeID)
    }

    private func replacePersistenceRecoveryIssue(_ issue: DurableStoreIssue) {
        if let index = persistenceRecoveryIssues.firstIndex(where: { $0.storeID == issue.storeID }) {
            persistenceRecoveryIssues[index] = issue
        } else {
            persistenceRecoveryIssues.append(issue)
        }
    }

    /// Immediate durable write at a safe boundary. Cancels/absorbs any pending debounced draft write.
    private func persist() {
        // Coordinator enforces the load-recovery write gate and reports real save failures.
        _ = sessionSaveCoordinator.saveNow(sessions)
        // Keep published failure in sync for synchronous MainActor paths (observer may be async).
        sessionSaveFailure = sessionSaveCoordinator.currentFailure
        if sessionSaveFailure == nil {
            expandedSessionSaveFailureDetails = false
        }
    }

    /// Load `text` into the shared composer without treating it as a user edit of the ordinary draft.
    private func applyComposerDraft(_ text: String) {
        isApplyingComposerDraft = true
        draft = text
        isApplyingComposerDraft = false
    }

    private func syncOrdinaryDraftToSelectedSessionIfNeeded() {
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
    private func forceSyncOrdinaryDraftToSelectedSession() {
        guard !isApplyingComposerDraft else { return }
        guard editingMessageContext == nil else { return }
        guard let id = selectedSessionID,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].draft != draft {
            sessions[index].draft = draft
        }
    }

    private func scheduleDraftPersist() {
        // Coalesced 250 ms draft durability via the save coordinator.
        sessionSaveCoordinator.scheduleDraftSnapshot(sessions)
    }

    private func scheduleSelectionPersist() {
        // Thread switching can happen repeatedly while scanning a session list;
        // coalescing avoids synchronous JSON serialization on the main actor.
        sessionSaveCoordinator.scheduleDebounced(sessions)
    }

    private func scheduleStreamingPersist() {
        // Partial assistant text and progress must survive a crash without rewriting the full
        // session archive for every token or provider progress notification.
        sessionSaveCoordinator.scheduleStreamingSnapshot(sessions)
    }

    /// Pure-policy selection apply: flush previous ordinary draft, restore/cancel edit without didSet races, load next draft.
    private func applyComposerSessionSelection(from previousID: UUID?, to nextID: UUID?) {
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

    private func upsertSessionAction(_ action: SessionAction, at sessionIndex: Int) {
        SessionActionTrail.upsert(action, in: &sessions[sessionIndex].actions)
        sessions[sessionIndex].lastUpdated = .now
        if action.status == .waiting {
            persist()
        } else {
            scheduleStreamingPersist()
        }
    }

    private func updateSessionAction(id actionID: UUID, status: SessionAction.Status, at sessionIndex: Int) {
        guard SessionActionTrail.update(id: actionID, status: status, in: &sessions[sessionIndex].actions) else { return }
        sessions[sessionIndex].lastUpdated = .now
        if status == .running {
            scheduleStreamingPersist()
        } else {
            persist()
        }
    }

    private func updateSessionAction(id actionID: UUID, status: SessionAction.Status, sessionID: UUID) {
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        updateSessionAction(id: actionID, status: status, at: sessionIndex)
    }

    private func finishPendingActions(
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

    private func finishCompletedTurnActions(at sessionIndex: Int) {
        guard let messageID = sessions[sessionIndex].messages.last(where: { $0.role == .assistant })?.id else { return }
        finalizePendingApprovalProvenance(
            at: sessionIndex,
            outcome: .cancelled,
            providerAcknowledgement: .cancelled
        )
        if SessionActionTrail.finishCompletedTurn(for: messageID, in: &sessions[sessionIndex].actions) > 0 { persist() }
    }

    private func finalizePendingApprovalProvenance(
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

    private func setActivity(_ items: [ActivityItem], sessionID: UUID) {
        reduceRunUI(.setActivity(items), for: sessionID)
    }

    private func upsertActivity(_ item: ActivityItem, sessionID: UUID) {
        reduceRunUI(.upsertActivity(item), for: sessionID)
    }

    private func clearActivity(for sessionID: UUID? = nil) {
        guard let sessionID = sessionID ?? selectedSessionID else { return }
        reduceRunUI(.clearActivity, for: sessionID)
    }

    private func setActiveComposerState(_ state: MorphingControlState, sessionID: UUID) {
        reduceRunUI(.setComposerState(state), for: sessionID)
    }

    private func clearActiveComposerState(for sessionID: UUID? = nil) {
        guard let sessionID = sessionID ?? selectedSessionID else { return }
        reduceRunUI(.setComposerState(.expanded), for: sessionID)
    }

    private func setError(_ message: String, sessionID: UUID? = nil) {
        if let sessionID {
            reduceRunUI(.setError(message), for: sessionID)
        } else {
            globalErrorMessage = message
        }
    }

    private func clearError() {
        globalErrorMessage = nil
        if let selectedSessionID {
            reduceRunUI(.clearError, for: selectedSessionID)
        }
    }

    private static func activityIcon(for kind: ToolRequest.Kind) -> String {
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

    private func startResourceMonitoring() {
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

    private func scheduleIdleUnloadIfNeeded(for backend: ChatBackend) {
        guard case .ollama(let model) = backend else { return }
        scheduleLocalModelIdleUnload(model: model)
    }

    private func scheduleLocalModelIdleUnload(model: String) {
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

    private func cancelLocalModelIdleUnload() {
        localModelIdleUnloadTask?.cancel()
        localModelIdleUnloadTask = nil
    }

    private func unloadLocalModel(_ model: String, reason: String) async {
        await ollama.unload(model: model)
        localModelStatus = reason
        localModelIdleUnloadTask = nil
    }

    private func unloadActiveLocalModel(reason: String) async {
        cancelLocalModelIdleUnload()
        await ollama.unloadActive()
        localModelStatus = reason
    }
}
