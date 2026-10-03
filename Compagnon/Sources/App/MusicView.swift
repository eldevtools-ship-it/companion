import SwiftUI

// MARK: - Music (Spotify)
// The cloud on the left as everywhere; the cover, the title and a thin progress bar, the
// three controls, then your pinned playlists as chips. Space plays / pauses, ← → change track.

struct MusicView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var spotify = SpotifyService.shared
    @State private var adding = false
    @State private var link = ""
    @State private var linkRefused = false
    @FocusState private var linkFocused: Bool

    private static let green = "#1DB954"

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 10) {
                if spotify.isRunning && !spotify.title.isEmpty {
                    nowPlaying
                } else {
                    idle
                }
                playlistRow
            }
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, IslandConst.cardInset + 6)
        }
        .onAppear { spotify.refresh() }
        .onDisappear { if adding { endAdding() } }
    }

    // MARK: Now playing

    private var nowPlaying: some View {
        HStack(spacing: 12) {
            cover
            VStack(alignment: .leading, spacing: 3) {
                Text(spotify.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                Text(spotify.artist)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .lineLimit(1)
                MusicProgress(spotify: spotify)
                    .padding(.top, 4)
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
        .frame(width: 50, height: 50)
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
                Text(spotify.playlists.isEmpty ? "Épingle une playlist ci-dessous pour la lancer en un clic."
                                               : "Choisis une playlist ou reprends la lecture.")
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

    // MARK: Pinned playlists

    private var playlistRow: some View {
        HStack(spacing: 6) {
            if adding {
                TextField("Colle le lien d'une playlist ou d'un album Spotify…", text: $link)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .focused($linkFocused)
                    .onSubmit { addLink() }
                    .onExitCommand { endAdding() }
                    .onChange(of: link) { _, _ in linkRefused = false }
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                        .fill(Color.white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                        .stroke(Color(hex: "#F4505E").opacity(linkRefused ? 0.7 : 0)))
                    .textCursor()
                    .transition(.opacity)
                CardLink(title: "Annuler", color: "#8E939C") { endAdding() }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(spotify.playlists) { p in
                            PlaylistChip(playlist: p) { spotify.play(p) } onRemove: { spotify.unpin(p) }
                        }
                        addChip
                    }
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                     startPoint: .leading, endPoint: .trailing))
            }
        }
        .frame(height: 24)
        .animation(.easeOut(duration: 0.18), value: adding)
    }

    private var addChip: some View {
        Button { startAdding() } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 9.5, weight: .bold))
                if spotify.playlists.isEmpty {
                    Text("Épingler une playlist").font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundColor(Color(hex: "#8E939C"))
            .padding(.horizontal, spotify.playlists.isEmpty ? 10 : 8)
            .frame(height: 24)
            .background(Capsule().stroke(Color.white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .help("Épingler une playlist (colle son lien Spotify)")
    }

    private func startAdding() {
        adding = true
        link = ""
        state.isEditingText = true
        NotificationCenter.default.post(name: .islandNeedsKeyboard, object: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { linkFocused = true }
    }

    private func endAdding() {
        adding = false
        link = ""
        linkRefused = false
        state.isEditingText = false
    }

    private func addLink() {
        if spotify.pin(link: link) { endAdding() } else { linkRefused = true }
    }
}

/// A pinned playlist: click to play it, right-click to remove it.
private struct PlaylistChip: View {
    let playlist: PinnedPlaylist
    let onPlay: () -> Void
    let onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 5) {
                Image(systemName: playlist.uri.contains(":album:") ? "square.stack" : "music.note.list")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#1DB954"))
                Text(playlist.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(hex: hovered ? "#F5F6F8" : "#C5C8CD"))
                    .lineLimit(1)
                    .frame(maxWidth: 130, alignment: .leading)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(hovered ? 0.1 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .pointingHand()
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h } }
        .help("Lancer « \(playlist.name) » · clic droit pour la retirer")
        .contextMenu {
            Button("Retirer « \(playlist.name) »", role: .destructive, action: onRemove)
        }
    }
}

/// Thin progress bar with the remaining time; drag or click to move in the track.
private struct MusicProgress: View {
    @ObservedObject var spotify: SpotifyService
    @State private var dragging: Double?
    @State private var hovered = false

    var body: some View {
        // Ticks only while it plays (and only while this view exists)
        TimelineView(.periodic(from: .now, by: spotify.isPlaying ? 0.5 : 3600)) { _ in
            let total = max(1, spotify.duration)
            let pos = dragging ?? spotify.currentPosition
            HStack(spacing: 8) {
                GeometryReader { g in
                    let w = g.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(Color(hex: "#F5F6F8"))
                            .frame(width: max(3, w * pos / total))
                    }
                    .frame(height: hovered || dragging != nil ? 5 : 3)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragging = max(0, min(1, v.location.x / w)) * total }
                        .onEnded { v in
                            spotify.seek(to: max(0, min(1, v.location.x / w)) * total)
                            dragging = nil
                        })
                }
                .frame(height: 12)
                .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovered = h } }
                .pointingHand()
                Text("-" + Self.time(total - pos))
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(Color(hex: "#6B7079"))
                    .frame(width: 34, alignment: .trailing)
            }
        }
    }

    static func time(_ t: Double) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
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
