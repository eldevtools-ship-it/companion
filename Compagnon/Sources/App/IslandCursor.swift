import AppKit
import SwiftUI

// MARK: - Cursor over the island
// Compagnon is never the active app, so macOS normally lets the app underneath
// decide the cursor (a text I-beam over an editor, even on our buttons). We ask the
// window server to accept our cursor while in the background, then set it ourselves:
// a hand over anything clickable, an I-beam over our text fields, an arrow elsewhere.

@MainActor
enum IslandCursor {
    /// What the hovered element wants; nil = arrow.
    static var wanted: NSCursor? = nil

    static func apply() {
        (wanted ?? NSCursor.arrow).set()
    }

    /// Private window-server switch (SetsCursorInBackground), looked up at run time so
    /// a missing symbol just leaves the default behaviour.
    static func allowInBackground() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let all = UnsafeMutableRawPointer(bitPattern: -2)   // RTLD_DEFAULT
        guard let conn = dlsym(all, "_CGSDefaultConnection"),
              let set = dlsym(all, "CGSSetConnectionProperty") else { return }
        let cid = unsafeBitCast(conn, to: DefaultConnection.self)()
        _ = unsafeBitCast(set, to: SetProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

private struct IslandCursorModifier: ViewModifier {
    let cursor: NSCursor
    @State private var inside = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                inside = hovering
                let cursor = cursor
                MainActor.assumeIsolated {
                    IslandCursor.wanted = hovering ? cursor : nil
                    IslandCursor.apply()
                }
            }
            .onDisappear {
                guard inside else { return }
                inside = false
                MainActor.assumeIsolated {
                    IslandCursor.wanted = nil
                    IslandCursor.apply()
                }
            }
    }
}

extension View {
    /// Hand cursor while the pointer is over this view (buttons, links, rows).
    func pointingHand() -> some View { modifier(IslandCursorModifier(cursor: .pointingHand)) }
    /// I-beam while the pointer is over this view (text fields).
    func textCursor() -> some View { modifier(IslandCursorModifier(cursor: .iBeam)) }
}
