import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @ObservedObject private var state = AppState.shared

    @State private var launchAtStartup: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var statusMessage: String = ""

    // Claude Code hooks
    @State private var showDiff: Bool = false
    @State private var pendingHookJSON: String = ""
    @State private var hookNeedsUpdate: Bool = HookServer.hooksNeedUpdate()
    @State private var hooksInstalled: Bool = HookServer.claudeHooksInstalled()

    // Keys (Keychain)
    @State private var slackUserToken: String = KeychainStore.shared.get(SlackService.userTokenKey) ?? ""
    @State private var slackAppToken: String  = KeychainStore.shared.get(SlackService.appTokenKey)  ?? ""
    @State private var harvestToken: String   = KeychainStore.shared.get(HarvestService.tokenKey)   ?? ""
    @State private var harvestAccount: String = KeychainStore.shared.get(HarvestService.accountKey) ?? ""
    @State private var githubToken: String    = KeychainStore.shared.get("github-token")            ?? ""
    @State private var vercelToken: String    = KeychainStore.shared.get(VercelService.tokenKey)    ?? ""
    @State private var updateToken: String    = KeychainStore.shared.get(UpdateService.tokenKey)    ?? ""

    // Hotkey
    @State private var hotkeyFlags: UInt    = AppState.shared.hotkeyFlags
    @State private var hotkeyCode: UInt16   = AppState.shared.hotkeyCode

    private var absenceMinutes: Binding<Double> {
        Binding(
            get: { state.absenceInterval / 60 },
            set: { state.absenceInterval = max(1, $0) * 60 }
        )
    }

    @AppStorage("settingsSection") private var selectedSection: String = "general"

    private var appVersion: String {
        "Version \(UpdateService.currentBuild)"
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                SidebarBackground()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Compagnon")
                                .font(.system(size: 13, weight: .semibold))
                            Text(appVersion)
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                    Divider()
                    List(selection: Binding(
                        get: { Optional(selectedSection) },
                        set: { if let v = $0 { selectedSection = v; statusMessage = "" } }
                    )) {
                        SettingsSidebarRow(title: "Général",       icon: "gearshape.fill",             color: "#8E939C").tag("general")
                        SettingsSidebarRow(title: "Claude Code",   icon: "terminal.fill",              color: "#D97757").tag("claude")
                        SettingsSidebarRow(title: "Slack",         icon: "bubble.left.fill",           color: "#E01E5A").tag("slack")
                        SettingsSidebarRow(title: "Harvest",       icon: "clock.fill",                 color: "#FA5D00").tag("harvest")
                        SettingsSidebarRow(title: "Vercel",        icon: "triangle.fill",              color: "#111111").tag("vercel")
                        SettingsSidebarRow(title: "GitHub",        icon: "chevron.left.forwardslash.chevron.right", color: "#6E7681").tag("github")
                        SettingsSidebarRow(title: "Mises à jour",  icon: "arrow.down.circle.fill",     color: "#22C55E").tag("updates")
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 200)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text(sectionTitle)
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        sectionContent
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
                if !statusMessage.isEmpty {
                    Divider()
                    Text(statusMessage)
                        .font(.system(size: 12))
                        .foregroundColor(statusMessage.hasPrefix("❌") ? .red : .secondary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
            }
        }
    }

    // MARK: - Section routing

    private var sectionTitle: String {
        switch selectedSection {
        case "claude":  return "Claude Code"
        case "slack":   return "Slack"
        case "harvest": return "Harvest"
        case "vercel":  return "Vercel"
        case "github":  return "GitHub"
        case "updates": return "Mises à jour"
        default:        return "Général"
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch selectedSection {
        case "claude":  claudeSection
        case "slack":   slackSection
        case "harvest": harvestSection
        case "vercel":  vercelSection
        case "github":  githubSection
        case "updates": updatesSection
        default:        generalSection
        }
    }

    // MARK: - General

    @ViewBuilder private var generalSection: some View {
        GroupBox("Son") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Activer les sons", isOn: $state.soundEnabled)
                HStack(spacing: 8) {
                    Text("Volume")
                        .frame(width: 56, alignment: .leading)
                    Slider(value: $state.soundVolume, in: 0...0.2)
                        .disabled(!state.soundEnabled)
                    Text("\(Int(state.soundVolume / 0.2 * 100)) %")
                        .frame(width: 36, alignment: .trailing)
                        .monospacedDigit()
                }
            }
            .padding(6)
        }

        GroupBox("Comportement") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Fermer après")
                    TextField("15", value: $state.autoCloseInterval, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Text("s d'inactivité")
                }
                HStack(spacing: 8) {
                    Text("Masquer après")
                    TextField("3", value: absenceMinutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                    Text("min sans mouvement")
                }
            }
            .padding(6)
        }

        GroupBox("Raccourci clavier") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Afficher l'île avec un raccourci", isOn: $state.hotkeyEnabled)
                if state.hotkeyEnabled {
                    HStack(spacing: 8) {
                        Text("Raccourci")
                            .frame(width: 70, alignment: .leading)
                        ShortcutRecorderButton(flags: $hotkeyFlags, code: $hotkeyCode)
                            .onChange(of: hotkeyFlags) { _, v in state.hotkeyFlags = v }
                            .onChange(of: hotkeyCode)  { _, v in state.hotkeyCode  = v }
                        Text("→ ouvre l'île")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(6)
        }

        GroupBox("Démarrage") {
            Toggle("Lancer au démarrage du Mac", isOn: $launchAtStartup)
                .onChange(of: launchAtStartup) { _, on in toggleStartup(on) }
                .padding(6)
        }
    }

    // MARK: - Claude Code

    @ViewBuilder private var claudeSection: some View {
        GroupBox("Hooks") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    StatusDot(ok: hooksInstalled && !hookNeedsUpdate)
                    Text(hooksInstalled ? (hookNeedsUpdate ? "Hooks à mettre à jour" : "Hooks installés") : "Hooks non installés")
                        .font(.system(size: 12, weight: .medium))
                }
                Text("Les hooks envoient à Compagnon ce que fait Claude Code sur ce Mac (terminal, VS Code, app Claude en local) et lui permettent de te demander les autorisations. Une sauvegarde de ~/.claude/settings.json est faite avant toute écriture.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(hooksInstalled ? "Réinstaller les hooks" : "Installer les hooks") { installHooks() }
                        .buttonStyle(.borderedProminent)
                    if hooksInstalled {
                        Button("Désinstaller") { uninstallHooks() }
                            .buttonStyle(.bordered)
                    }
                }
                if showDiff {
                    ScrollView {
                        Text(pendingHookJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    HStack {
                        Button("Confirmer et écrire") { confirmInstall() }
                            .buttonStyle(.borderedProminent)
                        Button("Annuler") { showDiff = false; pendingHookJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }
        GroupBox("Questions de Claude") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Quand Claude te pose une question à choix, elle s'affiche dans l'île : clique une réponse, écris la tienne, ou renvoie-la dans Claude. Sans réponse en 10 minutes, Claude la pose lui-même. (Nécessite des hooks à jour.)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Mode compatibilité (si Claude repose la question malgré ta réponse)", isOn: $state.questionCompatMode)
                    .font(.system(size: 12))
            }
            .padding(6)
        }
    }

    // MARK: - Slack

    @ViewBuilder private var slackSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    StatusDot(ok: state.slackStatus == .connected)
                    Text(state.slackStatus.label).font(.system(size: 12, weight: .medium))
                }
                Text("Messages directs et mentions en temps réel, avec réponse depuis l'île. Crée l'app Slack à partir du manifeste (api.slack.com/apps → Create New App → From a manifest), installe-la, puis colle les deux jetons. Pas à pas : docs/SLACK.md.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Copier le manifeste") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(SlackService.manifest, forType: .string)
                        statusMessage = "✓ Manifeste Slack copié."
                    }
                    Button("Ouvrir api.slack.com") { open("https://api.slack.com/apps") }
                }
                SecureField("Jeton utilisateur  (xoxp-…)", text: $slackUserToken)
                    .textFieldStyle(.roundedBorder)
                SecureField("Jeton d'app, connexions  (xapp-…)", text: $slackAppToken)
                    .textFieldStyle(.roundedBorder)
                Button("Enregistrer") {
                    saveKey(SlackService.userTokenKey, slackUserToken)
                    saveKey(SlackService.appTokenKey, slackAppToken)
                    SlackService.shared.restart()
                    state.refreshPills()
                    statusMessage = "✓ Jetons Slack enregistrés."
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(6)
        }
    }

    // MARK: - Harvest

    @ViewBuilder private var harvestSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    StatusDot(ok: HarvestService.shared.isConfigured && state.harvestError == nil)
                    Text(state.harvestError.map { "Erreur : \($0)" }
                         ?? (HarvestService.shared.isConfigured ? "Connecté" : "Non configuré"))
                        .font(.system(size: 12, weight: .medium))
                }
                Text("Crée un jeton d'accès personnel sur id.getharvest.com/developers et copie l'ID de compte affiché sur la même page.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Ouvrir id.getharvest.com") { open("https://id.getharvest.com/developers") }
                SecureField("Jeton d'accès personnel", text: $harvestToken)
                    .textFieldStyle(.roundedBorder)
                TextField("ID de compte  (Account ID)", text: $harvestAccount)
                    .textFieldStyle(.roundedBorder)
                Button("Enregistrer") {
                    saveKey(HarvestService.tokenKey, harvestToken)
                    saveKey(HarvestService.accountKey, harvestAccount)
                    HarvestService.shared.restart()
                    state.refreshPills()
                    statusMessage = "✓ Harvest enregistré."
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(6)
        }
        GroupBox("Rappel") {
            Toggle("Me rappeler de lancer un timer (jours ouvrés, 9 h – 19 h)", isOn: $state.harvestReminder)
                .padding(6)
        }
    }

    // MARK: - Vercel

    @ViewBuilder private var vercelSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    StatusDot(ok: VercelService.shared.isConfigured && state.vercelError == nil)
                    Text(state.vercelError.map { "Erreur : \($0)" }
                         ?? (VercelService.shared.isConfigured ? "Connecté" : "Non configuré"))
                        .font(.system(size: 12, weight: .medium))
                }
                Text("Tes derniers déploiements dans l'île, et une alerte quand l'un d'eux est en ligne ou échoue. Crée un jeton sur vercel.com/account/tokens.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Ouvrir vercel.com") { open("https://vercel.com/account/tokens") }
                SecureField("Jeton Vercel", text: $vercelToken)
                    .textFieldStyle(.roundedBorder)
                Button("Enregistrer") {
                    saveKey(VercelService.tokenKey, vercelToken)
                    VercelService.shared.restart()
                    state.refreshPills()
                    statusMessage = "✓ Jeton Vercel enregistré."
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(6)
        }
    }

    // MARK: - GitHub

    @ViewBuilder private var githubSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Statistiques de tes dépôts dans l'île. Un jeton d'accès personnel suffit.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                SecureField("Jeton d'accès personnel", text: $githubToken)
                    .textFieldStyle(.roundedBorder)
                Button("Enregistrer") {
                    saveKey("github-token", githubToken)
                    state.refreshPills()
                    statusMessage = "✓ Jeton GitHub enregistré."
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(6)
        }
    }

    // MARK: - Updates

    @ViewBuilder private var updatesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Version \(UpdateService.currentBuild)")
                    Text(state.updateStatus.label).foregroundColor(.secondary)
                    Spacer()
                    if case .available = state.updateStatus {
                        Button("Installer maintenant") { Task { await UpdateService.shared.install() } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Rechercher") { Task { await UpdateService.shared.check() } }
                            .disabled(state.updateStatus == .checking || state.updateStatus == .installing)
                    }
                }
                Toggle("Installer automatiquement (quand rien n'est en cours)", isOn: $state.autoUpdate)
            }
            .padding(6)
        }
        GroupBox("Accès au dépôt") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Le dépôt étant privé, Compagnon a besoin d'un jeton GitHub en lecture sur le dépôt companion (sinon il utilise le jeton de la section GitHub).")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    SecureField("Jeton GitHub (lecture du dépôt)", text: $updateToken)
                        .textFieldStyle(.roundedBorder)
                    Button("Enregistrer") {
                        saveKey(UpdateService.tokenKey, updateToken)
                        Task { await UpdateService.shared.check() }
                    }
                }
                Button("Créer un jeton sur GitHub") { open("https://github.com/settings/personal-access-tokens/new") }
                    .buttonStyle(.link)
            }
            .padding(6)
        }
    }

    // MARK: - Actions

    private func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }

    private func saveKey(_ key: String, _ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { KeychainStore.shared.remove(key) }
        else { KeychainStore.shared.set(key, value: value) }
    }

    private func toggleStartup(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else  { try SMAppService.mainApp.unregister() }
        } catch {
            statusMessage = "❌ Démarrage : \(error.localizedDescription)"
            launchAtStartup = !on
        }
    }

    private func installHooks() {
        do {
            pendingHookJSON = try HookServer.shared.previewClaudeHooks()
            showDiff = true
            statusMessage = "Vérifie le JSON ci-dessous avant de confirmer."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmInstall() {
        do {
            try HookServer.shared.writeClaudeHooks()
            showDiff = false
            pendingHookJSON = ""
            hookNeedsUpdate = false
            hooksInstalled = true
            statusMessage = "✓ Hooks installés dans ~/.claude/settings.json"
        } catch {
            statusMessage = "❌ Erreur d'écriture : \(error.localizedDescription)"
        }
    }

    private func uninstallHooks() {
        do {
            try HookServer.shared.uninstallClaudeHooks()
            hooksInstalled = false
            statusMessage = "✓ Hooks supprimés."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }
}

// MARK: - Status dot

struct StatusDot: View {
    let ok: Bool
    var body: some View {
        Circle()
            .fill(ok ? Color(hex: "#22C55E") : Color(hex: "#F5A524"))
            .frame(width: 8, height: 8)
    }
}

// MARK: - Sidebar background (NSVisualEffectView .sidebar)

struct SidebarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Sidebar row (System Settings style icon)

struct SettingsSidebarRow: View {
    let title: String
    let icon: String
    let color: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color(hex: color)))
        }
    }
}

// MARK: - Shortcut recorder button

struct ShortcutRecorderButton: View {
    @Binding var flags: UInt
    @Binding var code: UInt16
    @State private var isRecording = false

    var body: some View {
        Button {
            guard !isRecording else { return }
            isRecording = true
            var token: Any?
            token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
                guard !mods.isEmpty else { return event }
                DispatchQueue.main.async {
                    self.flags = mods.rawValue
                    self.code = event.keyCode
                    self.isRecording = false
                    if let t = token { NSEvent.removeMonitor(t) }
                }
                return nil
            }
        } label: {
            Text(isRecording ? "Appuie sur les touches…" : shortcutLabel)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(isRecording ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
                .cornerRadius(5)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.gray.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var shortcutLabel: String {
        let f = NSEvent.ModifierFlags(rawValue: flags)
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option)  { s += "⌥" }
        if f.contains(.shift)   { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        s += keyChar(code)
        return s.isEmpty ? "Aucun" : s
    }

    private func keyChar(_ c: UInt16) -> String {
        let map: [UInt16: String] = [
            0:"A", 1:"S", 2:"D", 3:"F", 4:"H", 5:"G", 6:"Z", 7:"X", 8:"C", 9:"V",
            11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T", 31:"O", 32:"U",
            34:"I", 37:"L", 38:"J", 40:"K", 45:"N", 46:"M", 49:"Espace", 50:"`", 27:"-"
        ]
        return map[c] ?? "·"
    }
}
