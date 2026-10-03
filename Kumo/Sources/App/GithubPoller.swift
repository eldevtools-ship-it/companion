import Foundation

// MARK: - GitHub
// Repos and stars for the GitHub card. They change slowly: every 15 minutes is plenty.

@MainActor
final class GithubPoller {
    static let shared = GithubPoller()
    private var loop: Task<Void, Never>?
    private init() {}

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            while !Task.isCancelled {
                if !AppState.shared.macAsleep { await self?.poll() }
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
            }
        }
    }

    private func poll() async {
        guard let token = KeychainStore.shared.get("github-token"),
              let user = await get("https://api.github.com/user", token: token) as? [String: Any],
              let repos = await get("https://api.github.com/user/repos?per_page=100&affiliation=owner&sort=pushed",
                                    token: token) as? [[String: Any]] else { return }
        let publicRepos = (user["public_repos"] as? Int) ?? 0
        let privateOwned = (user["owned_private_repos"] as? Int) ?? (user["total_private_repos"] as? Int) ?? 0
        let stars = repos.reduce(0) { $0 + (($1["stargazers_count"] as? Int) ?? 0) }
        AppState.shared.githubStats = GitHubStats(totalRepos: publicRepos + privateOwned, totalStars: stars)
    }

    private func get(_ urlString: String, token: String) async -> Any? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: result.0)
    }
}
