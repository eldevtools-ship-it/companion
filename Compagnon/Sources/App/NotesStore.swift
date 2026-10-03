import Foundation

// MARK: - Notes (pense-bête)
// Plain notes, optionally in a folder. Kept in a JSON file next to the hook socket
// (~/Library/Application Support/Compagnon/notes.json): they're yours, not secrets,
// and they never leave the Mac.

struct Note: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var folder: String?
    var created = Date()
    var updated = Date()

    /// "à l'instant", "5 min", "2 h", "hier", "3 j"
    var age: String {
        let s = Date().timeIntervalSince(updated)
        if s < 60 { return "à l'instant" }
        if s < 3600 { return "\(Int(s / 60)) min" }
        if Calendar.current.isDateInToday(updated) { return "\(Int(s / 3600)) h" }
        if Calendar.current.isDateInYesterday(updated) { return "hier" }
        return "\(max(2, Int(s / 86400))) j"
    }
}

@MainActor
final class NotesStore: ObservableObject {
    static let shared = NotesStore()

    @Published private(set) var notes: [Note] = []      // newest first
    @Published private(set) var folders: [String] = []
    /// What you're typing, kept while you visit other views.
    @Published var draft = ""

    private struct Stored: Codable { var notes: [Note]; var folders: [String] }
    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Compagnon", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("notes.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let stored = try? decoder.decode(Stored.self, from: data) {
            notes = stored.notes
            folders = stored.folders
        }
    }

    /// One colour per folder, in the order they were created.
    static let folderColors = ["#F5A524", "#22C55E", "#3B9EFF", "#E879F9", "#F4505E", "#14B8A6", "#A78BFA"]
    func color(for folder: String) -> String {
        let i = folders.firstIndex(of: folder) ?? 0
        return Self.folderColors[i % Self.folderColors.count]
    }

    func notes(in folder: String?) -> [Note] {
        guard let folder else { return notes }
        return notes.filter { $0.folder == folder }
    }

    func add(_ text: String, folder: String?) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        notes.insert(Note(text: clean, folder: folder), at: 0)
        save()
    }

    func update(_ id: UUID, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        if clean.isEmpty { notes.remove(at: i) } else { notes[i].text = clean; notes[i].updated = Date() }
        save()
    }

    func move(_ id: UUID, to folder: String?) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].folder = folder
        save()
    }

    /// Removes a note and returns what's needed to bring it back.
    func delete(_ id: UUID) -> (note: Note, index: Int)? {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return nil }
        let note = notes.remove(at: i)
        save()
        return (note, i)
    }

    func restore(_ note: Note, at index: Int) {
        if let f = note.folder, !folders.contains(f) { folders.append(f) }
        notes.insert(note, at: min(index, notes.count))
        save()
    }

    @discardableResult
    func addFolder(_ name: String) -> String? {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
        guard !clean.isEmpty else { return nil }
        if let existing = folders.first(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) { return existing }
        folders.append(clean)
        save()
        return clean
    }

    /// Deletes the folder; its notes stay, without a folder.
    func deleteFolder(_ name: String) {
        folders.removeAll { $0 == name }
        for i in notes.indices where notes[i].folder == name { notes[i].folder = nil }
        save()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(Stored(notes: notes, folders: folders)) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
