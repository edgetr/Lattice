import AppKit
import Combine
import Foundation
import QuickLook
import SwiftUI
import LatticeCore

struct AssistantArtifactCard: View {
    let artifact: AssistantArtifact
    let workspace: URL

    @StateObject private var model = AssistantArtifactCardModel()

    private let applicationSupportRoot = LatticeApplicationSupport.productRootURL()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(artifact.displayName)
                            .font(.callout.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(metadataDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    statusBadge
                }

                actionControls
            }
            .padding(12)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contextMenu { artifactActions }
        .quickLookPreview(Binding(
            get: { model.previewURL },
            set: { model.previewURL = $0 }
        ))
        .task(id: model.refreshSequence) { await load() }
        .alert("Image action failed", isPresented: Binding(
            get: { model.actionError != nil },
            set: { if !$0 { model.actionError = nil } }
        )) {
            Button("OK", role: .cancel) { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "The image action could not be completed.")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Assistant image, \(artifact.displayName)")
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier("lattice.assistant-artifact.\(artifact.id.uuidString)")
    }

    @ViewBuilder
    private var preview: some View {
        ZStack {
            Color.primary.opacity(0.035)
            switch model.phase {
            case .loading:
                VStack(spacing: 9) {
                    ProgressView()
                    Text("Loading image…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading \(artifact.displayName)")
            case .ready(let data, _):
                if let image = NSImage(data: data) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 360)
                        .padding(8)
                        .accessibilityHidden(true)
                } else {
                    unavailablePreview(symbol: "exclamationmark.triangle", title: "Image could not be decoded")
                }
            case .unavailable(let presentation):
                switch presentation.availability {
                case .missing:
                    unavailablePreview(symbol: "photo.badge.exclamationmark", title: "Image file is missing")
                case .invalid:
                    unavailablePreview(symbol: "lock.trianglebadge.exclamationmark", title: "Image is unavailable")
                case .available:
                    unavailablePreview(symbol: "exclamationmark.triangle", title: "Image could not be loaded")
                }
            }
        }
        .frame(minHeight: 150, idealHeight: 240, maxHeight: 376)
    }

    private func unavailablePreview(symbol: String, title: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 27, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.medium))
            if case .unavailable(let presentation) = model.phase {
                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch model.phase {
        case .loading:
            Label("Loading", systemImage: "clock")
                .artifactStatusStyle(color: .secondary)
        case .ready:
            Label("Available", systemImage: "checkmark.circle.fill")
                .artifactStatusStyle(color: .green)
        case .unavailable(let presentation):
            switch presentation.availability {
            case .missing:
                Label("Missing", systemImage: "questionmark.folder")
                    .artifactStatusStyle(color: .orange)
            case .invalid:
                Label("Blocked", systemImage: "lock.fill")
                    .artifactStatusStyle(color: .red)
            case .available:
                Label("Error", systemImage: "exclamationmark.triangle.fill")
                    .artifactStatusStyle(color: .orange)
            }
        }
    }

    @ViewBuilder
    private var actionControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                primaryAction
                Spacer(minLength: 6)
                secondaryActionButtons
            }
            VStack(alignment: .leading, spacing: 8) {
                primaryAction
                secondaryActionButtons
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if canOpen {
            Button {
                model.previewURL = URL(fileURLWithPath: artifact.canonicalPath)
            } label: {
                Label("Open Full Size", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help("Open this image in Quick Look")
            .accessibilityHint("Opens a full-size Quick Look preview")
        } else {
            Button {
                model.refreshSequence &+= 1
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isLoading)
            .help("Check the recorded image location again")
        }
    }

    private var secondaryActionButtons: some View {
        HStack(spacing: 6) {
            Button(action: reveal) {
                Label("Reveal", systemImage: "folder")
            }
            .disabled(!canReveal)
            .help("Reveal in Finder")

            Button(action: saveCopy) {
                Label("Save Copy", systemImage: "square.and.arrow.down")
            }
            .disabled(!canSaveCopy)
            .help("Save a copy elsewhere")

            Menu {
                artifactActions
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More image actions")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    @ViewBuilder
    private var artifactActions: some View {
        Button("Open Full Size", systemImage: "arrow.up.left.and.arrow.down.right") {
            model.previewURL = URL(fileURLWithPath: artifact.canonicalPath)
        }
        .disabled(!canOpen)
        Button("Reveal in Finder", systemImage: "folder") { reveal() }
            .disabled(!canReveal)
        Button("Save Copy…", systemImage: "square.and.arrow.down") { saveCopy() }
            .disabled(!canSaveCopy)
        Divider()
        Button("Copy Path", systemImage: "doc.on.doc") { copyPath() }
            .disabled(!canCopyPath)
    }

    private var presentation: AssistantArtifactPresentationPolicy.Presentation? {
        switch model.phase {
        case .loading: nil
        case .ready(_, let presentation), .unavailable(let presentation): presentation
        }
    }

    private var metadataDetail: String {
        presentation?.detail ?? "\(artifact.provenance.provider) image"
    }

    private var accessibilityValue: String {
        switch model.phase {
        case .loading: "Loading"
        case .ready: "Available. \(metadataDetail)"
        case .unavailable(let presentation): presentation.detail
        }
    }

    private var isLoading: Bool {
        if case .loading = model.phase { return true }
        return false
    }

    private var canOpen: Bool { presentation?.canOpen == true }
    private var canReveal: Bool { presentation?.canReveal == true }
    private var canSaveCopy: Bool { presentation?.canSaveCopy == true }
    private var canCopyPath: Bool { presentation?.canCopyPath == true }

    private func load() async {
        model.phase = .loading
        let artifact = artifact
        let workspace = workspace
        let applicationSupportRoot = applicationSupportRoot
        let loaded = await Task.detached(priority: .utility) {
            let presentation = AssistantArtifactPresentationPolicy.presentation(
                for: artifact,
                workspace: workspace,
                applicationSupportRoot: applicationSupportRoot
            )
            guard presentation.canOpen else { return LoadPhase.unavailable(presentation) }
            do {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: artifact.canonicalPath))
                defer { try? handle.close() }
                let data = try handle.read(upToCount: AssistantImageArtifactPolicy.maximumByteCount + 1) ?? Data()
                guard !data.isEmpty, data.count <= AssistantImageArtifactPolicy.maximumByteCount else {
                    return LoadPhase.unavailable(.init(
                        availability: .invalid(.oversize),
                        detail: "The image is too large to display safely.",
                        canOpen: false,
                        canReveal: false,
                        canSaveCopy: false,
                        canCopyPath: false
                    ))
                }
                return LoadPhase.ready(data, presentation)
            } catch {
                return LoadPhase.unavailable(.init(
                    availability: .invalid(.unreadable),
                    detail: "The image could not be read from its recorded location.",
                    canOpen: false,
                    canReveal: false,
                    canSaveCopy: false,
                    canCopyPath: false
                ))
            }
        }.value
        guard !Task.isCancelled else { return }
        model.phase = loaded
    }

    private func reveal() {
        guard canReveal else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact.canonicalPath)])
    }

    private func copyPath() {
        guard canCopyPath else { return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(artifact.canonicalPath, forType: .string) else {
            model.actionError = "The path could not be copied to the clipboard."
            return
        }
    }

    private func saveCopy() {
        guard canSaveCopy, case .ready(let data, _) = model.phase else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = artifact.displayName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Save Image Copy"
        panel.prompt = "Save Copy"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            model.actionError = "The image copy could not be saved: \(error.localizedDescription)"
        }
    }
}

private enum LoadPhase: Equatable, Sendable {
    case loading
    case ready(Data, AssistantArtifactPresentationPolicy.Presentation)
    case unavailable(AssistantArtifactPresentationPolicy.Presentation)
}

@MainActor
private final class AssistantArtifactCardModel: ObservableObject {
    @Published var phase: LoadPhase = .loading
    @Published var previewURL: URL?
    @Published var refreshSequence = 0
    @Published var actionError: String?
}

private extension View {
    func artifactStatusStyle(color: Color) -> some View {
        self
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
            .fixedSize()
    }
}
