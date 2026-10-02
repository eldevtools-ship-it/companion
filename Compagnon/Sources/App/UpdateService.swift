import Foundation
import AppKit

// MARK: - Self-update
// Each green build on GitHub is published as a release tagged "build-<n>" with
// Compagnon.zip attached (.github/workflows/build.yml). The app compares <n> with
// its own CFBundleVersion, downloads the zip, swaps its bundle and relaunches.
// The repo is private, so this needs a GitHub token with read access to it.
// A file downloaded by the app itself carries no quarantine flag, so macOS does
// not ask to confirm the new version.

enum UpdateStatus: Equatable {
    case idle
    case checking
    case upToDate
    case available(build: Int)
    case installing
    case failed(String)

    var label: String {
        switch self {
        case .idle:                  return ""
        case .checking:              return "Recherche…"
        case .upToDate:              return "À jour"
        case .available(let b):      return "Version \(b) disponible"
        case .installing:            return "Installation…"
        case .failed(let m):         return "Échec : \(m)"
        }
    }
}

/// Drops the GitHub token when the asset download is redirected to the storage host.
private final class StripAuthOnRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var req = request
        if req.url?.host != task.originalRequest?.url?.host {
            req.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return req
    }
}

@MainActor
final class UpdateService {
    static let shared = UpdateService()
    static let tokenKey = "update-token"
    private static let repo = "eldevtools-ship-it/companion"

    private var loop: Task<Void, Never>?
    private var assetURL: URL?
    private var availableBuild = 0

    private init() {}

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0
    }

    /// Dedicated token if set, otherwise the GitHub integration's token.
    private var token: String? {
        KeychainStore.shared.get(Self.tokenKey) ?? KeychainStore.shared.get("github-token")
    }

    // MARK: Lifecycle

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            while !Task.isCancelled {
                await self?.check()
                await self?.installWhenIdleIfWanted()
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
            }
        }
    }

    // MARK: Check

    func check() async {
        let state = AppState.shared
        guard let token else {
            state.updateStatus = .failed("ajoute un jeton GitHub dans les réglages")
            return
        }
        state.updateStatus = .checking
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                state.updateStatus = .failed(code == 401 || code == 404 ? "jeton sans accès au dépôt" : "erreur \(code)")
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let build = Int(tag.replacingOccurrences(of: "build-", with: "")),
                  let assets = json["assets"] as? [[String: Any]],
                  let zip = assets.first(where: { ($0["name"] as? String) == "Compagnon.zip" }),
                  let api = zip["url"] as? String, let assetURL = URL(string: api) else {
                state.updateStatus = .failed("release illisible")
                return
            }
            if build > Self.currentBuild {
                self.assetURL = assetURL
                availableBuild = build
                state.updateStatus = .available(build: build)
            } else {
                state.updateStatus = .upToDate
            }
        } catch {
            state.updateStatus = .failed(error.localizedDescription)
        }
    }

    /// Automatic mode waits for a quiet moment: no approval pending, no agent
    /// working, island not open.
    private func installWhenIdleIfWanted() async {
        let state = AppState.shared
        guard state.autoUpdate, case .available = state.updateStatus else { return }
        for _ in 0..<120 {   // up to an hour, checked every 30 s
            let busyStates: Set<BotState> = [.working, .thinking, .searching, .approval, .question]
            let busy = state.pendingApproval != nil
                || state.mode == .expanded
                || state.tasks.contains { !$0.isIntegration && busyStates.contains($0.state) }
                || state.tasks.contains { $0.id == "integration_claude" && busyStates.contains($0.state) }
            if !busy { await install(); return }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }

    // MARK: Install

    func install() async {
        let state = AppState.shared
        guard let assetURL, let token else { return }
        state.updateStatus = .installing
        do {
            var req = URLRequest(url: assetURL, timeoutInterval: 120)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            let (file, response) = try await URLSession.shared.download(for: req, delegate: StripAuthOnRedirect())
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("téléchargement refusé") }

            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("compagnon-update-\(availableBuild)", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("Compagnon.zip")
            try FileManager.default.moveItem(at: file, to: zip)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

            let newApp = work.appendingPathComponent("Compagnon.app")
            guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
                  let v = info["CFBundleVersion"] as? String, (Int(v) ?? 0) > Self.currentBuild else {
                throw UpdateError("archive inattendue")
            }
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
            try relaunch(replacingWith: newApp)
        } catch {
            state.updateStatus = .failed(error.localizedDescription)
            appendAppLog("update.log", "install: \(error.localizedDescription)")
        }
    }

    /// Hands over to a tiny script that waits for us to quit, swaps the bundles
    /// (rolling back if anything fails) and opens the new version.
    private func relaunch(replacingWith newApp: URL) throws {
        let target = Bundle.main.bundleURL.path
        let script = """
        #!/bin/sh
        mkdir -p "$HOME/Library/Logs/Compagnon"
        exec >> "$HOME/Library/Logs/Compagnon/update.log" 2>&1
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        T=\(Self.shellQuote(target))
        N=\(Self.shellQuote(newApp.path))
        rm -rf "$T.old"
        if mv "$T" "$T.old"; then
          if ditto "$N" "$T"; then rm -rf "$T.old"; else rm -rf "$T"; mv "$T.old" "$T"; fi
        fi
        open "$T"
        """
        let scriptURL = newApp.deletingLastPathComponent().appendingPathComponent("swap.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path]
        try p.run()
        appendAppLog("update.log", "relaunching into build \(availableBuild)")
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\((tool as NSString).lastPathComponent) a échoué") }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private struct UpdateError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }
}
