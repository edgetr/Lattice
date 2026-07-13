import Foundation

public enum ModelInstallEvent: Sendable {
    case output(String)
    case completed
    case failed(String)
    case cancelled
}

public final class OllamaModelInstaller: @unchecked Sendable {
    private let executableURL: URL?
    private let lock = NSLock()
    private var process: Process?

    public init(executableURL: URL? = ExecutableDiscovery.locate("ollama")) { self.executableURL = executableURL }

    public func pull(_ tag: String) -> AsyncStream<ModelInstallEvent> {
        AsyncStream { continuation in
            Task.detached { [self] in
                guard let executableURL else { continuation.yield(.failed("Ollama is not installed.")); continuation.finish(); return }
                let process = Process(); let pipe = Pipe()
                process.executableURL = executableURL; process.arguments = ["pull", tag]
                process.standardOutput = pipe; process.standardError = pipe
                do {
                    try process.run(); lock.withLock { self.process = process }
                    while true {
                        let chunk = try pipe.fileHandleForReading.read(upToCount: 4096) ?? Data()
                        if chunk.isEmpty { break }
                        if let text = String(data: chunk, encoding: .utf8) {
                            let line = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).last.map(String.init) ?? text
                            continuation.yield(.output(line))
                        }
                    }
                    process.waitUntilExit(); let wasCancelled = lock.withLock { let value = self.process == nil; self.process = nil; return value }
                    if wasCancelled { continuation.yield(.cancelled) }
                    else if process.terminationStatus == 0 { continuation.yield(.completed) }
                    else { continuation.yield(.failed("Model download failed.")) }
                } catch { continuation.yield(.failed(error.localizedDescription)) }
                continuation.finish()
            }
        }
    }

    public func cancel() {
        lock.lock(); let current = process; process = nil; lock.unlock()
        if current?.isRunning == true { current?.terminate() }
    }
}
