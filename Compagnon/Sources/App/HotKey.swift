import Carbon

// MARK: - Global shortcut for the notes (⌥⌘N)
// A Carbon hot key works from any app without the Accessibility permission.

enum NotesHotKey {
    nonisolated(unsafe) private static var ref: EventHotKeyRef?
    nonisolated(unsafe) private static var handler: EventHandlerRef?

    static func register() {
        guard ref == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            NotificationCenter.default.post(name: .openNotes, object: nil)
            return noErr
        }, 1, &type, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x434D_504E), id: 1)   // 'CMPN'
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}

extension Notification.Name {
    static let openNotes = Notification.Name("compagnon.openNotes")
}
