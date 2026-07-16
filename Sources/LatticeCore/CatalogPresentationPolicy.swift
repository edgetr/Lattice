import Foundation

// MARK: - Extension / skill toggle accessibility

/// Record-specific accessibility tokens for extension and skill enablement switches.
/// Pure string policy — views apply labels/values/hints and surface disabled reasons.
public enum CatalogToggleAccessibility: Sendable {
    public struct Tokens: Equatable, Sendable {
        public let label: String
        public let value: String
        public let hint: String
        /// Spoken when the control is disabled; nil when enabled for interaction.
        public let disabledReason: String?

        public init(label: String, value: String, hint: String, disabledReason: String?) {
            self.label = label
            self.value = value
            self.hint = hint
            self.disabledReason = disabledReason
        }
    }

    public static func extensionToggle(
        name: String,
        isEnabled: Bool,
        isValid: Bool,
        hasRuntimePatches: Bool,
        validationMessages: [String]
    ) -> Tokens {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "Untitled extension" : trimmed
        let label = "\(displayName) extension"
        let value = isEnabled ? "On" : "Off"
        let hint: String
        if !isValid {
            hint = "Extension failed validation and cannot be enabled."
        } else if !hasRuntimePatches {
            hint = "This extension has no active changes to enable."
        } else {
            hint = isEnabled
                ? "Disable to stop applying this extension’s changes."
                : "Enable to apply this extension’s changes."
        }
        let disabledReason: String?
        if !isValid {
            let detail = validationMessages
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            disabledReason = detail.isEmpty
                ? "Extension is invalid and cannot be toggled."
                : "Extension is invalid: \(detail)"
        } else if !hasRuntimePatches {
            disabledReason = "No active changes to enable."
        } else {
            disabledReason = nil
        }
        return Tokens(label: label, value: value, hint: hint, disabledReason: disabledReason)
    }

    public static func skillToggle(
        title: String,
        isEnabled: Bool,
        isValid: Bool,
        canToggle: Bool,
        ownerDisabledMessage: String?,
        validationMessages: [String]
    ) -> Tokens {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmed.isEmpty ? "Untitled skill" : trimmed
        let label = "\(displayName) skill"
        let value = isEnabled ? "On" : "Off"
        let hint: String
        if let ownerDisabledMessage, !ownerDisabledMessage.isEmpty {
            hint = ownerDisabledMessage
        } else if !isValid {
            hint = "Skill failed validation and cannot be enabled."
        } else {
            hint = isEnabled
                ? "Disable to hide this skill from the command palette and composer."
                : "Enable to make this skill available in the command palette and composer."
        }
        let disabledReason: String?
        if canToggle {
            disabledReason = nil
        } else if let ownerDisabledMessage, !ownerDisabledMessage.isEmpty {
            disabledReason = ownerDisabledMessage
        } else if !isValid {
            let detail = validationMessages
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            disabledReason = detail.isEmpty
                ? "Skill is invalid and cannot be toggled."
                : "Skill is invalid: \(detail)"
        } else {
            disabledReason = "This skill cannot be toggled right now."
        }
        return Tokens(label: label, value: value, hint: hint, disabledReason: disabledReason)
    }

    /// Spoken accessibility value combining On/Off with an optional disabled reason.
    public static func spokenValue(_ tokens: Tokens) -> String {
        if let reason = tokens.disabledReason, !reason.isEmpty {
            return "\(tokens.value). \(reason)"
        }
        return tokens.value
    }
}

// MARK: - Progressive disclosure

/// Density rules for catalog lists. Readiness and primary actions stay outside disclosure.
public enum CatalogProgressiveDisclosure: Sendable {
    /// Default visible provider models before “Show more”.
    public static let collapsedProviderModelLimit = 3
    /// Default visible model-visibility checkboxes before expanding the full list.
    public static let collapsedModelVisibilityLimit = 4

    public static func displayedCount(total: Int, expanded: Bool, collapsedLimit: Int) -> Int {
        guard total > 0 else { return 0 }
        if expanded { return total }
        return min(total, max(0, collapsedLimit))
    }

    public static func remainingHiddenCount(total: Int, expanded: Bool, collapsedLimit: Int) -> Int {
        max(0, total - displayedCount(total: total, expanded: expanded, collapsedLimit: collapsedLimit))
    }

    public static func showMoreTitle(hiddenCount: Int) -> String {
        hiddenCount == 1 ? "Show 1 more" : "Show \(hiddenCount) more"
    }

    public static func showLessTitle() -> String { "Show less" }

    public static func modelVisibilitySectionTitle(modelCount: Int) -> String {
        modelCount == 1 ? "Model visibility (1)" : "Model visibility (\(modelCount))"
    }

    public static func providerDetailsTitle() -> String { "Details" }
    public static func recommendationDetailsTitle() -> String { "Fit details" }
}

// MARK: - Provider model configuration

/// Presentation-ready model visibility data. A selected model can remain here after it
/// disappears from the latest runtime catalog so the user's exact route is never hidden.
public struct ProviderModelConfigurationItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let detail: String
    public let isProviderDefault: Bool
    public let isDiscovered: Bool
    public let isEnabled: Bool
    public let isSelected: Bool

    public init(
        id: String,
        name: String,
        detail: String = "",
        isProviderDefault: Bool,
        isDiscovered: Bool,
        isEnabled: Bool,
        isSelected: Bool
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.isProviderDefault = isProviderDefault
        self.isDiscovered = isDiscovered
        self.isEnabled = isEnabled
        self.isSelected = isSelected
    }
}

/// View-model state for the explicit All models disclosure. Search text survives a
/// collapse/re-expand cycle, avoiding a surprising loss of keyboard-entered context.
public struct ProviderModelDisclosureState: Equatable, Sendable {
    public var isExpanded: Bool
    public var query: String

    public init(isExpanded: Bool = false, query: String = "") {
        self.isExpanded = isExpanded
        self.query = query
    }
}

public enum ProviderModelConfigurationPolicy: Sendable {
    public static let searchThreshold = 8

    public static func items(
        providerID: String,
        discoveredModels: [ProviderModel],
        disabledModelIDs: Set<String>,
        selectedModelIDs: Set<String>
    ) -> [ProviderModelConfigurationItem] {
        let selected = Set(selectedModelIDs.compactMap(normalizedIdentifier))
        let discoveredIDs = Set(discoveredModels.map(\.id))
        let discoveredItems = discoveredModels.map { model in
            let preferenceID = preferenceID(providerID: providerID, modelID: model.id)
            return ProviderModelConfigurationItem(
                id: model.id,
                name: model.name,
                detail: model.description,
                isProviderDefault: model.isDefault,
                isDiscovered: true,
                isEnabled: !disabledModelIDs.contains(preferenceID),
                isSelected: selected.contains(model.id)
            )
        }
        let unavailableSelections = selected
            .subtracting(discoveredIDs)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { modelID in
                ProviderModelConfigurationItem(
                    id: modelID,
                    name: modelID,
                    isProviderDefault: false,
                    isDiscovered: false,
                    isEnabled: !disabledModelIDs.contains(preferenceID(providerID: providerID, modelID: modelID)),
                    isSelected: true
                )
            }
        return discoveredItems + unavailableSelections
    }

    /// Only provider-reported metadata can establish a default. Ordering is not treated
    /// as a recommendation here, even if another execution fallback uses the first item.
    public static func providerDefault(in items: [ProviderModelConfigurationItem]) -> ProviderModelConfigurationItem? {
        items.first { $0.isDiscovered && $0.isProviderDefault }
    }

    public static func filtered(
        _ items: [ProviderModelConfigurationItem],
        query: String
    ) -> [ProviderModelConfigurationItem] {
        let terms = query
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        guard !terms.isEmpty else { return items }
        return items.filter { item in
            let haystack = "\(item.name) \(item.id) \(item.detail)".lowercased()
            return terms.allSatisfy(haystack.contains)
        }
    }

    /// Changes one model preference without rebuilding the set, preserving choices for
    /// other providers and models that are temporarily absent from discovery.
    public static func updatedDisabledModelIDs(
        _ disabledModelIDs: Set<String>,
        providerID: String,
        modelID: String,
        enabled: Bool
    ) -> Set<String> {
        var result = disabledModelIDs
        let id = preferenceID(providerID: providerID, modelID: modelID)
        if enabled { result.remove(id) }
        else { result.insert(id) }
        return result
    }

    public static func preferenceID(providerID: String, modelID: String) -> String {
        "\(providerID):\(modelID)"
    }

    private static func normalizedIdentifier(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Empty states (existing actions only)

public enum CatalogEmptyStateKind: String, Sendable, Equatable {
    case extensions
    case skills
    case providerModelsHidden
    case noConnectedProviderModels
    case noInstalledLocalModels
}

public struct CatalogEmptyStateCopy: Equatable, Sendable {
    public let title: String
    public let message: String
    public let primaryActionTitle: String?
    public let secondaryActionTitle: String?

    public init(title: String, message: String, primaryActionTitle: String?, secondaryActionTitle: String?) {
        self.title = title
        self.message = message
        self.primaryActionTitle = primaryActionTitle
        self.secondaryActionTitle = secondaryActionTitle
    }
}

public enum CatalogEmptyStatePolicy: Sendable {
    public static func copy(for kind: CatalogEmptyStateKind, providerName: String? = nil) -> CatalogEmptyStateCopy {
        switch kind {
        case .extensions:
            return CatalogEmptyStateCopy(
                title: "No extensions yet",
                message: "Extensions are user-owned packages in Lattice’s extensions folder. Open the folder to add a package, then Refresh.",
                primaryActionTitle: "Open Folder",
                secondaryActionTitle: "Refresh"
            )
        case .skills:
            return CatalogEmptyStateCopy(
                title: "No skills imported",
                message: "Lattice imports skills from ~/.codex/skills and ~/.agents/skills into its shared skills folder. Open the folder or Refresh after adding files. Generated /self-edit skills land here too.",
                primaryActionTitle: "Open Folder",
                secondaryActionTitle: "Refresh"
            )
        case .providerModelsHidden:
            let name = providerName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = (name?.isEmpty == false) ? name! : "this provider"
            return CatalogEmptyStateCopy(
                title: "All \(subject) models are hidden",
                message: "Model visibility is controlled in Connections. Turn models back on there, then return to Models.",
                primaryActionTitle: "Open Connections",
                secondaryActionTitle: nil
            )
        case .noConnectedProviderModels:
            return CatalogEmptyStateCopy(
                title: "No provider models available",
                message: "Sign in to a provider in Connections, or check again after signing in. Model installs never start automatically from this page.",
                primaryActionTitle: "Open Connections",
                secondaryActionTitle: "Check Again"
            )
        case .noInstalledLocalModels:
            return CatalogEmptyStateCopy(
                title: "No local chat models installed",
                message: "Install a recommended model below when Ollama is running, or Refresh after pulling models outside Lattice.",
                primaryActionTitle: "Refresh",
                secondaryActionTitle: nil
            )
        }
    }
}

// MARK: - Settings copy (truthful existing context only)

public enum LatticeSettingsCopy: Sendable {
    public static let overlayShortcutDisplay = "⌘⇧Space"
    public static let overlayShortcutExplanation =
        "Press ⌘⇧Space to show or hide the floating Lattice overlay while Lattice is running. The shortcut is registered by the app; this setting is informational."

    public static let localUnloadExplanation =
        "When idle unload is on, Lattice asks Ollama to unload the active local model after the chosen number of idle minutes. Set to Off to keep models loaded until Ollama’s own defaults apply."

    public static let privacySecurityBody =
        "Write containment is route- and policy-dependent, not universal. ACP and Lattice Agent harnesses use Lattice macOS write containment; Codex uses a provider-configured sandbox that can be read-only, workspace-write, or absent (YOLO danger-full-access); Antigravity only passes a provider sandbox option that Lattice does not independently verify. Live provider tools do not pass through LocalToolBroker, so broker credential denial does not apply on those paths. File reads and network are not confidentiality-contained where tools run—models and CLIs may still read outside the workspace or contact remote services. Prefer Local Only privacy on a chat when you need cloud routes blocked. Do not treat the sandbox as prompt-injection or exfiltration prevention."

    public static let extensionsFolderHelp =
        "Opens Lattice’s user extensions directory in Finder."
    public static let skillsFolderHelp =
        "Opens Lattice’s shared skills directory in Finder."
    public static let refreshModelsHelp =
        "Reloads locally discovered Ollama chat models without changing connections."
    public static let showOnboardingTitle = "Show Onboarding…"
    public static let showOnboardingHelp =
        "Reopen the first-run onboarding guide. Does not install software or change preferences by itself."
}

// MARK: - Onboarding step machine

public enum LatticeOnboardingStep: Int, CaseIterable, Sendable, Equatable, Comparable {
    case welcome = 0
    case chooseWorkspace = 1
    case localVersusCloud = 2
    case ready = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var title: String {
        switch self {
        case .welcome: "Welcome to Lattice"
        case .chooseWorkspace: "Choose a workspace"
        case .localVersusCloud: "Local vs cloud"
        case .ready: "You’re ready"
        }
    }

    public var body: String {
        switch self {
        case .welcome:
            return "Lattice is a macOS workspace for chatting with local and connected coding agents. This short guide explains the basics. Nothing is installed and no preferences change until you act."
        case .chooseWorkspace:
            return "A chat can use a folder as its workspace. Write containment depends on the route and execution policy—check Route & Safety before a run. You can choose a folder now or choose one later from the chat inspector."
        case .localVersusCloud:
            return "Local routes use Apple Intelligence or Ollama on this Mac and do not run delegated tools here. Cloud routes use signed-in providers such as Codex, Grok, and OpenCode. Per-chat model privacy can block cloud routes. Write containment, approvals, and tool mediation depend on the route and policy—they are not universal. Reads and network are not confidentiality-contained where tools run."
        case .ready:
            return "Open Connections to install runtimes, sign in to providers, and check availability. Use Models to pick a provider and model, check Route & Safety for the selected runtime’s limits, and use Extensions & Skills for your customizations. You can reopen this guide later from Settings."
        }
    }

    public var headingIdentifier: String { "lattice.onboarding.heading.\(rawValue)" }
}

public enum LatticeOnboardingNavigation: Sendable {
    public static var first: LatticeOnboardingStep { .welcome }
    public static var last: LatticeOnboardingStep { .ready }

    public static func canGoBack(from step: LatticeOnboardingStep) -> Bool {
        step > first
    }

    public static func canContinue(from step: LatticeOnboardingStep) -> Bool {
        step < last
    }

    public static func isFinish(step: LatticeOnboardingStep) -> Bool {
        step == last
    }

    public static func advancing(from step: LatticeOnboardingStep) -> LatticeOnboardingStep {
        LatticeOnboardingStep(rawValue: min(step.rawValue + 1, last.rawValue)) ?? last
    }

    public static func retreating(from step: LatticeOnboardingStep) -> LatticeOnboardingStep {
        LatticeOnboardingStep(rawValue: max(step.rawValue - 1, first.rawValue)) ?? first
    }

    public static func primaryActionTitle(for step: LatticeOnboardingStep) -> String {
        isFinish(step: step) ? "Finish" : "Continue"
    }

    public static func showsSkip(for step: LatticeOnboardingStep) -> Bool {
        !isFinish(step: step)
    }
}
