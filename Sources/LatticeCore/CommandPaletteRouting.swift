import Foundation

/// How the command palette should open relative to the active surface.
public enum LatticeCommandPaletteOpenRoute: Equatable, Sendable {
    /// Present the palette sheet on the already-front workspace surface.
    case presentInPlace
    /// Hand off from the floating overlay to a single workspace window, then present.
    case handoffToWorkspaceThenPresent
}

/// Pure routing decisions for opening the command palette.
///
/// The overlay header must not call palette presentation and workspace open as two
/// uncoordinated side effects — that can race window activation against sheet focus.
public enum LatticeCommandPaletteRouting: Sendable {
    /// Choose the open path from overlay visibility alone.
    public static func route(isOverlayVisible: Bool) -> LatticeCommandPaletteOpenRoute {
        isOverlayVisible ? .handoffToWorkspaceThenPresent : .presentInPlace
    }

    /// When handing off from the overlay, defer sheet presentation until after the
    /// workspace window has been ordered front so search focus sticks.
    public static func shouldDeferPresentation(for route: LatticeCommandPaletteOpenRoute) -> Bool {
        route == .handoffToWorkspaceThenPresent
    }
}
