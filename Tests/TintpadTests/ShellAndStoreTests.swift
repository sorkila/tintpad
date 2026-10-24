import XCTest
@testable import Tintpad

final class ShellPathExtractTests: XCTestCase {
    private let begin = ShellEnvironment.pathBeginMarker
    private let end = ShellEnvironment.pathEndMarker

    func testCleanPosixOutput() {
        let out = "\n\(begin)\n/opt/homebrew/bin:/usr/bin:/bin\n\(end)\n"
        XCTAssertEqual(ShellEnvironment.extractPath(from: out),
                       ["/opt/homebrew/bin", "/usr/bin", "/bin"])
    }

    // The bug: rc noise used to be fused onto the first entry and lose it.
    func testNoiseAroundTheMarkersIsIgnored() {
        let out = "Welcome back, erik\nNow using node v22\n\(begin)\n/Users/e/.local/bin:/usr/bin\n\(end)\nlogout\n"
        XCTAssertEqual(ShellEnvironment.extractPath(from: out), ["/Users/e/.local/bin", "/usr/bin"])
    }

    func testFishOneEntryPerLine() {
        let out = "\n\(begin)\n/opt/homebrew/bin\n/Users/e/.cargo/bin\n/usr/bin\n\(end)\n"
        XCTAssertEqual(ShellEnvironment.extractPath(from: out),
                       ["/opt/homebrew/bin", "/Users/e/.cargo/bin", "/usr/bin"])
    }

    func testEmptyOrUnmarkedOutputIsNil() {
        XCTAssertNil(ShellEnvironment.extractPath(from: ""))
        XCTAssertNil(ShellEnvironment.extractPath(from: "/usr/bin:/bin"))
        XCTAssertNil(ShellEnvironment.extractPath(from: "\(begin)\n/usr/bin\n"))   // cut short
        XCTAssertNil(ShellEnvironment.extractPath(from: "/usr/bin\n\(end)\n"))
        XCTAssertNil(ShellEnvironment.extractPath(from: "\(begin)\n\n\(end)\n"))
    }

    func testLastBlockWinsAndQuotedMarkersDontCount() {
        let out = "echo \(begin)\n\(begin)\n/decoy\n\(end)\nmotd\n\(begin)\n/real/bin\n\(end)\n"
        XCTAssertEqual(ShellEnvironment.extractPath(from: out), ["/real/bin"])
    }

    func testCRLFAndRelativeEntries() {
        let out = "hi\r\n\(begin)\r\n/usr/local/bin:.:bin::/usr/bin\r\n\(end)\r\n"
        XCTAssertEqual(ShellEnvironment.extractPath(from: out), ["/usr/local/bin", "/usr/bin"])
    }

    func testFishGetsAnUnquotedListAndPosixAQuotedString() {
        XCTAssertTrue(ShellEnvironment.pathProbeCommand(shell: "/opt/homebrew/bin/fish")
            .contains("printf '%s\\n' $PATH;"))
        for shell in ["/bin/zsh", "/bin/bash", "/bin/sh"] {
            XCTAssertTrue(ShellEnvironment.pathProbeCommand(shell: shell)
                .contains("printf '%s\\n' \"$PATH\";"), shell)
        }
    }

    // The real command through real shells (no rc files), with noise on both
    // sides and a PATH entry holding a space and a glob character, which an
    // unquoted bash expansion would split and expand.
    func testProbeCommandRoundTripsThroughPosixShells() throws {
        let path = "/opt/homebrew/bin:/Users/e/My Tools/bin:/x/*:/usr/bin:/bin"
        let shells: [(String, [String])] = [("/bin/zsh", ["-f", "-c"]), ("/bin/bash", ["--norc", "-c"]),
                                            ("/bin/sh", ["-c"])]
        for (shell, flags) in shells {
            let script = "echo hello; \(ShellEnvironment.pathProbeCommand(shell: shell)); echo bye"
            let out = try ProcessRunner.run(shell, arguments: flags + [script],
                                            environment: ["PATH": path], timeout: 10)
            XCTAssertEqual(ShellEnvironment.extractPath(from: out.stdout),
                           path.split(separator: ":").map(String.init), shell)
        }
    }

    func testInteractiveProbeFirstThenLoginOnly() {
        let attempts = ShellEnvironment.probeArguments(shell: "/bin/zsh")
        XCTAssertEqual(attempts.map(\.first), ["-lic", "-lc"])
        XCTAssertEqual(Set(attempts.map(\.last)), [ShellEnvironment.pathProbeCommand(shell: "/bin/zsh")])
    }

    // The probe's stdin is an empty, closed pipe: an rc that reads from it
    // sees EOF at once instead of holding a developer's TTY until the timeout.
    func testEmptyInputGivesTheShellEOF() throws {
        let out = try ProcessRunner.run("/bin/sh", arguments: ["-c", "read x; echo read=$?"],
                                        input: Data(), timeout: 5)
        XCTAssertEqual(out.stdout, "read=1\n")
    }

    // One Latin-1 byte in a motd used to decode the whole stream to "",
    // markers included.
    func testANonUTF8ByteInTheNoiseKeepsThePath() throws {
        let script = "printf 'caf\\351\\n'; \(ShellEnvironment.pathProbeCommand(shell: "/bin/sh"))"
        let out = try ProcessRunner.run("/bin/sh", arguments: ["-c", script],
                                        environment: ["PATH": "/usr/bin:/bin"], timeout: 10)
        XCTAssertTrue(out.stdout.hasPrefix("caf\u{FFFD}"))
        XCTAssertEqual(ShellEnvironment.extractPath(from: out.stdout), ["/usr/bin", "/bin"])
    }

    func testMergeKeepsShellOrderThenProbesWithoutDuplicates() {
        XCTAssertEqual(ShellEnvironment.mergedPath(shell: ["/a", "/usr/bin", "/a"], probes: ["/usr/bin", "/b"]),
                       "/a:/usr/bin:/b")
        XCTAssertEqual(ShellEnvironment.mergedPath(shell: [], probes: ["/b"]), "/b")
    }
}

final class ResolveBinaryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tintpad-bin-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("first"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("second"), withIntermediateDirectories: true)
        // first/: a non-executable "agent" and a directory named "tool".
        fm.createFile(atPath: dir.appendingPathComponent("first/agent").path, contents: Data("x".utf8),
                      attributes: [.posixPermissions: 0o644])
        try fm.createDirectory(at: dir.appendingPathComponent("first/tool"), withIntermediateDirectories: true)
        // second/: the real executables.
        for name in ["agent", "tool"] {
            fm.createFile(atPath: dir.appendingPathComponent("second/\(name)").path,
                          contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var searchPath: String { "\(dir.path)/first:\(dir.path)/second" }

    func testSkipsNonExecutablesAndDirectories() {
        XCTAssertEqual(ShellEnvironment.resolveBinary("agent", searchPath: searchPath),
                       "\(dir.path)/second/agent")
        XCTAssertEqual(ShellEnvironment.resolveBinary("tool", searchPath: searchPath),
                       "\(dir.path)/second/tool")
        XCTAssertNil(ShellEnvironment.resolveBinary("missing", searchPath: searchPath))
    }

    func testAbsoluteNamesAreTrustedOnlyWhenExecutable() {
        XCTAssertEqual(ShellEnvironment.resolveBinary("\(dir.path)/second/agent", searchPath: ""),
                       "\(dir.path)/second/agent")
        XCTAssertNil(ShellEnvironment.resolveBinary("\(dir.path)/first/agent", searchPath: searchPath))
        XCTAssertNil(ShellEnvironment.resolveBinary("\(dir.path)/first/tool", searchPath: searchPath))
    }
}

@MainActor
final class StoreLoadTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("store.json") }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tintpad-store-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        // An unreadable fixture must be readable again to be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("store.corrupt-") }
    }

    func testFirstRunSeedsAndPersists() throws {
        let store = AppStore(fileURL: url)
        XCTAssertTrue(store.canPersist)
        XCTAssertEqual(store.agents.count, AgentSeed.defaults.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.writeCount, 1)
    }

    func testRoundTripThroughTheFile() throws {
        let first = AppStore(fileURL: url)
        first.addRepo(path: "/tmp/round/trip")
        first.settings.frecencyHalfLifeDays = 7
        first.save()

        let second = AppStore(fileURL: url)
        XCTAssertEqual(second.repos.map(\.path), ["/tmp/round/trip"])
        XCTAssertEqual(second.settings.frecencyHalfLifeDays, 7)
        XCTAssertEqual(second.writeCount, 0, "a clean load writes nothing")
    }

    // A transient read error must never reseed and then save over real data.
    // chmod 000 makes the file unreadable only for a non-root runner (root
    // reads it anyway), which is what CI and a developer Mac are.
    func testUnreadableStoreIsNeverOverwritten() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let original = Data(#"{"repos":[{"path":"/real","name":"real"}]}"#.utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let store = AppStore(fileURL: url)
        XCTAssertEqual(store.loadFailure, .unreadable)
        XCTAssertFalse(store.canPersist)
        XCTAssertFalse(store.shouldOnboard, "a returning user is not walked through setup")
        XCTAssertTrue(store.repos.isEmpty, "seeded in memory")
        XCTAssertFalse(store.agents.isEmpty, "the palette still has agents")
        store.addRepo(path: "/tmp/new")
        store.settings.frecencyHalfLifeDays = 3
        store.saveSoon(after: 0)
        store.save()
        store.flushPendingSave()

        XCTAssertEqual(store.writeCount, 0)
        XCTAssertTrue(backups().isEmpty, "an unreadable file is not corrupt")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    // A directory where the file should be reads as "unreadable" too, not "missing".
    func testSomethingAtThePathIsNeverAFirstRun() throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let store = AppStore(fileURL: url)
        XCTAssertFalse(store.canPersist)
        XCTAssertEqual(store.writeCount, 0)
    }

    func testCorruptStoreIsPreservedAndNotPersistedUntilAChange() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: url)

        let store = AppStore(fileURL: url)
        XCTAssertTrue(store.canPersist)
        XCTAssertEqual(backups().count, 1)
        XCTAssertEqual(store.loadFailure, .corrupt(backup: dir.appendingPathComponent(backups()[0])))
        XCTAssertTrue(store.shouldOnboard, "the fresh store saves, so onboarding can rebuild it")
        XCTAssertEqual(try Data(contentsOf: url), garbage, "the seed stays in memory")
        XCTAssertEqual(store.writeCount, 0)

        store.addRepo(path: "/tmp/after")
        XCTAssertEqual(store.writeCount, 1)
        XCTAssertEqual(AppStore(fileURL: url).repos.map(\.path), ["/tmp/after"])
        let backup = dir.appendingPathComponent(backups()[0])
        XCTAssertEqual(try Data(contentsOf: backup), garbage)
    }

    // A read-only folder: the store reads, the backup copy can't be made, so
    // nothing may be saved over the only copy (non-root runner, as above).
    func testCorruptStoreThatCantBeBackedUpIsReadOnly() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        let store = AppStore(fileURL: url)
        XCTAssertEqual(store.loadFailure, .corruptNotBackedUp(store: url))
        XCTAssertFalse(store.canPersist)
        XCTAssertFalse(store.shouldOnboard)
        XCTAssertTrue(backups().isEmpty)
    }

    func testOnboardingOnlyOnAStoreThatSaves() {
        XCTAssertTrue(AppStore.shouldOnboard(hasOnboarded: false, canPersist: true))
        XCTAssertFalse(AppStore.shouldOnboard(hasOnboarded: false, canPersist: false))
        XCTAssertFalse(AppStore.shouldOnboard(hasOnboarded: true, canPersist: true))
        XCTAssertFalse(AppStore.LoadFailure.unreadable.allowsSaving)
        XCTAssertFalse(AppStore.LoadFailure.corruptNotBackedUp(store: url).allowsSaving)
        XCTAssertTrue(AppStore.LoadFailure.corrupt(backup: url).allowsSaving)
    }

    func testLoadFailureAlertCopy() {
        let backup = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Tintpad/store.corrupt-1792840646.json")
        let corrupt = AppStore.LoadFailure.corrupt(backup: backup).alertCopy
        XCTAssertTrue(corrupt.informative.contains("store.corrupt-1792840646.json"))
        XCTAssertTrue(corrupt.informative.contains("~/Library/Application Support/Tintpad"))

        let unreadable = AppStore.LoadFailure.unreadable.alertCopy
        XCTAssertEqual(unreadable.message, "Tintpad couldn't read its data")
        XCTAssertEqual(unreadable.informative,
                       "Your repos and settings are safe on disk. Changes made this session won't be saved. Quit and reopen Tintpad to try again.")

        // House voice: no em dashes, no semicolons.
        let all: [AppStore.LoadFailure] = [.unreadable, .corrupt(backup: backup),
                                          .corruptNotBackedUp(store: url)]
        for copy in all.map(\.alertCopy) {
            for text in [copy.message, copy.informative] {
                XCTAssertFalse(text.contains("\u{2014}"), text)
                XCTAssertFalse(text.contains(";"), text)
            }
        }
    }

    func testModeMigrationWritesBackOnce() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A pre-vocabulary store: Claude's skip mode still says "YOLO".
        var agent = AgentSeed.claudeCode
        agent.modes = agent.modes.map {
            var m = $0
            if m.flags == "--dangerously-skip-permissions" { m.name = "YOLO" }
            return m
        }
        XCTAssertNotEqual(AgentSeed.migrateModeNames([agent]), [agent])
        let doc = StoreDocument(agents: [agent])
        try JSONEncoder.tintpad.encode(doc).write(to: url)

        XCTAssertEqual(AppStore(fileURL: url).writeCount, 1)
        XCTAssertEqual(AppStore(fileURL: url).writeCount, 0, "already migrated")
    }

    func testDiscoveryBatchIsOneWrite() throws {
        let store = AppStore(fileURL: url)
        let before = store.writeCount
        let added = store.addRepos(paths: ["/r/a", "/r/b/", "/r/a", "/r/c"], via: .autoDiscover)
        XCTAssertEqual(added, 3)
        XCTAssertEqual(store.repos.map(\.path), ["/r/a", "/r/b", "/r/c"])
        XCTAssertEqual(store.writeCount, before + 1)
        XCTAssertEqual(store.addRepos(paths: ["/r/b"], via: .autoDiscover), 0)
        XCTAssertEqual(store.writeCount, before + 1, "nothing new, nothing written")
    }

    func testClassifySeparatesReadFromDecode() {
        let noFile = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)
        let noPermission = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
        func kind(_ r: AppStore.LoadResult) -> String {
            switch r {
            case .loaded: return "loaded"
            case .missing: return "missing"
            case .unreadable: return "unreadable"
            case .corrupt: return "corrupt"
            }
        }
        XCTAssertEqual(kind(AppStore.classify(read: .failure(noFile), entryExists: false)), "missing")
        XCTAssertEqual(kind(AppStore.classify(read: .failure(noFile), entryExists: true)), "unreadable")
        XCTAssertEqual(kind(AppStore.classify(read: .failure(noPermission), entryExists: true)), "unreadable")
        XCTAssertEqual(kind(AppStore.classify(read: .failure(noPermission), entryExists: false)), "unreadable")
        XCTAssertEqual(kind(AppStore.classify(read: .success(Data("nope".utf8)), entryExists: true)), "corrupt")
        XCTAssertEqual(kind(AppStore.classify(read: .success(Data("{}".utf8)), entryExists: true)), "loaded")
    }

    func testAMissingFileReadsAsMissing() {
        let read = Result { try Data(contentsOf: url) }
        guard case .missing = AppStore.classify(read: read, entryExists: false) else {
            return XCTFail("Data(contentsOf:) on a missing file should classify as missing")
        }
    }
}
