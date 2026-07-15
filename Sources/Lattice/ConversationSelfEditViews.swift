import SwiftUI
import AppKit
import LatticeCore
import UniformTypeIdentifiers

struct SelfEditPreviewRow: View {
    let preview: LatticeExtensionPreviewRecord
    @ObservedObject var state: AppState

    private var previousManifest: LatticeExtensionManifest? {
        preview.previousManifestData.flatMap { try? JSONDecoder().decode(LatticeExtensionManifest.self, from: $0) }
    }

    private var review: LatticeExtensionChangeReview {
        LatticeExtensionChangeReviewBuilder.review(current: preview.manifest, previous: previousManifest)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wand.and.stars")
                    .foregroundStyle(.pink)
                    .frame(width: 22)
                Text("Review Lattice change")
                    .fontWeight(.semibold)
                Spacer()
                Text(previousManifest == nil ? "New" : "Update")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.pink.opacity(0.14), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("If you apply this")
                    .font(.caption.weight(.semibold))
                Text(review.acceptanceSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(review.changes.enumerated()), id: \.offset) { _, change in
                    Label(change, systemImage: "arrow.right.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("If you apply this")
            .accessibilityValue(review.acceptanceSummary)
            .padding(10)
            .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            HStack {
                Text("Ask for a revision in the composer, or apply exactly the changes shown above.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Discard") { state.discardSelfEditPreview(preview) }
                    .buttonStyle(LatticeSecondaryButtonStyle())
                Button("Apply") { state.acceptSelfEditPreview(preview) }
                    .buttonStyle(LatticePrimaryButtonStyle())
                    .disabled(!review.hasChanges)
                    .help(review.hasChanges ? "Apply this Lattice change" : "There are no changes to apply")
            }
        }
        .padding(14)
        .latticeContentSurface(cornerRadius: LatticeMetrics.glassRadius)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(LatticeAccessibilityID.selfEditReview)
        .accessibilityLabel("Review Lattice change")
    }
}

