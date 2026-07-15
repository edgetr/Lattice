import AppKit
import LatticeCore
import SwiftUI

/// Lazy workspace file tree with single-click text/image preview.
struct FileBrowserPanel: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if state.fileBrowserRootPath.isEmpty {
                LatticeEmptyState(
                    title: "No workspace",
                    message: "Choose a project folder to browse files the agent can change.",
                    systemImage: "folder.badge.questionmark",
                    primaryActionTitle: "Choose Workspace…",
                    primaryAction: { state.chooseWorkspace() }
                )
            } else {
                GeometryReader { geometry in
                    HSplitView {
                        treeColumn
                            .frame(minWidth: 160, idealWidth: min(240, geometry.size.width * 0.42), maxWidth: 320)
                        previewColumn
                            .frame(minWidth: 180)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LatticeAccessibilityID.fileBrowser)
        .accessibilityLabel("Workspace files")
        .onAppear { state.refreshFileBrowserListing() }
        .onChange(of: state.fileBrowserRootPath) { _, _ in
            state.refreshFileBrowserListing()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            LatticeSectionHeader(title: "Files", systemImage: "folder")
            Spacer(minLength: 4)
            if !state.fileBrowserRelativeDirectory.isEmpty {
                Button {
                    state.fileBrowserNavigateUp()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(LatticeIconButtonStyle(size: .compact))
                .accessibilityLabel("Go to parent folder")
            }
            Button {
                state.refreshFileBrowserListing()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(LatticeIconButtonStyle(size: .compact))
            .accessibilityLabel("Refresh file list")
            Button {
                state.showFileBrowser = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(LatticeIconButtonStyle(size: .compact))
            .accessibilityLabel("Close file browser")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var treeColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(breadcrumb)
                .font(LatticeTypography.monoSmall)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .help(breadcrumb)
            if let error = state.fileBrowserError {
                Text(error)
                    .font(LatticeTypography.caption)
                    .foregroundStyle(LatticeStatusSemantic.failed.color)
                    .padding(12)
            } else if state.fileBrowserIsLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.fileBrowserNodes.isEmpty {
                Text("This folder is empty.")
                    .font(LatticeTypography.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(state.fileBrowserNodes) { node in
                                fileRow(node)
                                    .id(node.relativePath)
                            }
                            if state.fileBrowserTruncated {
                                Text("Listing capped — refine with a subdirectory.")
                                    .font(LatticeTypography.caption)
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                    }
                    .onChange(of: state.fileBrowserSelectedPath) { _, selected in
                        guard let selected, state.fileBrowserNodes.contains(where: { $0.relativePath == selected }) else { return }
                        proxy.scrollTo(selected, anchor: .center)
                    }
                }
            }
        }
    }

    private var breadcrumb: String {
        let root = (state.fileBrowserRootPath as NSString).lastPathComponent
        if state.fileBrowserRelativeDirectory.isEmpty { return root }
        return root + "/" + state.fileBrowserRelativeDirectory
    }

    private func fileRow(_ node: WorkspaceFileNode) -> some View {
        let selected = state.fileBrowserSelectedPath == node.relativePath
        return Button {
            state.selectFileBrowserNode(node)
        } label: {
            LatticeRow(isSelected: selected) {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: node))
                        .foregroundStyle(node.isSecretPath ? LatticeStatusSemantic.warning.color : .secondary)
                        .frame(width: 14)
                    Text(node.name)
                        .font(LatticeTypography.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if node.isSecretPath {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(LatticeStatusSemantic.warning.color)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(node.name)
        .accessibilityValue(node.isSecretPath ? "Secret path" : node.kind.rawValue)
        .accessibilityHint(node.kind == .directory ? "Open folder" : "Preview file")
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(state.fileBrowserSelectedPath ?? "Preview")
                    .font(LatticeTypography.mono)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                if let path = state.fileBrowserSelectedPath, !path.isEmpty {
                    Button {
                        state.pinFileBrowserSelection()
                    } label: {
                        Image(systemName: state.fileBrowserPinnedPaths.contains(path) ? "pin.fill" : "pin")
                    }
                    .buttonStyle(LatticeIconButtonStyle(size: .compact))
                    .accessibilityLabel(state.fileBrowserPinnedPaths.contains(path) ? "Unpin file" : "Pin file open")
                    Button {
                        state.revealFileBrowserSelectionInFinder()
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(LatticeIconButtonStyle(size: .compact))
                    .accessibilityLabel("Reveal in Finder")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if !state.fileBrowserPinnedPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(state.fileBrowserPinnedPaths, id: \.self) { path in
                            Button {
                                state.openFileBrowserPath(path)
                            } label: {
                                Text((path as NSString).lastPathComponent)
                            }
                            .buttonStyle(LatticeChipButtonStyle(isProminent: path == state.fileBrowserSelectedPath))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
            }

            Divider()

            Group {
                if state.fileBrowserPreviewLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let preview = state.fileBrowserPreview {
                    previewBody(preview)
                        .id(preview.relativePath)
                } else {
                    Text("Select a file to preview.")
                        .font(LatticeTypography.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                }
            }
        }
    }

    @ViewBuilder
    private func previewBody(_ preview: WorkspaceFilePreview) -> some View {
        switch preview.kind {
        case .text:
            ScrollView {
                Text(preview.text ?? "")
                    .font(LatticeTypography.monoBody)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        case .image:
            if let image = state.fileBrowserPreviewImage {
                ScrollView {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .padding(12)
                }
            } else {
                Text(preview.message ?? "Image could not be loaded.")
                    .font(LatticeTypography.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        case .secretBlocked:
            secretBlockedView(preview)
        case .binary, .tooLarge, .missing:
            Text(preview.message ?? "Cannot preview this file.")
                .font(LatticeTypography.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func secretBlockedView(_ preview: WorkspaceFilePreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Secret path protected", systemImage: "lock.shield")
                .font(LatticeTypography.captionStrong)
                .foregroundStyle(LatticeStatusSemantic.warning.color)
            Text(preview.message ?? "Lattice never auto-opens secret-looking paths.")
                .font(LatticeTypography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func icon(for node: WorkspaceFileNode) -> String {
        if node.isSecretPath { return "lock.doc" }
        switch node.kind {
        case .directory: return "folder.fill"
        case .symbolicLink: return "link"
        case .file: return "doc.text"
        case .other: return "questionmark.square"
        }
    }
}
