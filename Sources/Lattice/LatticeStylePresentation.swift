import SwiftUI
import LatticeCore

/// Presentation helpers derived from active extension style/layout/copy patches.
/// Kept out of AppState so orchestration does not own Color metrics.
enum LatticeStylePresentation {
    static func stylePatch(for target: LatticeStyleTarget, patches: [LatticeStylePatch]) -> LatticeStylePatch? {
        patches.reversed().first { $0.target == target || $0.target == .all }
    }

    static func tintColor(for target: LatticeStyleTarget, patches: [LatticeStylePatch]) -> Color? {
        stylePatch(for: target, patches: patches)?.tintHex.flatMap(Color.init(latticeHex:))
    }

    static func cornerRadius(for target: LatticeStyleTarget, default value: CGFloat, patches: [LatticeStylePatch]) -> CGFloat {
        CGFloat(stylePatch(for: target, patches: patches)?.cornerRadius ?? Double(value))
    }

    static func copyText(for target: LatticeCopyTarget, fallback: String, patches: [LatticeCopyPatch]) -> String {
        patches.reversed().first { $0.target == target }?.text ?? fallback
    }

    static func composerLayoutDensity(patches: [LatticeLayoutPatch]) -> LatticeLayoutDensity {
        patches.reversed().first { $0.target == .composer }?.density ?? .comfortable
    }

    static func composerSpacing(patches: [LatticeLayoutPatch]) -> CGFloat {
        switch composerLayoutDensity(patches: patches) {
        case .compact: 6
        case .comfortable: 9
        case .spacious: 13
        }
    }

    static func composerMaxWidth(patches: [LatticeLayoutPatch]) -> CGFloat {
        switch composerLayoutDensity(patches: patches) {
        case .compact: 680
        case .comfortable: 760
        case .spacious: 840
        }
    }

    static func composerHorizontalPadding(patches: [LatticeLayoutPatch]) -> CGFloat {
        switch composerLayoutDensity(patches: patches) {
        case .compact: 18
        case .comfortable: 28
        case .spacious: 36
        }
    }
}
