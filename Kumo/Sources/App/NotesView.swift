import SwiftUI

// MARK: - Notes view
// The island grows to show the notes: folders on top, a field to jot something down
// (⏎ keeps it), and the list. Hover a note to edit, file or delete it.

struct NotesView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store = NotesStore.shared

    @State private var folder: String? = nil          // nil = every note
    @State private var editing: UUID? = nil
    @State private var editText = ""
    @State private var moving: UUID? = nil
    @State private var addingFolder = false
    @State private var newFolder = ""
    @State private var lastDeleted: (note: Note, index: Int)? = nil
    @FocusState private var focus: Field?

    enum Field: Hashable { case compose, edit, folder, search }

    @State private var searching = false
    @State private var query = ""

    private var shown: [Note] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let notes = store.notes(in: folder)
        return q.isEmpty ? notes : notes.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }
    /// The search only shows up once there's enough to search through.
    private var offersSearch: Bool { store.notes.count > 10 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: NotesLayout.spacing) {
                folderBar
                composeRow
                if !shown.isEmpty { list }
            }
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, IslandConst.cardInset)
            .padding(.top, NotesLayout.top)
            .padding(.bottom, NotesLayout.bottom)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onChange(of: state.view) { _, v in
            if v == .notes {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focus = .compose }
            } else {
                endEditing()
            }
        }
        .onChange(of: focus) { _, _ in syncHold() }
        .onChange(of: shown.isEmpty) { _, empty in if empty { state.notesContentHeight = 0 } }
        .onChange(of: store.draft) { _, _ in
            state.typingAt = Date()
            syncHold()
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focus = .compose } }
        .onDisappear { endEditing(); if state.isEditingText { state.isEditingText = false } }
    }

    // MARK: Folders

    private var folderBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FolderChip(title: "Toutes", count: store.notes.count, selected: folder == nil) { select(nil) }
                ForEach(store.folders, id: \.self) { f in
                    FolderChip(title: f, count: store.notes(in: f).count, selected: folder == f, color: store.color(for: f),
                               onDelete: folder == f ? { store.deleteFolder(f); select(nil) } : nil) { select(f) }
                }
                if offersSearch {
                    if searching {
                        TextField("", text: $query, prompt: Text("Chercher").foregroundColor(.white.opacity(0.48)))
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#F5F6F8"))
                            .focused($focus, equals: .search)
                            .onExitCommand { searching = false; query = "" }
                            .frame(width: 100)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .textCursor()
                    } else {
                        Button {
                            searching = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .search }
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(Color.white.opacity(0.6))
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                        .pointingHand()
                        .help("Chercher dans les notes")
                    }
                }
                if addingFolder {
                    TextField("", text: $newFolder, prompt: Text("Nom du dossier").foregroundColor(.white.opacity(0.48)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .focused($focus, equals: .folder)
                        .onSubmit(createFolder)
                        .onExitCommand { addingFolder = false; newFolder = "" }
                        .frame(width: 110)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .textCursor()
                } else {
                    Button {
                        addingFolder = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .folder }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                            Text("Dossier").font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(Color.white.opacity(0.55))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .overlay(Capsule().stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .pointingHand()
                }
            }
        }
        .frame(height: 24)
    }

    // MARK: Compose

    private var composeRow: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                if store.draft.isEmpty {
                    Text(folder.map { "Noter dans \($0)…" } ?? "Note quelque chose…")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.48))
                        .allowsHitTesting(false)
                }
                TextField("", text: $store.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .focused($focus, equals: .compose)
                    .onSubmit(add)
                    .onExitCommand { if store.draft.isEmpty { state.view = .overview } else { store.draft = "" } }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(
                RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                    .fill(Color.white.opacity(focus == .compose ? 0.1 : 0.07))
                    .overlay(RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                        .stroke(Color.white.opacity(focus == .compose ? 0.16 : 0.07), lineWidth: 1))
            )
            .textCursor()

            if let last = lastDeleted {
                Button {
                    store.restore(last.note, at: last.index)
                    lastDeleted = nil
                } label: {
                    Text("Annuler")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(hex: "#C4B5FD"))
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help("Remettre la note supprimée")
                .transition(.opacity)
            }

            Button(action: add) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(store.draft.isEmpty ? Color.white.opacity(0.4) : .black)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(store.draft.isEmpty ? Color.white.opacity(0.08) : Color.white))
            }
            .buttonStyle(.plain)
            .disabled(store.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .pointingHand()
            .help("Garder la note (⏎)")
        }
    }

    // MARK: List

    // The island grows with the list, up to a cap, then it scrolls
    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(shown) { note in
                    NoteRow(note: note,
                            showFolder: folder == nil,
                            folderColor: note.folder.map { store.color(for: $0) },
                            folders: store.folders,
                            isEditing: editing == note.id,
                            isMoving: moving == note.id,
                            editText: $editText,
                            focus: $focus,
                            onEdit: { startEdit(note) },
                            onSave: saveEdit,
                            onCancel: { editing = nil },
                            onToggleMove: { withAnimation(.easeOut(duration: 0.15)) { moving = moving == note.id ? nil : note.id } },
                            onMove: { f in store.move(note.id, to: f); moving = nil },
                            onDelete: { delete(note) })
                }
            }
            .background(GeometryReader { g in
                Color.clear.preference(key: NotesHeightKey.self, value: g.size.height)
            })
        }
        .onPreferenceChange(NotesHeightKey.self) { h in
            MainActor.assumeIsolated {
                if abs(state.notesContentHeight - h) > 1 { state.notesContentHeight = h }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Actions

    private func select(_ f: String?) {
        withAnimation(.easeOut(duration: 0.15)) { folder = f }
        moving = nil
    }

    private func add() {
        let text = store.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { store.add(text, folder: folder) }
        store.draft = ""
        SoundEngine.shared.play("blip")
        // The cloud is pleased you told it something
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
    }

    private func startEdit(_ note: Note) {
        editText = note.text
        editing = note.id
        moving = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focus = .edit }
    }

    private func saveEdit() {
        guard let id = editing else { return }
        store.update(id, text: editText)
        editing = nil
        focus = .compose
    }

    private func delete(_ note: Note) {
        withAnimation(.easeOut(duration: 0.2)) { lastDeleted = store.delete(note.id) }
        let id = note.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            if lastDeleted?.note.id == id { withAnimation { lastDeleted = nil } }
        }
    }

    private func createFolder() {
        if let f = store.addFolder(newFolder) { select(f) }
        addingFolder = false
        newFolder = ""
        focus = .compose
    }

    private func endEditing() {
        editing = nil
        moving = nil
        addingFolder = false
        if focus != nil { focus = nil }
        if state.isEditingText && state.view != .notes { state.isEditingText = false }
    }

    /// Keep the island open while you're actually writing something.
    private func syncHold() {
        let writing = focus != nil && (!store.draft.isEmpty || focus == .edit || focus == .folder)
        if state.isEditingText != writing { state.isEditingText = writing }
    }
}

// MARK: - Layout

/// Vertical rhythm of the notes card; IslandWindowController sizes the island from it.
enum NotesLayout {
    static let top: CGFloat = 12
    static let bottom: CGFloat = IslandConst.cardInset
    static let spacing: CGFloat = 10
    static let folderBar: CGFloat = 24
    static let compose: CGFloat = 32
    static let maxHeight: CGFloat = 320

    /// Island height for a list taking `list` points (0 = nothing to show).
    static func islandHeight(list: CGFloat) -> CGFloat {
        let chrome = IslandConst.cardTop + IslandConst.contentInset + top + bottom + folderBar + compose + spacing
        let withList = list > 0 ? chrome + spacing + list : chrome
        return min(maxHeight, max(IslandConst.expandedHeight, withList))
    }
}

private struct NotesHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Pieces

private struct FolderChip: View {
    let title: String
    let count: Int
    let selected: Bool
    var color: String? = nil
    var onDelete: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            Button(action: action) {
                HStack(spacing: 5) {
                    if let color { Circle().fill(Color(hex: color)).frame(width: 6, height: 6) }
                    Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .opacity(0.5)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHand()
            if let onDelete, hovered {
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        .frame(width: 12, height: 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help("Supprimer le dossier (ses notes restent)")
            }
        }
        .foregroundColor(selected ? .black : Color.white.opacity(0.75))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(selected ? Color.white : Color.white.opacity(hovered ? 0.12 : 0.07)))
        .onHover { hovered = $0 }
    }
}

private struct NoteRow: View {
    let note: Note
    let showFolder: Bool
    let folderColor: String?
    let folders: [String]
    let isEditing: Bool
    let isMoving: Bool
    @Binding var editText: String
    var focus: FocusState<NotesView.Field?>.Binding
    let onEdit: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void
    let onToggleMove: () -> Void
    let onMove: (String?) -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                TextField("", text: $editText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1...5)
                    .focused(focus, equals: .edit)
                    .onSubmit(onSave)
                    .onExitCommand(perform: onCancel)
                    .textCursor()
            } else {
                Text(note.text)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#E8E9EC"))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2, perform: onEdit)
            }
            HStack(spacing: 10) {
                if showFolder, let folderColor {
                    Circle().fill(Color(hex: folderColor)).frame(width: 5, height: 5)
                }
                Text([showFolder ? note.folder : nil, note.age].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(Color.white.opacity(0.38))
                Spacer(minLength: 0)
                if isEditing {
                    action("checkmark", "Enregistrer (⏎)", action: onSave)
                } else if hovered || isMoving {
                    action("pencil", "Modifier", action: onEdit)
                    action(isMoving ? "folder.fill" : "folder", "Ranger dans un dossier", action: onToggleMove)
                    action("trash", "Supprimer", action: onDelete)
                }
            }
            .frame(height: 14)
            if isMoving {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        moveChip("Sans dossier", target: nil)
                        ForEach(folders, id: \.self) { moveChip($0, target: $0) }
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: IslandConst.innerRadius)
            .fill(Color.white.opacity(isEditing ? 0.09 : (hovered ? 0.07 : 0.04))))
        .onHover { hovered = $0 }
    }

    private func action(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.7))
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHand()
        .help(help)
    }

    private func moveChip(_ title: String, target: String?) -> some View {
        let current = note.folder == target
        return Button { onMove(target) } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(current ? .black : Color.white.opacity(0.75))
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(current ? Color.white : Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .pointingHand()
    }
}
