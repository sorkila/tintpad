import XCTest
@testable import Tintpad

/// House style for product copy: no em dashes, no prose semicolons.
private func assertHouseStyle(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
    for text in lines {
        XCTAssertFalse(text.contains("—"), text, file: file, line: line)
        XCTAssertFalse(text.contains(";"), text, file: file, line: line)
    }
}

/// The app's own Swift sources, every subfolder included, as (path relative
/// to Sources/Tintpad, line, code). Comment lines are dropped, so a comment
/// may name a color the code must not use.
private func sourceCodeLines() throws -> [(file: String, line: Int, text: String)] {
    let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/Tintpad").standardizedFileURL
    guard let walk = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil) else {
        XCTFail("can't walk \(sources.path)")
        return []
    }
    let files = walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    XCTAssertFalse(files.isEmpty, "no sources found at \(sources.path)")
    var out: [(String, Int, String)] = []
    for url in files {
        let relative = String(url.standardizedFileURL.path.dropFirst(sources.path.count + 1))
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
            out.append((relative, i + 1, line))
        }
    }
    return out
}

/// Black and white only, danger red the one color. A stray system color or
/// a second red is a design leak, caught here the way the em-dash tests
/// catch a voice leak. Content colors (repo hues, agent tints) are built
/// with `Color(hue:)` or from stored values, and stay allowed.
final class ColorLeakTests: XCTestCase {
    private static let named = "red|green|blue|orange|yellow|purple|pink|teal|mint|cyan|indigo|brown"

    func testNoSystemColorsOrAccentInProductSurfaces() throws {
        let patterns = [
            // `Color.green`, `NSColor.red`
            "\\b(Color|NSColor)\\.(\(Self.named))\\b",
            // `NSColor.systemGreen`
            "\\bNSColor\\.system(Red|Green|Blue|Orange|Yellow|Purple|Pink|Teal|Mint|Cyan|Indigo|Brown)\\b",
            // `.foregroundStyle(.green)`, `.tint(.red)`, `.fill(.orange)`
            "\\b(foregroundStyle|foregroundColor|tint|fill|stroke|strokeBorder|background)\\(\\s*\\.(\(Self.named))\\b",
            // The system accent is the user's color, never ours.
            "\\.accentColor\\b",
        ].map { try! NSRegularExpression(pattern: $0) }
        for (file, line, text) in try sourceCodeLines() {
            let range = NSRange(text.startIndex..., in: text)
            for p in patterns where p.firstMatch(in: text, range: range) != nil {
                XCTFail("\(file):\(line) leaks a color: \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    /// One red: `dangerTint` in Models.swift is the only literal RGB color.
    func testDangerTintIsTheOnlyRGBLiteral() throws {
        let literal = try NSRegularExpression(pattern: "\\b(Color|NSColor)\\((red|srgbRed|calibratedRed|deviceRed):")
        for (file, line, text) in try sourceCodeLines() where file != "Models.swift" {
            if literal.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                XCTFail("\(file):\(line) defines its own color, use dangerTint or ink: \(text)")
            }
        }
    }
}

/// Every middle line fits one storey: the copy is written to a budget, the
/// tail cut in the view is only the safety net.
final class MiddleLineBudgetTests: XCTestCase {
    private let budget = DropCopy.maxLineCharacters
    /// Every terminal and editor a launch line can name, and the fallback.
    private let targets = ["Ghostty", "kitty", "Alacritty", "WezTerm", "iTerm2", "Terminal", "Warp",
                           "VS Code", "Cursor", "Zed", "Sublime Text", "IntelliJ IDEA", "the terminal"]

    private func assertFits(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        for text in lines {
            XCTAssertLessThanOrEqual(text.count, budget, "\(text.count) chars: \(text)", file: file, line: line)
        }
        assertHouseStyle(lines, file: file, line: line)
    }

    func testPermissionLinesFit() {
        for summary in PermissionSummary.allCases {
            XCTAssertLessThanOrEqual(summary.text.count, PermissionEscalation.maxSummary, summary.text)
        }
        var lines = PermissionSummary.allCases.map {
            PermissionEscalation.line(pane: .accessibility, summary: $0.text, failures: 1)
        }
        for pane in [PrivacyPane.accessibility, .automation] {
            lines.append(PermissionEscalation.line(pane: pane, summary: "x", failures: 2))
            // An agent name is the user's, give it room to be long.
            lines.append(PermissionEscalation.grantedLine(pane: pane, agent: "Claude Code (sonnet, beta)"))
        }
        assertFits(lines)
    }

    /// The offer leaves the repo to its subject token (so no repo name can
    /// push it past the budget), and VoiceOver, which can't see the token,
    /// still hears the repo.
    func testGrantedAnnouncementNamesTheRepo() {
        let longRepo = String(repeating: "r", count: 60)
        for pane in [PrivacyPane.accessibility, .automation] {
            XCTAssertTrue(PermissionEscalation.grantedAnnouncement(pane: pane, repo: longRepo, agent: "Codex")
                .contains(longRepo))
        }
    }

    func testOtherStatusLinesFit() {
        assertFits([
            DropCopy.noEditor,
            "\(LaunchService.ResumeError.unavailable)",
            "\(LaunchService.ResumeError.inFlight)",
        ])
    }

    func testEscalatedLinesStillSayTheRemedy() {
        let ax = PermissionEscalation.line(pane: .accessibility, summary: "x", failures: 2)
        XCTAssertTrue(ax.contains("re-add Tintpad"), ax)
        let auto = PermissionEscalation.line(pane: .automation, summary: "x", failures: 2)
        XCTAssertTrue(auto.contains("off and on"), auto)
    }

    func testErrorLinesFitWhateverTheReason() {
        let long = String(repeating: "word ", count: 30)
        var lines: [String] = []
        for target in targets {
            for error: Error in [
                TerminalLaunchError.launchFailed(long),
                TerminalLaunchError.launchFailed("AppleScript: \(long)"),
                TerminalLaunchError.launchFailed("AppleScript: \(target) \(long)"),
                TerminalLaunchError.notInstalled,
                ProcessRunner.RunError.timedOut(60),
            ] {
                lines.append(LaunchStatusCopy.error(terminal: target, error: error))
            }
        }
        assertFits(lines)
        // Every error line still ends with what Return and Esc do.
        XCTAssertTrue(lines.allSatisfy { $0.hasSuffix(LaunchStatusCopy.retryKeys) })
    }

    func testAReasonAboutTheTargetIsTheLine() {
        XCTAssertEqual(
            LaunchStatusCopy.error(terminal: "Ghostty",
                                   error: TerminalLaunchError.launchFailed("AppleScript: Ghostty lost focus, nothing was typed.")),
            "Ghostty lost focus, Return retries, Esc closes")
        XCTAssertEqual(
            LaunchStatusCopy.error(terminal: "Ghostty", error: TerminalLaunchError.launchFailed("exited 1: boom")),
            "Couldn't open Ghostty (exit 1), Return retries, Esc closes")
    }

    func testDropLinesFit() {
        let agents = ["Claude Code", "Codex", "the agent"]
        var lines = [
            DropCopy.worktree(path: nil),
            DropCopy.worktree(path: "~/Developer/tintpad-worktrees/feature-a-rather-long-branch-name"),
            DropCopy.scanned(1), DropCopy.scanned(120),
            LaunchStatusCopy.opening("IntelliJ IDEA"), LaunchStatusCopy.stillOpening("IntelliJ IDEA"),
        ]
        for agent in agents {
            lines.append(DropCopy.prompt(agent: agent))
            lines.append(DropCopy.confirm(mode: "Skip permissions", agent: agent))
        }
        assertFits(lines)
    }

    func testConfirmNamesModeAndAgent() {
        XCTAssertEqual(DropCopy.confirm(mode: "Skip permissions", agent: "Claude Code"),
                       "Skip permissions with Claude Code, Return confirms, Esc cancels")
    }

    func testWorktreePathKeepsHeadAndTail() {
        let path = "~/Developer/tintpad-worktrees/feature-a-rather-long-branch-name"
        let line = DropCopy.worktree(path: path)
        XCTAssertEqual(line.count, budget)
        XCTAssertTrue(line.hasPrefix("New worktree at ~/Developer/"), line)
        XCTAssertTrue(line.hasSuffix("branch-name, Return creates and launches"), line)
        XCTAssertTrue(line.contains("…"), line)
        // A short path is left whole.
        XCTAssertEqual(DropCopy.worktree(path: "~/wt/fix"), "New worktree at ~/wt/fix, Return creates and launches")
    }

    func testMiddleCut() {
        XCTAssertEqual(DropCopy.middleCut("abcdefghij", to: 5), "ab…ij")
        XCTAssertEqual(DropCopy.middleCut("abc", to: 5), "abc")
    }
}

/// The drop's reshape curve and its honest empty strip.
final class ReshapeAndEmptyStateTests: XCTestCase {
    /// One curve for every reshape, defined from the content's arrival.
    func testReshapeIsTheArrivalCurve() {
        XCTAssertEqual(DropTimeline.reshapeDuration, DropTimeline.contentArrivalDuration)
        XCTAssertEqual(DropTimeline.reshape, DropTimeline.contentArrival)
    }

    /// A whitespace-only query matches everything (`RepoSearch.rank` trims),
    /// and a padded one is echoed trimmed, never as empty quotes.
    func testQueryEchoIsTrimmed() {
        XCTAssertEqual(DropCopy.emptyState(query: "  xyz \n", storeEmpty: false), "No repo matches “xyz”")
        let repo = Repo(path: "/x/tintpad", name: "tintpad")
        XCTAssertEqual(RepoSearch.rank("   ", in: [repo]).count, 1)
    }

    /// Tooltips and VoiceOver hints share one shape: what the chip does,
    /// then how to change it, never the chip's own noun again.
    func testChipHelpNeverRepeatsTheTag() {
        let helps = [
            DropCopy.promptHelp, DropCopy.agentHelp,
            DropCopy.modeHelp(flags: "", dangerous: false),
            DropCopy.modeHelp(flags: "--ask-for-approval untrusted", dangerous: false),
            DropCopy.modeHelp(flags: "--dangerously-skip-permissions", dangerous: true),
        ]
        for help in helps {
            for tag in ["Prompt", "Agent", "Mode"] { XCTAssertFalse(help.hasPrefix(tag), help) }
        }
        XCTAssertEqual(DropCopy.modeHelp(flags: "", dangerous: false), "Flags: none, click or ⇧⇥ to switch")
        XCTAssertEqual(DropCopy.modeHelp(flags: "--x", dangerous: true),
                       "Skips permissions (--x), click or ⇧⇥ to switch")
        assertHouseStyle(helps)
    }

    func testNoMatchSaysSoWithoutSellingARescan() {
        XCTAssertEqual(DropCopy.emptyState(query: "xyz", storeEmpty: false), "No repo matches “xyz”")
        XCTAssertFalse(DropCopy.emptyState(query: "xyz", storeEmpty: false).contains("⌘R"))
    }

    func testEmptyStoreOffersTheScan() {
        XCTAssertEqual(DropCopy.emptyState(query: "", storeEmpty: true),
                       "No repos yet, ⌘R scans your folders, or add roots in Settings")
    }

    func testLongQueryIsCutSoTheLineStaysOneStorey() {
        let line = DropCopy.emptyState(query: String(repeating: "a", count: 200), storeEmpty: false)
        XCTAssertLessThanOrEqual(line.count, DropCopy.maxLineCharacters)
        XCTAssertTrue(line.hasSuffix("…”"), line)
        assertHouseStyle([line, DropCopy.emptyState(query: "", storeEmpty: true)])
    }

    func testScanNoteHoldsLikeALaunchNote() {
        XCTAssertEqual(PaletteModel.noteHold, 1.6)
    }
}

/// The Keys pane: the global shortcuts and the drop's keys in one place.
final class KeysPaneTests: XCTestCase {
    func testPaneIsKeysAndSaysWhatItHolds() {
        XCTAssertEqual(SettingsTab.hotkeys.title, "Keys")
        XCTAssertEqual(SettingsTab.hotkeys.subtitle, "Two global shortcuts, and every key the drop answers to")
    }

    func testSettingsChromeHouseStyle() {
        assertHouseStyle(SettingsTab.allCases.flatMap { [$0.title, $0.subtitle] })
        assertHouseStyle(PaletteKeys.all.map(\.action))
    }
}

/// An available update, said once in the menu and once in About.
final class UpdateCopyTests: XCTestCase {
    func testMenuNamesThePendingVersion() {
        XCTAssertEqual(UpdateCopy.menuTitle(pending: "0.4.2"), "Update to 0.4.2…")
        XCTAssertEqual(UpdateCopy.menuTitle(pending: nil), "Check for Updates…")
    }

    func testAboutButtonInstallsThePendingVersion() {
        XCTAssertEqual(UpdateCopy.buttonTitle(pending: "0.4.2"), "Install 0.4.2…")
        XCTAssertEqual(UpdateCopy.buttonTitle(pending: nil), "Check for Updates…")
    }

    func testUpdateCopyHouseStyle() {
        assertHouseStyle([
            UpdateCopy.menuTitle(pending: "0.4.2"), UpdateCopy.menuTitle(pending: nil),
            UpdateCopy.buttonTitle(pending: "0.4.2"), UpdateCopy.buttonTitle(pending: nil),
        ])
    }
}
