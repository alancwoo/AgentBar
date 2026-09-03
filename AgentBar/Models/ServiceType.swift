import SwiftUI

enum ServiceType: String, CaseIterable, Codable, Sendable {
    case claude  = "Claude Code"
    case codex   = "OpenAI Codex"
    case gemini  = "Google Gemini"
    case copilot = "GitHub Copilot"
    case cursor  = "Cursor"
    case grok    = "Grok"
    case opencode = "OpenCode"
    case zai     = "Z.ai Coding Plan"

    var darkColor: Color {
        switch self {
        case .claude:  Color(red: 0.851, green: 0.467, blue: 0.024) // amber-600
        case .codex:   Color(red: 0.60, green: 0.63, blue: 0.67)     // gray-400
        case .gemini:  Color(red: 0.102, green: 0.431, blue: 0.882) // blue-600
        case .copilot: Color(red: 0.09, green: 0.47, blue: 0.95)    // blue-600
        case .cursor:  Color(red: 0.15, green: 0.68, blue: 0.38)    // green-600
        case .grok:    Color(red: 0.88, green: 0.30, blue: 0.47)    // rose-500
        case .opencode: Color(red: 0.0, green: 0.62, blue: 0.74)    // cyan-600
        case .zai:     Color(red: 0.486, green: 0.227, blue: 0.929) // violet-600
        }
    }

    var lightColor: Color {
        switch self {
        case .claude:  Color(red: 0.988, green: 0.827, blue: 0.302) // amber-300
        case .codex:   Color(red: 0.82, green: 0.84, blue: 0.86)     // gray-200
        case .gemini:  Color(red: 0.576, green: 0.773, blue: 0.992) // blue-300
        case .copilot: Color(red: 0.53, green: 0.75, blue: 0.99)    // blue-300
        case .cursor:  Color(red: 0.49, green: 0.89, blue: 0.64)    // green-300
        case .grok:    Color(red: 0.99, green: 0.64, blue: 0.75)    // rose-300
        case .opencode: Color(red: 0.57, green: 0.89, blue: 0.95)   // cyan-300
        case .zai:     Color(red: 0.769, green: 0.710, blue: 0.992) // violet-300
        }
    }

    /// Backmost stacked-bar segment, for the monthly window.
    var monthColor: Color {
        lightColor.opacity(0.45)
    }

    var shortName: String {
        switch self {
        case .claude:  "CC"
        case .codex:   "CX"
        case .gemini:  "GM"
        case .copilot: "CP"
        case .cursor:  "CR"
        case .grok:    "GK"
        case .opencode: "OC"
        case .zai:     "Z"
        }
    }

    var fiveHourLabel: String {
        switch self {
        case .gemini: "1d"
        case .copilot, .cursor: "Mo"
        case .grok: "7d"
        default: "5h"
        }
    }

    var monthlyLabel: String {
        "Mo"
    }

    var weeklyLabel: String {
        switch self {
        case .zai: "MCP"
        default: "7d"
        }
    }

    /// Whether this service uses the standard 5h / 7d dual-window structure.
    var hasFiveHourSevenDayStructure: Bool {
        fiveHourLabel == "5h" && weeklyLabel == "7d"
    }

    /// UserDefaults key holding this provider's on/off switch.
    var enabledDefaultsKey: String {
        switch self {
        case .claude:  "claudeEnabled"
        case .codex:   "codexEnabled"
        case .gemini:  "geminiEnabled"
        case .copilot: "copilotEnabled"
        case .cursor:  "cursorEnabled"
        case .grok:    "grokEnabled"
        case .opencode: "opencodeEnabled"
        case .zai:     "zaiEnabled"
        }
    }

    var keychainAccount: String {
        switch self {
        case .claude:  "claude"
        case .codex:   "openai"
        case .gemini:  "gemini"
        case .copilot: "copilot"
        case .cursor:  "cursor"
        case .grok:    "grok"
        case .opencode: "opencode"
        case .zai:     "zai"
        }
    }
}
