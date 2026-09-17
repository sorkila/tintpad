import Foundation

/// How a query finds a repo, in tiers from strongest to weakest. Pure logic,
/// no store: the palette asks `RepoSearch.rank` and draws the offsets.
///
/// Matching is case- and diacritic-insensitive ("cafe" finds "Café"). The
/// tiers, first hit wins:
/// - `exact`: the whole name.
/// - `prefix`: the start of the name.
/// - `wordBoundary`: contiguous runs that each begin a word ("dl" and "led"
///   both find demand-ledger). A word begins at offset 0, after anything that
///   is not a letter or digit (`-`, `.`, a space, an emoji), at a lower-to-upper
///   transition (`myTintFork`), or where letters and digits meet (`v2Plan`).
/// - `infix`: one contiguous run anywhere ("dger" in demand-ledger, "pad" in
///   tintpad), so a fragment lights the letters it actually typed. Three
///   letters or more: a two-letter query reads as initials ("tp" is t…p in
///   tintpad, not the "tp" in its middle).
/// - `subsequence`: the letters in order, anywhere ("tp" finds tintpad).
/// - `path`: a substring of the path, for a parent folder. No offsets, since
///   nothing in the name is what matched.
enum FuzzyMatch {
    enum Tier: Int, Comparable {
        case exact, prefix, wordBoundary, infix, subsequence, path

        static func < (a: Tier, b: Tier) -> Bool { a.rawValue < b.rawValue }
    }

    struct Match: Equatable {
        let tier: Tier
        /// Character offsets into the repo's name, ascending and unique.
        let offsets: [Int]
    }

    /// The comparable form of a query or name: case and diacritics folded away.
    static func fold(_ s: String) -> [Character] {
        Array(s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    }

    static func match(_ query: String, name: String, path: String) -> Match? {
        let q = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return nil }

        // Fold the name per character so every folded character remembers the
        // original one it came from (a fold can expand, e.g. a ligature).
        let original = Array(name)
        var folded: [Character] = []
        var source: [Int] = []
        var starts: [Bool] = []
        for (i, ch) in original.enumerated() {
            let pieces = fold(String(ch))
            let boundary = isWordStart(original, at: i)
            for (k, piece) in pieces.enumerated() {
                folded.append(piece)
                source.append(i)
                starts.append(k == 0 && boundary)
            }
        }
        func offsets(_ positions: [Int]) -> [Int] {
            var out: [Int] = []
            for p in positions where out.last != source[p] { out.append(source[p]) }
            return out
        }

        if folded == q {
            return Match(tier: .exact, offsets: offsets(Array(folded.indices)))
        }
        if folded.starts(with: q) {
            return Match(tier: .prefix, offsets: offsets(Array(0..<q.count)))
        }
        if let positions = wordRuns(q, in: folded, starts: starts) {
            return Match(tier: .wordBoundary, offsets: offsets(positions))
        }
        if q.count >= minInfixLength, let start = infixStart(q, in: folded, starts: starts) {
            return Match(tier: .infix, offsets: offsets(Array(start..<start + q.count)))
        }
        if let positions = subsequence(q, in: folded) {
            return Match(tier: .subsequence, offsets: offsets(positions))
        }
        if occurrences(of: q, in: fold(path)).first != nil {
            return Match(tier: .path, offsets: [])
        }
        return nil
    }

    static let minInfixLength = 3

    static func isWordStart(_ chars: [Character], at i: Int) -> Bool {
        let cur = chars[i]
        guard cur.isLetter || cur.isNumber else { return false }
        guard i > 0 else { return true }
        let prev = chars[i - 1]
        if !prev.isLetter && !prev.isNumber { return true }
        if prev.isNumber != cur.isNumber { return true }   // v2Plan: "2" and "Plan"
        return prev.isLowercase && cur.isUppercase
    }

    /// Every start index where `q` occurs contiguously in `s`, ascending.
    private static func occurrences(of q: [Character], in s: [Character]) -> [Int] {
        guard !q.isEmpty, s.count >= q.count else { return [] }
        return (0...(s.count - q.count)).filter { s[$0..<$0 + q.count].elementsEqual(q) }
    }

    /// The first occurrence that begins a word, else the first occurrence.
    private static func infixStart(_ q: [Character], in name: [Character], starts: [Bool]) -> Int? {
        let all = occurrences(of: q, in: name)
        return all.first(where: { starts[$0] }) ?? all.first
    }

    /// The query as one or more contiguous runs, each beginning a word, in
    /// order. Leftmost first, backtracking where a greedy run would strand
    /// the rest ("dle" in demand-ledger: "d", then "le").
    private static func wordRuns(_ q: [Character], in name: [Character], starts: [Bool]) -> [Int]? {
        var failed = Set<Int>()   // (query index, name index) pairs known to fail
        func solve(_ qi: Int, _ from: Int) -> [Int]? {
            if qi == q.count { return [] }
            let key = qi * (name.count + 1) + from
            if failed.contains(key) { return nil }
            var b = from
            while b < name.count {
                if starts[b], name[b] == q[qi] {
                    // Try the longest run first, then shorter ones.
                    var len = 0
                    while qi + len < q.count, b + len < name.count, name[b + len] == q[qi + len] {
                        len += 1
                    }
                    while len > 0 {
                        if let rest = solve(qi + len, b + len) {
                            return Array(b..<b + len) + rest
                        }
                        len -= 1
                    }
                }
                b += 1
            }
            failed.insert(key)
            return nil
        }
        return solve(0, 0)
    }

    /// In-order greedy: each query character at its leftmost place after the last.
    private static func subsequence(_ q: [Character], in name: [Character]) -> [Int]? {
        var positions: [Int] = []
        var n = 0
        for ch in q {
            while n < name.count, name[n] != ch { n += 1 }
            guard n < name.count else { return nil }
            positions.append(n)
            n += 1
        }
        return positions
    }
}

enum RepoSearch {
    /// Every repo the query finds, strongest tier first, and inside a tier
    /// in the order given (frecency). The key is `(tier, index in ordered)`,
    /// a strict weak ordering with no ties, so the result never reshuffles.
    /// A blank query finds everything, in order, with no offsets.
    static func rank(_ query: String, in ordered: [Repo]) -> [(repo: Repo, match: FuzzyMatch.Match)] {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ordered.map { ($0, FuzzyMatch.Match(tier: .exact, offsets: [])) }
        }
        typealias Hit = (index: Int, repo: Repo, match: FuzzyMatch.Match)
        var hits: [Hit] = []
        for (index, repo) in ordered.enumerated() {
            if let match = FuzzyMatch.match(query, name: repo.name, path: repo.path) {
                hits.append((index, repo, match))
            }
        }
        hits.sort { a, b in
            if a.match.tier != b.match.tier { return a.match.tier < b.match.tier }
            return a.index < b.index
        }
        return hits.map { (repo: $0.repo, match: $0.match) }
    }
}
