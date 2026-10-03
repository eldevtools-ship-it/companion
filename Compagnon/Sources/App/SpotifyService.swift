import AppKit
import SwiftUI

// MARK: - Spotify
// Drives the Spotify app on this Mac through AppleScript: no account, no key, no network
// (except the cover image). Spotify announces every change itself (a distributed
// notification), so nothing polls. Playlists you pin are kept in UserDefaults.

struct PinnedPlaylist: Codable, Equatable, Identifiable {
    var uri: String       // spotify:playlist:… or spotify:album:…
    var name: String
    var id: String { uri }
}

@MainActor
final class SpotifyService: ObservableObject {
    static let shared = SpotifyService()
    static let bundleID = "com.spotify.client"

    @Published private(set) var isInstalled = false
    @Published private(set) var isRunning = false
    @Published private(set) var isPlaying = false
    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var trackID = ""
    @Published private(set) var duration: Double = 0      // seconds
    @Published private(set) var artwork: NSImage?
    /// The cover's average colour: the cloud takes it while the music is on screen.
    @Published private(set) var artworkColor: CGColor?
    @Published private(set) var playlists: [PinnedPlaylist] = []

    /// Position at `positionAt`; while playing, the current position is extrapolated from it.
    private var position: Double = 0
    private var positionAt = Date()
    private var artworkFor = ""
    private let queue = DispatchQueue(label: "compagnon.spotify")
    private static let playlistsKey = "spotifyPlaylists"

    private init() {
        isInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
        if let data = UserDefaults.standard.data(forKey: Self.playlistsKey),
           let saved = try? JSONDecoder().decode([PinnedPlaylist].self, from: data) {
            playlists = saved
        }
        guard isInstalled else { return }
        isRunning = Self.spotifyRunning
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { note in
            let info = note.userInfo ?? [:]
            let stateName = info["Player State"] as? String ?? ""
            let name = info["Name"] as? String ?? ""
            let artist = info["Artist"] as? String ?? ""
            let id = info["Track ID"] as? String ?? ""
            let duration = (info["Duration"] as? NSNumber)?.doubleValue ?? 0
            let position = (info["Playback Position"] as? NSNumber)?.doubleValue ?? 0
            MainActor.assumeIsolated {
                SpotifyService.shared.apply(state: stateName, name: name, artist: artist, id: id,
                                            durationMs: duration, position: position)
            }
        }
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SpotifyService.bundleID else { return }
                let launched = note.name == NSWorkspace.didLaunchApplicationNotification
                MainActor.assumeIsolated { SpotifyService.shared.runningChanged(launched) }
            }
        }
        if isRunning { refresh() }
    }

    private static var spotifyRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    var currentPosition: Double {
        guard isPlaying else { return position }
        return min(duration, position + Date().timeIntervalSince(positionAt))
    }

    // MARK: State

    private func apply(state stateName: String, name: String, artist: String, id: String,
                       durationMs: Double, position: Double) {
        isRunning = true
        isPlaying = stateName == "Playing"
        if stateName == "Stopped" { clearTrack(); return }
        if !name.isEmpty { title = name }
        if !artist.isEmpty { self.artist = artist }
        if durationMs > 0 { duration = durationMs / 1000 }
        self.position = position
        positionAt = Date()
        if !id.isEmpty && id != trackID {
            trackID = id
            loadArtwork()
        }
    }

    private func runningChanged(_ running: Bool) {
        isRunning = running
        if !running { isPlaying = false; clearTrack() }
    }

    private func clearTrack() {
        title = ""; artist = ""; trackID = ""; duration = 0; position = 0
        artwork = nil; artworkColor = nil; artworkFor = ""
    }

    /// Reads the current track (when the music view opens, or at launch). Never starts Spotify.
    func refresh() {
        guard isInstalled, Self.spotifyRunning else { isRunning = false; return }
        let script = """
        tell application id "com.spotify.client"
            set s to player state as string
            if s is "stopped" then return "stopped"
            set t to current track
            return s & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (id of t) & linefeed & ((duration of t) as string) & linefeed & ((player position) as string)
        end tell
        """
        run(script) { result in
            guard let result else { return }
            let parts = result.components(separatedBy: "\n")
            if parts.first == "stopped" || parts.count < 6 {
                SpotifyService.shared.apply(state: "Stopped", name: "", artist: "", id: "", durationMs: 0, position: 0)
                return
            }
            let number = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
            SpotifyService.shared.apply(state: parts[0] == "playing" ? "Playing" : "Paused",
                                        name: parts[1], artist: parts[2], id: parts[3],
                                        durationMs: number(parts[4]), position: number(parts[5]))
        }
    }

    // MARK: Commands

    func playPause() {
        // Optimistic: the button answers at once, Spotify's notification confirms
        if isRunning { position = currentPosition; positionAt = Date(); isPlaying.toggle() }
        send(isRunning ? "playpause" : "play")
    }
    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to seconds: Double) {
        let s = max(0, min(duration, seconds))
        position = s; positionAt = Date()
        send(String(format: "set player position to %.2f", locale: Locale(identifier: "en_US_POSIX"), s))
    }

    func play(_ playlist: PinnedPlaylist) {
        send("play track \"\(playlist.uri)\"")
    }

    /// Opens Spotify (when it's closed).
    func open() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func send(_ command: String) {
        run("tell application id \"com.spotify.client\" to \(command)") { _ in }
    }

    /// Runs AppleScript off the main thread (the first call shows macOS's permission prompt).
    private func run(_ source: String, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        queue.async {
            var error: NSDictionary?
            let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
            if let error { appendAppLog("spotify.log", "AppleScript: \(error)") }
            let result: String? = error == nil ? (output ?? "") : nil
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }

    // MARK: Cover

    private func loadArtwork() {
        let id = trackID
        guard artworkFor != id, !AppState.shared.macAsleep else { return }
        artworkFor = id
        run("tell application id \"com.spotify.client\" to return artwork url of current track") { url in
            guard let url, let link = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
                  link.scheme == "https" else { return }
            Task.detached {
                guard let (data, _) = try? await URLSession.shared.data(from: link) else { return }
                let rgb = Self.averageColor(of: data)
                await MainActor.run {
                    guard SpotifyService.shared.trackID == id, let image = NSImage(data: data) else { return }
                    SpotifyService.shared.artwork = image
                    SpotifyService.shared.artworkColor = rgb.map { CGColor(red: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
                }
            }
        }
    }

    /// The cover shrunk to one pixel, lifted a little so a dark cover still lights the cloud.
    nonisolated private static func averageColor(of data: Data) -> (CGFloat, CGFloat, CGFloat)? {
        guard let image = NSImage(data: data),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .medium
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let c = rep.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        guard let lifted = NSColor(hue: h, saturation: min(1, s * 1.25), brightness: max(0.62, b), alpha: 1)
            .usingColorSpace(.sRGB) else { return nil }
        return (lifted.redComponent, lifted.greenComponent, lifted.blueComponent)
    }

    // MARK: Pinned playlists

    /// Accepts an open.spotify.com link or a spotify: URI (playlist or album). Returns false if
    /// it isn't one. The name comes from Spotify's public page info (no account needed).
    @discardableResult
    func pin(link: String) -> Bool {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        var kind = "", id = ""
        if text.hasPrefix("spotify:") {
            let parts = text.split(separator: ":")
            if parts.count >= 3 { kind = String(parts[1]); id = String(parts[2]) }
        } else if let url = URL(string: text), url.host?.hasSuffix("spotify.com") == true {
            let comps = url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") }
            if comps.count >= 2 { kind = comps[0]; id = comps[1] }
        }
        guard ["playlist", "album"].contains(kind),
              !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        let uri = "spotify:\(kind):\(id)"
        guard !playlists.contains(where: { $0.uri == uri }) else { return true }
        playlists.append(PinnedPlaylist(uri: uri, name: kind == "album" ? "Album" : "Playlist"))
        savePlaylists()
        fetchName(uri: uri, page: "https://open.spotify.com/\(kind)/\(id)")
        return true
    }

    func unpin(_ playlist: PinnedPlaylist) {
        playlists.removeAll { $0.uri == playlist.uri }
        savePlaylists()
    }

    private func savePlaylists() {
        if let data = try? JSONEncoder().encode(playlists) {
            UserDefaults.standard.set(data, forKey: Self.playlistsKey)
        }
    }

    private func fetchName(uri: String, page: String) {
        var comps = URLComponents(string: "https://open.spotify.com/oembed")
        comps?.queryItems = [URLQueryItem(name: "url", value: page)]
        guard let url = comps?.url else { return }
        Task.detached {
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String, !title.isEmpty else { return }
            await MainActor.run {
                let s = SpotifyService.shared
                guard let i = s.playlists.firstIndex(where: { $0.uri == uri }) else { return }
                s.playlists[i].name = title
                s.savePlaylists()
            }
        }
    }
}
