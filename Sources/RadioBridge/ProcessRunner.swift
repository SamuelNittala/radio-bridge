import Foundation

/// Runs a command-line tool and collects its output; shared by the `shortcuts` and `claude` runners.
enum ProcessRunner {
    struct TimedOut: Error {}

    /// How long a tool gets to end after SIGTERM before it is killed.
    static let graceAfterTerminate: TimeInterval = 5

    /// Collects one pipe's output as it arrives. Unlike a blocking read, it can be told to stop
    /// (`finish`) even if the pipe never reaches end-of-file, e.g. a child process still holds it.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var finished = false
        private var waiting: CheckedContinuation<Void, Never>?
        private let handle: FileHandle

        init(_ handle: FileHandle) {
            self.handle = handle
            handle.readabilityHandler = { [weak self] h in
                let chunk = h.availableData
                if chunk.isEmpty { self?.finish() } else { self?.append(chunk) }
            }
        }

        private func append(_ chunk: Data) {
            lock.lock(); data.append(chunk); lock.unlock()
        }

        /// Stops reading. The pipe's read end closes when the `Pipe` is released.
        func finish() {
            lock.lock()
            let alreadyFinished = finished
            finished = true
            let continuation = waiting
            waiting = nil
            lock.unlock()
            guard !alreadyFinished else { return }
            handle.readabilityHandler = nil
            continuation?.resume()
        }

        func collected() async -> Data {
            await withCheckedContinuation { continuation in
                if !wait(continuation) { continuation.resume() }
            }
            return snapshot()
        }

        /// Parks the continuation unless already finished (then false: the caller resumes it).
        private func wait(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if finished { return false }
            waiting = continuation
            return true
        }

        private func snapshot() -> Data {
            lock.lock(); defer { lock.unlock() }
            return data
        }
    }

    /// Ends the process when the deadline passes or the calling task is cancelled: SIGTERM first,
    /// then SIGKILL if it is still running after the grace period, and the pipes are let go either
    /// way, so a tool that ignores SIGTERM, or leaves children holding its pipes, can't stall us.
    private final class Killer: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private let collectors: [Collector]
        private var timedOut = false
        private var killing = false

        init(_ process: Process, _ collectors: [Collector]) {
            self.process = process
            self.collectors = collectors
        }

        func kill(timedOut: Bool) {
            lock.lock()
            if timedOut { self.timedOut = true }
            let alreadyKilling = killing
            killing = true
            lock.unlock()
            guard !alreadyKilling else { return }
            if process.isRunning { process.terminate() }
            Task.detached { [process, collectors] in
                try? await Task.sleep(for: .seconds(ProcessRunner.graceAfterTerminate))
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                collectors.forEach { $0.finish() }
            }
        }

        var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    }

    /// Starts `executable`, feeds it `input` and waits for it to end. stdout and stderr are read
    /// at the same time, so neither can fill its pipe and stall the tool. Throws `TimedOut` if
    /// it runs longer than `timeout`; cancelling the calling task ends it too.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                    directory: URL? = nil, input: Data? = nil, timeout: TimeInterval? = nil
    ) async throws -> (status: Int32, output: Data, error: Data) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let directory { process.currentDirectoryURL = directory }
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        if input != nil { process.standardInput = stdin }
        process.standardOutput = stdout
        process.standardError = stderr
        let out = Collector(stdout.fileHandleForReading), err = Collector(stderr.fileHandleForReading)
        do {
            try process.run()
        } catch {
            out.finish(); err.finish()
            throw error
        }

        let killer = Killer(process, [out, err])
        let timer = timeout.map { seconds in
            Task {
                try await Task.sleep(for: .seconds(seconds))
                killer.kill(timedOut: true)
            }
        }
        defer { timer?.cancel() }

        return try await withTaskCancellationHandler {
            if let input {
                // A tool that exits without reading its input must not kill the app with SIGPIPE,
                // so the write is by the throwing API with SIGPIPE off, and its error is ignored:
                // the exit status and stderr say what went wrong.
                let writer = stdin.fileHandleForWriting
                _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                Task.detached {
                    try? writer.write(contentsOf: input)
                    try? writer.close()
                }
            }
            async let output = out.collected()
            async let error = err.collected()
            let (o, e) = await (output, error)
            await Task.detached { process.waitUntilExit() }.value
            if killer.didTimeOut { throw TimedOut() }
            return (process.terminationStatus, o, e)
        } onCancel: {
            killer.kill(timedOut: false)
        }
    }
}
