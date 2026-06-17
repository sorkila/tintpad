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
    var rootScanFolders: [String] = []
    var tintAccent: TintAccent = .orange
    var frecencyHalfLifeDays: Double = 30
    var confirmDangerousModes: Bool = true
    var appearance: AppearanceMode = .dark
    var panelWidth: Double = 640

    static func defaults() -> Settings {
        let home = NSHomeDirectory()
        return Settings(rootScanFolders: [
            "\(home)/Documents/Repositories",
            "\(home)/Developer",
        ])
    }
}

// MARK: - Persisted document

/// Everything stored in `store.json`. Versioned for forward migration.
struct StoreDocument: Codable {
    var version: Int = 1
    var repos: [Repo] = []
    var agents: [Agent] = []
    var settings: Settings = .defaults()

    static func seeded() -> StoreDocument {
        StoreDocument(repos: [], agents: AgentSeed.defaults, settings: .defaults())
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
            tintHex: nil,
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
            tintHex: nil,
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
