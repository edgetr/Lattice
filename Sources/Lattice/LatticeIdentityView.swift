import AppKit
import SwiftUI
import LatticeCore

private enum LatticeCompanionAsset {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "LatticeCompanion", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()
}

struct LatticeCompanionMark: View {
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let image = LatticeCompanionAsset.image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                LatticeIdentityMark(size: size)
            }
        }
        .frame(width: size, height: size)
        .accessibilityIdentifier(LatticeAccessibilityID.companionMark)
        .accessibilityLabel("Lattice companion")
    }
}

struct LatticeIdentityMark: View {
    var size: CGFloat = 34

    private let petalColors: [Color] = [
        Color(red: 0.97, green: 0.79, blue: 0.66),
        Color(red: 0.97, green: 0.67, blue: 0.70),
        Color(red: 0.95, green: 0.58, blue: 0.66),
        Color(red: 0.93, green: 0.46, blue: 0.61),
        Color(red: 0.90, green: 0.32, blue: 0.57)
    ]

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.54, blue: 0.35),
                            Color(red: 0.91, green: 0.40, blue: 0.25)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            ForEach(Array(petalColors.enumerated()), id: \.offset) { index, color in
                LatticeFlowerPetal()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.98), color.opacity(0.82)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: size * 0.25, height: size * 0.37)
                    .offset(y: -size * 0.105)
                    .rotationEffect(.degrees(Double(index) * 72))
            }

            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.96, green: 0.77, blue: 0.55),
                            Color(red: 0.93, green: 0.66, blue: 0.42)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 0.30, height: size * 0.30)
                .overlay(Circle().stroke(.white.opacity(0.13), lineWidth: max(0.5, size * 0.018)))

            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .stroke(.white.opacity(0.15), lineWidth: max(0.5, size * 0.022))
        }
        .frame(width: size, height: size)
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

private struct LatticeFlowerPetal: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.10, y: rect.height * 0.34),
            control1: CGPoint(x: rect.width * 0.20, y: rect.height * 0.82),
            control2: CGPoint(x: -rect.width * 0.02, y: rect.height * 0.55)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.minY),
            control1: CGPoint(x: rect.width * 0.12, y: rect.height * 0.10),
            control2: CGPoint(x: rect.width * 0.33, y: rect.minY)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX - rect.width * 0.10, y: rect.height * 0.34),
            control1: CGPoint(x: rect.width * 0.67, y: rect.minY),
            control2: CGPoint(x: rect.width * 0.88, y: rect.height * 0.10)
        )
        path.addCurve(
            to: CGPoint(x: rect.midX, y: rect.maxY),
            control1: CGPoint(x: rect.width * 1.02, y: rect.height * 0.55),
            control2: CGPoint(x: rect.width * 0.80, y: rect.height * 0.82)
        )
        path.closeSubpath()
        return path
    }
}

struct LatticeIdentityAnchor: View {
    var body: some View {
        HStack(spacing: 9) {
            LatticeCompanionMark(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Lattice")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Workspace assistant")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .latticeGlass(cornerRadius: 22, tint: Color(red: 0.95, green: 0.42, blue: 0.25).opacity(0.08))
        .accessibilityElement(children: .combine)
    }
}
