import Foundation

/// Spawns a binary, drains stdout/stderr without deadlocking, enforces a deadline,
/// and maps the exit status to `EngineError`. All process interaction is confined
/// to one background dispatch and bridged to async with a single continuation
/// resume, so no non-Sendable process state crosses a concurrency boundary.
public struct ProcessClient: Sendable {
    public init() {}

    /// Runs `executable` with `arguments`, returning stdout on success.
    /// - `timeout`: wall-clock deadline; on elapse the process gets SIGTERM, then
    ///   SIGKILL after a short grace, and the call throws `.timeout`.
    /// - Throws `EngineError` only.
    public func run(executable: URL,
                    arguments: [String],
                    timeout: TimeInterval = 20,
                    environment: [String: String]? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                switch Self.runBlocking(executable: executable,
                                        arguments: arguments,
                                        timeout: timeout,
                                        environment: environment) {
                case .success(let data): continuation.resume(returning: data)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Blocking core (runs entirely on one background thread)

    private static func runBlocking(executable: URL,
                                    arguments: [String],
                                    timeout: TimeInterval,
                                    environment: [String: String]?) -> Result<Data, EngineError> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Keep HOME/PATH/locale so codexbar can find ~/.codex, ~/.gemini, Keychain.
        process.environment = environment ?? ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Concurrent drain. Each handler closure captures only the Sendable `sink`
        // and `group`; the FileHandle arrives as the handler argument, so nothing
        // non-Sendable is captured across a boundary.
        let sink = OutputSink()
        let drain = DispatchGroup()
        drain.enter() // stdout EOF
        drain.enter() // stderr EOF
        outPipe.fileHandleForReading.readabilityHandler = Self.drainHandler(into: sink, channel: .out, group: drain)
        errPipe.fileHandleForReading.readabilityHandler = Self.drainHandler(into: sink, channel: .err, group: drain)

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            return .failure(.binaryMissing)
        }

        var didTimeout = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            didTimeout = true
            process.terminate() // SIGTERM
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait() // reap; SIGKILL is not catchable so this returns promptly
            }
        }

        // Wait for both pipes to reach EOF so no trailing bytes are lost, bounded so
        // a stuck reader can't hang us forever.
        let drained = drain.wait(timeout: .now() + 3)
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        if didTimeout { return .failure(.timeout) }

        let status = process.terminationStatus
        switch status {
        case 0:
            // If EOF never arrived, stdout may be truncated — don't pass it off as a
            // clean success (truncated JSON would mis-decode).
            if drained == .timedOut {
                return .failure(.badOutput("output drain timed out before EOF"))
            }
            return .success(sink.stdout)
        case 2:
            return .failure(.providerMissing)
        case 3:
            return .failure(.badOutput(sink.stderrString))
        case 4:
            return .failure(.timeout)
        default:
            return .failure(.unexpected("exit \(status): \(sink.stderrString)"))
        }
    }

    private enum Channel { case out, err }

    private static func drainHandler(into sink: OutputSink,
                                     channel: Channel,
                                     group: DispatchGroup) -> @Sendable (FileHandle) -> Void {
        // `oneShot` guards against the group being left twice if the handler is
        // invoked again after EOF.
        let oneShot = OnceFlag()
        return { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if oneShot.tryRun() { group.leave() }
            } else {
                switch channel {
                case .out: sink.appendOut(data)
                case .err: sink.appendErr(data)
                }
            }
        }
    }
}

/// Thread-safe accumulator for the two streams. `@unchecked Sendable` is sound
/// because every access is serialized by the lock.
private final class OutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()

    func appendOut(_ data: Data) { lock.lock(); out.append(data); lock.unlock() }
    func appendErr(_ data: Data) { lock.lock(); err.append(data); lock.unlock() }

    var stdout: Data { lock.lock(); defer { lock.unlock() }; return out }
    var stderrString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}

/// Runs its check exactly once across threads.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func tryRun() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
