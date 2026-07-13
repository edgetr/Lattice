import SwiftUI

/// Known provider identities with dedicated visual marks in Models / Connections.
enum LatticeProviderIdentity: String, CaseIterable, Sendable {
    case codex
    case grok
    case opencode

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .grok: "Grok"
        case .opencode: "OpenCode"
        }
    }

    init?(providerID: String) {
        self.init(rawValue: providerID.lowercased())
    }
}

/// Distinct, monochrome provider mark. Avoids action-like SF Symbols such as
/// `xmark` (close) and `command` (palette shortcut) that previously stood in
/// for Grok and Codex identity.
struct ProviderIdentityMark: View {
    let identity: LatticeProviderIdentity
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.secondary.opacity(0.12))

            Group {
                switch identity {
                case .codex:
                    CodexProviderGlyph()
                case .grok:
                    GrokProviderGlyph()
                case .opencode:
                    OpenCodeProviderGlyph()
                }
            }
            .foregroundStyle(.secondary)
            .frame(width: size * 0.62, height: size * 0.62)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Compact readiness cue that does not rely on color alone.
/// Color remains supplemental; shape/symbol and accessibility value carry status.
struct ReadinessStatusIndicator: View {
    let ready: Bool
    /// Optional short status used as accessibility value when the surrounding
    /// row already announces a longer detail string.
    var accessibilityStatus: String? = nil

    var body: some View {
        Image(systemName: ready ? "checkmark.circle.fill" : "minus.circle")
            .font(.system(size: 13, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(ready ? Color.green : Color.secondary)
            .accessibilityLabel(ready ? "Ready" : "Not ready")
            .accessibilityValue(accessibilityStatus ?? (ready ? "Available" : "Unavailable"))
            .help(ready ? "Ready" : "Not ready")
    }
}

// MARK: - Provider glyphs (local vector, no remote assets)

/// Codex: paired curly braces — coding-agent identity, not the ⌘ key.
private struct CodexProviderGlyph: View {
    var body: some View {
        CodexBracesShape()
            .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            .aspectRatio(1, contentMode: .fit)
    }
}

/// Grok: geometric diamond ring with a solid center — not SF Symbol `xmark`.
private struct GrokProviderGlyph: View {
    var body: some View {
        ZStack {
            GrokDiamondShape()
                .stroke(style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))
            GrokDiamondShape()
                .fill()
                .scaleEffect(0.34)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// OpenCode: angled `</>` chevrons — open tooling / code-host identity.
private struct OpenCodeProviderGlyph: View {
    var body: some View {
        OpenCodeChevronsShape()
            .stroke(style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round))
            .aspectRatio(1, contentMode: .fit)
    }
}

private struct CodexBracesShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: rect.width * 0.06, dy: rect.height * 0.04)
        let midY = inset.midY
        let leftX = inset.minX + inset.width * 0.18
        let rightX = inset.maxX - inset.width * 0.18
        let jaw = inset.width * 0.16
        let notch = inset.width * 0.10

        var path = Path()

        // Left brace
        path.move(to: CGPoint(x: leftX + jaw, y: inset.minY))
        path.addLine(to: CGPoint(x: leftX, y: inset.minY))
        path.addLine(to: CGPoint(x: leftX, y: midY - notch))
        path.addLine(to: CGPoint(x: leftX - jaw * 0.55, y: midY))
        path.addLine(to: CGPoint(x: leftX, y: midY + notch))
        path.addLine(to: CGPoint(x: leftX, y: inset.maxY))
        path.addLine(to: CGPoint(x: leftX + jaw, y: inset.maxY))

        // Right brace
        path.move(to: CGPoint(x: rightX - jaw, y: inset.minY))
        path.addLine(to: CGPoint(x: rightX, y: inset.minY))
        path.addLine(to: CGPoint(x: rightX, y: midY - notch))
        path.addLine(to: CGPoint(x: rightX + jaw * 0.55, y: midY))
        path.addLine(to: CGPoint(x: rightX, y: midY + notch))
        path.addLine(to: CGPoint(x: rightX, y: inset.maxY))
        path.addLine(to: CGPoint(x: rightX - jaw, y: inset.maxY))

        return path
    }
}

private struct GrokDiamondShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: rect.width * 0.08, dy: rect.height * 0.08)
        var path = Path()
        path.move(to: CGPoint(x: inset.midX, y: inset.minY))
        path.addLine(to: CGPoint(x: inset.maxX, y: inset.midY))
        path.addLine(to: CGPoint(x: inset.midX, y: inset.maxY))
        path.addLine(to: CGPoint(x: inset.minX, y: inset.midY))
        path.closeSubpath()
        return path
    }
}

private struct OpenCodeChevronsShape: Shape {
    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: rect.width * 0.04, dy: rect.height * 0.10)
        let midY = inset.midY
        let left = inset.minX + inset.width * 0.08
        let midLeft = inset.minX + inset.width * 0.38
        let midRight = inset.maxX - inset.width * 0.38
        let right = inset.maxX - inset.width * 0.08
        let peak = inset.height * 0.36

        var path = Path()

        // <
        path.move(to: CGPoint(x: midLeft, y: midY - peak))
        path.addLine(to: CGPoint(x: left, y: midY))
        path.addLine(to: CGPoint(x: midLeft, y: midY + peak))

        // /
        path.move(to: CGPoint(x: inset.midX - inset.width * 0.06, y: inset.maxY - inset.height * 0.08))
        path.addLine(to: CGPoint(x: inset.midX + inset.width * 0.06, y: inset.minY + inset.height * 0.08))

        // >
        path.move(to: CGPoint(x: midRight, y: midY - peak))
        path.addLine(to: CGPoint(x: right, y: midY))
        path.addLine(to: CGPoint(x: midRight, y: midY + peak))

        return path
    }
}
