import Foundation

/// Short letterforms for agents that have no brand mark.
///
/// A monogram is only useful if it's *distinct* from the others on screen, so
/// they're assigned for the whole set at once rather than per agent: everyone
/// gets one letter until two agents collide, and only the colliding ones grow.
/// "Claude Code" and "Codex" both want `C`, so they become `CL` and `CO`, while
/// an unambiguous "Gemini" stays a clean single `G`.
enum Monogram {
    /// Assign a monogram per name, in the same order. Deterministic: the same
    /// set of names always produces the same letters.
    static func assign(_ names: [String]) -> [String] {
        var result = names.map { level1($0) }
        // Grow only the members of a colliding group, and repeat, since a level-2
        // form can collide with something that was already unique at level 1.
        for level in [level2, level3] {
            guard hasDuplicates(result) else { break }
            let duplicated = duplicates(result)
            for i in result.indices where duplicated.contains(result[i]) {
                result[i] = level(names[i])
            }
        }
        return result
    }

    /// The monogram for one name among a set.
    static func of(_ name: String, in names: [String]) -> String {
        guard let idx = names.firstIndex(of: name) else { return level1(name) }
        return assign(names)[idx]
    }

    // MARK: - Levels

    /// First letter: "Gemini CLI" → "G".
    private static func level1(_ name: String) -> String {
        guard let c = letters(name).first else { return "?" }
        return String(c).uppercased()
    }

    /// Initials of the first two words, or the first two letters of a single
    /// word: "Claude Code" → "CC", "Codex" → "CO".
    private static func level2(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 {
            let a = words[0].first.map { String($0) } ?? ""
            let b = words[1].first.map { String($0) } ?? ""
            return (a + b).uppercased()
        }
        return String(letters(name).prefix(2)).uppercased()
    }

    /// Last resort: first and last letter of the first word, which separates
    /// names that share a prefix ("Codex" → "CX", "Coder" → "CR").
    private static func level3(_ name: String) -> String {
        let word = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first ?? ""
        guard let f = word.first, let l = word.last, word.count > 1 else { return level2(name) }
        return (String(f) + String(l)).uppercased()
    }

    private static func letters(_ name: String) -> [Character] {
        name.filter { $0.isLetter || $0.isNumber }.map { $0 }
    }

    private static func hasDuplicates(_ xs: [String]) -> Bool {
        Set(xs).count != xs.count
    }

    private static func duplicates(_ xs: [String]) -> Set<String> {
        var seen = Set<String>(), dupes = Set<String>()
        for x in xs where !seen.insert(x).inserted { dupes.insert(x) }
        return dupes
    }
}
