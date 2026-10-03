import Carbon

// MARK: - Global shortcuts: ⌥⌘N notes, ⌥⌘J chat with Claude
// Carbon hot keys work from any app without the Accessibility permission.

enum NotesHotKey {
    nonisolated(unsafe) private static var refs: [EventHotKeyRef?] = []
    nonisolated(unsafe) private static var handler: EventHandlerRef?

    static func register() {
        guard refs.isEmpty else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            NotificationCenter.default.post(name: hk.id == 2 ? .openChat : .openNotes, object: nil)
            return noErr
        }, 1, &type, nil, &handler)
        for (id, key) in [(UInt32(1), kVK_ANSI_N), (UInt32(2), kVK_ANSI_J)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey),
                                EventHotKeyID(signature: OSType(0x434D_504E), id: id),   // 'CMPN'
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }
}

extension Notification.Name {
    static let openNotes = Notification.Name("kumo.openNotes")
    static let openChat = Notification.Name("kumo.openChat")
}
