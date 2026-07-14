import Testing
@testable import LatticeCore

@Suite("Catalog presentation policy")
struct CatalogPresentationPolicyTests {

    @Test func extensionToggleIsRecordSpecific() {
        let on = CatalogToggleAccessibility.extensionToggle(
            name: "Theme Pack",
            isEnabled: true,
            isValid: true,
            hasRuntimePatches: true,
            validationMessages: []
        )
        #expect(on.label == "Theme Pack extension")
        #expect(on.value == "On")
        #expect(on.disabledReason == nil)
        #expect(on.hint.contains("Disable"))

        let invalid = CatalogToggleAccessibility.extensionToggle(
            name: "Broken",
            isEnabled: false,
            isValid: false,
            hasRuntimePatches: true,
            validationMessages: ["Missing permissions"]
        )
        #expect(invalid.label == "Broken extension")
        #expect(invalid.value == "Off")
        #expect(invalid.disabledReason == "Extension is invalid: Missing permissions")
        #expect(CatalogToggleAccessibility.spokenValue(invalid).contains("Missing permissions"))
    }

    @Test func skillToggleSurfacesOwnerDisabledReason() {
        let tokens = CatalogToggleAccessibility.skillToggle(
            title: "Hatch Pet",
            isEnabled: false,
            isValid: true,
            canToggle: false,
            ownerDisabledMessage: "Enable Theme Pack to use this skill.",
            validationMessages: []
        )
        #expect(tokens.label == "Hatch Pet skill")
        #expect(tokens.value == "Off")
        #expect(tokens.hint == "Enable Theme Pack to use this skill.")
        #expect(tokens.disabledReason == "Enable Theme Pack to use this skill.")
    }

    @Test func progressiveDisclosureKeepsCollapsedPrefix() {
        #expect(CatalogProgressiveDisclosure.displayedCount(total: 10, expanded: false, collapsedLimit: 3) == 3)
        #expect(CatalogProgressiveDisclosure.remainingHiddenCount(total: 10, expanded: false, collapsedLimit: 3) == 7)
        #expect(CatalogProgressiveDisclosure.displayedCount(total: 2, expanded: false, collapsedLimit: 3) == 2)
        #expect(CatalogProgressiveDisclosure.displayedCount(total: 10, expanded: true, collapsedLimit: 3) == 10)
        #expect(CatalogProgressiveDisclosure.showMoreTitle(hiddenCount: 1) == "Show 1 more")
        #expect(CatalogProgressiveDisclosure.showMoreTitle(hiddenCount: 4) == "Show 4 more")
        #expect(CatalogProgressiveDisclosure.modelVisibilitySectionTitle(modelCount: 1) == "Model visibility (1)")
        #expect(CatalogProgressiveDisclosure.modelVisibilitySectionTitle(modelCount: 5) == "Model visibility (5)")
    }

    @Test func emptyStatesUseExistingActionTitlesOnly() {
        let extensions = CatalogEmptyStatePolicy.copy(for: .extensions)
        #expect(extensions.primaryActionTitle == "Open Folder")
        #expect(extensions.secondaryActionTitle == "Refresh")

        let hidden = CatalogEmptyStatePolicy.copy(for: .providerModelsHidden, providerName: "Codex")
        #expect(hidden.title.contains("Codex"))
        #expect(hidden.primaryActionTitle == "Open Connections")
        #expect(hidden.secondaryActionTitle == nil)

        let none = CatalogEmptyStatePolicy.copy(for: .noConnectedProviderModels)
        #expect(none.primaryActionTitle == "Open Connections")
        #expect(none.secondaryActionTitle == "Refresh")
    }

    @Test func catalogFailureAndValidEmptyStayDistinct() {
        let failed = ProviderCatalogResult<String>(models: [], succeeded: false)
        let empty = ProviderCatalogResult<String>(models: [], succeeded: true)
        #expect(failed.models.isEmpty)
        #expect(empty.models.isEmpty)
        #expect(failed.status == .failed)
        #expect(empty.status == .empty)

        let failedCopy = ProviderReadinessPresentationPolicy.copy(
            providerName: "Codex",
            readiness: ProviderReadinessSnapshot(installed: true, authenticated: true, catalogStatus: failed.status, runnableModelCount: 0)
        )
        let emptyCopy = ProviderReadinessPresentationPolicy.copy(
            providerName: "Codex",
            readiness: ProviderReadinessSnapshot(installed: true, authenticated: true, catalogStatus: empty.status, runnableModelCount: 0)
        )
        #expect(failedCopy.detail.contains("catalog unavailable"))
        #expect(emptyCopy.detail.contains("no Codex models found"))
        #expect(!failedCopy.isReady)
        #expect(!emptyCopy.isReady)
    }

    @Test func privacyCopyIsWriteContainedNotConfidentialityContained() {
        let body = LatticeSettingsCopy.privacySecurityBody
        #expect(body.contains("workspace write containment") || body.contains("write containment"))
        #expect(body.contains("not confidentiality-contained"))
        #expect(body.localizedCaseInsensitiveContains("network"))
    }

    @Test func onboardingNavigationIsLinearWithoutHiddenSideEffects() {
        #expect(LatticeOnboardingStep.allCases.count == 4)
        #expect(LatticeOnboardingNavigation.first == .welcome)
        #expect(LatticeOnboardingNavigation.last == .ready)
        #expect(!LatticeOnboardingNavigation.canGoBack(from: .welcome))
        #expect(LatticeOnboardingNavigation.canContinue(from: .welcome))
        #expect(LatticeOnboardingNavigation.advancing(from: .welcome) == .chooseWorkspace)
        #expect(LatticeOnboardingNavigation.advancing(from: .localVersusCloud) == .ready)
        #expect(LatticeOnboardingNavigation.advancing(from: .ready) == .ready)
        #expect(LatticeOnboardingNavigation.retreating(from: .welcome) == .welcome)
        #expect(LatticeOnboardingNavigation.retreating(from: .ready) == .localVersusCloud)
        #expect(LatticeOnboardingNavigation.primaryActionTitle(for: .welcome) == "Continue")
        #expect(LatticeOnboardingNavigation.primaryActionTitle(for: .ready) == "Finish")
        #expect(LatticeOnboardingNavigation.showsSkip(for: .chooseWorkspace))
        #expect(!LatticeOnboardingNavigation.showsSkip(for: .ready))
        #expect(!LatticeOnboardingStep.welcome.body.isEmpty)
        #expect(LatticeOnboardingStep.ready.headingIdentifier.contains("3"))
    }

    @Test func commandSuggestionsHaveABoundedScrollableViewport() {
        #expect(CommandSuggestionLayoutPolicy.height(resultCount: 0) == 0)
        #expect(CommandSuggestionLayoutPolicy.height(resultCount: 1) == CommandSuggestionLayoutPolicy.estimatedRowHeight)
        #expect(CommandSuggestionLayoutPolicy.height(resultCount: 7) == 378)
        #expect(CommandSuggestionLayoutPolicy.height(resultCount: 100) == 378)
    }
}
