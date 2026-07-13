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
