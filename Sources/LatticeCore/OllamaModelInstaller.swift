import Foundation

public enum ModelInstallEvent: Sendable, Equatable {
    case output(String)
    case completed
    case failed(String)
    case cancelled
}

/// Runs one bounded Ollama pull at a time.
///
/// Progress is intentionally a newest-value stream: a slow view does not retain an
/// unbounded copy of provider output, while terminal events are always the newest item.
public final class OllamaModelInstaller: @unchecked Sendable {
    private final class ActiveDownload: @unchecked Sendable {
        let id = UUID()
        var transport: BoundedProcessTransport?
        var cancellationRequested = false
    }

    public static let maximumTagBytes = 512
    public static let maximumProgressCharacters = 4_096
    public static let pullDeadline: TimeInterval = 60 * 60
    public static let maximumObservedOutputBytes = 32 * 1_024 * 1_024

    private let executableURL: URL?
    private let lock = NSLock()
    private var activeDownload: ActiveDownload?

    public init(executableURL: URL? = ExecutableDiscovery.locate("ollama")) {
        self.executableURL = executableURL
    }

    public static func isValidTag(_ rawTag: String) -> Bool {
        guard !rawTag.isEmpty,
              rawTag == rawTag.trimmingCharacters(in: .whitespacesAndNewlines),
              rawTag.utf8.count <= maximumTagBytes,
              rawTag.first != "-" else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-/:@"))
        return rawTag.unicodeScalars.allSatisfy(allowed.contains)
    }

    public static func progressText(from raw: String) -> String? {
        let withoutControls = String(raw.unicodeScalars.filter { scalar in
            scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        })
        let trimmed = withoutControls.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return CLIActionStatusPolicy.redactedDetail(String(trimmed.prefix(maximumProgressCharacters)))
    }

    public func pull(_ tag: String) -> AsyncStream<ModelInstallEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            guard Self.isValidTag(tag) else {
                continuation.yield(.failed("The Ollama model tag is invalid."))
                continuation.finish()
                return
            }

            let download = ActiveDownload()
            guard begin(download) else {
                continuation.yield(.failed("Another Ollama model download is already running."))
                continuation.finish()
                return
            }

            let task = Task { [self] in
                await BoundedSubprocess.performOffCooperativeExecutor {
                    self.run(tag: tag, download: download, continuation: continuation)
                }
            }
            continuation.onTermination = { [weak self] termination in
                guard case .cancelled = termination else { return }
                self?.cancel(download)
                task.cancel()
            }
        }
    }

    public func cancel() {
        let download = lock.withLock { activeDownload }
        if let download { cancel(download) }
    }

    private func begin(_ download: ActiveDownload) -> Bool {
        lock.withLock {
            guard activeDownload == nil else { return false }
            activeDownload = download
            return true
        }
    }

    private func attach(_ transport: BoundedProcessTransport, to download: ActiveDownload) -> Bool {
        lock.withLock {
            guard activeDownload === download, !download.cancellationRequested else { return false }
            download.transport = transport
            return true
        }
    }

    private func finish(_ download: ActiveDownload) -> Bool {
        lock.withLock {
            let wasCancelled = download.cancellationRequested
            if activeDownload === download { activeDownload = nil }
            download.transport = nil
            return wasCancelled
        }
    }

    private func cancel(_ download: ActiveDownload) {
        let transport = lock.withLock { () -> BoundedProcessTransport? in
            guard activeDownload === download else { return nil }
            download.cancellationRequested = true
            return download.transport
        }
        transport?.cancel()
    }

    private func run(
        tag: String,
        download: ActiveDownload,
        continuation: AsyncStream<ModelInstallEvent>.Continuation
    ) {
        guard let executableURL else {
            _ = finish(download)
            continuation.yield(.failed("Ollama is not installed."))
            continuation.finish()
            return
        }

        let transport = BoundedProcessTransport(
            request: .init(
                executableURL: executableURL,
                arguments: ["pull", tag],
                environment: ChildProcessEnvironmentPolicy.providerOwnedRuntime(),
                deadline: Self.pullDeadline,
                maximumOutputBytes: Self.maximumObservedOutputBytes
            ),
            mergeStandardError: true
        )
        guard attach(transport, to: download) else {
            transport.cancel()
            _ = finish(download)
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        do {
            try transport.start()
            transport.closeInput()
            while let chunk = try transport.readChunk(maxLength: 16_384) {
                let text = String(decoding: chunk, as: UTF8.self)
                for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
                    if let progress = Self.progressText(from: String(line)) {
                        continuation.yield(.output(progress))
                    }
                }
            }
            let status = transport.waitForExit(timeout: 2)
            let wasCancelled = finish(download)
            if wasCancelled || transport.terminationReason == .cancelled {
                continuation.yield(.cancelled)
            } else if transport.terminationReason == .timedOut {
                continuation.yield(.failed("The Ollama model download timed out."))
            } else if transport.terminationReason == .outputLimitExceeded {
                continuation.yield(.failed("Ollama progress output exceeded Lattice's safety limit."))
            } else if status == 0 {
                continuation.yield(.completed)
            } else if let status {
                continuation.yield(.failed("Ollama model download exited with status \(status)."))
            } else {
                transport.cancel()
                continuation.yield(.failed("Ollama did not exit cleanly."))
            }
        } catch {
            let wasCancelled = finish(download)
            transport.cancel()
            if wasCancelled || transport.terminationReason == .cancelled {
                continuation.yield(.cancelled)
            } else if transport.terminationReason == .timedOut {
                continuation.yield(.failed("The Ollama model download timed out."))
            } else if transport.terminationReason == .outputLimitExceeded {
                continuation.yield(.failed("Ollama progress output exceeded Lattice's safety limit."))
            } else {
                continuation.yield(.failed("Ollama model download failed: \(error.localizedDescription)"))
            }
        }
        continuation.finish()
    }
}
