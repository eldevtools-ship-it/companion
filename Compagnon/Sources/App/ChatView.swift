import SwiftUI

// MARK: - Chat view
// Model chip and "new chat" on top, the conversation, then the field (⏎ sends).
// Empty conversation: one-click actions on the copied text.

struct ChatView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var chat = ChatService.shared
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: ChatLayout.spacing) {
                if !chat.messages.isEmpty {
                    topBar
                    conversation
                }
                inputRow
            }
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, IslandConst.cardInset)
            .padding(.top, ChatLayout.top)
            .padding(.bottom, ChatLayout.bottom)
            // Empty chat: the field sits in the middle, next to the cloud
            .frame(maxHeight: .infinity, alignment: chat.messages.isEmpty ? .center : .bottom)
        }
        .onChange(of: state.view) { _, v in
            if v == .chat { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } }
            else if focused { focused = false }
        }
        .onChange(of: focused) { _, _ in syncHold() }
        .onChange(of: chat.draft) { _, _ in syncHold() }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } }
        .onDisappear { if state.isEditingText { state.isEditingText = false } }
        .onChange(of: chat.messages.isEmpty) { _, empty in if empty { state.chatContentHeight = 0 } }
    }

    // MARK: Top bar (only once there's a conversation)

    private var topBar: some View {
        HStack {
            Spacer(minLength: 0)
            Button { chat.newConversation(); focused = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.and.pencil").font(.system(size: 10, weight: .semibold))
                    Text("Nouvelle").font(.system(size: 10.5, weight: .medium))
                }
                .foregroundColor(Color.white.opacity(0.6))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHand()
            .help("Nouvelle conversation")
        }
        .frame(height: ChatLayout.topBar)
    }

    // MARK: Conversation — the island grows with it, up to a cap, then it scrolls

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(chat.messages) { m in
                        ChatBubble(message: m, typing: chat.busy && m.id == chat.messages.last?.id) {
                            chat.copy(m)
                        }
                        .id(m.id)
                    }
                }
                .padding(.vertical, 2)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ChatHeightKey.self, value: g.size.height)
                })
            }
            .onPreferenceChange(ChatHeightKey.self) { h in
                MainActor.assumeIsolated {
                    if abs(state.chatContentHeight - h) > 1 { state.chatContentHeight = h }
                }
            }
            .onChange(of: chat.messages.last?.text) { _, _ in
                if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: Input

    private var inputRow: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                if chat.draft.isEmpty {
                    Text("Demande quelque chose à Claude…")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.48))
                        .allowsHitTesting(false)
                }
                TextField("", text: $chat.draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .focused($focused)
                    .onSubmit(send)
                    .onExitCommand { if chat.busy { chat.stop() } else if chat.draft.isEmpty { state.view = .overview } else { chat.draft = "" } }
            }
            .padding(.horizontal, 10)
            .frame(height: ChatLayout.input)
            .background(
                RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                    .fill(Color.white.opacity(focused ? 0.1 : 0.07))
                    .overlay(RoundedRectangle(cornerRadius: IslandConst.innerRadius)
                        .stroke(Color.white.opacity(focused ? 0.16 : 0.07), lineWidth: 1))
            )
            .textCursor()

            Button(action: { chat.busy ? chat.stop() : send() }) {
                Image(systemName: chat.busy ? "stop.fill" : "arrow.up")
                    .font(.system(size: chat.busy ? 9 : 11, weight: .bold))
                    .foregroundColor(chat.busy || !chat.draft.isEmpty ? .black : Color.white.opacity(0.4))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(chat.busy || !chat.draft.isEmpty ? Color.white : Color.white.opacity(0.08)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .pointingHand()
            .help(chat.busy ? "Arrêter" : "Envoyer (⏎)")
        }
    }

    private func send() {
        let text = chat.draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !chat.busy else { return }
        chat.draft = ""
        chat.send(text)
    }

    /// Keep the island open while you're writing.
    private func syncHold() {
        let writing = focused && !chat.draft.isEmpty
        if state.isEditingText != writing { state.isEditingText = writing }
    }
}

/// Vertical rhythm of the chat card; IslandWindowController sizes the island from it.
enum ChatLayout {
    static let top: CGFloat = 10
    static let bottom: CGFloat = IslandConst.cardInset
    static let spacing: CGFloat = 8
    static let topBar: CGFloat = 18
    static let input: CGFloat = 32
    static let maxHeight: CGFloat = 320

    /// Island height for a conversation whose messages take `content` points.
    static func islandHeight(content: CGFloat, empty: Bool) -> CGFloat {
        guard !empty else { return IslandConst.expandedHeight }
        let chrome = IslandConst.cardTop + IslandConst.contentInset + top + bottom + topBar + input + spacing * 2
        return min(maxHeight, max(IslandConst.expandedHeight, chrome + content))
    }
}

private struct ChatHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct ChatBubble: View {
    let message: ChatMessage
    let typing: Bool
    let onCopy: () -> Void
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        if message.role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(6)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: IslandConst.innerRadius + 4).fill(Color.white.opacity(0.1)))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if message.text.isEmpty && typing {
                    TypingDots()
                } else {
                    Text(Self.markdown(message.text))
                        .font(.system(size: 12))
                        .foregroundColor(message.failed ? Color(hex: "#FF8D97") : Color(hex: "#E8E9EC"))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !message.text.isEmpty && !typing && !message.failed {
                    Button {
                        onCopy()
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: copied ? "checkmark" : "doc.on.doc").font(.system(size: 9, weight: .semibold))
                            Text(copied ? "Copié" : "Copier").font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(Color.white.opacity(copied ? 0.8 : 0.45))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHand()
                    .opacity(hovered || copied ? 1 : 0)
                }
            }
            .onHover { hovered = $0 }
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 5, height: 5)
                        .opacity(0.3 + 0.6 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
            .frame(height: 16)
        }
    }
}
