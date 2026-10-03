import AppKit
import Carbon

// MARK: - Global shortcuts: ⌥⌘N notes, ⌥⌘J chat with Claude, and the one you choose in
// Settings to show the island. Carbon hot keys work from any app without the
// Accessibility permission (an NSEvent global monitor would need it).

enum NotesHotKey {
    nonisolated(unsafe) private static var refs: [EventHotKeyRef?] = []
    nonisolated(unsafe) private static var islandRef: EventHotKeyRef?
    nonisolated(unsafe) private static var handler: EventHandlerRef?
    private static let signature = OSType(0x434D_504E)   // 'CMPN'

    static func register() {
        guard refs.isEmpty else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let name: Notification.Name = hk.id == 3 ? .openIsland : hk.id == 2 ? .openChat : .openNotes
            NotificationCenter.default.post(name: name, object: nil)
            return noErr
        }, 1, &type, nil, &handler)
        for (id, key) in [(UInt32(1), kVK_ANSI_N), (UInt32(2), kVK_ANSI_J)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey),
                                EventHotKeyID(signature: signature, id: id),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    /// The Settings shortcut that shows the island (re-registered whenever it changes).
    static func updateIslandHotKey(enabled: Bool, flags rawFlags: UInt, code: UInt16) {
        if let islandRef { UnregisterEventHotKey(islandRef) }
        islandRef = nil
        guard enabled else { return }
        let flags = NSEvent.ModifierFlags(rawValue: rawFlags)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        guard mods != 0 else { return }
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(code), mods, EventHotKeyID(signature: signature, id: 3),
                            GetApplicationEventTarget(), 0, &ref)
        islandRef = ref
    }
}

extension Notification.Name {
    static let openNotes = Notification.Name("kumo.openNotes")
    static let openChat = Notification.Name("kumo.openChat")
    static let openIsland = Notification.Name("kumo.openIsland")
}
