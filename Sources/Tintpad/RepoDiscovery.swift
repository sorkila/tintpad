import Foundation

/// Scans configured root folders for git repositories, 1–2 levels deep.
enum RepoDiscovery {
    /// Returns canonical paths of directories containing a `.git` entry.
    static func scan(roots: [String], maxDepth: Int = 2) -> [String] {
        let fm = FileManager.default
        var found: [String] = []
        var seen = Set<String>()

        func visit(_ dir: String, depth: Int) {
            guard depth <= maxDepth else { return }
            // A directory with .git is a repo; don't descend into it.
            if fm.fileExists(atPath: "\(dir)/.git") {
                let canonical = (dir as NSString).standardizingPath
                if seen.insert(canonical).inserted { found.append(canonical) }
                return
            }
            guard depth < maxDepth,
                  let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for entry in entries where !entry.hasPrefix(".") {
                let child = "\(dir)/\(entry)"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child, isDirectory: &isDir), isDir.boolValue {
                    visit(child, depth: depth + 1)
                }
            }
        }

        for root in roots {
            let expanded = (root as NSString).expandingTildeInPath
            visit(expanded, depth: 1)
        }
        return found.sorted()
    }
}
