import AppKit
import SwiftUI

// MARK: - Shared chrome metrics

/// Tiny semantic tokens for duplicated visible metrics (radii, padding, icon targets).
/// Prefer these when a call site already matches the shared value; do not force-rewrite unique layout.
enum LatticeMetrics {
    /// Default glass / material surface radius.
    static let glassRadius: CGFloat = 16
    /// Compact chips, meters, and inline alerts.
    static let compactRadius: CGFloat = 12
    /// Dense control and strip surfaces.
    static let controlRadius: CGFloat = 14
    /// Catalog cards and provider sections.
    static let cardRadius: CGFloat = 18
    /// Primary page surfaces and large content blocks.
    static let surfaceRadius: CGFloat = 20
    /// Standard inset inside glass cards.
    static let cardPadding: CGFloat = 14
    /// Comfortable inset for larger catalog panels.
    static let panelPadding: CGFloat = 16
    /// Shared vertical inset for catalog / page scroll hosts (around page headers).
    static let pageVerticalPadding: CGFloat = 24
    /// Bottom breathing room under page titles before the first content block.
    static let pageHeaderBottomSpacing: CGFloat = 4
}

// MARK: - Content surface

/// Quiet, opaque grouping for dense content. Glass is reserved for chrome and
/// floating controls so nested information does not become a stack of blur.
struct LatticeContentSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                Color.primary.opacity(colorScheme == .dark ? 0.055 : 0.035),
                in: shape
            )
            .overlay {
                if colorSchemeContrast == .increased {
                    shape.strokeBorder(Color.primary.opacity(0.28), lineWidth: 1.5)
                }
            }
    }
}

// MARK: - Glass surface

struct GlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool
    let tint: Color?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var increasedContrast: Bool { colorSchemeContrast == .increased }

    private var outlineColor: Color {
        if increasedContrast {
            return colorScheme == .dark ? Color.primary.opacity(0.42) : Color.primary.opacity(0.28)
        }
        return colorScheme == .dark ? Color.primary.opacity(0.16) : Color.primary.opacity(0.10)
    }

    private var outlineWidth: CGFloat { increasedContrast ? 1.5 : 1 }

    private var opaqueFill: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private var tintOpacity: Double {
        if tint == nil { return 0 }
        if reduceTransparency { return increasedContrast ? 0.10 : 0.08 }
        return increasedContrast ? 0.18 : 0.16
    }

    private var lightShadowOpacity: Double {
        if reduceTransparency || colorScheme == .dark { return 0 }
        return increasedContrast ? 0.10 : 0.07
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        if reduceTransparency {
            // Opaque semantic surface + visible boundary when Reduce Transparency is on.
            content
                .background(opaqueFill, in: shape)
                .background((tint ?? .clear).opacity(tintOpacity), in: shape)
                .overlay(shape.strokeBorder(outlineColor, lineWidth: outlineWidth))
                .shadow(color: .black.opacity(lightShadowOpacity), radius: 2, x: 0, y: 1)
        } else if #available(macOS 26.0, *) {
            content
                .glassEffect(
                    (interactive ? Glass.regular.interactive() : Glass.regular)
                        .tint(tint?.opacity(tintOpacity)),
                    in: shape
                )
                .overlay {
                    if increasedContrast {
                        shape.strokeBorder(outlineColor, lineWidth: outlineWidth)
                    }
                }
                .shadow(color: colorScheme == .dark ? .clear : .black.opacity(lightShadowOpacity), radius: 2, x: 0, y: 1)
                .shadow(color: colorScheme == .dark ? .clear : .black.opacity(increasedContrast ? 0.06 : 0.04), radius: 8, x: 0, y: 3)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .background((tint ?? .clear).opacity(tintOpacity), in: shape)
                .overlay(shape.strokeBorder(outlineColor, lineWidth: outlineWidth))
                .shadow(color: colorScheme == .dark ? .clear : .black.opacity(lightShadowOpacity), radius: 2, x: 0, y: 1)
                .shadow(color: colorScheme == .dark ? .clear : .black.opacity(increasedContrast ? 0.06 : 0.04), radius: 8, x: 0, y: 3)
        }
    }
}

extension View {
    func latticeGlass(cornerRadius: CGFloat = LatticeMetrics.glassRadius, interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassSurface(cornerRadius: cornerRadius, interactive: interactive, tint: tint))
    }

    func latticeContentSurface(cornerRadius: CGFloat = LatticeMetrics.surfaceRadius) -> some View {
        modifier(LatticeContentSurface(cornerRadius: cornerRadius))
    }
}

struct LatticeGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

// MARK: - Icon button chrome

/// Named sizes for pointer-first macOS icon chrome.
/// Keep `prominent` (40×40) for floating composer/overlay weight; use denser sizes in lists and transcripts.
/// Interaction targets are always at least 40×40; visual glyph/background chrome stays compact.
enum LatticeIconButtonSize: Equatable, Sendable {
    /// Dense list, transcript, search-field, and attachment chrome.
    case compact
    /// Secondary toolbar and medium-density chrome.
    case regular
    /// Floating composer and primary overlay header actions.
    case prominent

    /// Minimum interaction target side (HIG-friendly pointer target).
    static let minimumInteractionSide: CGFloat = 40

    /// Visual chrome side length (glyph + glass background). Compact stays dense in rows.
    var side: CGFloat {
        switch self {
        case .compact: 28
        case .regular: 32
        case .prominent: 40
        }
    }

    /// Layout / hit-testing side length. Always ≥ `minimumInteractionSide`.
    var interactionSide: CGFloat {
        max(side, Self.minimumInteractionSide)
    }

    var symbolPointSize: CGFloat {
        switch self {
        case .compact: 12
        case .regular: 12
        case .prominent: 13
        }
    }

    var cornerRadius: CGFloat { side / 2 }
}

struct LatticeIconButtonStyle: ButtonStyle {
    var size: LatticeIconButtonSize = .regular
    var isDestructive = false
    var tint: Color? = nil
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size.symbolPointSize, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isDestructive ? Color.red : (tint ?? Color.secondary))
            // Compact visual chrome (glyph + glass circle).
            .frame(width: size.side, height: size.side)
            .latticeGlass(
                cornerRadius: size.cornerRadius,
                interactive: true,
                tint: tint?.opacity(colorSchemeContrast == .increased ? 0.14 : 0.10)
            )
            // Expand layout/hit target to ≥40×40 without growing adjacent chrome into each other:
            // interaction frames abut with HStack spacing; visual circles stay size.side and centered.
            .frame(width: size.interactionSide, height: size.interactionSide)
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct LatticeScaleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.42)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension Color {
    init?(latticeHex value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6 || hex.count == 8, let raw = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let red = hasAlpha ? Double((raw >> 24) & 0xff) / 255 : Double((raw >> 16) & 0xff) / 255
        let green = hasAlpha ? Double((raw >> 16) & 0xff) / 255 : Double((raw >> 8) & 0xff) / 255
        let blue = hasAlpha ? Double((raw >> 8) & 0xff) / 255 : Double(raw & 0xff) / 255
        let alpha = hasAlpha ? Double(raw & 0xff) / 255 : 1
        self = Color(red: red, green: green, blue: blue, opacity: alpha)
    }
}
