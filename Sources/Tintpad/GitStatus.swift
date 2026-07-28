import Foundation

/// Answers "does this repo have uncommitted changes". This is the one git
/// question `GitInfo` can't answer by parsing `.git` files (the index is
/// binary), so it shells out to the system git — bounded by a timeout, never
/// on the main thread, and never taking the index lock.
enum GitStatus {
    /// nil means unknown (no system git, not a repo, or git hung past the
    /// timeout) — callers render unknown as nothing rather than guessing.
    nonisolated static func isDirty(at repoPath: String, timeout: TimeInterval = 2) -> Bool? {
        let git = "/usr/bin/git"
        guard FileManager.default.isExecutableFile(atPath: git) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["-C", repoPath, "status", "--porcelain", "--no-renames"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_OPTIONAL_LOCKS"] = "0"   // a read must never contend with the user's git
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        // Bounded (AUDIT Q1): a hung git gets killed, which also closes the
        // pipe and unblocks the read below.
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        defer { killer.cancel() }

        // One byte answers the question — and stopping there keeps a huge
        // status from deadlocking against a full 64KB pipe buffer.
        let firstByte = try? out.fileHandleForReading.read(upToCount: 1)
        if let firstByte, !firstByte.isEmpty {
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
            return true
        }
        // EOF with no output: clean if git agreed, unknown if it errored or
        // was killed by the timeout.
        p.waitUntilExit()
        return p.terminationStatus == 0 ? false : nil
    }
}
