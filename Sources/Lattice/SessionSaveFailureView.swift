import SwiftUI
import LatticeCore

/// Non-destructive status surface for runtime session *save* failures.
/// Distinct from `PersistenceRecoveryView` (corrupt/unreadable load recovery):
/// in-memory work remains, Retry is offered, and no reset/quarantine of readable data is suggested.
struct SessionSaveFailureView: View {
    @ObservedObject var state: AppState

    var body: some View {
        if let failure = state.sessionSaveFailure {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.title3)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Couldn’t save chats")
                            .font(.headline)
                        Text(failure.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Your in-memory work is still here. Retry writes the latest draft and session state. Lattice does not reset or quarantine readable chat data for save failures.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Button("Retry") {
                        state.retrySessionSave()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Retry saving chats")
                    .accessibilityHint("Writes the latest in-memory sessions and draft to disk")
                }

                DisclosureGroup(
                    isExpanded: Binding(
                        get: { state.expandedSessionSaveFailureDetails },
                        set: { state.expandedSessionSaveFailureDetails = $0 }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure.filePath)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(failure.technicalDetails)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        HStack(spacing: 10) {
                            Text(failure.kind.displayName)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                                .foregroundStyle(.orange)
                                .accessibilityLabel("Save failure kind: \(failure.kind.displayName)")
                            Button("Copy Technical Details") {
                                state.copySessionSaveFailureDetails()
                            }
                            .buttonStyle(.bordered)
                            .accessibilityHint("Copies store path and error details to the clipboard")
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Technical details")
                        .font(.subheadline.weight(.medium))
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .latticeGlass(cornerRadius: 16)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Session save failure")
            .accessibilityValue(failure.summary)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
