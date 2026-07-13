import SwiftUI
import LatticeCore

/// First-run / revisit onboarding. Independent of `AppState` — callers supply
/// bindings and actions. Performs no installs and writes no hidden preferences.
struct OnboardingView: View {
    @Binding var step: LatticeOnboardingStep
    /// Optional display path for the chosen workspace; onboarding never mutates prefs itself.
    var workspacePath: String?
    var onChooseWorkspace: () -> Void
    var onOpenConnections: (() -> Void)?
    var onBack: (() -> Void)?
    var onContinue: (() -> Void)?
    var onSkip: () -> Void
    var onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: OnboardingFocus?

    private enum OnboardingFocus: Hashable {
        case heading
        case primary
        case skip
        case back
        case chooseWorkspace
        case openConnections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progressChrome
                .padding(.bottom, 20)

            ScrollView {
                stepContent
                    .frame(maxWidth: 560, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().padding(.vertical, 12)
            footer
        }
        .padding(24)
        .frame(
            minWidth: 420,
            idealWidth: 560,
            maxWidth: .infinity,
            minHeight: 360,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .onAppear {
            moveFocusToHeading()
        }
        .onChange(of: step) { _, _ in
            moveFocusToHeading()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lattice onboarding")
    }

    // MARK: - Chrome

    private var progressChrome: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Step \(step.rawValue + 1) of \(LatticeOnboardingStep.allCases.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            ProgressView(
                value: Double(step.rawValue + 1),
                total: Double(LatticeOnboardingStep.allCases.count)
            )
            .progressViewStyle(.linear)
            .accessibilityLabel("Onboarding progress")
            .accessibilityValue("Step \(step.rawValue + 1) of \(LatticeOnboardingStep.allCases.count)")
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(step.title)
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
                .focusable(true)
                .focused($focusedField, equals: .heading)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(step.headingIdentifier)

            Text(step.body)
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            switch step {
            case .welcome:
                EmptyView()
            case .chooseWorkspace:
                workspaceStepExtras
            case .localVersusCloud:
                localCloudExtras
            case .ready:
                readyExtras
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: step)
    }

    private var workspaceStepExtras: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let workspacePath, !workspacePath.isEmpty {
                LabeledContent("Workspace") {
                    Text(workspacePath)
                        .font(.caption)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No workspace selected yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Choose Workspace…") {
                onChooseWorkspace()
            }
            .focused($focusedField, equals: .chooseWorkspace)
            .accessibilityHint("Opens a folder picker supplied by the host. Onboarding does not write preferences itself.")
            Text("Choosing a folder only runs the action the host provides. Skip if you prefer to set a workspace later from a chat.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LatticeMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.cardRadius, interactive: true)
    }

    private var localCloudExtras: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledBullet(
                title: "Local",
                detail: "Apple Intelligence and Ollama stay on this Mac. Idle unload for Ollama is configured in Settings."
            )
            labeledBullet(
                title: "Cloud / connected",
                detail: "Provider CLIs sign in under Connections. Per-chat privacy can block cloud routes."
            )
            labeledBullet(
                title: "Sandbox truth",
                detail: LatticeSettingsCopy.privacySecurityBody
            )
        }
        .padding(LatticeMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.cardRadius)
    }

    private var readyExtras: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Next steps")
                .font(.subheadline.weight(.semibold))
            if let onOpenConnections {
                Button("Open Connections") {
                    onOpenConnections()
                }
                .focused($focusedField, equals: .openConnections)
                .accessibilityHint("Switches to the Connections section when the host supplies this action.")
            } else {
                Text("Use the sidebar Connections section when you are ready to sign in or install provider CLIs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Finish closes this guide. Lattice will not run installers or change preferences from this screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(LatticeMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: LatticeMetrics.cardRadius, interactive: true)
    }

    private func labeledBullet(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if LatticeOnboardingNavigation.canGoBack(from: step) {
                Button("Back") { goBack() }
                    .focused($focusedField, equals: .back)
                    .accessibilityHint("Return to the previous onboarding step.")
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }
            Spacer(minLength: 8)
            if LatticeOnboardingNavigation.showsSkip(for: step) {
                Button("Skip") { onSkip() }
                    .focused($focusedField, equals: .skip)
                    .accessibilityHint("Skip the remaining onboarding steps without installing software or changing preferences.")
                    .keyboardShortcut(.escape, modifiers: [])
            }
            Button(LatticeOnboardingNavigation.primaryActionTitle(for: step)) {
                goPrimary()
            }
            .keyboardShortcut(.defaultAction)
            .focused($focusedField, equals: .primary)
            .accessibilityHint(
                LatticeOnboardingNavigation.isFinish(step: step)
                    ? "Close onboarding."
                    : "Continue to the next onboarding step."
            )
        }
    }

    // MARK: - Navigation

    private func goBack() {
        if let onBack {
            onBack()
        } else {
            step = LatticeOnboardingNavigation.retreating(from: step)
        }
    }

    private func goPrimary() {
        if LatticeOnboardingNavigation.isFinish(step: step) {
            onFinish()
            return
        }
        if let onContinue {
            onContinue()
        } else {
            step = LatticeOnboardingNavigation.advancing(from: step)
        }
    }

    private func moveFocusToHeading() {
        let apply = { focusedField = .heading }
        if reduceMotion {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }
}
