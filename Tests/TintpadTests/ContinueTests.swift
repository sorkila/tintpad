import KeyboardShortcuts
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

/// Substitution is one fixed pass over the template: a value is never scanned
/// for placeholders again, so the result can't depend on hash order.
final class SubstitutionOrderTests: XCTestCase {
    private let keys = ["repoPath", "repoName", "branch", "remote", "prompt", "mode",
                        "continue", "shell", "worktreePath"]

    func testAContinueFormNamingAPlaceholderStaysLiteral() {
        let c = CommandTemplate.Context(repo: Repo(path: "/x", name: "x"), mode: .defaultMode(),
                                        prompt: "next turn", branch: nil, remote: nil,
                                        continueFlags: "resume --last {prompt}")
        for _ in 0..<20 {
            XCTAssertEqual(CommandTemplate.preview("codex {mode} {prompt}", context: c),
                           "codex resume --last {prompt} 'next turn'")
        }
    }

    func testEveryValueStaysLiteralWhateverItNames() {
        for key in keys where key != "shell" {
            let literal = "{\(key)}"
            let c = CommandTemplate.Context(
                repo: Repo(path: "/p\(literal)", name: "n\(literal)"),
                mode: RunMode(name: "M", flags: "--m\(literal)", isDangerous: false, description: ""),
                prompt: "say \(literal)", branch: "b\(literal)", remote: "r\(literal)",
                worktreePath: "/w\(literal)", continueFlags: "--c\(literal)")
            let template = keys.map { "{\($0)}" }.joined(separator: " ")
            for _ in 0..<10 {
                let out = CommandTemplate.preview(template, context: c)
                XCTAssertEqual(out, [
                    "'/p\(literal)'", "'n\(literal)'", "'b\(literal)'", "'r\(literal)'",
                    "'say \(literal)'", "--m\(literal)", "--c\(literal)",
                    ShellEnvironment.loginShell, "'/w\(literal)'",
                ].joined(separator: " "), key)
            }
        }
    }

    func testUnknownAndUnclosedBracesAreLeftAsWritten() {
        let c = CommandTemplate.Context(repo: Repo(path: "/x", name: "x"), mode: .defaultMode(),
                                        prompt: "go", branch: nil, remote: nil)
        XCTAssertEqual(CommandTemplate.preview("echo {nope} {prompt} {", context: c), "echo {nope} 'go' {")
        XCTAssertEqual(CommandTemplate.preview("awk '{print $1}' {prompt}", context: c), "awk '{print $1}' 'go'")
    }

    // The tidy eats a template space next to an empty slot, never a value's.
    func testTidyStillCollapsesEmptySlots() {
        let c = CommandTemplate.Context(repo: Repo(path: "/x", name: "x"), mode: .defaultMode(),
                                        prompt: nil, branch: nil, remote: nil)
        XCTAssertEqual(CommandTemplate.preview("claude {continue} {mode} {prompt}", context: c), "claude")
        XCTAssertEqual(CommandTemplate.preview("a {mode}{prompt} b", context: c), "a b")
        XCTAssertEqual(CommandTemplate.preview("{mode} claude  {prompt}", context: c), "claude")
        XCTAssertEqual(CommandTemplate.preview("echo {repoName} {branch}", context: c), "echo 'x'")
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

final class ContinueMakeLaunchTests: XCTestCase {
    private func agent(_ flags: String?) -> Agent {
        Agent(name: "Mycli", commandTemplate: "/bin/echo {mode} {prompt}", continueFlags: flags,
              acceptsPrompt: true, tintHex: nil, symbol: "terminal", modes: [.defaultMode()], defaultModeID: nil)
    }

    func testContinuingSplicesWrapsAndKeepsTheWorktree() throws {
        let mode = RunMode(name: "YOLO", flags: "--go", isDangerous: true, description: "")
        let launch = try LaunchService.makeLaunch(
            repo: Repo(path: "/tmp/acme", name: "acme"), agent: agent("--continue"),
            mode: mode, prompt: "next turn", worktreePath: "/tmp/wt/feature",
            settings: Settings(), continuing: true)
        XCTAssertEqual(launch.workingDirectory, "/tmp/wt/feature")
        XCTAssertEqual(launch.command, CommandTemplate.inFreshSession("/bin/echo --continue --go 'next turn'"))
    }

    func testFreshLaunchIgnoresTheForm() throws {
        let launch = try LaunchService.makeLaunch(
            repo: Repo(path: "/tmp/acme", name: "acme"), agent: agent("--continue"),
            mode: .defaultMode(), prompt: nil, worktreePath: nil, settings: Settings())
        XCTAssertEqual(launch.command, CommandTemplate.inFreshSession("/bin/echo"))
    }

    func testNoFormThrowsInsteadOfLaunchingFresh() {
        for flags in [nil, "", "  "] as [String?] {
            XCTAssertThrowsError(try LaunchService.makeLaunch(
                repo: Repo(path: "/tmp/acme", name: "acme"), agent: agent(flags),
                mode: .defaultMode(), prompt: nil, worktreePath: nil,
                settings: Settings(), continuing: true)) { error in
                XCTAssertEqual(error as? LaunchService.ContinueError, .noContinueForm("Mycli"))
            }
        }
    }
}

/// A terminal that records what it was handed and opens nothing.
private final class CapturingTerminal: TerminalAdapter, @unchecked Sendable {
    var launches: [TerminalLaunch] = []
    let displayName = "Fake"
    let bundleID = "com.example.fake"
    var isInstalled: Bool { true }
    @MainActor func prepare(_ launch: TerminalLaunch) throws -> TerminalHandoff {
        launches.append(launch)
        return .done(LaunchOutcome())
    }
}

@MainActor
final class ContinueServiceTests: XCTestCase {
    private var dir: URL!
    private var store: AppStore!
    private var terminal: CapturingTerminal!
    private var savedResolver: (@MainActor (Settings) -> TerminalAdapter)!
    private var repo: Repo!
    private var agent: Agent!
    private let mode = RunMode(name: "Go", flags: "--go", isDangerous: false, description: "")

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tintpad-continue-svc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = AppStore(fileURL: dir.appendingPathComponent("store.json"))
        terminal = CapturingTerminal()
        savedResolver = LaunchService.resolveTerminal
        let fake = terminal!
        LaunchService.resolveTerminal = { _ in fake }

        store.addRepo(path: dir.path)
        repo = store.repos[0]
        agent = Agent(name: "Echo", commandTemplate: "/bin/echo {mode} {prompt}", continueFlags: "--continue",
                      acceptsPrompt: true, tintHex: nil, symbol: "terminal", modes: [mode], defaultModeID: mode.id)
        store.agents = [agent]
    }

    override func tearDown() async throws {
        LaunchService.resolveTerminal = savedResolver
        try? FileManager.default.removeItem(at: dir)
    }

    private func record(prompt: String? = "the first message", worktree: String? = nil) {
        store.recordSession(repo: repo, agent: agent, mode: mode, prompt: prompt, worktreePath: worktree)
    }

    private func continueLast() -> Result<LaunchOutcome, Error>? {
        var answer: Result<LaunchOutcome, Error>?
        // A `.done` handoff answers synchronously.
        LaunchService.continueLast(store: store) { answer = $0 }
        return answer
    }

    func testNothingToContinueWithoutASession() {
        XCTAssertFalse(LaunchService.canContinueLast(store: store))
        guard case .failure(let error)? = continueLast() else { return XCTFail("expected a failure") }
        XCTAssertEqual(error as? LaunchService.ContinueError, .noSession)
    }

    func testCanContinueNeedsAForm() {
        record()
        XCTAssertTrue(LaunchService.canContinueLast(store: store))
        store.agents[0].continueFlags = ""
        XCTAssertFalse(LaunchService.canContinueLast(store: store))
        XCTAssertEqual(LaunchService.continueBlocker(for: store.lastSession!, store: store),
                       .noContinueForm("Echo"))
    }

    func testCanContinueNeedsTheWorktreeToExist() throws {
        let worktree = dir.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        record(worktree: worktree.path)
        XCTAssertTrue(LaunchService.canContinueLast(store: store))
        try FileManager.default.removeItem(at: worktree)
        XCTAssertFalse(LaunchService.canContinueLast(store: store))
        XCTAssertEqual(LaunchService.continueBlocker(for: store.lastSession!, store: store), .worktreeGone)
    }

    func testAGoneModeIsUnavailable() {
        record()
        store.agents[0].modes = [.defaultMode()]
        XCTAssertEqual(LaunchService.continueBlocker(for: store.lastSession!, store: store), .unavailable)
    }

    func testContinueLastDropsThePromptAndRunsInTheWorktree() throws {
        let worktree = dir.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        record(worktree: worktree.path)

        guard case .success? = continueLast() else { return XCTFail("expected the continue to land") }
        XCTAssertEqual(terminal.launches.count, 1)
        XCTAssertEqual(terminal.launches.first?.workingDirectory, worktree.path)
        XCTAssertEqual(terminal.launches.first?.command,
                       CommandTemplate.inFreshSession("/bin/echo --continue --go"))
        // Recorded like any launch: collapsed onto the session it continued,
        // still in its worktree, and free for the next continue.
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertEqual(store.lastSession?.worktreePath, worktree.path)
        XCTAssertFalse(LaunchService.continueInFlight)
    }

    func testNoFormLaunchesNothing() {
        record()
        store.agents[0].continueFlags = nil
        guard case .failure(let error)? = continueLast() else { return XCTFail("expected a failure") }
        XCTAssertEqual(error as? LaunchService.ContinueError, .noContinueForm("Echo"))
        XCTAssertTrue(terminal.launches.isEmpty, "a continue never falls back to a fresh launch")
    }

    func testAFreshLaunchStampsItsWorktree() {
        var answer: Result<LaunchOutcome, Error>?
        LaunchService.launchAgent(repo: repo, agent: agent, mode: mode, prompt: nil, store: store,
                                  worktreePath: "/tmp/wt/x") { answer = $0 }
        guard case .success? = answer else { return XCTFail("expected the launch to land") }
        XCTAssertEqual(store.lastSession?.worktreePath, "/tmp/wt/x")
        XCTAssertEqual(terminal.launches.first?.command, CommandTemplate.inFreshSession("/bin/echo --go"))
    }
}

/// The drop's two continue gestures, driven on the model with a terminal
/// that opens nothing. No event is ever posted: ⌃R is handed to `handle(_:)`
/// as an `NSEvent` object, the way the panel's monitor would.
@MainActor
final class ContinueDropTests: XCTestCase {
    private var dir: URL!
    private var store: AppStore!
    private var terminal: CapturingTerminal!
    private var savedResolver: (@MainActor (Settings) -> TerminalAdapter)!
    private var model: PaletteModel!
    private let safe = RunMode(name: "Default", flags: "", isDangerous: false, description: "")
    private let skip = RunMode(name: "Skip permissions", flags: "--skip", isDangerous: true, description: "")

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tintpad-continue-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = AppStore(fileURL: dir.appendingPathComponent("store.json"))
        store.settings.rootScanFolders = []
        store.settings.confirmDangerousModes = true
        terminal = CapturingTerminal()
        savedResolver = LaunchService.resolveTerminal
        let fake = terminal!
        LaunchService.resolveTerminal = { _ in fake }

        store.addRepo(path: dir.path)
        store.agents = [Agent(name: "Echo", commandTemplate: "/bin/echo {mode} {prompt}",
                              continueFlags: "--continue", acceptsPrompt: true, tintHex: nil,
                              symbol: "terminal", modes: [safe, skip], defaultModeID: safe.id)]
        store.prompts = [PromptTemplate(title: "Tests", text: "write tests")]
        model = PaletteModel(store: store, onClose: {}, onOpenSettings: {})
        model.isPresented = { true }
    }

    override func tearDown() async throws {
        LaunchService.resolveTerminal = savedResolver
        try? FileManager.default.removeItem(at: dir)
    }

    private func controlR(_ extra: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: NSEvent.ModifierFlags.control.union(extra),
                         timestamp: 0, windowNumber: 0, context: nil, characters: "\u{12}",
                         charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15)!
    }

    private var lastCommand: String? { terminal.launches.last?.command }

    func testControlRContinuesWithThePromptChip() {
        model.cyclePrompt()
        XCTAssertTrue(model.handle(controlR()))
        XCTAssertEqual(lastCommand, CommandTemplate.inFreshSession("/bin/echo --continue 'write tests'"))
        XCTAssertEqual(terminal.launches.last?.workingDirectory, dir.path)
    }

    func testReturnStillStartsFresh() {
        model.handleReturn(modifiers: [])
        XCTAssertEqual(lastCommand, CommandTemplate.inFreshSession("/bin/echo"))
    }

    func testOptionControlRPassesTheGate() {
        XCTAssertTrue(model.handle(controlR(.option)))
        XCTAssertTrue(model.isPendingDangerous, "a dangerous continue arms the confirm first")
        XCTAssertTrue(terminal.launches.isEmpty)
        model.handleReturn(modifiers: [])
        XCTAssertEqual(lastCommand, CommandTemplate.inFreshSession("/bin/echo --continue --skip"))
    }

    func testControlROverAPendingConfirmOnlyCancels() {
        model.handleReturn(modifiers: [.option])
        XCTAssertTrue(model.isPendingDangerous)
        XCTAssertTrue(model.handle(controlR()))
        XCTAssertFalse(model.isPendingDangerous)
        XCTAssertTrue(terminal.launches.isEmpty, "a ⌃R on a red line is a cancel, never a launch")
    }

    func testPromptModeSendsTheTypedTextAsTheNextTurn() {
        model.enterPromptMode()
        model.query = "and now the docs"
        XCTAssertTrue(model.handle(controlR()))
        XCTAssertEqual(lastCommand, CommandTemplate.inFreshSession("/bin/echo --continue 'and now the docs'"))
    }

    func testWorktreeModeIsInert() {
        model.enterWorktreeMode()
        model.query = "feature"
        XCTAssertFalse(model.handle(controlR()))
        XCTAssertTrue(terminal.launches.isEmpty)
    }

    func testNoFormSaysSoAndLaunchesNothing() {
        store.agents[0].continueFlags = ""
        XCTAssertTrue(model.handle(controlR()))
        XCTAssertEqual(model.status, DropCopy.noContinueForm(agent: "Echo"))
        XCTAssertNil(model.subjectRepo, "a status line about nothing wears no subject token")
        XCTAssertTrue(terminal.launches.isEmpty)
    }

    func testCommandZeroWithNoSession() {
        XCTAssertTrue(model.continueLastSession())
        XCTAssertEqual(model.status, DropCopy.noSessionToContinue)
        XCTAssertTrue(terminal.launches.isEmpty)
    }

    func testCommandZeroContinuesInTheWorktreeWithoutTheStoredPrompt() throws {
        let worktree = dir.appendingPathComponent("wt", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        store.recordSession(repo: store.repos[0], agent: store.agents[0], mode: safe,
                            prompt: "the first message", worktreePath: worktree.path)
        XCTAssertTrue(model.canContinueLast)
        XCTAssertTrue(model.continueLastSession())
        XCTAssertEqual(lastCommand, CommandTemplate.inFreshSession("/bin/echo --continue"))
        XCTAssertEqual(terminal.launches.last?.workingDirectory, worktree.path)
    }

    func testCommandZeroSaysAGoneWorktree() {
        store.recordSession(repo: store.repos[0], agent: store.agents[0], mode: safe,
                            prompt: nil, worktreePath: dir.appendingPathComponent("gone").path)
        XCTAssertFalse(model.canContinueLast)
        XCTAssertTrue(model.continueLastSession())
        XCTAssertEqual(model.status, DropCopy.worktreeGone)
        XCTAssertTrue(terminal.launches.isEmpty)
    }

    func testCommandZeroOnADangerousSessionPassesTheGate() {
        store.recordSession(repo: store.repos[0], agent: store.agents[0], mode: skip, prompt: nil)
        XCTAssertTrue(model.continueLastSession())
        XCTAssertTrue(model.isPendingDangerous)
        XCTAssertTrue(terminal.launches.isEmpty)
        model.handleReturn(modifiers: [])
        XCTAssertEqual(lastCommand, CommandTemplate.inFreshSession("/bin/echo --continue --skip"))
    }

    // Settings → Recents routes a dangerous row here, which need not be the last session.
    func testARecentsSessionByIDMeetsTheGate() {
        store.recordSession(repo: store.repos[0], agent: store.agents[0], mode: skip, prompt: nil)
        let older = store.sessions[0].id
        store.recordSession(repo: store.repos[0], agent: store.agents[0], mode: safe, prompt: nil)
        XCTAssertTrue(model.continueSession(older))
        XCTAssertTrue(model.isPendingDangerous, "the row's own mode, not the last session's")
        model.handleReturn(modifiers: [])
        XCTAssertEqual(lastCommand, CommandTemplate.inFreshSession("/bin/echo --continue --skip"))
    }

    func testAGoneSessionIDSaysSo() {
        XCTAssertTrue(model.continueSession(UUID()))
        XCTAssertEqual(model.status, DropCopy.sessionGone)
        XCTAssertTrue(terminal.launches.isEmpty)
    }
}

final class ContinueSurfaceTests: XCTestCase {
    // Renamed in code, never on disk: a chord recorded for "Resume last
    // session" must still answer as "Continue last session".
    func testHotkeyKeepsItsStoredName() {
        XCTAssertEqual(KeyboardShortcuts.Name.continueLast.rawValue, "resumeLast")
    }

    // A blocked Recents row's tooltip is the blocker's description, which
    // must be the drop's own line for the same reason.
    func testBlockerTooltipsAreTheDropLines() {
        XCTAssertEqual(LaunchService.ContinueError.unavailable.description, DropCopy.sessionGone)
        XCTAssertEqual(LaunchService.ContinueError.worktreeGone.description, DropCopy.worktreeGone)
        XCTAssertEqual(LaunchService.ContinueError.noContinueForm("Codex").description,
                       DropCopy.noContinueForm(agent: "Codex"))
    }

    func testSettingsCopyKeepsHouseStyle() {
        for text in [SettingsTab.recents.subtitle, DropCopy.noContinueForm(agent: "Codex")] {
            XCTAssertFalse(text.contains("—"), text)
            XCTAssertFalse(text.contains(";"), text)
        }
    }
}

/// The post-grant offer for a held continue says continue, never "launches".
final class ContinueGrantedLineTests: XCTestCase {
    func testHeldContinueSaysContinue() {
        XCTAssertEqual(PermissionEscalation.grantedLine(pane: .accessibility, agent: "Claude Code", continuing: true),
                       "Accessibility granted, Return continues with Claude Code")
        XCTAssertEqual(PermissionEscalation.grantedLine(pane: .automation, agent: "Claude Code", continuing: true),
                       "Return tries again, continuing with Claude Code")
        for pane in [PrivacyPane.accessibility, .automation] {
            let spoken = PermissionEscalation.grantedAnnouncement(pane: pane, repo: "tintpad",
                                                                  agent: "Codex", continuing: true)
            XCTAssertTrue(spoken.contains("continu"), spoken)
            XCTAssertTrue(spoken.contains("tintpad"), spoken)
            XCTAssertFalse(spoken.contains("launch"), spoken)
        }
        // A fresh launch reads as it always did.
        XCTAssertEqual(PermissionEscalation.grantedLine(pane: .accessibility, agent: "Codex"),
                       "Accessibility granted, Return launches Codex")
    }

    func testContinueOffersFitTheBudget() {
        // An agent name is the user's, give it room to be long.
        for pane in [PrivacyPane.accessibility, .automation] {
            let line = PermissionEscalation.grantedLine(pane: pane, agent: "Claude Code (sonnet, beta)",
                                                        continuing: true)
            XCTAssertLessThanOrEqual(line.count, DropCopy.maxLineCharacters, line)
            XCTAssertFalse(line.contains("—"), line)
            XCTAssertFalse(line.contains(";"), line)
        }
    }
}

final class ContinueCopyTests: XCTestCase {
    func testContinueLinesFitAndKeepHouseStyle() {
        let lines = [
            "\(LaunchService.ContinueError.noSession)",
            "\(LaunchService.ContinueError.unavailable)",
            "\(LaunchService.ContinueError.inFlight)",
            "\(LaunchService.ContinueError.worktreeGone)",
            "\(LaunchService.ContinueError.noContinueForm(AgentSeed.claudeCode.name))",
            "\(LaunchService.ContinueError.noContinueForm(AgentSeed.codex.name))",
        ]
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, DropCopy.maxLineCharacters, line)
            XCTAssertFalse(line.contains("—"), line)
            XCTAssertFalse(line.contains(";"), line)
            XCTAssertFalse(line.hasPrefix("⚠"), "continue lines are status, not errors: \(line)")
        }
        XCTAssertEqual(DropCopy.noContinueForm(agent: "Claude Code"),
                       "Claude Code has no continue form, set one in Settings → Agents")
    }
}
