import Foundation

// MARK: - Computer frame domain

/// Observable control-boundary statement for provider computer-use frames.
/// Lattice never claims to mediate the provider's mouse or keyboard tools.
public enum ComputerFrameControlState: String, Codable, Sendable, Hashable {
    /// Lattice only observes frames supplied by the provider.
    case observeOnly
    /// Input tools remain owned and executed by the provider runtime.
    case providerOwned
}

public struct ComputerFrameControlBoundary: Hashable, Codable, Sendable, Equatable {
    public static let defaultStatement =
        "Controls remain provider-owned. Lattice observes frames only and does not mediate mouse or keyboard tools."

    public var state: ComputerFrameControlState
    public var statement: String

    public init(
        state: ComputerFrameControlState = .observeOnly,
        statement: String = ComputerFrameControlBoundary.defaultStatement
    ) {
        self.state = state
        let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        self.statement = trimmed.isEmpty ? Self.defaultStatement : trimmed
    }

    public static let observeOnly = ComputerFrameControlBoundary(state: .observeOnly)
}

/// A provider-supplied computer-use frame for observable UI only.
public struct ComputerFrame: Identifiable, Hashable, Codable, Sendable, Equatable {
    public static let maximumImageByteCount = 10 * 1024 * 1024
    public static let allowedImageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "tif", "tiff", "bmp", "heic", "heif"
    ]

    public let id: UUID
    public let provider: String
    public let timestamp: Date
    /// Local file path/URL string supplied by a structured provider event.
    public let imagePath: String
    /// Immutable bytes admitted at the provider-event boundary. The UI renders
    /// these bytes instead of reopening a provider-controlled path later.
    public let imageData: Data?
    /// Monotonic frame sequence when the provider supplies one.
    public let sequence: Int?
    /// Stable source identity (for example a computer-use tool call or stream id).
    public let sourceIdentity: String?
    public let controlBoundary: ComputerFrameControlBoundary

    public init(
        id: UUID = UUID(),
        provider: String,
        timestamp: Date = Date(),
        imagePath: String,
        imageData: Data? = nil,
        sequence: Int? = nil,
        sourceIdentity: String? = nil,
        controlBoundary: ComputerFrameControlBoundary = .observeOnly
    ) {
        self.id = id
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        self.timestamp = timestamp
        self.imagePath = imagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.imageData = imageData.flatMap { data in
            guard !data.isEmpty, data.count <= Self.maximumImageByteCount else { return nil }
            return data
        }
        self.sequence = sequence
        self.sourceIdentity = sourceIdentity?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.controlBoundary = controlBoundary
    }

    public var imageURL: URL? {
        guard imageData?.isEmpty == false else { return nil }
        return Self.validatedFileURL(from: imagePath)
    }

    public static func validatedFileURL(from pathOrURL: String) -> URL? {
        let trimmed = pathOrURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), url.isFileURL else { return nil }
            let path = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : url
        }

        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    /// Reads an immutable, bounded frame only when the provider path is a
    /// regular image file contained by one of the explicitly authorized roots.
    /// The descriptor-safe store reader rejects symlinks and unstable files.
    public static func authorizedImage(
        from pathOrURL: String,
        under allowedRoots: [URL],
        maximumByteCount: Int = maximumImageByteCount
    ) -> (url: URL, data: Data)? {
        guard maximumByteCount > 0,
              let url = validatedFileURL(from: pathOrURL) else { return nil }
        let ext = url.pathExtension.lowercased()
        guard allowedImageExtensions.contains(ext) else { return nil }

        for root in allowedRoots where root.isFileURL {
            do {
                let data = try LatticeStorePathSecurity.readData(at: url, under: root)
                guard !data.isEmpty, data.count <= maximumByteCount else { continue }
                return (url.standardizedFileURL, data)
            } catch {
                continue
            }
        }
        return nil
    }
}

// MARK: - Latest-frame accumulator

public enum ComputerFrameAcceptResult: Equatable, Sendable {
    case accepted
    case rejectedInvalidPath
    case rejectedRateLimited
    case rejectedStopped
    case rejectedCancelled
}

/// Deterministic, bounded, rate-limited latest-frame accumulator.
/// Pure Foundation state machine; suitable for `@MainActor` ownership. No timers.
public struct ComputerFrameAccumulator: Equatable, Sendable {
    public var minimumInterval: TimeInterval
    public var recentCapacity: Int

    public private(set) var latest: ComputerFrame?
    public private(set) var recent: [ComputerFrame]
    public private(set) var droppedCount: Int
    public private(set) var lastAcceptedAt: Date?
    public private(set) var isStopped: Bool
    public private(set) var isCancelled: Bool

    public init(
        minimumInterval: TimeInterval = 0.25,
        recentCapacity: Int = 8,
        latest: ComputerFrame? = nil,
        recent: [ComputerFrame] = [],
        droppedCount: Int = 0,
        lastAcceptedAt: Date? = nil,
        isStopped: Bool = false,
        isCancelled: Bool = false
    ) {
        self.minimumInterval = max(0, minimumInterval)
        self.recentCapacity = max(0, recentCapacity)
        self.latest = latest
        self.recent = recent
        self.droppedCount = max(0, droppedCount)
        self.lastAcceptedAt = lastAcceptedAt
        self.isStopped = isStopped
        self.isCancelled = isCancelled
    }

    public var isActive: Bool { !isStopped && !isCancelled }

    @discardableResult
    public mutating func offer(_ frame: ComputerFrame, observedAt: Date = Date()) -> ComputerFrameAcceptResult {
        if isCancelled {
            droppedCount += 1
            return .rejectedCancelled
        }
        if isStopped {
            droppedCount += 1
            return .rejectedStopped
        }
        guard frame.imageData?.isEmpty == false else {
            droppedCount += 1
            return .rejectedInvalidPath
        }
        if let lastAcceptedAt, observedAt.timeIntervalSince(lastAcceptedAt) < minimumInterval {
            droppedCount += 1
            return .rejectedRateLimited
        }

        latest = frame
        lastAcceptedAt = observedAt
        if recentCapacity > 0 {
            recent.append(frame)
            if recent.count > recentCapacity {
                recent.removeFirst(recent.count - recentCapacity)
            }
        } else {
            recent = []
        }
        return .accepted
    }

    public mutating func stop() {
        isStopped = true
    }

    public mutating func cancel() {
        isCancelled = true
        isStopped = true
    }

    public mutating func resetForNewRun() {
        latest = nil
        recent = []
        droppedCount = 0
        lastAcceptedAt = nil
        isStopped = false
        isCancelled = false
    }
}

// MARK: - Presentation policy

public enum ComputerFrameViewerVisibility: String, Sendable, Equatable {
    case hidden
    case visible
}

public enum ComputerFrameViewerContent: Equatable, Sendable {
    case none
    case latestFrameOnly(ComputerFrame)
    case imageUnavailable(reason: String)
}

public struct ComputerFrameViewerPresentation: Equatable, Sendable {
    public var visibility: ComputerFrameViewerVisibility
    public var content: ComputerFrameViewerContent
    public var isStopped: Bool
    public var isCancelled: Bool
    public var droppedCount: Int
    /// Always true: Lattice never owns provider mouse/keyboard tools.
    public var controlsRemainProviderOwned: Bool
    public var controlBoundaryStatement: String

    public init(
        visibility: ComputerFrameViewerVisibility,
        content: ComputerFrameViewerContent,
        isStopped: Bool,
        isCancelled: Bool,
        droppedCount: Int,
        controlsRemainProviderOwned: Bool = true,
        controlBoundaryStatement: String = ComputerFrameControlBoundary.defaultStatement
    ) {
        self.visibility = visibility
        self.content = content
        self.isStopped = isStopped
        self.isCancelled = isCancelled
        self.droppedCount = droppedCount
        self.controlsRemainProviderOwned = controlsRemainProviderOwned
        self.controlBoundaryStatement = controlBoundaryStatement
    }
}

public enum ComputerFramePresentationPolicy {
    public static let controlsOwnershipStatement = ComputerFrameControlBoundary.defaultStatement

    /// Pure presentation rules for the computer-frame viewer/card.
    public static func presentation(for accumulator: ComputerFrameAccumulator) -> ComputerFrameViewerPresentation {
        let statement = accumulator.latest?.controlBoundary.statement ?? controlsOwnershipStatement

        if accumulator.isCancelled {
            return ComputerFrameViewerPresentation(
                visibility: accumulator.latest == nil ? .hidden : .visible,
                content: content(for: accumulator.latest, unavailableReason: "Computer frame stream cancelled."),
                isStopped: true,
                isCancelled: true,
                droppedCount: accumulator.droppedCount,
                controlBoundaryStatement: statement
            )
        }

        if accumulator.isStopped {
            return ComputerFrameViewerPresentation(
                visibility: accumulator.latest == nil ? .hidden : .visible,
                content: content(for: accumulator.latest, unavailableReason: "Computer frame stream stopped."),
                isStopped: true,
                isCancelled: false,
                droppedCount: accumulator.droppedCount,
                controlBoundaryStatement: statement
            )
        }

        guard let latest = accumulator.latest else {
            return ComputerFrameViewerPresentation(
                visibility: .hidden,
                content: .none,
                isStopped: false,
                isCancelled: false,
                droppedCount: accumulator.droppedCount,
                controlBoundaryStatement: statement
            )
        }

        if latest.imageData?.isEmpty != false {
            return ComputerFrameViewerPresentation(
                visibility: .visible,
                content: .imageUnavailable(reason: "Computer frame image path is missing or not a local file."),
                isStopped: false,
                isCancelled: false,
                droppedCount: accumulator.droppedCount,
                controlBoundaryStatement: statement
            )
        }

        return ComputerFrameViewerPresentation(
            visibility: .visible,
            content: .latestFrameOnly(latest),
            isStopped: false,
            isCancelled: false,
            droppedCount: accumulator.droppedCount,
            controlBoundaryStatement: statement
        )
    }

    private static func content(for latest: ComputerFrame?, unavailableReason: String) -> ComputerFrameViewerContent {
        guard let latest else { return .none }
        if ComputerFrame.validatedFileURL(from: latest.imagePath) == nil {
            return .imageUnavailable(reason: unavailableReason)
        }
        return .latestFrameOnly(latest)
    }
}
