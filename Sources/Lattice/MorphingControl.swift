import SwiftUI
import LatticeCore
import UniformTypeIdentifiers

struct MorphingControl: View {
    @Binding var state: MorphingControlState
    @Binding var text: String
    var compactTitle: String = "Ask Lattice"
    var compactIcon: String = "bubble.left"
    var expandedPlaceholder: String = "What do you need?"
    var onSubmit: () -> Void
    var onStop: () -> Void = {}
    var onChooseFiles: () -> Void = {}
    var onDropFiles: ([URL]) -> Void = { _ in }
    var onDismissContext: () -> Void = {}
    var isSubmitEnabled: Bool = true
    var isStopEnabled: Bool = true
    var submitDisabledHelp: String? = nil
    var stopDisabledHelp: String? = nil
    var surfaceTint: Color? = nil
    var surfaceCornerRadius: CGFloat = 16
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @Namespace private var morph

    private var presentation: MorphingControlPresentationPolicy.Presentation {
        MorphingControlPresentationPolicy.presentation(for: state)
    }

    /// No matched-geometry or phase animation when Reduce Motion is on.
    private var phaseAnimation: Animation? {
        reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.02)
    }

    private var resolvedSurfaceTint: Color? {
        guard let surfaceTint else { return nil }
        switch presentation.phase {
        case .expanded, .context:
            return surfaceTint.opacity(0.18)
        default:
            return surfaceTint
        }
    }

    var body: some View {
        Group {
            switch presentation.phase {
            case .compact:
                Button {
                    applyPhaseChange { state = .expanded }
                    focused = true
                } label: {
                    Label(compactTitle, systemImage: compactIcon)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 11)
                }
                .buttonStyle(LatticeScaleButtonStyle())
                .morphSurface(reduceMotion: reduceMotion, namespace: morph)
                .accessibilityHint("Expands into a prompt field")
            case .expanded:
                HStack(spacing: 10) {
                    TextField(expandedPlaceholder, text: $text, axis: .vertical)
                        .textFieldStyle(.plain).focused($focused).lineLimit(1...5)
                        .foregroundStyle(.primary)
                        .tint(.pink)
                        .layoutPriority(1)
                        .accessibilityIdentifier(LatticeAccessibilityID.composerDraft)
                        .accessibilityLabel("Composer draft")
                        .accessibilityValue(text)
                        .onSubmit { onSubmit() }
                    if let addContext = presentation.secondaryAction {
                        Button {
                            applyPhaseChange { state = .context }
                        } label: {
                            Image(systemName: addContext.systemImage)
                        }
                        .buttonStyle(actionButtonStyle(for: addContext))
                        .accessibilityLabel(addContext.accessibilityLabel)
                        .help(addContext.help)
                    }
                    if let send = presentation.primaryAction {
                        Button(action: onSubmit) {
                            Image(systemName: send.systemImage)
                        }
                        .buttonStyle(actionButtonStyle(for: send))
                        .disabled(!isSubmitEnabled || !MorphingControlPresentationPolicy.isDraftActionEnabled(
                            text: text,
                            requiresNonEmptyDraft: send.requiresNonEmptyDraft
                        ))
                        .accessibilityLabel(send.accessibilityLabel)
                        .help(isSubmitEnabled ? send.help : (submitDisabledHelp ?? send.help))
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .morphSurface(reduceMotion: reduceMotion, namespace: morph)
            case .context:
                HStack(spacing: 10) {
                    if let icon = presentation.statusSystemImage {
                        Image(systemName: icon)
                            .foregroundStyle(semanticColor(presentation.statusSemantic) ?? Color.secondary)
                    }
                    Text(presentation.statusTitle ?? "Add context")
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer()
                    Button("Files…", action: onChooseFiles).buttonStyle(.borderedProminent)
                    if let dismiss = presentation.secondaryAction {
                        Button(action: onDismissContext) {
                            Image(systemName: dismiss.systemImage)
                        }
                        .buttonStyle(actionButtonStyle(for: dismiss))
                        .accessibilityLabel(dismiss.accessibilityLabel)
                        .help(dismiss.help)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .morphSurface(reduceMotion: reduceMotion, namespace: morph)
            case .progress:
                HStack(spacing: 10) {
                    progressIndicator
                    if let title = presentation.statusTitle {
                        Text(title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                            // Status copy can flip Starting/Working without a phase animation.
                            .transaction { transaction in
                                if reduceMotion { transaction.disablesAnimations = true }
                            }
                    }
                    TextField(presentation.draftPlaceholder ?? "Queue follow-up…", text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .lineLimit(1...3)
                        .layoutPriority(1)
                        .onSubmit { onSubmit() }
                    if let queue = presentation.primaryAction {
                        Button(action: onSubmit) {
                            Image(systemName: queue.systemImage)
                        }
                        .buttonStyle(actionButtonStyle(for: queue))
                        .disabled(!isSubmitEnabled || !MorphingControlPresentationPolicy.isDraftActionEnabled(
                            text: text,
                            requiresNonEmptyDraft: queue.requiresNonEmptyDraft
                        ))
                        .accessibilityLabel(queue.accessibilityLabel)
                        .help(isSubmitEnabled ? queue.help : (submitDisabledHelp ?? queue.help))
                    }
                    if let stop = presentation.secondaryAction {
                        Button(action: onStop) {
                            Image(systemName: stop.systemImage)
                        }
                        .buttonStyle(actionButtonStyle(for: stop))
                        .disabled(!isStopEnabled)
                        .accessibilityLabel(stop.accessibilityLabel)
                        .help(isStopEnabled ? stop.help : (stopDisabledHelp ?? stop.help))
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .morphSurface(reduceMotion: reduceMotion, namespace: morph)
            case .approval:
                HStack(spacing: 10) {
                    if let icon = presentation.statusSystemImage {
                        Image(systemName: icon)
                            .foregroundStyle(semanticColor(presentation.statusSemantic) ?? Color.orange)
                    }
                    Text(presentation.statusTitle ?? "Approval needed")
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer()
                    if let stop = presentation.secondaryAction {
                        Button(action: onStop) {
                            Image(systemName: stop.systemImage)
                        }
                        .buttonStyle(actionButtonStyle(for: stop))
                        .disabled(!isStopEnabled)
                        .accessibilityLabel(stop.accessibilityLabel)
                        .help(isStopEnabled ? stop.help : (stopDisabledHelp ?? stop.help))
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .morphSurface(reduceMotion: reduceMotion, namespace: morph)
            case .success:
                Label {
                    Text(presentation.statusTitle ?? "Done")
                } icon: {
                    Image(systemName: presentation.statusSystemImage ?? "checkmark.circle.fill")
                }
                .foregroundStyle(semanticColor(presentation.statusSemantic) ?? Color.green)
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .morphSurface(reduceMotion: reduceMotion, namespace: morph)
            case .failure:
                HStack(spacing: 10) {
                    Label {
                        Text(presentation.statusTitle ?? "Something went wrong")
                    } icon: {
                        Image(systemName: presentation.statusSystemImage ?? "exclamationmark.triangle.fill")
                    }
                    .foregroundStyle(semanticColor(presentation.statusSemantic) ?? Color.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    Spacer(minLength: 8)
                    if let retry = presentation.primaryAction {
                        Button {
                            applyPhaseChange { state = .expanded }
                        } label: {
                            Image(systemName: retry.systemImage)
                        }
                        .buttonStyle(actionButtonStyle(for: retry))
                        .accessibilityLabel(retry.accessibilityLabel)
                        .help(retry.help)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .morphSurface(reduceMotion: reduceMotion, namespace: morph)
            }
        }
        .frame(minHeight: LatticeIconButtonSize.prominent.side)
        .latticeGlass(
            cornerRadius: surfaceCornerRadius,
            interactive: presentation.usesInteractiveGlass,
            tint: resolvedSurfaceTint
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: .constant(false)) { providers in
            // Claim success only when at least one provider can yield a file URL.
            loadDroppedFileURLs(from: providers)
        }
        // Animate only discrete phase identity — not progress fraction or status copy.
        .animation(phaseAnimation, value: presentation.animationIdentity)
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if presentation.showsIndeterminateProgress {
            ProgressView()
                .controlSize(.small)
        } else if let fraction = presentation.progressFraction {
            ProgressView(value: fraction)
                .controlSize(.small)
                .frame(width: 28)
                .tint(Color.secondary)
                // Fraction updates must not drive phase morph animations.
                .transaction { transaction in
                    transaction.animation = nil
                }
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func actionButtonStyle(for action: MorphingControlPresentationPolicy.ActionChrome) -> LatticeIconButtonStyle {
        let size: LatticeIconButtonSize = action.isProminent ? .prominent : .regular
        switch action.semantic {
        case .danger:
            return LatticeIconButtonStyle(size: size, isDestructive: true)
        case .accent:
            return LatticeIconButtonStyle(size: size, tint: .pink)
        case .warning:
            return LatticeIconButtonStyle(size: size, tint: .orange)
        case .success:
            return LatticeIconButtonStyle(size: size, tint: .green)
        case .neutral:
            return LatticeIconButtonStyle(size: size)
        }
    }

    private func semanticColor(_ semantic: MorphingControlPresentationPolicy.Semantic?) -> Color? {
        switch semantic {
        case .accent: return .pink
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        case .neutral, .none: return nil
        }
    }

    private func applyPhaseChange(_ update: () -> Void) {
        if let phaseAnimation {
            withAnimation(phaseAnimation, update)
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction, update)
        }
    }

    /// Collects valid file URLs in provider order and delivers them once on the main actor.
    @discardableResult
    private func loadDroppedFileURLs(from providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }

        Task {
            var urls: [URL] = []
            urls.reserveCapacity(fileProviders.count)
            for provider in fileProviders {
                if let url = await Self.loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            await MainActor.run { onDropFiles(urls) }
        }
        return true
    }

    private static func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                continuation.resume(returning: fileURL(from: item))
            }
        }
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL, url.isFileURL { return url }
        if let url = item as? NSURL, (url as URL).isFileURL { return url as URL }
        if let data = item as? Data,
           let value = String(data: data, encoding: .utf8),
           let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
           url.isFileURL { return url }
        return nil
    }
}

private extension View {
    /// Matched-geometry morph only when Reduce Motion is off.
    @ViewBuilder
    func morphSurface(reduceMotion: Bool, namespace: Namespace.ID) -> some View {
        if reduceMotion {
            self
        } else {
            self.matchedGeometryEffect(id: "surface", in: namespace)
        }
    }
}
