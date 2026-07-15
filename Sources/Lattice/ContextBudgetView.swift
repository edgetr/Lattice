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
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous)
                .strokeBorder(statusBorder, lineWidth: increasedContrast ? 1.25 : 1)
        }
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

    private var statusSemantic: LatticeStatusSemantic {
        switch estimate.status {
        case .comfortable: .success
        case .tight: .warning
        case .nearLimit: .approval
        case .overLimit: .failed
        }
    }

    private var statusSymbol: String { statusSemantic.systemImage }

    /// Accent used for progress and glass tint (shared semantic map).
    private var statusAccent: Color { statusSemantic.color }

    private var statusBackground: Color {
        let baseOpacity = increasedContrast ? 0.22 : statusSemantic.fillOpacity
        // Slightly lift fill in light mode so warning chips remain readable on glass.
        let schemeBoost = (colorScheme == .light && !increasedContrast) ? 0.02 : 0
        return statusAccent.opacity(baseOpacity + schemeBoost)
    }

    private var statusBorder: Color {
        statusAccent.opacity(increasedContrast ? 0.55 : statusSemantic.borderOpacity)
    }

    static func format(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return "\(tokens / 1_000_000)M" }
        if tokens >= 1_000 { return "\(tokens / 1_000)K" }
        return "\(tokens)"
    }
}

/// OpenCode-style category breakdown. All values are local estimates unless a
/// provider-reported total is present separately.
struct ContextBudgetBreakdownView: View {
    let breakdown: LatticeContextBudgetBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Breakdown")
                    .font(LatticeTypography.captionStrong)
                Text(breakdown.isEstimate ? "local estimate" : "reported")
                    .font(LatticeTypography.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let providerTotal = breakdown.providerReportedTotalTokens {
                    Text("Provider: \(ContextBudgetMeter.format(providerTotal))")
                        .font(LatticeTypography.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            ForEach(breakdown.slices.filter { $0.estimatedTokens > 0 }, id: \.category) { slice in
                HStack(spacing: 8) {
                    Text(slice.category.displayName)
                        .font(LatticeTypography.caption)
                    Spacer(minLength: 4)
                    Text(ContextBudgetMeter.format(slice.estimatedTokens))
                        .font(LatticeTypography.mono)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text("Estimates use a local heuristic. Provider tokenizers may differ.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Context category breakdown")
        .accessibilityValue(
            breakdown.slices
                .filter { $0.estimatedTokens > 0 }
                .map { "\($0.category.displayName) \(ContextBudgetMeter.format($0.estimatedTokens))" }
                .joined(separator: ", ")
        )
    }
}
