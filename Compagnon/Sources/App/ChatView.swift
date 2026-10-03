import SwiftUI

// MARK: - Chat view
// Model chip and "new chat" on top, the conversation, then the field (⏎ sends).
// Empty conversation: one-click actions on the copied text.

struct ChatView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var chat = ChatService.shared
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 8) {
                topBar
                conversation
                inputRow
            }
            .padding(.leading, CardLayout.contentLeading)
            .padding(.trailing, IslandConst.cardInset)
            .padding(.top, 10)
            .padding(.bottom, IslandConst.cardInset)
        }
        .onChange(of: state.view) { _, v in
            if v == .chat { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focused = true } }
            else if focused { focused = false }
        }
        .onChange(of: focused) { _, _ in syncHold() }
        .onChange(of: draft) { _, _ in syncHold() }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 6) {
            ForEach(ChatModel.allCases, id: \.self) { m in
                Button { chat.model = m } label: {
                    Text(m.label)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(chat.model == m ? .black : Color.white.opacity(0.7))
                        .padding(.horizontal, 9)
                        .frame(height: 20)
                        .background(Capsule().fill(chat.model == m ? Color.white : Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .pointingHand()
            }
            Spacer(minLength: 0)
            if !chat.messages.isEmpty {
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
        }
        .frame(height: 20)
    }

    // MARK: Conversation

    private var conversation: some View {
        Group {
            if chat.messages.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Demande ce que tu veux à Claude, ou travaille le texte que tu as copié :")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color.white.opacity(0.5))
                    HStack(spacing: 6) {
                        quick("Corriger", "Corrige l'orthographe, la grammaire et la ponctuation de ce texte, sans changer le ton :")
                        quick("En anglais", "Traduis ce texte en anglais naturel :")
                        quick("Plus court", "Rends ce texte plus court et plus clair, même ton :")
                        quick("Plus pro", "Reformule ce texte sur un ton professionnel et cordial :")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, 4)
            } else {
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
                    }
                    .onChange(of: chat.messages.last?.text) { _, _ in
                        if let id = chat.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func quick(_ title: String, _ instruction: String) -> some View {
        Button { chat.sendWithClipboard(instruction) } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.white.opacity(0.8))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .pointingHand()
        .help("Avec le texte copié (⌘C)")
    }

    // MARK: Input

    private var inputRow: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                if draft.isEmpty {
                    Text("Demande quelque chose à Claude…")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.48))
                        .allowsHitTesting(false)
                }
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .focused($focused)
                    .onSubmit(send)
                    .onExitCommand { if chat.busy { chat.stop() } else if draft.isEmpty { state.view = .overview } else { draft = "" } }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
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
                    .foregroundColor(chat.busy || !draft.isEmpty ? .black : Color.white.opacity(0.4))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(chat.busy || !draft.isEmpty ? Color.white : Color.white.opacity(0.08)))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .pointingHand()
            .help(chat.busy ? "Arrêter" : "Envoyer (⏎)")
        }
    }

    private func send() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, !chat.busy else { return }
        draft = ""
        chat.send(text)
    }

    /// Keep the island open while you're writing.
    private func syncHold() {
        let writing = focused && !draft.isEmpty
        if state.isEditingText != writing { state.isEditingText = writing }
    }
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
        TimelineView(.animation) { tl in
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
