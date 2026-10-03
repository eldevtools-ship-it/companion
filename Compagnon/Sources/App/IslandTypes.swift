import Foundation

// MARK: - Island Mode

enum IslandMode: String, CaseIterable {
    case hidden, compact, expanded
}

// MARK: - Island View

enum IslandView: String, CaseIterable {
    case overview, empty, approval, question, error, finished
    case confused, note, settings, greeting
    case harvest    // Harvest: choose project, task and note
    case notes      // Pense-bête: your notes and folders
    case day        // Good morning / evening summary
    case chat       // Quick chat with Claude
}

// MARK: - Bot State

enum BotState: String, CaseIterable {
    case idle, working, thinking, searching
    case approval, question, error, finished
    case ratelimit, sleeping, dizzy
}

// MARK: - Bot Emote

enum BotEmote: String, CaseIterable {
    case love, surprised, proud, wink, yawn, happy, annoyed
}

// MARK: - Approval info (pending PermissionRequest from Claude Code)

struct ApprovalInfo: Sendable {
    var sessionId: String
    var tool: String
    var command: String
    /// tool_input serialized to JSON with sortedKeys, "" if absent — used to match PostToolUse.
    var inputKey: String
    /// Pill that owns this approval: "integration_claude", "agent_cursor", or "agent_codex".
    var pillId: String
}

// MARK: - Pill badge (shown on pill edge when non-focused task has an alert)

/// A multiple-choice question asked by Claude (AskUserQuestion), answered from the island.
struct ClaudeQuestion: Equatable {
    struct Option: Equatable {
        let label: String
        let description: String
    }
    struct Item: Equatable {
        let question: String
        let header: String
        let options: [Option]
        let multiSelect: Bool
    }
    let sessionId: String
    let items: [Item]
}

enum PillBadge { case approval, finished, error, message }

// MARK: - Agent Task

struct AgentTask: Identifiable, Equatable {
    var id: String
    var name: String
    var color: String          // hex
    var state: BotState
    var stepIndex: Int = 0
    var steps: [String]
    var source: AgentSource
    var isIntegration: Bool = false  // true for persistent integration pills
    var emote: BotEmote? = nil
    var miniEye: EyeShape? = nil
    var pillBadge: PillBadge? = nil  // alert badge shown on pill when not focused
    var sessionCwd: String?  = nil  // last known working directory (Claude Code sessions)
    var startedAt: Date?     = nil  // when the current Claude turn started (your prompt)
    var lastDuration: TimeInterval? = nil  // how long the last finished turn took
}

enum AgentSource: Equatable {
    case claudeCode
    case service  // Slack, Harvest, GitHub
    case agent   // third-party agent via compagnon_agent field
}

// MARK: - View dimensions (from VIEWS in prototype)

struct ViewLayout {
    let height: CGFloat
    let botX: CGFloat
    let botY: CGFloat?         // nil = auto-centered
    let botDiameter: CGFloat
    let agentMode: AgentLayoutMode
}

enum AgentLayoutMode {
    case none, grid, pills, column
}

// MARK: - Card layout
// Every expanded view is the same: the character sits in the left of the card,
// centred, with the same gap between card edge → character → content.

enum CardLayout {
    static let botDiameter: CGFloat = 54
    /// The gumdrop body is 1.14 × the diameter wide (BotEngine: rx = 0.57 D).
    static let botBodyWidth: CGFloat = botDiameter * 1.14
    static let botMargin: CGFloat = 22
    /// Where text and boxes start, measured from the card's left edge.
    static let contentLeading: CGFloat = (botMargin * 2 + botBodyWidth).rounded()
    /// Character centre, measured from the island's left edge.
    static let botCenterX: CGFloat = IslandConst.contentInset + botMargin + botBodyWidth / 2
    /// The cloud spans ±0.44 D around its body centre, which sits 0.03 D below the
    /// canvas centre: lift the canvas by that much to centre the cloud in the card.
    static let botCenterYOffset: CGFloat = -botDiameter * 0.03
    static let headerTop: CGFloat = IslandConst.cardInset + 2
    /// Top of the line under a card's title — the same gap in every card.
    static let secondLineTop: CGFloat = headerTop + 21
}

// MARK: - Constants (from NW, NH, EW in prototype)

enum IslandConst {
    static let notchWidth: CGFloat  = IslandScreenGeometry.fallbackNotchWidth
    static let notchHeight: CGFloat = 32
    static let expandedWidth: CGFloat = 640
    static let expandedHeight: CGFloat = 146
    static let earRadius: CGFloat   = 14
    static let roundedCorner: CGFloat = 14    // hidden/peek/compact

    // Corner radii follow one rule: inner radius = outer radius − the gap between them.
    static let expandedCorner: CGFloat = 24                          // island, expanded
    static let contentInset: CGFloat = 10                            // island edge → cards
    static let cardRadius: CGFloat = expandedCorner - contentInset   // 14
    static let cardInset: CGFloat = 8                                // card edge → inner boxes
    static let innerRadius: CGFloat = cardRadius - cardInset         // 6

    // Island chrome: header strip (back / gear / sound), then the cards.
    static let headerTop: CGFloat = 8
    static let headerHeight: CGFloat = 34
    static let cardTop: CGFloat = headerTop + headerHeight          // 42
    /// Concave flare joining the island to the top of the screen.
    static let flareExpanded: CGFloat = 17
    static let flareCompact: CGFloat = 8
    /// Width of each "ear" on either side of the notch when compact (bot left, minis right).
    static let compactEar: CGFloat = IslandRestingLayout.compactEar
    /// Island height while the Harvest project / task list is open.
    static let harvestListHeight: CGFloat = 284
    /// Island height on the notes.
    static let notesHeight: CGFloat = 300

    static let viewLayouts: [IslandView: ViewLayout] = {
        var d: [IslandView: ViewLayout] = [:]
        for v in IslandView.allCases where v != .greeting {
            d[v] = ViewLayout(height: IslandConst.expandedHeight, botX: CardLayout.botCenterX, botY: nil,
                              botDiameter: CardLayout.botDiameter, agentMode: .none)
        }
        // Greeting: bot drawn by GreetingCanvasView; no BotPlacement needed
        d[.greeting] = ViewLayout(height: 150, botX: 320, botY: 90, botDiameter: 0, agentMode: .none)
        return d
    }()

    // Project colors — keyed by lowercase display name or slug
    static let projectColors: [String: String] = [
        "compagnon":         "#EC4899",
        "raneo-cep":         "#38BDF8",
    ]

    static let fallbackColors = ["#22C55E", "#EAB308", "#60A5FA", "#E879F9"]

    /// Returns the fixed project color for a display name, or a stable fallback.
    static func colorForProject(_ name: String) -> String {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let c = projectColors[key] { return c }
        // partial match (e.g. "korus-api" → "korus")
        for (k, c) in projectColors where key.hasPrefix(k) || key.contains(k) { return c }
        return fallbackColors[abs(name.hashValue) % fallbackColors.count]
    }

    // State card wash colors (radial gradient from bottom)
    static let washColors: [IslandView: String] = [
        .approval:  "rgba(245,165,36,0.42)",
        .question:  "rgba(34,211,238,0.38)",
        .error:     "rgba(244,80,94,0.55)",
        .finished:  "rgba(52,211,153,0.5)",
        .confused:  "rgba(244,114,182,0.55)",
    ]
}
