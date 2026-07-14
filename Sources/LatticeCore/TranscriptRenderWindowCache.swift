import Foundation

public struct TranscriptRenderWindow: Equatable, Sendable {
    public let range: Range<Int>
    public let totalCount: Int

    public var hiddenEarlierCount: Int { range.lowerBound }

    public init(range: Range<Int>, totalCount: Int) {
        self.range = range
        self.totalCount = totalCount
    }
}

/// Bounded LRU cache of per-thread render windows. It stores only integer ranges; durable messages
/// stay in the transcript store and the active session remains the source of truth.
public struct TranscriptRenderWindowCache: Sendable {
    public let pageSize: Int
    public let maximumThreadCount: Int
    public let maximumVisibleMessageCount: Int

    private struct Entry: Sendable {
        var lowerBound: Int
        var totalCount: Int
        var accessSequence: UInt64
    }

    private var entries: [UUID: Entry] = [:]
    private var sequence: UInt64 = 0

    public init(pageSize: Int = 100, maximumThreadCount: Int = 6, maximumVisibleMessageCount: Int = 1_200) {
        precondition(pageSize > 0 && maximumThreadCount > 0 && maximumVisibleMessageCount >= pageSize)
        self.pageSize = pageSize
        self.maximumThreadCount = maximumThreadCount
        self.maximumVisibleMessageCount = maximumVisibleMessageCount
    }

    public var cachedThreadCount: Int { entries.count }
    public var cachedVisibleMessageCount: Int {
        entries.values.reduce(0) { $0 + ($1.totalCount - $1.lowerBound) }
    }

    public mutating func activate(sessionID: UUID, messageCount: Int) -> TranscriptRenderWindow {
        sequence &+= 1
        let count = max(0, messageCount)
        var entry = entries[sessionID] ?? Entry(
            lowerBound: max(0, count - pageSize), totalCount: count, accessSequence: sequence
        )
        let previouslyAtTail = entry.lowerBound >= max(0, entry.totalCount - pageSize)
        entry.totalCount = count
        if previouslyAtTail {
            entry.lowerBound = max(0, count - pageSize)
        } else {
            entry.lowerBound = min(entry.lowerBound, count)
        }
        entry.accessSequence = sequence
        entries[sessionID] = entry
        trim(protecting: sessionID)
        return window(for: sessionID, messageCount: count)
    }

    public mutating func loadEarlier(sessionID: UUID, messageCount: Int) -> TranscriptRenderWindow {
        _ = activate(sessionID: sessionID, messageCount: messageCount)
        guard var entry = entries[sessionID] else { return window(for: sessionID, messageCount: messageCount) }
        sequence &+= 1
        entry.lowerBound = max(max(0, entry.totalCount - maximumVisibleMessageCount), entry.lowerBound - pageSize)
        entry.accessSequence = sequence
        entries[sessionID] = entry
        trim(protecting: sessionID)
        return window(for: sessionID, messageCount: messageCount)
    }

    public func window(for sessionID: UUID, messageCount: Int) -> TranscriptRenderWindow {
        let count = max(0, messageCount)
        let lower = min(entries[sessionID]?.lowerBound ?? max(0, count - pageSize), count)
        return TranscriptRenderWindow(range: lower..<count, totalCount: count)
    }

    public mutating func invalidate(sessionID: UUID) {
        entries.removeValue(forKey: sessionID)
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
    }

    private mutating func trim(protecting protectedID: UUID) {
        while entries.count > maximumThreadCount {
            guard let victim = entries.filter({ $0.key != protectedID }).min(by: { $0.value.accessSequence < $1.value.accessSequence })?.key else { break }
            entries.removeValue(forKey: victim)
        }
        while cachedVisibleMessageCount > maximumVisibleMessageCount {
            let candidates = entries.filter { $0.key != protectedID && $0.value.totalCount - $0.value.lowerBound > pageSize }
            if let victim = candidates.min(by: { $0.value.accessSequence < $1.value.accessSequence })?.key,
               var entry = entries[victim] {
                entry.lowerBound = min(entry.totalCount, entry.lowerBound + pageSize)
                entries[victim] = entry
            } else if let victim = entries
                .filter({ $0.key != protectedID })
                .min(by: { $0.value.accessSequence < $1.value.accessSequence })?.key {
                entries.removeValue(forKey: victim)
            } else {
                break
            }
        }
    }
}
