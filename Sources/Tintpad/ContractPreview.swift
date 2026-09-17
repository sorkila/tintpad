import AppKit

/// Which mode a launch uses for the modifiers held with it. The one rule, shared
/// by the launch (`PaletteModel.resolveMode`) and the chips that preview it
/// (`ContractPreview`), so what the MODE chip says and what ⏎ runs cannot drift.
enum ModeResolution {
    /// - Parameters:
    ///   - resting: the mode a plain ⏎ uses (override → pin → last-used → default).
    ///   - option: ⌥ asks for the agent's permission-skipping mode, when it has one.
    ///   - shift: ⇧ asks for the safest mode.
    static func mode(for agent: Agent, resting: RunMode, option: Bool, shift: Bool) -> RunMode {
        if option, let danger = agent.dangerousMode { return danger }
        if shift {
            // "Safest available": the first non-dangerous mode, whatever the
            // agent calls it (modes speak the agent's language, not ours).
            return agent.modes.first { !$0.isDangerous } ?? agent.modes.first ?? .defaultMode()
        }
        return resting
    }
}

/// The contract chips as they read with the modifiers held right now, so the
/// contract is always true: ⌥ turns MODE red before Return lands, ⇧ shows the
/// safest mode, ⌃ appends RUN · Headless, a held ⌘ appends OPEN IN · <editor>.
/// Pure, so the preview is tested against `ModeResolution` directly.
///
/// Accepted trade-off: ⌘ suspends the mode preview at once, but OPEN IN only
/// appears after the hold beat and only when an editor is detected. So ⌘⏎
/// pressed within that beat, or with no editor installed, shows the resting
/// MODE while Return opens (or fails to open) an editor. That never runs an
/// agent, so it is never dangerous, and it keeps ⌘R and ⌘P from flashing.
enum ContractPreview {
    /// One capsule of the contract. `kind` is the identity (and decides what a
    /// click does), the rest is what it says. Extend here (a key hint, say)
    /// rather than growing positional parameters at the call site.
    struct Chip: Equatable, Identifiable {
        enum Kind: String, Equatable {
            case prompt, agent, mode, run
            case openIn = "open in"
        }
        let kind: Kind
        let label: String
        var danger = false

        var id: Kind { kind }
        /// The micro-eyebrow above the value.
        var tag: String { kind.rawValue }
    }

    /// The modifiers the palette currently sees held.
    struct Held: Equatable {
        var option = false
        var shift = false
        var control = false
        /// ⌘ is down at all. ⌘⏎ opens the editor and ⌘1–⌘9 launch at rest, so
        /// while it is down no other modifier changes what a launch runs.
        var command = false
        /// ⌘ has been held past the short beat that tells a hold from a chord
        /// (⌘R, ⌘P), which is when OPEN IN appears.
        var commandHeldLong = false

        static let none = Held()

        init(option: Bool = false, shift: Bool = false, control: Bool = false,
             command: Bool = false, commandHeldLong: Bool = false) {
            self.option = option
            self.shift = shift
            self.control = control
            self.command = command
            self.commandHeldLong = commandHeldLong
        }

        init(flags: NSEvent.ModifierFlags, commandHeldLong: Bool) {
            self.init(option: flags.contains(.option), shift: flags.contains(.shift),
                      control: flags.contains(.control), command: flags.contains(.command),
                      commandHeldLong: commandHeldLong && flags.contains(.command))
        }
    }

    /// The mode the MODE chip states: what ⏎ would run with these modifiers.
    static func mode(agent: Agent, restingMode: RunMode, held: Held) -> RunMode {
        guard !held.command else { return restingMode }
        return ModeResolution.mode(for: agent, resting: restingMode,
                                   option: held.option, shift: held.shift)
    }

    static func chips(agent: Agent, restingMode: RunMode, prompt: PromptTemplate?,
                      editorName: String?, held: Held) -> [Chip] {
        var chips: [Chip] = []
        if let prompt { chips.append(Chip(kind: .prompt, label: prompt.title)) }
        let mode = mode(agent: agent, restingMode: restingMode, held: held)
        chips.append(Chip(kind: .agent, label: agent.name))
        chips.append(Chip(kind: .mode, label: mode.name, danger: mode.isDangerous))
        // ⌘ outranks ⌃ at the Return key, so the preview does too.
        if held.control && !held.command { chips.append(Chip(kind: .run, label: "Headless")) }
        if held.commandHeldLong, let editorName {
            chips.append(Chip(kind: .openIn, label: editorName))
        }
        return chips
    }
}
