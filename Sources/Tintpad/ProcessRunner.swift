import Foundation

/// Runs a subprocess with a hard timeout and concurrently drained pipes, so a
/// chatty child can never deadlock against a full 64KB pipe buffer and a hung
/// one can never outlive its deadline (SIGTERM, then SIGKILL half a second
/// later). Blocking — call it from a GCD queue or a bounded user action, never
/// from the Swift cooperative pool.
enum ProcessRunner {
    struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    enum RunError: Error, CustomStringConvertible, LocalizedError {
        case timedOut(TimeInterval)
        case spawnFailed(String)

        var description: String {
            switch self {
            case .timedOut(let t): return "timed out after \(Int(t))s"
            case .spawnFailed(let m): return m
            }
        }
        var errorDescription: String? { description }
    }

    /// Thread-safe accumulation for the readability handlers.
    private final class Buffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    @discardableResult
    nonisolated static func run(_ executable: String, arguments: [String],
                                environment: [String: String]? = nil,
                                timeout: TimeInterval) throws -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err

        // Drain as data arrives — never after exit.
        let outBuf = Buffer(), errBuf = Buffer()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { outBuf.append(d) }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { errBuf.append(d) }
        }

        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { throw RunError.spawnFailed(error.localizedDescription) }

        var timedOut = false
        if done.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            let pid = p.processIdentifier
            p.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if p.isRunning { kill(pid, SIGKILL) }
            }
            _ = done.wait(timeout: .now() + 2)
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        if timedOut { throw RunError.timedOut(timeout) }
        return Output(status: p.terminationStatus,
                      stdout: String(data: outBuf.value, encoding: .utf8) ?? "",
                      stderr: String(data: errBuf.value, encoding: .utf8) ?? "")
    }

    /// Spawn without waiting, for processes that *are* the thing being opened
    /// (a terminal GUI): waiting for their exit would wait for the window.
    nonisolated static func spawnDetached(_ executable: String, arguments: [String],
                                          environment: [String: String]? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let environment { p.environment = environment }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw RunError.spawnFailed(error.localizedDescription) }
    }
}
