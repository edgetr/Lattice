import Foundation
import Testing
@testable import LatticeCore

@Suite("Bounded protocol frames")
struct BoundedProtocolReaderTests {
    @Test func preservesValidFramesAndEOFPartialFrame() throws {
        let reader = try makeReader(Data(#"{"id":1}
{"id":2}"#.utf8))

        let first = try #require(reader.next())
        #expect(first["id"] as? Int == 1)
        let second = try #require(reader.next())
        #expect(second["id"] as? Int == 2)
        #expect(try reader.next() == nil)
    }

    @Test func rejectsOversizedFrame() throws {
        let reader = try makeReader(Data(#"{"value":"123456789"}
"#.utf8), maximumFrameBytes: 8)

        do {
            _ = try reader.next()
            Issue.record("Expected oversized frame error")
        } catch let error as ProtocolFrameError {
            #expect(error == .frameTooLarge(maximumBytes: 8))
        }
    }

    @Test func rejectsMalformedFrame() throws {
        let reader = try makeReader(Data(#"{"id":}
"#.utf8))

        do {
            _ = try reader.next()
            Issue.record("Expected malformed frame error")
        } catch let error as ProtocolFrameError {
            #expect(error == .malformedFrame)
        }
    }

    private func makeReader(_ data: Data, maximumFrameBytes: Int = ProtocolFrameLimits.maximumJSONLineBytes) throws -> BoundedJSONLineReader {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-protocol-\(UUID().uuidString)")
        try data.write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        try FileManager.default.removeItem(at: url)
        return BoundedJSONLineReader(handle, maximumFrameBytes: maximumFrameBytes)
    }
}
