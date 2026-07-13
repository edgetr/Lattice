import Foundation

enum ProtocolFrameError: Error, Equatable, LocalizedError, Sendable {
    case frameTooLarge(maximumBytes: Int)
    case malformedFrame

    var errorDescription: String? {
        switch self {
        case .frameTooLarge(let maximumBytes):
            "Protocol frame exceeds \(maximumBytes) bytes."
        case .malformedFrame:
            "Protocol returned a malformed JSON frame."
        }
    }
}

enum ProtocolFrameLimits {
    static let maximumJSONLineBytes = 4 * 1024 * 1024
    static let readChunkBytes = 16 * 1024
}

struct BoundedJSONLineBuffer {
    private let maximumFrameBytes: Int
    private var buffer = Data()

    init(maximumFrameBytes: Int = ProtocolFrameLimits.maximumJSONLineBytes) {
        precondition(maximumFrameBytes > 0)
        self.maximumFrameBytes = maximumFrameBytes
    }

    mutating func append(_ chunk: Data) throws -> [[String: Any]] {
        var frames: [[String: Any]] = []
        for byte in chunk {
            if byte == 0x0A {
                if !buffer.isEmpty { frames.append(try decodeBufferedFrame()) }
            } else {
                guard buffer.count < maximumFrameBytes else {
                    throw ProtocolFrameError.frameTooLarge(maximumBytes: maximumFrameBytes)
                }
                buffer.append(byte)
            }
        }
        return frames
    }

    mutating func finish() throws -> [[String: Any]] {
        guard !buffer.isEmpty else { return [] }
        return [try decodeBufferedFrame()]
    }

    private mutating func decodeBufferedFrame() throws -> [String: Any] {
        let data = buffer
        buffer.removeAll(keepingCapacity: true)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProtocolFrameError.malformedFrame
        }
        return object
    }
}

final class BoundedJSONLineReader {
    private let readChunk: () throws -> Data?
    private var buffer: BoundedJSONLineBuffer
    private var pending: [[String: Any]] = []

    init(_ handle: FileHandle, maximumFrameBytes: Int = ProtocolFrameLimits.maximumJSONLineBytes) {
        self.readChunk = {
            try handle.read(upToCount: ProtocolFrameLimits.readChunkBytes) ?? Data()
        }
        self.buffer = BoundedJSONLineBuffer(maximumFrameBytes: maximumFrameBytes)
    }

    init(_ transport: BoundedProcessTransport, maximumFrameBytes: Int = ProtocolFrameLimits.maximumJSONLineBytes) {
        self.readChunk = {
            try transport.readChunk(maxLength: ProtocolFrameLimits.readChunkBytes) ?? Data()
        }
        self.buffer = BoundedJSONLineBuffer(maximumFrameBytes: maximumFrameBytes)
    }

    func next() throws -> [String: Any]? {
        if !pending.isEmpty { return pending.removeFirst() }
        while true {
            let chunk = try readChunk() ?? Data()
            if chunk.isEmpty {
                pending = try buffer.finish()
                return pending.isEmpty ? nil : pending.removeFirst()
            }
            pending = try buffer.append(chunk)
            if !pending.isEmpty { return pending.removeFirst() }
        }
    }
}
