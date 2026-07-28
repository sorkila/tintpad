import AppKit
import SwiftUI

struct GitHubSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var token = GitHubService.token ?? ""
    @State private var repos: [GitHubService.Repo] = []
    @State private var loading = false
    @State private var error: String?
    @State private var cloneRoot: String = ""
    @State private var added: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("GitHub access") {
                    SecureField("Personal access token (repo scope)", text: $token)
                        .font(.monoStyle(.body))
                    HStack {
                        Button("Save token") { GitHubService.token = token }
                            .disabled(token.isEmpty)
                        Button(loading ? "Fetching…" : "Fetch repos") { fetch() }
                            .disabled(token.isEmpty || loading)
                        Spacer()
                        Link("Create a token", destination:
                            URL(string: "https://github.com/settings/tokens/new?scopes=repo&description=Tintpad")!)
                            .font(.caption)
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }

                Section("Clone into") {
                    Picker("Folder", selection: $cloneRoot) {
                        ForEach(store.settings.rootScanFolders, id: \.self) { Text($0).tag($0) }
                        if store.settings.rootScanFolders.isEmpty {
                            Text(NSHomeDirectory()).tag(NSHomeDirectory())
                        }
                    }
                }

                if !repos.isEmpty {
                    Section("Your repositories (\(repos.count))") {
                        ForEach(repos) { repo in repoRow(repo) }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onAppear {
            if cloneRoot.isEmpty {
                cloneRoot = store.settings.rootScanFolders.first ?? NSHomeDirectory()
            }
        }
    }

    private func repoRow(_ repo: GitHubService.Repo) -> some View {
        HStack {
            Image(systemName: repo.isPrivate ? "lock.fill" : "book.closed")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(repo.name).font(.body.weight(.medium))
                Text(repo.fullName).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if added.contains(repo.id) {
                Label("Added", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    .font(.caption)
            } else {
                Button("Clone & Add") { clone(repo) }.controlSize(.small)
            }
        }
    }

    private func fetch() {
        GitHubService.token = token
        loading = true; error = nil
        Task {
            do {
                let result = try await GitHubService.listRepos()
                await MainActor.run { repos = result; loading = false }
            } catch {
                await MainActor.run { self.error = "\(error)"; loading = false }
            }
        }
    }

    private func clone(_ repo: GitHubService.Repo) {
        Task {
            do {
                // Async clone: the git work runs on a GCD queue, so this task
                // (MainActor-inherited) just awaits — the UI stays live.
                let path = try await GitHubService.clone(repo, into: cloneRoot)
                store.addRepo(path: path, via: .github)
                added.insert(repo.id)
            } catch {
                self.error = "\(error)"
            }
        }
    }
}
