import Foundation
import SwiftUI

// MARK: - Run modes

/// A named flag preset for an agent (Safe / Default / YOLO). Modes map the
/// shared safety vocabulary onto each agent's specific flags.
struct RunMode: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Injected into the command template's `{mode}` slot; may be empty.
    var flags: String
    /// Drives warning styling + confirm affordance.
    var isDangerous: Bool
    var description: String

    static func safe() -> RunMode {
        RunMode(name: "Safe", flags: "", isDangerous: false, description: "Normal permission prompts")
    }
    static func defaultMode() -> RunMode {
        RunMode(name: "Default", flags: "", isDangerous: false, description: "Agent default behavior")
    }
}

// MARK: - Agent

/// A user-defined CLI agent: a command template plus a set of run modes.
struct Agent: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Command template with variables, e.g. `claude {mode} {prompt}`.
    /// The leading binary token is resolved to an absolute path at launch.
    var commandTemplate: String
    var acceptsPrompt: Bool
    /// Hex tint string, e.g. "#FF7333"; nil = use the global accent.
    var tintHex: String?
    /// SF Symbol name for the row badge.
    var symbol: String
    var modes: [RunMode]
    var defaultModeID: UUID?

    var defaultMode: RunMode {
        modes.first { $0.id == defaultModeID } ?? modes.first ?? RunMode.defaultMode()
    }

    var dangerousMode: RunMode? {
        modes.first { $0.isDangerous }
    }
}

// MARK: - Repo

enum RepoSource: String, Codable {
    case manual, autoDiscover, github
}

struct Repo: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var path: String
    var name: String
    var addedVia: RepoSource = .manual
    /// Security-scoped bookmark for resilience across moves/permissions.
    var bookmark: Data?

    // Frecency state (fre-style continuous half-life decay).
    var frecencyScore: Double = 0
    var lastLaunchedAt: Date?
    var launchCount: Int = 0

    var defaultAgentID: UUID?
    var defaultModeID: UUID?
    var pinned: Bool = false
}

// MARK: - Prompt library

/// A reusable starting prompt, injected into a command template's `{prompt}`.
struct PromptTemplate: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var text: String
}

// MARK: - Sessions

/// A recorded launch, for recents / quick-resume.
struct Session: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var repoID: UUID
    var repoPath: String
    var repoName: String
    var agentID: UUID
    var agentName: String
    var modeID: UUID
    var modeName: String
    var prompt: String?
    var date: Date
}

// MARK: - Appearance

/// Curated accent palette. The tint is the brand identity.
enum TintAccent: String, Codable, CaseIterable, Identifiable {
    case orange, teal, lime, coral, blue, grey

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .orange: return Color(red: 1.00, green: 0.45, blue: 0.20)
        case .teal:   return Color(red: 0.20, green: 0.80, blue: 0.74)
        case .lime:   return Color(red: 0.65, green: 0.90, blue: 0.25)
        case .coral:  return Color(red: 1.00, green: 0.42, blue: 0.42)
        case .blue:   return Color(red: 0.35, green: 0.60, blue: 1.00)
        case .grey:   return Color(red: 0.70, green: 0.72, blue: 0.75)
        }
    }

    var displayName: String { rawValue.capitalized }
}

/// Dedicated warning tint for dangerous/YOLO modes, regardless of accent.
let dangerTint = Color(red: 1.0, green: 0.35, blue: 0.35)

enum AppearanceMode: String, Codable, CaseIterable, Identifiable {
    case system, dark
    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

// MARK: - Settings

struct Settings: Codable {
    var preferredTerminalBundleID: String?
    var preferredEditorID: String?
    var rootScanFolders: [String] = []
    var tintAccent: TintAccent = .orange
    var frecencyHalfLifeDays: Double = 30
    var confirmDangerousModes: Bool = true
    var appearance: AppearanceMode = .dark
    var panelWidth: Double = 640
    /// Multi-step launch: also open the editor when launching an agent.
    var alsoOpenEditor: Bool = false
    /// Optional root folder where new worktrees are created (nil = sibling of repo).
    var worktreeRoot: String?
    /// Pro license key (Ed25519-signed); nil = free tier.
    var licenseKey: String?
    /// First-run onboarding completed.
    var hasOnboarded: Bool = false

    init() {}

    /// Tolerant decode: any missing key falls back to its default, so adding a
    /// new setting never invalidates an existing store.json (which would reseed).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func g<T: Decodable>(_ k: CodingKeys, _ d: T) -> T { (try? c.decode(T.self, forKey: k)) ?? d }
        preferredTerminalBundleID = try? c.decode(String.self, forKey: .preferredTerminalBundleID)
        preferredEditorID = try? c.decode(String.self, forKey: .preferredEditorID)
        worktreeRoot = try? c.decode(String.self, forKey: .worktreeRoot)
        licenseKey = try? c.decode(String.self, forKey: .licenseKey)
        rootScanFolders = g(.rootScanFolders, [])
        tintAccent = g(.tintAccent, .orange)
        frecencyHalfLifeDays = g(.frecencyHalfLifeDays, 30)
        confirmDangerousModes = g(.confirmDangerousModes, true)
        appearance = g(.appearance, .dark)
        panelWidth = g(.panelWidth, 640)
        alsoOpenEditor = g(.alsoOpenEditor, false)
        hasOnboarded = g(.hasOnboarded, false)
    }

    static func defaults() -> Settings {
        let home = NSHomeDirectory()
        var s = Settings()
        s.rootScanFolders = ["\(home)/Documents/Repositories", "\(home)/Developer"]
        return s
    }
}

// MARK: - Persisted document

/// Everything stored in `store.json`. Versioned for forward migration.
struct StoreDocument: Codable {
    var version: Int = 1
    var repos: [Repo] = []
    var agents: [Agent] = []
    var prompts: [PromptTemplate] = []
    var sessions: [Session] = []
    var settings: Settings = .defaults()

    init(version: Int = 1, repos: [Repo] = [], agents: [Agent] = [],
         prompts: [PromptTemplate] = [], sessions: [Session] = [],
         settings: Settings = .defaults()) {
        self.version = version; self.repos = repos; self.agents = agents
        self.prompts = prompts; self.sessions = sessions; self.settings = settings
    }

    /// Tolerant decode: missing keys (e.g. an older store.json without
    /// prompts/sessions) fall back to defaults instead of failing the whole load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        repos = try c.decodeIfPresent([Repo].self, forKey: .repos) ?? []
        agents = try c.decodeIfPresent([Agent].self, forKey: .agents) ?? []
        prompts = try c.decodeIfPresent([PromptTemplate].self, forKey: .prompts) ?? []
        sessions = try c.decodeIfPresent([Session].self, forKey: .sessions) ?? []
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? .defaults()
    }

    static func seeded() -> StoreDocument {
        StoreDocument(repos: [], agents: AgentSeed.defaults,
                      prompts: PromptSeed.defaults, sessions: [], settings: .defaults())
    }
}

enum PromptSeed {
    static var defaults: [PromptTemplate] {
        [
            PromptTemplate(title: "Review changes", text: "Review my uncommitted changes for bugs and clarity."),
            PromptTemplate(title: "Write tests", text: "Write tests for the code I just changed."),
        ]
    }
}

// MARK: - Seed agents

enum AgentSeed {
    static var defaults: [Agent] {
        [claudeCode, codex]
    }

    static var claudeCode: Agent {
        let safe = RunMode.safe()
        let def = RunMode.defaultMode()
        let yolo = RunMode(
            name: "YOLO",
            flags: "--dangerously-skip-permissions",
            isDangerous: true,
            description: "Skips ALL permission prompts"
        )
        return Agent(
            name: "Claude Code",
            commandTemplate: "claude {mode} {prompt}",
            acceptsPrompt: true,
            tintHex: "#D97757",   // Claude clay
            symbol: "sparkle",
            modes: [safe, def, yolo],
            defaultModeID: def.id
        )
    }

    static var codex: Agent {
        let safe = RunMode(name: "Safe", flags: "--ask-for-approval", isDangerous: false,
                           description: "Approval required for actions")
        let def = RunMode.defaultMode()
        let yolo = RunMode(name: "YOLO", flags: "--full-auto", isDangerous: true,
                           description: "Full-auto, no approvals")
        return Agent(
            name: "Codex",
            commandTemplate: "codex {mode} {prompt}",
            acceptsPrompt: true,
            tintHex: "#10A37F",   // OpenAI teal
            symbol: "chevron.left.forwardslash.chevron.right",
            modes: [safe, def, yolo],
            defaultModeID: def.id
        )
    }
}

// MARK: - Color hex helpers

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt64(s, radix: 16) else { return nil }
        self.init(
            red: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255
        )
    }
}
