import Foundation

/// One Tintpad per store. A second instance (say a `swift run` dev build next
/// to the installed app) would hold its own copy of store.json in memory and
/// silently last-writer-win over the other's repos, sessions, and settings.
/// flock on a sidecar file: released automatically when the process dies, so
/// a crash can never leave a stale lock behind.
enum SingleInstance {
    private nonisolated(unsafe) static var fd: CInt = -1

    /// True if this process now holds the lock (or the lock can't be taken at
    /// all, in which case launching is better than refusing to start).
    static func acquire() -> Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Tintpad", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(".lock").path
        fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }
}
