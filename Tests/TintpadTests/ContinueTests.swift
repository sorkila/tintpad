import XCTest
@testable import Tintpad

// Continue the conversation: the continue form, where it lands in a template,
// the seeds that carry it, and the backfill that gives it to existing stores.

final class ContinueTemplateTests: XCTestCase {
    private let skip = RunMode(name: "Skip permissions", flags: "--dangerously-skip-permissions",
                               isDangerous: true, description: "")

    private func ctx(mode: RunMode = .defaultMode(), prompt: String? = nil,
                     continueFlags: String?) -> CommandTemplate.Context {
        CommandTemplate.Context(repo: Repo(path: "/Users/me/acme", name: "acme"),
                                mode: mode, prompt: prompt, branch: "main", remote: nil,
                                continueFlags: continueFlags)
    }

    func testSlotTakesTheFormWhenContinuing() {
        let out = CommandTemplate.preview("claude {continue} {mode} {prompt}",
                                          context: ctx(prompt: "go", continueFlags: "--continue"))
        XCTAssertEqual(out, "claude --continue 'go'")
    }

    func testSlotTidiesAwayOnAFreshLaunch() {
        XCTAssertEqual(CommandTemplate.preview("claude {continue} {mode} {prompt}",
                                               context: ctx(continueFlags: nil)), "claude")
        XCTAssertEqual(CommandTemplate.preview("claude {continue} {mode}",
                                               context: ctx(mode: skip, continueFlags: nil)),
                       "claude --dangerously-skip-permissions")
    }

    func testSpliceAfterTheBinaryWithADangerousMode() {
        let out = CommandTemplate.preview("claude {mode} {prompt}",
                                          context: ctx(mode: skip, prompt: "go", continueFlags: "--continue"))
        XCTAssertEqual(out, "claude --continue --dangerously-skip-permissions 'go'")
    }

    func testSpliceAfterAPathHead() {
        let untrusted = RunMode(name: "Untrusted", flags: "--ask-for-approval untrusted",
                                isDangerous: false, description: "")
        let out = CommandTemplate.preview("/opt/homebrew/bin/codex {mode} {prompt}",
                                          context: ctx(mode: untrusted, prompt: "next", continueFlags: "resume --last"))
        XCTAssertEqual(out, "/opt/homebrew/bin/codex resume --last --ask-for-approval untrusted 'next'")
    }

    func testSpliceOnASingleTokenTemplate() {
        XCTAssertEqual(CommandTemplate.preview("claude", context: ctx(continueFlags: "--continue")),
                       "claude --continue")
    }

    func testExplicitSlotIsNotSplicedTwice() {
        let out = CommandTemplate.preview("npx some-agent {continue} {prompt}",
                                          context: ctx(prompt: "hi", continueFlags: "--continue"))
        XCTAssertEqual(out, "npx some-agent --continue 'hi'")
        XCTAssertEqual(out.components(separatedBy: "--continue").count, 2)
    }

    func testFreshLaunchIsUnchangedByTheSplice() {
        XCTAssertEqual(CommandTemplate.spliced("claude {mode} {prompt}", context: ctx(continueFlags: nil)),
                       "claude {mode} {prompt}")
        XCTAssertEqual(CommandTemplate.spliced("claude {mode} {prompt}", context: ctx(continueFlags: " ")),
                       "claude {mode} {prompt}")
    }

    func testFragmentIsSanitizedAndNeverQuoted() {
        let out = CommandTemplate.preview("claude {mode}",
                                          context: ctx(continueFlags: "--continue\n--fork-session"))
        XCTAssertEqual(out, "claude --continue --fork-session")
        XCTAssertFalse(out.contains("\n"))
        XCTAssertFalse(out.contains("'"))
    }

    // The resolved command keeps a path head as it is, so this is deterministic.
    func testResolvedSplicesBeforeResolvingTheBinary() throws {
        let out = try CommandTemplate.resolved("/bin/echo {mode} {prompt}",
                                               context: ctx(mode: skip, prompt: "go", continueFlags: "--continue"))
        XCTAssertEqual(out, "/bin/echo --continue --dangerously-skip-permissions 'go'")
    }
}

final class ContinueSeedTests: XCTestCase {
    private func agent(_ template: String, name: String = "T", flags: String? = nil) -> Agent {
        Agent(name: name, commandTemplate: template, continueFlags: flags, acceptsPrompt: true,
              tintHex: nil, symbol: "terminal", modes: [.defaultMode()], defaultModeID: nil)
    }

    func testSeedsCarryTheirContinueForms() {
        XCTAssertEqual(AgentSeed.claudeCode.continueFlags, "--continue")
        XCTAssertEqual(AgentSeed.codex.continueFlags, "resume --last")
    }

    func testBackfillFillsKnownBinaries() {
        let filled = AgentSeed.backfillContinueFlags([
            agent("claude {mode} {prompt}"),
            agent("claude {mode} {prompt}", name: "My Claude"),
            agent("/opt/homebrew/bin/codex {mode} {prompt}"),
            agent("  codex"),
        ])
        XCTAssertEqual(filled.map(\.continueFlags), ["--continue", "--continue", "resume --last", "resume --last"])
    }

    func testBackfillLeavesTheUsersChoicesAlone() {
        let filled = AgentSeed.backfillContinueFlags([
            agent("claude {mode} {prompt}", flags: ""),
            agent("claude {mode} {prompt}", flags: "--resume"),
            agent("mycli {mode} {prompt}"),
            // The seed's name pointed at another binary is not Claude any more.
            agent("my-wrapper {mode}", name: "Claude Code"),
        ])
        XCTAssertEqual(filled.map(\.continueFlags), ["", "--resume", nil, nil])
    }

    func testBackfillPreservesIDsAndIsIdempotent() {
        let agents = [agent("claude {mode} {prompt}"), agent("codex {mode}"), agent("mycli")]
        let once = AgentSeed.backfillContinueFlags(agents)
        XCTAssertEqual(once.map(\.id), agents.map(\.id))
        XCTAssertEqual(AgentSeed.backfillContinueFlags(once), once)
        XCTAssertNotEqual(once, agents, "the store's compare must see a backfill as a change")
    }

    func testContinueFormTreatsClearedAsNone() {
        XCTAssertNil(agent("claude").continueForm)
        XCTAssertNil(agent("claude", flags: "").continueForm)
        XCTAssertNil(agent("claude", flags: " \n").continueForm)
        XCTAssertEqual(agent("claude", flags: "--continue").continueForm, "--continue")
    }
}

final class ContinueDecodeTests: XCTestCase {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder.tintpad.decode(T.self, from: JSONEncoder.tintpad.encode(value))
    }

    func testAgentWithoutContinueFlagsDecodesNil() throws {
        var agent = AgentSeed.claudeCode
        agent.continueFlags = nil
        let data = try JSONEncoder.tintpad.encode(agent)
        // Never set means never written: no store changes shape until it has a value.
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("continueFlags"))
        XCTAssertNil(try JSONDecoder.tintpad.decode(Agent.self, from: data).continueFlags)
    }

    func testAgentContinueFlagsRoundTrip() throws {
        var agent = AgentSeed.codex
        agent.continueFlags = ""
        XCTAssertEqual(try roundTrip(agent).continueFlags, "")
        agent.continueFlags = "resume --last"
        XCTAssertEqual(try roundTrip(agent).continueFlags, "resume --last")
    }

    func testSessionWithoutWorktreeDecodesNilAndRoundTrips() throws {
        var session = Session(repoID: UUID(), repoPath: "/r", repoName: "r", agentID: UUID(),
                              agentName: "A", modeID: UUID(), modeName: "M", prompt: nil, date: Date())
        let data = try JSONEncoder.tintpad.encode(session)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("worktreePath"))
        XCTAssertNil(try JSONDecoder.tintpad.decode(Session.self, from: data).worktreePath)
        session.worktreePath = "/wt/feature"
        XCTAssertEqual(try roundTrip(session).worktreePath, "/wt/feature")
    }
}

@MainActor
final class ContinueStoreLoadTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("store.json") }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tintpad-continue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testBackfillWritesBackOnceAndKeepsIDs() throws {
        var claude = AgentSeed.claudeCode
        claude.continueFlags = nil
        var codex = AgentSeed.codex
        codex.continueFlags = ""   // cleared by the user, stays cleared
        try JSONEncoder.tintpad.encode(StoreDocument(agents: [claude, codex])).write(to: url)

        let first = AppStore(fileURL: url)
        XCTAssertEqual(first.writeCount, 1)
        XCTAssertEqual(first.agents.map(\.id), [claude.id, codex.id])
        XCTAssertEqual(first.agents.map(\.continueFlags), ["--continue", ""])
        XCTAssertEqual(AppStore(fileURL: url).writeCount, 0, "already backfilled")
    }
}
