import SwiftUI
import LatticeCore

/// Restrained localized timestamp caption under a message bubble.
struct MessageTimestampCaption: View {
    let date: Date

    var body: some View {
        Text(MessageTimestampPresentationPolicy.formattedTimestamp(date))
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .monospacedDigit()
            .accessibilityHidden(true)
    }
}

/// Restrained assistant chat-route provenance from session backend/harness (not message payload).
struct AssistantRouteProvenanceCaption: View {
    let backend: ChatBackend
    let sessionHarnessID: String?

    private var provenance: ChatRouteProvenancePresentationPolicy.Provenance {
        ChatRouteProvenancePresentationPolicy.provenance(
            backend: backend,
            sessionHarnessID: sessionHarnessID
        )
    }

    var body: some View {
        Text(provenance.displayLine)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(provenance.accessibilityLabel)
    }
}
