import AppKit
import SwiftUI

// MARK: - Typography

/// Fixed scale for titles, body copy, and mono (paths, diffs, terminal).
enum LatticeTypography {
    static let title = Font.system(.title3, design: .default).weight(.semibold)
    static let titleLarge = Font.system(.title2, design: .default).weight(.semibold)
    static let body = Font.system(.body, design: .default)
    static let callout = Font.system(.callout, design: .default)
    static let caption = Font.system(.caption, design: .default)
    static let captionStrong = Font.system(.caption, design: .default).weight(.semibold)
    static let mono = Font.system(.caption, design: .monospaced)
    static let monoBody = Font.system(.callout, design: .monospaced)
    static let monoSmall = Font.system(.caption2, design: .monospaced)

    /// Readable transcript column (~72–80ch at body size). Keep aligned with
    /// `LatticeMessageRowLayoutPolicy.transcriptMaxWidth` in LatticeCore.
    static let transcriptMaxReadableWidth: CGFloat = 720
}

// MARK: - Semantic status colors

/// One map for running / approval / failed / success used across chrome, chips, and rows.
enum LatticeStatusSemantic: String, Sendable, CaseIterable, Equatable {
    case idle
    case running
    case queued
    case approval
    case failed
    case success
    case warning
    case neutral

    var label: String {
        switch self {
        case .idle: "Idle"
        case .running: "Running"
        case .queued: "Queued"
        case .approval: "Needs approval"
        case .failed: "Failed"
        case .success: "Success"
        case .warning: "Warning"
        case .neutral: "Neutral"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .queued: "clock"
        case .approval: "hand.raised.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .neutral: "circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .idle, .neutral: Color.secondary
        case .running: Color(nsColor: .systemBlue)
        case .queued: Color(nsColor: .systemPurple)
        case .approval: Color(nsColor: .systemOrange)
        case .failed: Color(nsColor: .systemRed)
        case .success: Color(nsColor: .systemGreen)
        case .warning: Color(nsColor: .systemYellow)
        }
    }

    var fillOpacity: Double { 0.14 }
    var borderOpacity: Double { 0.28 }
}

struct LatticeStatusChip: View {
    let semantic: LatticeStatusSemantic
    var title: String?
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var increasedContrast: Bool { colorSchemeContrast == .increased }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: semantic.systemImage)
                .foregroundStyle(semantic.color)
            Text(title ?? semantic.label)
                .foregroundStyle(.primary)
        }
        .font(LatticeTypography.captionStrong)
        .symbolRenderingMode(.hierarchical)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(semantic.color.opacity(increasedContrast ? 0.22 : semantic.fillOpacity), in: Capsule())
        .overlay(
            Capsule().strokeBorder(
                semantic.color.opacity(increasedContrast ? 0.55 : semantic.borderOpacity),
                lineWidth: increasedContrast ? 1.25 : 1
            )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title ?? semantic.label)
    }
}

// MARK: - Button styles

struct LatticePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
            .background(
                Color.accentColor.opacity(configuration.isPressed ? 0.82 : 1),
                in: RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous))
    }
}

struct LatticeSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous)
        configuration.label
            .font(.system(.callout, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(.primary)
            .background(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.06), in: shape)
            .overlay(
                shape.strokeBorder(
                    Color.primary.opacity(colorSchemeContrast == .increased ? 0.28 : 0.12),
                    lineWidth: colorSchemeContrast == .increased ? 1.25 : 1
                )
            )
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(shape)
    }
}

struct LatticeGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.callout, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
            .background(
                Color.primary.opacity(configuration.isPressed ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous)
            )
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: LatticeMetrics.compactRadius, style: .continuous))
    }
}

struct LatticeChipButtonStyle: ButtonStyle {
    var isProminent = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.caption, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isProminent ? Color(nsColor: .alternateSelectedControlTextColor) : Color.primary)
            .background(
                (isProminent ? Color.accentColor : Color.primary)
                    .opacity(isProminent ? (configuration.isPressed ? 0.82 : 1) : (configuration.isPressed ? 0.12 : 0.08)),
                in: Capsule()
            )
            .opacity(isEnabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

// MARK: - Empty state

struct LatticeEmptyState: View {
    enum Density: Sendable {
        case regular
        /// Inspector / palette hosts with limited vertical space.
        case compact
    }

    let title: String
    let message: String
    var systemImage: String = "bubble.left.and.bubble.right"
    var density: Density = .regular
    var primaryActionTitle: String?
    var primaryAction: (() -> Void)?
    var secondaryActionTitle: String?
    var secondaryAction: (() -> Void)?

    var body: some View {
        VStack(spacing: density == .compact ? 8 : 14) {
            Image(systemName: systemImage)
                .font(.system(size: density == .compact ? 20 : 28, weight: .medium))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
            VStack(spacing: density == .compact ? 4 : 6) {
                Text(title)
                    .font(density == .compact ? LatticeTypography.captionStrong : LatticeTypography.title)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .font(LatticeTypography.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if primaryActionTitle != nil || secondaryActionTitle != nil {
                HStack(spacing: 10) {
                    if let secondaryActionTitle, let secondaryAction {
                        Button(secondaryActionTitle, action: secondaryAction)
                            .buttonStyle(LatticeSecondaryButtonStyle())
                    }
                    if let primaryActionTitle, let primaryAction {
                        Button(primaryActionTitle, action: primaryAction)
                            .buttonStyle(LatticePrimaryButtonStyle())
                    }
                }
                .padding(.top, density == .compact ? 2 : 4)
            }
        }
        .frame(maxWidth: density == .compact ? 320 : 420)
        .padding(density == .compact ? 12 : 28)
        .frame(maxWidth: .infinity, maxHeight: density == .compact ? nil : .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(message)
    }
}

// MARK: - Section header + row

struct LatticeSectionHeader: View {
    let title: String
    var systemImage: String?
    var trailing: AnyView?

    init(title: String, systemImage: String? = nil, trailing: AnyView? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(title)
                .font(LatticeTypography.captionStrong)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.4)
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel(title)
    }
}

struct LatticeRow<Content: View>: View {
    var isSelected = false
    var cornerRadius: CGFloat = LatticeMetrics.compactRadius
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.14)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Spring helper

enum LatticeMotion {
    static func panelSpring(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: 0.24, extraBounce: 0.02)
    }

    static func quick(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.16)
    }
}
