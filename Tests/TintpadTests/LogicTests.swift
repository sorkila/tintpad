import XCTest
@testable import Tintpad

final class FrecencyTests: XCTestCase {
    func testDecayHalvesAfterOneHalfLife() {
        var repo = Repo(path: "/x", name: "x")
        let now = Date(timeIntervalSince1970: 1_000_000)
        repo.frecencyScore = 8
        repo.lastLaunchedAt = now
        let later = now.addingTimeInterval(86_400 * 10) // 10 days = one half-life
        let decayed = Frecency.decayedScore(repo, now: later, halfLifeDays: 10)
        XCTAssertEqual(decayed, 4, accuracy: 0.001)
    }

    func testRecordVisitIncrementsAndReanchors() {
        var repo = Repo(path: "/x", name: "x")
        let now = Date(timeIntervalSince1970: 2_000_000)
        Frecency.recordVisit(&repo, now: now, halfLifeDays: 30)
        XCTAssertEqual(repo.launchCount, 1)
        XCTAssertEqual(repo.frecencyScore, 1, accuracy: 0.001)
        XCTAssertEqual(repo.lastLaunchedAt, now)
        // Same-instant second visit accumulates to 2.
        Frecency.recordVisit(&repo, now: now, halfLifeDays: 30)
        XCTAssertEqual(repo.frecencyScore, 2, accuracy: 0.001)
    }
}

final class CommandTemplateTests: XCTestCase {
    private func ctx(mode: RunMode, prompt: String?) -> CommandTemplate.Context {
        CommandTemplate.Context(repo: Repo(path: "/Users/me/acme", name: "acme"),
                                mode: mode, prompt: prompt, branch: "main", remote: nil)
    }

    func testModeAndNameSubstitution() {
        let yolo = RunMode(name: "YOLO", flags: "--dangerously-skip-permissions", isDangerous: true, description: "")
        let out = CommandTemplate.preview("claude {mode}", context: ctx(mode: yolo, prompt: nil))
        XCTAssertEqual(out, "claude --dangerously-skip-permissions")
    }

    func testEmptyModeCollapsesSpaces() {
        let out = CommandTemplate.preview("claude {mode} {prompt}", context: ctx(mode: .defaultMode(), prompt: nil))
        XCTAssertEqual(out, "claude")
    }

    func testPromptIsQuoted() {
        let out = CommandTemplate.preview("claude {prompt}", context: ctx(mode: .defaultMode(), prompt: "fix bug"))
        XCTAssertEqual(out, "claude 'fix bug'")
    }

    func testRepoNameAndPath() {
        let out = CommandTemplate.preview("cd {repoPath} # {repoName}", context: ctx(mode: .defaultMode(), prompt: nil))
        XCTAssertEqual(out, "cd '/Users/me/acme' # acme")
    }
}

final class LicenseTests: XCTestCase {
    // The sample Pro key signed by the embedded public key (see secrets/).
    private let validKey = "eyJlbWFpbCI6ImVyaWtAc29ya2lsYS5jb20iLCJwbGFuIjoicHJvIiwiaWF0IjoxNzUwMDAwMDAwfQ==.HqALR7nuRgB6AeUq7daHFd33+ESLZn2qdMbMaKk1FwoIAACRxgs5rSXdkG2A2bxPXGJ4g1jRCNrQJ2LS08DeCQ=="

    func testValidKeyAccepted() {
        let info = LicenseManager.verify(validKey)
        XCTAssertEqual(info?.plan, "pro")
        XCTAssertEqual(info?.email, "erik@sorkila.com")
    }

    func testNilAndGarbageRejected() {
        XCTAssertNil(LicenseManager.verify(nil))
        XCTAssertNil(LicenseManager.verify(""))
        XCTAssertNil(LicenseManager.verify("not-a-key"))
        XCTAssertNil(LicenseManager.verify("a.b"))
    }

    func testTamperedSignatureRejected() {
        var bad = validKey
        let dot = bad.firstIndex(of: ".")!
        let after = bad.index(after: dot)
        bad.replaceSubrange(after...after, with: bad[after] == "H" ? "I" : "H")
        XCTAssertNil(LicenseManager.verify(bad))
    }
}

final class GitInfoTests: XCTestCase {
    func testParsesBranchAndRemote() throws {
        let dir = NSTemporaryDirectory() + "tintpad-gittest-\(UUID().uuidString)"
        let git = dir + "/.git"
        try FileManager.default.createDirectory(atPath: git, withIntermediateDirectories: true)
        try "ref: refs/heads/feature/x\n".write(toFile: git + "/HEAD", atomically: true, encoding: .utf8)
        try """
        [core]
            bare = false
        [remote "origin"]
            url = git@github.com:me/acme.git
        """.write(toFile: git + "/config", atomically: true, encoding: .utf8)

        let meta = GitInfo.read(at: dir)
        XCTAssertEqual(meta.branch, "x")  // last path component of refs/heads/feature/x
        XCTAssertEqual(meta.remoteURL, "git@github.com:me/acme.git")
        try? FileManager.default.removeItem(atPath: dir)
    }
}

final class RepoDiscoveryTests: XCTestCase {
    func testFindsGitRepos() throws {
        let root = NSTemporaryDirectory() + "tintpad-disc-\(UUID().uuidString)"
        let repo = root + "/myrepo"
        try FileManager.default.createDirectory(atPath: repo + "/.git", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: root + "/not-a-repo", withIntermediateDirectories: true)

        let found = RepoDiscovery.scan(roots: [root])
        XCTAssertTrue(found.contains { $0.hasSuffix("/myrepo") })
        XCTAssertFalse(found.contains { $0.hasSuffix("/not-a-repo") })
        try? FileManager.default.removeItem(atPath: root)
    }
}
