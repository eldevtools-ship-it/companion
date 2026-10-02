import Foundation

// MARK: - Pill category

enum PillCategory: String, CaseIterable {
    case workspace   // where Claude Code runs (always shown)
    case service     // shown as soon as it is configured
}

// MARK: - Pill definition

struct PillDefinition {
    let id:         String
    let name:       String
    let color:      String
    let category:   PillCategory
    /// Label shown next to the task name in the idle card header.
    let subtitle:   String
    let source:     AgentSource
    /// True when the service has what it needs (tokens…). Workspace pills are always on.
    let isConfigured: @MainActor @Sendable () -> Bool

    /// Label shown in the active-session card header.
    var sessionSubtitle: String { "Claude Code" }
}

// MARK: - Catalog
// The whole app: Claude Code, plus Slack, Harvest, Vercel and GitHub once their keys are set.

enum PillCatalog {
    static let all: [PillDefinition] = [
        .init(id: "integration_claude",  name: "Claude Code", color: "#F5F6F8",
              category: .workspace, subtitle: "Sessions",    source: .claudeCode,
              isConfigured: { true }),
        .init(id: "integration_slack",   name: "Slack",       color: "#E01E5A",
              category: .service,   subtitle: "Messages",    source: .service,
              isConfigured: {
                  KeychainStore.shared.get(SlackService.userTokenKey) != nil
                      && KeychainStore.shared.get(SlackService.appTokenKey) != nil
              }),
        .init(id: "integration_harvest", name: "Harvest",     color: "#FA5D00",
              category: .service,   subtitle: "Temps",       source: .service,
              isConfigured: { HarvestService.shared.isConfigured }),
        .init(id: "integration_vercel",  name: "Vercel",      color: "#E5E7EB",
              category: .service,   subtitle: "Déploiements", source: .service,
              isConfigured: { VercelService.shared.isConfigured }),
        .init(id: "integration_github",  name: "GitHub",      color: "#8B949E",
              category: .service,   subtitle: "Dépôts",      source: .service,
              isConfigured: { KeychainStore.shared.get("github-token") != nil }),
    ]

    static var available: [PillDefinition] { all }

    /// The always-on pill.
    static let defaultMainPillId = "integration_claude"

    static func definition(for id: String) -> PillDefinition? {
        all.first { $0.id == id }
    }
}
