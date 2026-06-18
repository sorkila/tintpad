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

    func testEqualScoresBreakTieByRecencyThenName() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Equal score (0, never launched) → sort by name.
        var c = Repo(path: "/c", name: "charlie")
        var a = Repo(path: "/a", name: "alpha")
        let ordered = Frecency.ordered([c, a], now: now, halfLifeDays: 30)
        XCTAssertEqual(ordered.map(\.name), ["alpha", "charlie"])
        // Same score but one launched more recently → it comes first.
        a.frecencyScore = 1; a.lastLaunchedAt = now.addingTimeInterval(-100)
        c.frecencyScore = 1; c.lastLaunchedAt = now.addingTimeInterval(-10)
        XCTAssertEqual(Frecency.ordered([a, c], now: now, halfLifeDays: 30).map(\.name), ["charlie", "alpha"])
    }

    // Guards the arrow-nav-jumping regression: the list order must not change as
    // time ticks (a non-transitive epsilon comparator made it reshuffle per render).
    func testOrderingStableAcrossTimeJitter() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var repos = ["alpha", "bravo", "charlie", "delta", "echo"].map { Repo(path: "/\($0)", name: $0) }
        repos[1].frecencyScore = 3; repos[1].lastLaunchedAt = now.addingTimeInterval(-3600)
        repos[3].frecencyScore = 3; repos[3].lastLaunchedAt = now.addingTimeInterval(-3600) // ties bravo
        let a = Frecency.ordered(repos, now: now, halfLifeDays: 30).map(\.name)
        let b = Frecency.ordered(repos, now: now.addingTimeInterval(1.5), halfLifeDays: 30).map(\.name)
        XCTAssertEqual(a, b, "frecency order must be stable as time advances")
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

    func testRepoNameAndPathQuoted() {
        let out = CommandTemplate.preview("cd {repoPath} # {repoName}", context: ctx(mode: .defaultMode(), prompt: nil))
        XCTAssertEqual(out, "cd '/Users/me/acme' # 'acme'")
    }

    // S1: an adversarial repo/branch name cannot escape the single-quoted argument.
    func testInjectionViaRepoNameNeutralized() {
        var repo = Repo(path: "/x", name: "$(rm -rf ~); echo pwned")
        let c = CommandTemplate.Context(repo: repo, mode: .defaultMode(), prompt: nil, branch: nil, remote: nil)
        let out = CommandTemplate.preview("claude {repoName}", context: c)
        XCTAssertEqual(out, "claude '$(rm -rf ~); echo pwned'")
        XCTAssertFalse(out.contains("') ") || out.contains("';"))  // no quote-break
        _ = repo
    }

    func testSingleQuoteInValueEscaped() {
        let c = CommandTemplate.Context(repo: Repo(path: "/x", name: "x"),
                                        mode: .defaultMode(), prompt: "it's fine", branch: nil, remote: nil)
        let out = CommandTemplate.preview("claude {prompt}", context: c)
        XCTAssertEqual(out, "claude 'it'\\''s fine'")
    }

    // S2: newlines/control chars are stripped so they can't submit early or break AppleScript.
    func testNewlinesStrippedFromPrompt() {
        let c = CommandTemplate.Context(repo: Repo(path: "/x", name: "x"),
                                        mode: .defaultMode(), prompt: "line1\nrm -rf ~\ttab", branch: nil, remote: nil)
        let out = CommandTemplate.preview("claude {prompt}", context: c)
        XCTAssertFalse(out.contains("\n"))
        XCTAssertFalse(out.contains("\t"))
        XCTAssertEqual(out, "claude 'line1 rm -rf ~ tab'")
    }
}

final class LaunchResolutionTests: XCTestCase {
    private func agent(_ template: String) -> Agent {
        Agent(name: "T", commandTemplate: template, acceptsPrompt: true, tintHex: nil,
              symbol: "terminal", modes: [.defaultMode()], defaultModeID: nil)
    }

    func testMakeLaunchResolvesCommandAndWorkingDir() throws {
        // A "/"-prefixed binary is trusted as-is, so resolution is deterministic.
        let mode = RunMode(name: "YOLO", flags: "--go", isDangerous: true, description: "")
        var s = Settings(); s.openInNewTab = false
        let launch = try LaunchService.makeLaunch(
            repo: Repo(path: "/tmp/acme", name: "acme"), agent: agent("/bin/echo {mode} {prompt}"),
            mode: mode, prompt: "fix it", worktreePath: nil, settings: s)
        XCTAssertEqual(launch.workingDirectory, "/tmp/acme")
        XCTAssertEqual(launch.command, "/bin/echo --go 'fix it'")
        XCTAssertFalse(launch.openInTab)
    }

    func testMakeLaunchHonorsTabSettingAndWorktree() throws {
        var s = Settings(); s.openInNewTab = true
        let launch = try LaunchService.makeLaunch(
            repo: Repo(path: "/tmp/acme", name: "acme"), agent: agent("/bin/echo"),
            mode: .defaultMode(), prompt: nil, worktreePath: "/tmp/wt/feature", settings: s)
        XCTAssertTrue(launch.openInTab)
        XCTAssertEqual(launch.workingDirectory, "/tmp/wt/feature")
        XCTAssertEqual(launch.command, "/bin/echo")
    }
}

final class ErrorMessageTests: XCTestCase {
    func testFriendlyLocalizedDescriptions() {
        XCTAssertEqual((TerminalLaunchError.notInstalled as LocalizedError).errorDescription,
                       "That terminal isn't installed.")
        let resolve = CommandTemplate.ResolveError.binaryNotFound("claude")
        XCTAssertEqual((resolve as LocalizedError).errorDescription,
                       "“claude” isn’t on your PATH — check it’s installed, then Re-scan.")
        // No raw "error N" Swift boilerplate leaks through.
        XCTAssertFalse((resolve as Error).localizedDescription.contains("error "))
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
