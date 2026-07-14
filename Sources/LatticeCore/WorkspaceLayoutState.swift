import Foundation

/// Non-sensitive presentation state for one workspace window. Conversation content,
/// paths, provider state, and credentials must never be added to this preferences model.
public struct WorkspaceLayoutState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var selectedPage: String
    public var sidebarVisibility: String
    public var sidebarExpanded: Bool
    public var sidebarWidth: Double
    public var inspectorVisible: Bool
    public var inspectorWidth: Double
    public var primarySplitSizes: [Double]
    public var windowFrame: WorkspaceWindowFrame?
    public var windowIsMaximized: Bool

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        selectedPage: String = "conversations",
        sidebarVisibility: String = "all",
        sidebarExpanded: Bool = true,
        sidebarWidth: Double = 190,
        inspectorVisible: Bool = false,
        inspectorWidth: Double = 350,
        primarySplitSizes: [Double] = [280],
        windowFrame: WorkspaceWindowFrame? = nil,
        windowIsMaximized: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.selectedPage = selectedPage
        self.sidebarVisibility = sidebarVisibility
        self.sidebarExpanded = sidebarExpanded
        self.sidebarWidth = sidebarWidth
        self.inspectorVisible = inspectorVisible
        self.inspectorWidth = inspectorWidth
        self.primarySplitSizes = primarySplitSizes
        self.windowFrame = windowFrame
        self.windowIsMaximized = windowIsMaximized
    }
}

public struct WorkspaceWindowFrame: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

public struct WorkspaceLayoutArchive: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var windows: [String: WorkspaceLayoutState]

    public init(schemaVersion: Int = WorkspaceLayoutState.currentSchemaVersion, windows: [String: WorkspaceLayoutState] = [:]) {
        self.schemaVersion = schemaVersion
        self.windows = windows
    }
}

public enum WorkspaceLayoutStatePolicy {
    public static let minimumWindowWidth = 900.0
    public static let minimumWindowHeight = 620.0
    public static let minimumSidebarWidth = 56.0
    public static let maximumSidebarWidth = 220.0
    public static let minimumInspectorWidth = 300.0
    public static let maximumInspectorWidth = 420.0
    public static let minimumPrimarySplitWidth = 220.0
    public static let maximumPrimarySplitWidth = 340.0

    public static func decodeArchive(_ data: Data?) -> WorkspaceLayoutArchive {
        guard let data else { return WorkspaceLayoutArchive() }
        let decoder = JSONDecoder()
        if let archive = try? decoder.decode(WorkspaceLayoutArchive.self, from: data),
           archive.schemaVersion == WorkspaceLayoutState.currentSchemaVersion {
            return sanitizedArchive(archive)
        }
        if let legacy = try? decoder.decode(LegacyWorkspaceLayoutStateV1.self, from: data),
           legacy.schemaVersion == 1 {
            let migrated = WorkspaceLayoutState(
                selectedPage: legacy.selectedPage,
                sidebarVisibility: legacy.sidebarVisible ? "all" : "doubleColumn",
                sidebarExpanded: true,
                sidebarWidth: legacy.sidebarWidth,
                inspectorVisible: legacy.inspectorVisible,
                inspectorWidth: legacy.inspectorWidth,
                primarySplitSizes: [legacy.primarySplitWidth],
                windowFrame: legacy.windowFrame,
                windowIsMaximized: legacy.windowIsMaximized
            )
            return WorkspaceLayoutArchive(windows: ["main": sanitized(migrated)])
        }
        return WorkspaceLayoutArchive()
    }

    public static func encodeArchive(_ archive: WorkspaceLayoutArchive) -> Data? {
        try? JSONEncoder().encode(sanitizedArchive(archive))
    }

    public static func restoredState(
        for key: String,
        in archive: WorkspaceLayoutArchive,
        visibleScreens: [WorkspaceWindowFrame],
        availableContentWidth: Double? = nil
    ) -> WorkspaceLayoutState {
        let value = archive.windows[key] ?? WorkspaceLayoutState()
        return clamped(sanitized(value), visibleScreens: visibleScreens, availableContentWidth: availableContentWidth)
    }

    public static func updating(
        _ archive: WorkspaceLayoutArchive,
        key: String,
        state: WorkspaceLayoutState
    ) -> WorkspaceLayoutArchive {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return sanitizedArchive(archive) }
        var result = sanitizedArchive(archive)
        result.windows[key] = sanitized(state)
        return result
    }

    public static func clamped(
        _ state: WorkspaceLayoutState,
        visibleScreens: [WorkspaceWindowFrame],
        availableContentWidth: Double? = nil
    ) -> WorkspaceLayoutState {
        var result = sanitized(state)
        if let width = availableContentWidth, width.isFinite, width > 0 {
            let minimumMainColumns = minimumPrimarySplitWidth + 360
            if result.inspectorVisible,
               width - result.inspectorWidth - (result.sidebarVisibility == "all" ? result.sidebarWidth : 0) < minimumMainColumns {
                result.inspectorVisible = false
            }
            if result.sidebarVisibility == "all", width - result.sidebarWidth < minimumMainColumns {
                result.sidebarVisibility = "doubleColumn"
            }
            let reserved = (result.sidebarVisibility == "all" ? result.sidebarWidth : 0)
                + (result.inspectorVisible ? result.inspectorWidth : 0)
            let usablePrimary = max(minimumPrimarySplitWidth, width - reserved - 360)
            result.primarySplitSizes = result.primarySplitSizes.map {
                min($0, min(maximumPrimarySplitWidth, usablePrimary))
            }
        }
        guard let frame = result.windowFrame, !visibleScreens.isEmpty else { return result }
        let target = bestScreen(for: frame, screens: visibleScreens)
        let width = min(max(frame.width, minimumWindowWidth), target.width)
        let height = min(max(frame.height, minimumWindowHeight), target.height)
        result.windowFrame = WorkspaceWindowFrame(
            x: min(max(frame.x, target.x), target.maxX - width),
            y: min(max(frame.y, target.y), target.maxY - height),
            width: width,
            height: height
        )
        return result
    }

    private static func sanitizedArchive(_ archive: WorkspaceLayoutArchive) -> WorkspaceLayoutArchive {
        WorkspaceLayoutArchive(
            windows: archive.windows.reduce(into: [:]) { result, entry in
                guard !entry.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                result[entry.key] = sanitized(entry.value)
            }
        )
    }

    private static func sanitized(_ state: WorkspaceLayoutState) -> WorkspaceLayoutState {
        var result = state
        result.schemaVersion = WorkspaceLayoutState.currentSchemaVersion
        let knownPages = ["conversations", "projects", "models", "connections", "extensions"]
        if !knownPages.contains(result.selectedPage) { result.selectedPage = "conversations" }
        let knownVisibilities = ["all", "doubleColumn", "detailOnly"]
        if !knownVisibilities.contains(result.sidebarVisibility) { result.sidebarVisibility = "all" }
        result.sidebarWidth = finiteClamp(result.sidebarWidth, default: 190, min: minimumSidebarWidth, max: maximumSidebarWidth)
        result.inspectorWidth = finiteClamp(result.inspectorWidth, default: 350, min: minimumInspectorWidth, max: maximumInspectorWidth)
        let sizes = result.primarySplitSizes.prefix(4).map {
            finiteClamp($0, default: 280, min: minimumPrimarySplitWidth, max: maximumPrimarySplitWidth)
        }
        result.primarySplitSizes = sizes.isEmpty ? [280] : sizes
        if let frame = result.windowFrame,
           [frame.x, frame.y, frame.width, frame.height].allSatisfy(\.isFinite),
           frame.width > 0, frame.height > 0 {
            result.windowFrame = frame
        } else {
            result.windowFrame = nil
            result.windowIsMaximized = false
        }
        return result
    }

    private static func finiteClamp(_ value: Double, default fallback: Double, min lower: Double, max upper: Double) -> Double {
        guard value.isFinite else { return fallback }
        return Swift.min(Swift.max(value, lower), upper)
    }

    private static func bestScreen(for frame: WorkspaceWindowFrame, screens: [WorkspaceWindowFrame]) -> WorkspaceWindowFrame {
        screens.max { intersectionArea(frame, $0) < intersectionArea(frame, $1) } ?? screens[0]
    }

    private static func intersectionArea(_ lhs: WorkspaceWindowFrame, _ rhs: WorkspaceWindowFrame) -> Double {
        max(0, min(lhs.maxX, rhs.maxX) - max(lhs.x, rhs.x))
            * max(0, min(lhs.maxY, rhs.maxY) - max(lhs.y, rhs.y))
    }
}

private struct LegacyWorkspaceLayoutStateV1: Codable {
    let schemaVersion: Int
    let selectedPage: String
    let sidebarVisible: Bool
    let sidebarWidth: Double
    let inspectorVisible: Bool
    let inspectorWidth: Double
    let primarySplitWidth: Double
    let windowFrame: WorkspaceWindowFrame?
    let windowIsMaximized: Bool
}
