import SwiftUI

// MARK: - Music (Spotify)
// The cloud on the left as everywhere (it dances while the music plays), the cover, the
// title and the three controls. Space plays / pauses, ← → change track.

struct MusicView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var spotify = SpotifyService.shared

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            Group {
                if spotify.isRunning && !spotify.title.isEmpty {
                    nowPlaying
                } else {
                    idle
                }
            }
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, IslandConst.cardInset + 10)
        }
        .onAppear { spotify.refresh() }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                Text(spotify.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                Text(spotify.artist)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                control("backward.fill", size: 12, help: "Morceau précédent (←)") { spotify.previous() }
                Button { spotify.playPause() } label: {
                    Image(systemName: spotify.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(hex: "#0B0C0E"))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color(hex: "#F5F6F8")))
                        .contentShape(Circle())
                }
                .buttonStyle(PressScale())
                .pointingHand()
                .help(spotify.isPlaying ? "Pause (espace)" : "Lecture (espace)")
                control("forward.fill", size: 12, help: "Morceau suivant (→)") { spotify.next() }
            }
        }
    }

    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: IslandConst.innerRadius + 2)
                .fill(Color.white.opacity(0.06))
            if let art = spotify.artwork {
                Image(nsImage: art)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.3))
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: IslandConst.innerRadius + 2))
        .overlay(RoundedRectangle(cornerRadius: IslandConst.innerRadius + 2).stroke(Color.white.opacity(0.06)))
        .animation(.easeOut(duration: 0.25), value: spotify.trackID)
    }

    private func control(_ icon: String, size: CGFloat, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .pointingHand()
        .help(help)
    }

    // MARK: Nothing playing / Spotify closed

    private var idle: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(spotify.isRunning ? "Rien en lecture" : "Spotify est fermé")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text(spotify.isRunning ? "Reprends la lecture, ou lance une musique dans Spotify."
                                       : "Ouvre-le pour piloter ta musique d'ici.")
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            PrimaryButton(spotify.isRunning ? "Lecture" : "Ouvrir Spotify") {
                if spotify.isRunning { spotify.playPause() } else { spotify.open() }
            }
        }
        .frame(height: 50)
    }

}

/// A button that sinks a little while pressed.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Three little bars dancing in the compact bar while music plays.
struct EqualizerBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { i in
                    let v = 0.35 + 0.65 * abs(sin(t * (5.1 + Double(i) * 1.7) + Double(i) * 1.3))
                    Capsule()
                        .fill(Color(hex: "#1DB954"))
                        .frame(width: 2, height: 8 * v)
                }
            }
            .frame(width: 9, height: 8, alignment: .bottom)
        }
    }
}
