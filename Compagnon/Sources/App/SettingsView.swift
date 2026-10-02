import SwiftUI
import ServiceManagement
import AppKit

struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
    @State private var apiKey: String = KeychainStore.shared.get("anthropic-api-key") ?? ""

    // Claude model — dynamic list fetched from the API, static fallback if unavailable
    private static let fallbackModels: [(id: String, label: String)] = [
        ("claude-sonnet-4-6",         "Claude Sonnet 4.6"),
        ("claude-sonnet-5-5",         "Claude Sonnet 5.5"),
        ("claude-opus-5-5",           "Claude Opus 5.5"),
        ("claude-haiku-4-5-20251001", "Claude Haiku 4.5"),
    ]
    private static let customModelTag = "__custom__"
    @State private var fetchedModels: [(id: String, label: String)] = []
    @State private var modelChoice: String = {
        let m = AppState.shared.claudeModel
        return SettingsView.fallbackModels.contains { $0.id == m } ? m : SettingsView.customModelTag
    }()
    @State private var customModel: String = {
        let m = AppState.shared.claudeModel
        return SettingsView.fallbackModels.contains { $0.id == m } ? "" : m
    }()
    private var displayModels: [(id: String, label: String)] {
        fetchedModels.isEmpty ? Self.fallbackModels : fetchedModels
    }
    @State private var launchAtStartup: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var statusMessage: String = ""
    @State private var showDiff: Bool = false
    @State private var pendingHookJSON: String = ""
    @State private var hookNeedsUpdate: Bool = HookServer.hooksNeedUpdate()

    @State private var geminiHooksInstalled: Bool = HookServer.geminiHooksInstalled()
    @State private var showGeminiDiff: Bool = false
    @State private var pendingGeminiJSON: String = ""
    @State private var geminiPendingInstall: Bool = true

    @State private var agyHooksInstalled: Bool = HookServer.agyHooksInstalled()
    @State private var showAgyDiff: Bool = false
    @State private var pendingAgyJSON: String = ""
    @State private var agyPendingInstall: Bool = true

    @State private var codexHooksInstalled: Bool = HookServer.codexHooksInstalled()
    @State private var showCodexDiff: Bool = false
    @State private var pendingCodexJSON: String = ""
    @State private var codexPendingInstall: Bool = true

    // Multi-provider chat keys
    @State private var googleKey: String  = KeychainStore.shared.get("google-api-key") ?? ""
    @State private var openAIKey: String  = KeychainStore.shared.get("openai-api-key") ?? ""

    // Integration keys
    @State private var resendKey: String    = KeychainStore.shared.get("resend-api-key")  ?? ""
    @State private var resendFrom: String   = KeychainStore.shared.get("resend-from")     ?? ""
    @State private var n8nUrl: String       = KeychainStore.shared.get("n8n-url")         ?? ""
    @State private var n8nKey: String       = KeychainStore.shared.get("n8n-api-key")     ?? ""
    @State private var vercelToken: String  = KeychainStore.shared.get("vercel-token")    ?? ""
    @State private var githubToken: String  = KeychainStore.shared.get("github-token")    ?? ""
    @State private var stripeKey: String    = KeychainStore.shared.get("stripe-api-key")  ?? ""
    @State private var calcomKey: String    = KeychainStore.shared.get("calcom-api-key")  ?? ""
    @State private var notionKey: String    = KeychainStore.shared.get("notion-api-key")  ?? ""

    // Hotkey
    @State private var hotkeyFlags: UInt    = AppState.shared.hotkeyFlags
    @State private var hotkeyCode: UInt16   = AppState.shared.hotkeyCode

    // Vercel project filter
    @State private var vercelProjects: [String] = []
    @State private var loadingVercel: Bool = false

    // n8n workflow filter
    @State private var n8nWorkflows: [String] = []
    @State private var loadingN8n: Bool = false

    // Bindings in minutes for the absence field
    private var absenceMinutes: Binding<Double> {
        Binding(
            get: { state.absenceInterval / 60 },
            set: { state.absenceInterval = max(1, $0) * 60 }
        )
    }

    // Sidebar selection persisted across sessions
    @AppStorage("settingsSection") private var selectedSection: String = "general"

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar — 200 pt, sidebar visual effect background
            ZStack(alignment: .topLeading) {
                SidebarBackground()
                VStack(alignment: .leading, spacing: 0) {
                    // Header
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
                        SettingsSidebarRow(title: "Général",      icon: "gearshape.fill",                    color: "#8E939C").tag("general")
                        SettingsSidebarRow(title: "Pastilles actives", icon: "square.grid.2x2.fill",              color: "#F5A524").tag("activepills")
                        SettingsSidebarRow(title: "Agents",       icon: "terminal.fill",                     color: "#3B9EFF").tag("agents")
                        SettingsSidebarRow(title: "Chat",         icon: "bubble.left.and.bubble.right.fill", color: "#E07950").tag("chat")
                        SettingsSidebarRow(title: "Intégrations", icon: "puzzlepiece.extension.fill",        color: "#7C5CFF").tag("integrations")
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 200)

            Divider()

            // Detail panel
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
        .onAppear {
            guard fetchedModels.isEmpty,
                  let key = KeychainStore.shared.get("anthropic-api-key"), !key.isEmpty else { return }
            Task {
                let models = await ClaudeService.fetchModels(apiKey: key)
                guard !models.isEmpty else { return }
                await MainActor.run {
                    fetchedModels = models
                    let m = state.claudeModel
                    if models.contains(where: { $0.id == m }) {
                        modelChoice = m
                        customModel = ""
                    } else if modelChoice != Self.customModelTag {
                        modelChoice = Self.customModelTag
                        customModel = m
                    }
                }
            }
        }
    }

    // MARK: - Section routing

    private var sectionTitle: String {
        switch selectedSection {
        case "general":      return "Général"
        case "activepills":  return "Pastilles actives"
        case "agents":       return "Agents"
        case "chat":         return "Chat"
        case "integrations": return "Intégrations"
        default:             return "Général"
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch selectedSection {
        case "activepills":  activePillsSection
        case "agents":       agentsSection
        case "chat":         chatSection
        case "integrations": integrationsSection
        default:             generalSection
        }
    }

    // MARK: - General section

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
                    TextField("60", value: $state.autoCloseInterval, format: .number)
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

    // MARK: - Active pills section

    @ViewBuilder private var activePillsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("Choisis les outils que tu utilises. Compagnon n'affiche que ce que tu déclares ici.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Text("\(state.activeIntegrations.count)/4 emplacements utilisés")
                    .font(.system(size: 11))
                    .foregroundColor(state.activeIntegrations.count >= 4 ? .orange : .secondary)

                Picker("Principale", selection: $state.mainPillId) {
                    ForEach(PillCatalog.available.filter { $0.category == .workspace && !$0.comingSoon }, id: \.id) { def in
                        Text(def.name).tag(def.id)
                    }
                }
                .onChange(of: state.mainPillId) { _, newId in
                    state.activeIntegrations.remove(newId)
                    state.loadIntegrationTasks()
                    state.setFocus(newId)
                }

                ForEach(PillCategory.allCases, id: \.self) { cat in
                    let catPills = PillCatalog.available.filter { $0.category == cat }
                    if !catPills.isEmpty {
                        Divider()
                        Text(cat.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        ForEach(catPills, id: \.id) { def in
                            pillRow(def)
                        }
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Agents section

    @ViewBuilder private var agentsSection: some View {
        GroupBox("Hooks Claude Code") {
            VStack(alignment: .leading, spacing: 10) {
                if hookNeedsUpdate {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Délai du hook obsolète — mets à jour pour réparer les validations")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                    Button("Mettre à jour les hooks") { installHooks() }
                }
                Text("compagnon-hook : \(HookServer.hookScriptPath)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button("Installer les hooks") { installHooks() }
                        .buttonStyle(.borderedProminent)
                    Button("Désinstaller") { uninstallHooks() }
                        .buttonStyle(.bordered)
                }

                if showDiff {
                    ScrollView {
                        Text(pendingHookJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)

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

        GroupBox("Hooks Gemini CLI") {
            VStack(alignment: .leading, spacing: 10) {
                Text(geminiHooksInstalled
                     ? "Hooks installés — relance Gemini CLI pour les activer"
                     : "~/.gemini/settings.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button("Installer les hooks") { triggerGeminiPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button("Désinstaller") { triggerGeminiPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showGeminiDiff {
                    ScrollView {
                        Text(pendingGeminiJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button("Confirmer et écrire") { confirmGeminiOp() }
                            .buttonStyle(.borderedProminent)
                        Button("Annuler") { showGeminiDiff = false; pendingGeminiJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox("Hooks Antigravity") {
            VStack(alignment: .leading, spacing: 10) {
                Text(agyHooksInstalled
                     ? "Hooks installés — relance Antigravity pour les activer"
                     : "~/.gemini/config/hooks.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button("Installer les hooks") { triggerAgyPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button("Désinstaller") { triggerAgyPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showAgyDiff {
                    ScrollView {
                        Text(pendingAgyJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button("Confirmer et écrire") { confirmAgyOp() }
                            .buttonStyle(.borderedProminent)
                        Button("Annuler") { showAgyDiff = false; pendingAgyJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }

        GroupBox("Hooks Codex") {
            VStack(alignment: .leading, spacing: 10) {
                Text(codexHooksInstalled
                     ? "Hooks installés — ouvre Codex et lance /hooks, ou ouvre Hooks dans les réglages de l'app, pour les approuver"
                     : "~/.codex/hooks.json")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                HStack(spacing: 10) {
                    Button("Installer les hooks") { triggerCodexPreview(install: true) }
                        .buttonStyle(.borderedProminent)
                    Button("Désinstaller") { triggerCodexPreview(install: false) }
                        .buttonStyle(.bordered)
                }
                if showCodexDiff {
                    ScrollView {
                        Text(pendingCodexJSON)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color(NSColor.textBackgroundColor))
                    .cornerRadius(6)
                    HStack {
                        Button("Confirmer et écrire") { confirmCodexOp() }
                            .buttonStyle(.borderedProminent)
                        Button("Annuler") { showCodexDiff = false; pendingCodexJSON = "" }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .padding(6)
        }
    }

    // MARK: - Chat section

    @ViewBuilder private var chatSection: some View {
        GroupBox("API Anthropic") {
            VStack(alignment: .leading, spacing: 8) {
                SecureField("Clé API (sk-ant-…)", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                Button("Enregistrer") {
                    KeychainStore.shared.set("anthropic-api-key", value: apiKey)
                    statusMessage = "✓ Clé enregistrée."
                }
                .buttonStyle(.borderedProminent)

                Divider().padding(.vertical, 2)

                Picker("Modèle", selection: $modelChoice) {
                    ForEach(displayModels, id: \.id) { preset in
                        Text(preset.label).tag(preset.id)
                    }
                    Text("Personnalisé…").tag(Self.customModelTag)
                }
                .onChange(of: modelChoice) { _, choice in
                    if choice != Self.customModelTag {
                        state.claudeModel = choice
                    } else {
                        applyCustomModel(customModel)
                    }
                }

                if modelChoice == Self.customModelTag {
                    TextField("ID du modèle (ex. claude-sonnet-4-6)", text: $customModel)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: customModel) { _, value in applyCustomModel(value) }
                }

                Text("Utilisé par le chat. La liste vient de ton compte Anthropic.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(6)
        }

        GroupBox("Chat — autres fournisseurs") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pour utiliser Google Gemini ou OpenAI depuis le chat. Les clés sont stockées dans le Trousseau.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Circle().fill(Color(hex: "#4285F4")).frame(width: 8, height: 8)
                    Text("Google AI").font(.system(size: 12, weight: .semibold))
                }
                SecureField("Clé API (AI Studio)", text: $googleKey)
                    .textFieldStyle(.roundedBorder)
                Button("Enregistrer") {
                    KeychainStore.shared.set("google-api-key", value: googleKey)
                    statusMessage = "✓ Clé Google enregistrée."
                }
                .buttonStyle(.borderedProminent)

                Divider()

                HStack(spacing: 8) {
                    Circle().fill(Color(hex: "#10A37F")).frame(width: 8, height: 8)
                    Text("OpenAI").font(.system(size: 12, weight: .semibold))
                }
                SecureField("Clé API (sk-…)", text: $openAIKey)
                    .textFieldStyle(.roundedBorder)
                Button("Enregistrer") {
                    KeychainStore.shared.set("openai-api-key", value: openAIKey)
                    statusMessage = "✓ Clé OpenAI enregistrée."
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Integrations section

    @ViewBuilder private var integrationsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {

                // Resend
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#22C55E")).frame(width: 8, height: 8)
                        Text("Resend").font(.system(size: 12, weight: .semibold))
                    }
                    SecureField("Clé API  (re_…)", text: $resendKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("Adresse d'envoi  (toi@ton-domaine.com)", text: $resendFrom)
                        .textFieldStyle(.roundedBorder)
                }

                // n8n
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#F29B38")).frame(width: 8, height: 8)
                        Text("n8n").font(.system(size: 12, weight: .semibold))
                    }
                    TextField("URL de l'instance  (https://…)", text: $n8nUrl)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Clé API", text: $n8nKey)
                        .textFieldStyle(.roundedBorder)
                    IntegrationFilterRow(
                        label: "Workflows",
                        items: n8nWorkflows,
                        filter: $state.n8nWorkflowFilter,
                        loading: loadingN8n,
                        onLoad: loadN8nWorkflows
                    )
                }

                // Vercel
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#7C5CFF")).frame(width: 8, height: 8)
                        Text("Vercel").font(.system(size: 12, weight: .semibold))
                    }
                    SecureField("Jeton", text: $vercelToken)
                        .textFieldStyle(.roundedBorder)
                    IntegrationFilterRow(
                        label: "Projets",
                        items: vercelProjects,
                        filter: $state.vercelProjectFilter,
                        loading: loadingVercel,
                        onLoad: loadVercelProjects
                    )
                }

                // GitHub
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#F4505E")).frame(width: 8, height: 8)
                        Text("GitHub").font(.system(size: 12, weight: .semibold))
                    }
                    SecureField("Jeton d'accès personnel", text: $githubToken)
                        .textFieldStyle(.roundedBorder)
                }

                // Stripe
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#0570DE")).frame(width: 8, height: 8)
                        Text("Stripe").font(.system(size: 12, weight: .semibold))
                    }
                    SecureField("Clé secrète  (sk_live_… ou sk_test_…)", text: $stripeKey)
                        .textFieldStyle(.roundedBorder)
                }

                // Cal.com
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#C9956A")).frame(width: 8, height: 8)
                        Text("Cal.com").font(.system(size: 12, weight: .semibold))
                    }
                    SecureField("Clé API  (cal_live_…)", text: $calcomKey)
                        .textFieldStyle(.roundedBorder)
                }

                // Notion
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: "#E8E8E8")).frame(width: 8, height: 8)
                        Text("Notion").font(.system(size: 12, weight: .semibold))
                    }
                    SecureField("Jeton d'intégration  (secret_…)", text: $notionKey)
                        .textFieldStyle(.roundedBorder)
                }

                Button("Enregistrer les intégrations") { saveIntegrations() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(6)
        }
    }

    // MARK: - Actions

    private func applyCustomModel(_ value: String) {
        let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { state.claudeModel = id }
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

    // MARK: - App Store: hooks via NSOpenPanel + security-scoped bookmark


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
            statusMessage = "✓ Hooks installés dans ~/.claude/settings.json"
            pendingHookJSON = ""
            hookNeedsUpdate = false
        } catch {
            statusMessage = "❌ Erreur d'écriture : \(error.localizedDescription)"
        }
    }

    private func uninstallHooks() {
        do {
            try HookServer.shared.uninstallClaudeHooks()
            statusMessage = "✓ Hooks supprimés."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerGeminiPreview(install: Bool) {
        do {
            geminiPendingInstall = install
            pendingGeminiJSON = try HookServer.shared.previewGeminiHooks(install: install)
            showGeminiDiff = true
            statusMessage = "Vérifie le JSON ci-dessous avant de confirmer."
        } catch let e as NSError where e.domain == "CompagnonNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmGeminiOp() {
        do {
            try HookServer.shared.writeGeminiHooks()
            showGeminiDiff = false
            pendingGeminiJSON = ""
            geminiHooksInstalled = geminiPendingInstall
            statusMessage = geminiPendingInstall
                ? "✓ Hooks Gemini CLI installés dans ~/.gemini/settings.json"
                : "✓ Hooks Gemini CLI supprimés."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerAgyPreview(install: Bool) {
        do {
            agyPendingInstall = install
            pendingAgyJSON = try HookServer.shared.previewAgyHooks(install: install)
            showAgyDiff = true
            statusMessage = "Vérifie le JSON ci-dessous avant de confirmer."
        } catch let e as NSError where e.domain == "CompagnonNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmAgyOp() {
        do {
            try HookServer.shared.writeAgyHooks()
            showAgyDiff = false
            pendingAgyJSON = ""
            agyHooksInstalled = agyPendingInstall
            statusMessage = agyPendingInstall
                ? "✓ Hooks Antigravity installés dans ~/.gemini/config/hooks.json"
                : "✓ Hooks Antigravity supprimés."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func triggerCodexPreview(install: Bool) {
        do {
            codexPendingInstall = install
            pendingCodexJSON = try HookServer.shared.previewCodexHooks(install: install)
            showCodexDiff = true
            statusMessage = "Vérifie le JSON ci-dessous avant de confirmer."
        } catch let e as NSError where e.domain == "CompagnonNoop" {
            statusMessage = e.localizedDescription
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func confirmCodexOp() {
        do {
            try HookServer.shared.writeCodexHooks()
            showCodexDiff = false
            pendingCodexJSON = ""
            codexHooksInstalled = codexPendingInstall
            statusMessage = codexPendingInstall
                ? "✓ Hooks Codex installés — lance /hooks dans Codex ou ouvre Hooks dans les réglages de l'app pour les approuver."
                : "✓ Hooks Codex supprimés."
        } catch {
            statusMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func saveIntegrations() {
        saveKey("resend-api-key",  value: resendKey)
        saveKey("resend-from",     value: resendFrom)
        saveKey("n8n-url",         value: n8nUrl)
        saveKey("n8n-api-key",     value: n8nKey)
        saveKey("vercel-token",    value: vercelToken)
        saveKey("github-token",    value: githubToken)
        saveKey("stripe-api-key",  value: stripeKey)
        saveKey("calcom-api-key",  value: calcomKey)
        saveKey("notion-api-key",  value: notionKey)
        statusMessage = "✓ Clés d'intégration enregistrées."
    }

    private func saveKey(_ key: String, value: String) {
        if value.isEmpty {
            KeychainStore.shared.remove(key)
        } else {
            KeychainStore.shared.set(key, value: value)
        }
    }

    // MARK: - Vercel project list

    private func loadVercelProjects() {
        guard let token = KeychainStore.shared.get("vercel-token") else {
            statusMessage = "❌ Enregistre d'abord le jeton Vercel."
            return
        }
        loadingVercel = true
        guard let url = URL(string: "https://api.vercel.com/v9/projects?limit=100") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let names: [String]
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let projects = json["projects"] as? [[String: Any]] {
                names = projects.compactMap { $0["name"] as? String }.sorted()
            } else {
                names = []
            }
            DispatchQueue.main.async {
                self.vercelProjects = names
                self.loadingVercel = false
                if names.isEmpty { self.statusMessage = "❌ Aucun projet Vercel trouvé." }
            }
        }.resume()
    }

    // MARK: - n8n workflow list

    private func loadN8nWorkflows() {
        guard let apiKey  = KeychainStore.shared.get("n8n-api-key"),
              let rawBase = KeychainStore.shared.get("n8n-url") else {
            statusMessage = "❌ Enregistre d'abord l'URL et la clé API n8n."
            return
        }
        loadingN8n = true
        let base = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urls = ["\(base)/api/v1/workflows?limit=100", "\(base)/rest/workflows?limit=100"]
        fetchN8nWorkflows(urls: urls, apiKey: apiKey, idx: 0)
    }

    private func fetchN8nWorkflows(urls: [String], apiKey: String, idx: Int) {
        guard idx < urls.count, let url = URL(string: urls[idx]) else {
            DispatchQueue.main.async { self.loadingN8n = false; self.statusMessage = "❌ Aucun workflow n8n trouvé." }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "X-N8N-API-KEY")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else {
                DispatchQueue.main.async { self.fetchN8nWorkflows(urls: urls, apiKey: apiKey, idx: idx + 1) }
                return
            }
            let items: [[String: Any]]
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let arr = obj["data"] as? [[String: Any]] { items = arr }
            else if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] { items = arr }
            else { items = [] }
            let names = items.compactMap { $0["name"] as? String }.sorted()
            DispatchQueue.main.async {
                self.n8nWorkflows = names
                self.loadingN8n = false
                if names.isEmpty { self.statusMessage = "❌ Aucun workflow n8n trouvé." }
            }
        }.resume()
    }

    @ViewBuilder
    private func pillRow(_ def: PillDefinition) -> some View {
        let isMain = def.id == state.mainPillId
        let isOn   = state.activeIntegrations.contains(def.id)
        let atMax  = state.activeIntegrations.count >= 4 && !isOn && !isMain
        let hint: String? = {
            if isMain { return nil }
            if def.comingSoon { return "Bientôt" }
            if def.id == "agent_gemini"        && !HookServer.geminiHooksInstalled()  { return "Hooks non installés" }
            if def.id == "agent_antigravity"   && !HookServer.agyHooksInstalled()    { return "Hooks non installés" }
            if def.id == "agent_codex"         && !HookServer.codexHooksInstalled()  { return "Hooks non installés" }
            if def.category == .ai {
                let keyId = def.id == "ai_anthropic" ? "anthropic-api-key"
                           : def.id == "ai_google"    ? "google-api-key" : "openai-api-key"
                if KeychainStore.shared.get(keyId) == nil { return "Clé non configurée" }
            }
            return nil
        }()
        HStack(spacing: 8) {
            Circle()
                .fill(Color(hex: def.color))
                .frame(width: 10, height: 10)
            Text(def.name)
                .font(.system(size: 12))
                .foregroundColor(atMax ? .secondary : .primary)
            Spacer()
            if isMain {
                Text("Principale")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            } else {
                if let h = hint {
                    Text(h)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { _ in state.toggleIntegration(def.id) }
                ))
                .labelsHidden()
                .disabled(atMax)
            }
        }
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

// MARK: - Integration filter row (reusable for Vercel / n8n)

struct IntegrationFilterRow: View {
    let label: String
    let items: [String]
    @Binding var filter: Set<String>
    let loading: Bool
    let onLoad: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                if loading {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Button(items.isEmpty ? "Charger la liste" : "Actualiser") { onLoad() }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
                if !filter.isEmpty {
                    Button("Effacer") { filter = [] }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .foregroundColor(.secondary)
                }
            }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(items, id: \.self) { item in
                        Toggle(item, isOn: Binding(
                            get: { filter.isEmpty || filter.contains(item) },
                            set: { on in
                                if on { filter.insert(item) }
                                else  {
                                    if filter.isEmpty { filter = Set(items).subtracting([item]) }
                                    else { filter.remove(item) }
                                    if filter.count == items.count { filter = [] }
                                }
                            }
                        ))
                        .font(.system(size: 11))
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 4)
                if !filter.isEmpty {
                    Text("\(filter.count) suivis sur \(items.count)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
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
