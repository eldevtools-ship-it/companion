import AVFoundation
import AppKit

/// Preloaded WAV players with near-zero latency.
/// Volume default 0.12 (matches prototype: gain ×6 then vol=0.12).
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    var volume: Float = 0.12 {
        didSet { players.values.forEach { $0.forEach { $0.volume = volume } } }
    }

    // Two players per sound so a quick repeat can overlap, created the first time
    // the sound plays (most sounds never play in a session).
    private var players: [String: [AVAudioPlayer]] = [:]

    private init() {}

    private func pool(for name: String) -> [AVAudioPlayer]? {
        if let p = players[name] { return p }
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds") else { return nil }
        let pool = (0..<2).compactMap { _ -> AVAudioPlayer? in
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
            p.volume = volume
            p.prepareToPlay()
            return p
        }
        guard !pool.isEmpty else { return nil }
        players[name] = pool
        return pool
    }

    func play(_ name: String) {
        guard AppState.shared.soundEnabled, let pool = pool(for: name) else { return }
        let player = pool.first { !$0.isPlaying } ?? pool[0]
        player.currentTime = 0
        player.volume = volume
        player.play()
    }
}
