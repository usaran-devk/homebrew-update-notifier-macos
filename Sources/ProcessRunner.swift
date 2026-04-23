import Foundation

/// Runs system processes, optionally streaming output line-by-line to the caller.
///
/// `ProcessRunner` is stateless and `Sendable`; a single shared instance can be
/// used from any concurrency context.
final class ProcessRunner: Sendable {

    // MARK: - Public API

    /// Runs a process and returns its combined stdout/stderr output.
    /// - Parameters:
    ///   - path: Path to the executable.
    ///   - arguments: Arguments to pass.
    /// - Returns: The stdout/stderr output as a string.
    /// - Throws: Any error raised while launching the process.
    func run(_ path: String, arguments: [String]) async throws -> String {
        try await runStreaming(path, arguments: arguments, environment: nil, onOutput: nil)
    }

    /// Runs a process with optional streaming output support.
    ///
    /// Each output chunk is delivered on the main actor via `onOutput` so callers
    /// can safely update `@Published` properties. The full accumulated output is
    /// also returned when the process finishes.
    /// - Parameters:
    ///   - path: Path to the executable.
    ///   - arguments: Arguments to pass.
    ///   - environment: Optional extra environment variables merged with the current process env.
    ///   - onOutput: Optional callback invoked with each chunk as it arrives (main actor).
    /// - Returns: The complete stdout/stderr output.
    /// - Throws: Any error raised while launching the process.
    @discardableResult
    func runStreaming(
        _ path: String,
        arguments: [String],
        environment: [String: String]?,
        onOutput: (@Sendable @MainActor (String) -> Void)?
    ) async throws -> String {
        let executableURL = URL(fileURLWithPath: path)
        var mergedEnv = ProcessInfo.processInfo.environment
        if let environment {
            mergedEnv.merge(environment) { _, new in new }
        }
        let env = mergedEnv

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Foundation.Process()
                let pipe = Pipe()

                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = pipe
                process.environment = env

                let accumulator = OutputAccumulator()

                // Stream chunks if callback provided.
                if let onOutput {
                    pipe.fileHandleForReading.readabilityHandler = { handle in
                        let data = handle.availableData
                        guard !data.isEmpty else { return }
                        if let chunk = String(data: data, encoding: .utf8) {
                            accumulator.append(chunk)
                            DispatchQueue.main.async {
                                onOutput(chunk)
                            }
                        }
                    }
                }

                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }

                if let onOutput {
                    // Wait for process to finish, then clean up handler.
                    process.waitUntilExit()
                    pipe.fileHandleForReading.readabilityHandler = nil
                    // Read any remaining data.
                    let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
                    if let chunk = String(data: remaining, encoding: .utf8), !chunk.isEmpty {
                        accumulator.append(chunk)
                        DispatchQueue.main.async {
                            onOutput(chunk)
                        }
                    }
                    continuation.resume(returning: accumulator.value)
                } else {
                    // Non-streaming: read all at once (avoids pipe-buffer deadlock).
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: output)
                }
            }
        }
    }

    // MARK: - Private

    /// Thread-safe accumulator for process output used during streaming.
    private final class OutputAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""

        func append(_ chunk: String) {
            lock.lock()
            buffer += chunk
            lock.unlock()
        }

        var value: String {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }
}
