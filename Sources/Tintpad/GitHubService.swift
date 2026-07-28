import Foundation

/// Imports repositories from GitHub. Uses a personal access token (stored in the
/// Keychain) rather than full OAuth — simpler, no callback server, and the token
/// never leaves the machine except in calls to api.github.com.
enum GitHubService {
    private static let tokenAccount = "github-pat"

    struct Repo: Identifiable, Hashable {
        let id: Int
        let fullName: String   // owner/name
        let name: String
        let cloneURL: String
        let isPrivate: Bool
    }

    enum GitHubError: Error, CustomStringConvertible {
        case noToken
        case http(Int)
        case transport(String)
        case cloneFailed(String)

        var description: String {
            switch self {
            case .noToken: return "No GitHub token saved"
            case .http(let c): return "GitHub API error (HTTP \(c))"
            case .transport(let m): return m
            case .cloneFailed(let m): return "Clone failed: \(m)"
            }
        }
    }

    // MARK: - Token

    static var token: String? {
        get { Keychain.get(account: tokenAccount) }
        set { Keychain.set(newValue, account: tokenAccount) }
    }

    static var hasToken: Bool { token?.isEmpty == false }

    // MARK: - API

    /// Fetch the authenticated user's repos (most-recently-updated first).
    static func listRepos() async throws -> [Repo] {
        guard let token, !token.isEmpty else { throw GitHubError.noToken }
        var comps = URLComponents(string: "https://api.github.com/user/repos")!
        comps.queryItems = [
            .init(name: "per_page", value: "100"),
            .init(name: "sort", value: "updated"),
            .init(name: "affiliation", value: "owner,collaborator,organization_member"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Tintpad", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw GitHubError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw GitHubError.transport("no response") }
        guard (200..<300).contains(http.statusCode) else { throw GitHubError.http(http.statusCode) }

        let decoded = try JSONDecoder().decode([APIRepo].self, from: data)
        return decoded.map {
            Repo(id: $0.id, fullName: $0.full_name, name: $0.name,
                 cloneURL: $0.clone_url, isPrivate: $0.`private`)
        }
    }

    /// Clone `repo` into `root` and return the local path. Async: the actual
    /// clone runs on a GCD queue (a big clone takes minutes and must never
    /// touch the main actor or the cooperative pool), bounded at 10 minutes.
    static func clone(_ repo: Repo, into root: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try cloneSync(repo, into: root)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    private static func cloneSync(_ repo: Repo, into root: String) throws -> String {
        let expandedRoot = (root as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: expandedRoot, withIntermediateDirectories: true)
        let dest = (expandedRoot as NSString).appendingPathComponent(repo.name)
        guard !FileManager.default.fileExists(atPath: dest) else { return dest }

        let git = ShellEnvironment.resolveBinary("git") ?? "/usr/bin/git"
        let result: ProcessRunner.Output
        do {
            result = try ProcessRunner.run(git, arguments: ["clone", "--", repo.cloneURL, dest],
                                           environment: ShellEnvironment.processEnvironment,
                                           timeout: 600)
        } catch {
            throw GitHubError.cloneFailed(error.localizedDescription)
        }
        if result.status != 0 {
            throw GitHubError.cloneFailed(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return dest
    }

    private struct APIRepo: Codable {
        let id: Int
        let name: String
        let full_name: String
        let clone_url: String
        let `private`: Bool
    }
}
