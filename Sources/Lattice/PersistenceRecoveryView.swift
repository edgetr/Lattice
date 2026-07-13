import SwiftUI
import AppKit
import LatticeCore

/// Blocking, accessible recovery surface for durable stores that failed initial load.
/// Source files are only changed through explicit AppState recovery actions.
struct PersistenceRecoveryView: View {
    @ObservedObject var state: AppState
    @AccessibilityFocusState private var headerFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let status = state.persistenceRecoveryStatusMessage, !status.isEmpty {
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .latticeGlass(cornerRadius: 14)
                            .accessibilityLabel("Recovery status")
                            .accessibilityValue(status)
                    }
                    ForEach(state.persistenceRecoveryIssues) { issue in
                        issueCard(issue)
                    }
                }
                .padding(28)
                .frame(maxWidth: 720)
            }
            .frame(maxWidth: 760, maxHeight: 640)
            .latticeGlass(cornerRadius: 24)
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LatticeAccessibilityID.recovery)
        .accessibilityLabel("Persistence recovery")
        .accessibilityAddTraits(.isModal)
        .onAppear {
            DispatchQueue.main.async { headerFocused = true }
        }
        .onChange(of: state.persistenceRecoveryIssues.map(\.id)) { _, issues in
            if !issues.isEmpty {
                DispatchQueue.main.async { headerFocused = true }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Local data needs attention", systemImage: "exclamationmark.shield")
                .font(.title2.weight(.semibold))
            Text("Lattice found durable files it cannot safely load. Original files stay untouched until you choose an action. Autosave is paused for affected stores so corrupt data is never overwritten.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityFocused($headerFocused)
    }

    @ViewBuilder
    private func issueCard(_ issue: DurableStoreIssue) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.storeName)
                        .font(.headline)
                    Text(issue.filePath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Text(issue.kind.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(kindColor(issue.kind).opacity(0.15), in: Capsule())
                    .foregroundStyle(kindColor(issue.kind))
                    .accessibilityLabel("Problem kind: \(issue.kind.displayName)")
            }

            Text(issue.summary)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup(
                isExpanded: Binding(
                    get: { state.expandedPersistenceRecoveryDetailIDs.contains(issue.id) },
                    set: { expanded in
                        if expanded {
                            state.expandedPersistenceRecoveryDetailIDs.insert(issue.id)
                        } else {
                            state.expandedPersistenceRecoveryDetailIDs.remove(issue.id)
                        }
                    }
                )
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(issue.technicalDetails)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Button("Copy Technical Details") {
                        state.copyPersistenceRecoveryDetails(issue)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityHint("Copies store path and error details to the clipboard")
                }
                .padding(.top, 6)
            } label: {
                Text("Technical details")
                    .font(.subheadline.weight(.medium))
            }

            ViewThatFits(in: .horizontal) {
                actionRow(issue, stacking: false)
                actionRow(issue, stacking: true)
            }
            .controlSize(.regular)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .latticeGlass(cornerRadius: 18)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LatticeAccessibilityID.recoveryIssue(issue.storeID))
        .accessibilityLabel("\(issue.storeName) recovery")
        .accessibilityValue(issue.summary)
    }

    @ViewBuilder
    private func actionRow(_ issue: DurableStoreIssue, stacking: Bool) -> some View {
        let buttons = Group {
            Button("Reveal in Finder") { state.revealPersistenceStoreInFinder(issue) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Reveal \(issue.storeName) in Finder")
                .accessibilityHint("Shows the durable file in Finder without changing it")
            Button("Export Copy…") { state.exportPersistenceStoreCopy(issue) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Export a copy of \(issue.storeName)")
                .accessibilityHint("Saves a byte-for-byte copy to a location you choose. Refuses to replace an existing file.")
            Button("Create Backup") { state.createPersistenceStoreBackup(issue) }
                .buttonStyle(.bordered)
                .accessibilityLabel("Create backup of \(issue.storeName)")
                .accessibilityHint("Writes an adjacent collision-safe backup and keeps recovery open")
            Button("Retry") { state.retryPersistenceStoreRecovery(issue) }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(LatticeAccessibilityID.recoveryRetry(issue.storeID))
                .accessibilityLabel("Retry loading \(issue.storeName)")
                .accessibilityHint("Re-reads the file without mutating it. Dismisses recovery only if it loads or is missing.")
            Button("Reset…", role: .destructive) { state.requestPersistenceStoreReset(issue) }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(LatticeAccessibilityID.recoveryReset(issue.storeID))
                .accessibilityLabel("Reset \(issue.storeName)")
                .accessibilityHint("Asks for confirmation, backs up the original, then creates a new empty store")
        }
        if stacking {
            VStack(alignment: .leading, spacing: 10) { buttons }
        } else {
            HStack(spacing: 10) { buttons }
        }
    }

    private func kindColor(_ kind: DurableStoreIssueKind) -> Color {
        switch kind {
        case .unreadable: return .orange
        case .corrupt: return .red
        case .oversized: return .red
        }
    }
}
