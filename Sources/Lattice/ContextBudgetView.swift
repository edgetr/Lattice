import AppKit
import SwiftUI
import LatticeCore

struct ContextBudgetMeter: View {
    let estimate: LatticeContextBudgetEstimate
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var increasedContrast: Bool { colorSchemeContrast == .increased }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Label("Context", systemImage: "text.badge.checkmark")
                    .font(.caption.weight(.semibold))
                Text("\(Self.format(estimate.estimatedTokens)) / \(Self.format(estimate.tokenLimit)) estimated tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer(minLength: 8)
                statusBadge
            }
            ProgressView(value: estimate.usageFraction)
                .progressViewStyle(.linear)
                .tint(statusAccent)
                .accessibilityLabel("Estimated context usage")
                .accessibilityValue("\(Self.format(estimate.estimatedTokens)) of \(Self.format(estimate.tokenLimit)) tokens, \(estimate.status.displayName)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .latticeGlass(cornerRadius: LatticeMetrics.compactRadius, tint: statusAccent.opacity(increasedContrast ? 0.10 : 0.06))
        .help("Local estimate from visible transcript, current draft, and attached path metadata. Provider tokenizers may differ.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Context budget")
        .accessibilityValue("\(estimate.status.displayName). \(Self.format(estimate.estimatedTokens)) of \(Self.format(estimate.tokenLimit)) estimated tokens")
    }

    /// Status chip: explicit text + SF Symbol so meaning does not rely on color alone.
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusAccent)
            Text(estimate.status.displayName)
                .foregroundStyle(.primary)
        }
            .font(.caption2.weight(.semibold))
            .symbolRenderingMode(.hierarchical)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .fixedSize(horizontal: true, vertical: false)
            .background(statusBackground, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(statusBorder, lineWidth: increasedContrast ? 1.25 : 1)
            )
            .accessibilityHidden(true)
    }

    private var statusSymbol: String {
        switch estimate.status {
        case .comfortable: "checkmark.circle.fill"
        case .tight: "exclamationmark.circle.fill"
        case .nearLimit: "exclamationmark.triangle.fill"
        case .overLimit: "xmark.octagon.fill"
        }
    }

    /// Accent used for progress and glass tint (semantic system colors).
    private var statusAccent: Color {
        switch estimate.status {
        case .comfortable: Color(nsColor: .systemGreen)
        case .tight: Color(nsColor: .systemYellow)
        case .nearLimit: Color(nsColor: .systemOrange)
        case .overLimit: Color(nsColor: .systemRed)
        }
    }

    private var statusBackground: Color {
        let baseOpacity: Double
        switch estimate.status {
        case .comfortable: baseOpacity = increasedContrast ? 0.22 : 0.14
        case .tight: baseOpacity = increasedContrast ? 0.24 : 0.16
        case .nearLimit: baseOpacity = increasedContrast ? 0.26 : 0.18
        case .overLimit: baseOpacity = increasedContrast ? 0.28 : 0.18
        }
        // Slightly lift fill in light mode so warning chips remain readable on glass.
        let schemeBoost = (colorScheme == .light && !increasedContrast) ? 0.02 : 0
        return statusAccent.opacity(baseOpacity + schemeBoost)
    }

    private var statusBorder: Color {
        statusAccent.opacity(increasedContrast ? 0.55 : 0.28)
    }

    static func format(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return "\(tokens / 1_000_000)M" }
        if tokens >= 1_000 { return "\(tokens / 1_000)K" }
        return "\(tokens)"
    }
}
