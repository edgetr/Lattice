import Foundation
import Darwin
import Testing
@testable import LatticeCore

@Suite("Bounded interactive process transport")
struct BoundedProcessTransportTests {
    private var shell: URL { URL(fileURLWithPath: "/bin/sh") }

    @Test func deadlineStopsBlockedProtocolRead() async {
        let reason = await BoundedSubprocess.performOffCooperativeExecutor { () -> BoundedProcessTerminationReason? in
            let transport = BoundedProcessTransport(request: BoundedSubprocessRequest(
                executableURL: shell,
                arguments: ["-c", "while true; do sleep 0.05; done"],
                deadline: 0.12,
                maximumOutputBytes: 1024,
                terminateGraceInterval: 0.03
            ))
            do {
                try transport.start()
                _ = try transport.readLine()
            } catch {
                transport.cancel()
            }
            return transport.terminationReason
        }
        #expect(reason == .timedOut)
    }

    @Test func protocolOutputCapStopsOversizedLine() async {
        let result = await BoundedSubprocess.performOffCooperativeExecutor { () -> (BoundedProcessTerminationReason?, Int) in
            let transport = BoundedProcessTransport(request: BoundedSubprocessRequest(
                executableURL: shell,
                arguments: ["-c", "dd if=/dev/zero bs=4096 count=16 2>/dev/null"],
                deadline: 5,
                maximumOutputBytes: 1024,
                terminateGraceInterval: 0.03
            ))
            do {
                try transport.start()
                _ = try transport.readLine()
            } catch {
                transport.cancel()
            }
            return (transport.terminationReason, transport.observedOutputBytes)
        }
        #expect(result.0 == .outputLimitExceeded)
        #expect(result.1 > 1024)
    }

    @Test func cancellationStopsReadAndAllowsNextProcess() async {
        let outcome = await BoundedSubprocess.performOffCooperativeExecutor { () -> Bool in
            let transport = BoundedProcessTransport(request: BoundedSubprocessRequest(
                executableURL: shell,
                arguments: ["-c", "while true; do sleep 0.05; done"],
                deadline: 10,
                maximumOutputBytes: 1024,
                terminateGraceInterval: 0.03
            ))
            try? transport.start()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.08) { transport.cancel() }
            do { _ = try transport.readLine() } catch {}
            let cancelled = transport.terminationReason == .cancelled && !transport.isRunning

            let recovery = BoundedProcessTransport(request: BoundedSubprocessRequest(
                executableURL: shell,
                arguments: ["-c", "printf 'recovered\n'"],
                deadline: 2,
                maximumOutputBytes: 1024
            ))
            do {
                try recovery.start()
                let line = try recovery.readLine()
                recovery.finish()
                return cancelled && String(data: line ?? Data(), encoding: .utf8) == "recovered"
            } catch {
                recovery.cancel()
                return false
            }
        }
        #expect(outcome)
    }

    @Test func timeoutCleansUpDescendantProcessTree() async {
        let descendantWasReaped = await BoundedSubprocess.performOffCooperativeExecutor { () -> Bool in
            let transport = BoundedProcessTransport(request: .init(
                executableURL: self.shell,
                arguments: ["-c", "sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait"],
                deadline: 0.15,
                maximumOutputBytes: 1024,
                terminateGraceInterval: 0.03
            ))
            do {
                try transport.start()
                guard let line = try transport.readLine(),
                      let childPID = pid_t(String(decoding: line, as: UTF8.self)) else {
                    transport.cancel()
                    return false
                }
                do { _ = try transport.readLine() } catch {}
                let deadline = Date().addingTimeInterval(0.5)
                while Date() < deadline {
                    if kill(childPID, 0) == -1, errno == ESRCH { return true }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                return kill(childPID, 0) == -1 && errno == ESRCH
            } catch {
                transport.cancel()
                return false
            }
        }
        #expect(descendantWasReaped)
    }
    @Test func immediateWriteReadRoundTripPreservesParentPipeEnds() async {
        let line = await BoundedSubprocess.performOffCooperativeExecutor { () -> String? in
            let transport = BoundedProcessTransport(request: .init(
                executableURL: self.shell,
                arguments: ["-c", "IFS= read -r value; printf '%s\\n' \"$value\""],
                deadline: 2,
                maximumOutputBytes: 1024
            ))
            do {
                try transport.start()
                try transport.write(Data("round-trip\n".utf8))
                let data = try transport.readLine()
                transport.finish()
                return data.map { String(decoding: $0, as: UTF8.self) }
            } catch {
                transport.cancel()
                return nil
            }
        }
        #expect(line == "round-trip")
    }

    @Test func fastExitRetainsBufferedOutputWithoutFalseLaunchFailure() async {
        let result = await BoundedSubprocess.performOffCooperativeExecutor { () -> (String?, Int32?) in
            let transport = BoundedProcessTransport(request: .init(
                executableURL: self.shell,
                arguments: ["-c", "printf 'fast-exit\\n'"],
                deadline: 2,
                maximumOutputBytes: 1024
            ))
            do {
                try transport.start()
                let data = try transport.readLine()
                let status = transport.waitForExit()
                transport.finish()
                return (data.map { String(decoding: $0, as: UTF8.self) }, status)
            } catch {
                transport.cancel()
                return (nil, nil)
            }
        }
        #expect(result.0 == "fast-exit")
        #expect(result.1 == 0)
    }

    @Test func transportBackedJSONReaderEnforcesTotalOutputLimit() async {
        let reason = await BoundedSubprocess.performOffCooperativeExecutor { () -> BoundedProcessTerminationReason? in
            let transport = BoundedProcessTransport(request: .init(
                executableURL: self.shell,
                arguments: ["-c", "i=0; while [ $i -lt 20 ]; do printf '{\"value\":\"1234567890\"}\\n'; i=$((i+1)); done"],
                deadline: 2,
                maximumOutputBytes: 128,
                terminateGraceInterval: 0.03
            ))
            do {
                try transport.start()
                let reader = BoundedJSONLineReader(transport, maximumFrameBytes: 64)
                while try reader.next() != nil {}
            } catch {}
            let reason = transport.terminationReason
            transport.cancel()
            return reason
        }
        #expect(reason == .outputLimitExceeded)
    }

    @Test func fastExitCleanupDoesNotWaitFullTerminationGrace() async {
        let elapsed = await BoundedSubprocess.performOffCooperativeExecutor { () -> TimeInterval in
            let transport = BoundedProcessTransport(request: .init(
                executableURL: self.shell,
                arguments: ["-c", "exit 0"],
                deadline: 2,
                maximumOutputBytes: 1024,
                terminateGraceInterval: 0.5
            ))
            try? transport.start()
            _ = transport.waitForExit()
            let start = Date()
            transport.finish()
            return Date().timeIntervalSince(start)
        }
        #expect(elapsed < 0.2)
    }

    @Test func concurrentLargeProtocolWritesRemainWholeFrames() async {
        let framesAreWhole = await BoundedSubprocess.performOffCooperativeExecutor { () -> Bool in
            let payloadA = String(repeating: "a", count: 128_000)
            let payloadB = String(repeating: "b", count: 128_000)
            let frames = ["{\"value\":\"\(payloadA)\"}\n", "{\"value\":\"\(payloadB)\"}\n"]
            let transport = BoundedProcessTransport(request: .init(
                executableURL: self.shell,
                arguments: ["-c", "awk '{ print length($0) }'"],
                deadline: 2,
                maximumOutputBytes: 1_000_000,
                terminateGraceInterval: 0.03
            ))
            do {
                try transport.start()
                let group = DispatchGroup()
                let results = LockedWriteResults()
                for frame in frames {
                    group.enter()
                    DispatchQueue.global().async {
                        do { try transport.write(Data(frame.utf8)) }
                        catch { results.recordFailure() }
                        group.leave()
                    }
                }
                group.wait()
                transport.closeInput()
                var lengths: [Int] = []
                while let line = try transport.readLine() {
                    if let length = Int(String(decoding: line, as: UTF8.self)) { lengths.append(length) }
                }
                transport.finish()
                guard !results.failed else { return false }
                return lengths.sorted() == frames.map { Data($0.utf8).count - 1 }.sorted()
            } catch {
                transport.cancel()
                return false
            }
        }
        #expect(framesAreWhole)
    }

    private final class LockedWriteResults: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var failed = false

        func recordFailure() {
            lock.lock()
            failed = true
            lock.unlock()
        }
    }
}
