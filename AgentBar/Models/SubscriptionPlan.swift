import Foundation

enum CodexPlan: String, CaseIterable, Codable, Sendable {
    case plus = "Plus"
    case pro = "Pro"
    case custom = "Custom"

    var fiveHourTokenLimit: Double {
        switch self {
        case .plus: return 1_000_000
        case .pro: return 10_000_000
        case .custom: return 0
        }
    }

    var weeklyTokenLimit: Double {
        switch self {
        case .plus: return 10_000_000
        case .pro: return 100_000_000
        case .custom: return 0
        }
    }
}

enum ClaudePlan: String, CaseIterable, Codable, Sendable {
    case free = "Free"
    case pro = "Pro"
    case max5x = "Max 5x"
    case max20x = "Max 20x"
    case team = "Team"

    /// Stored in place of a case when the label should follow the plan recorded
    /// in the Claude Code credentials instead of a manual choice.
    static let autoRawValue = "Auto"

    /// Maps the `subscriptionType` Claude Code stores alongside its OAuth token
    /// onto a display label. Claude Code does not distinguish Max 5x from
    /// Max 20x, so "max" stays generic — pick a case manually for the tier.
    static func displayName(forSubscriptionType rawValue: String) -> String? {
        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "free": return ClaudePlan.free.rawValue
        case "pro": return ClaudePlan.pro.rawValue
        case "max": return "Max"
        case "max_5x", "max5x": return ClaudePlan.max5x.rawValue
        case "max_20x", "max20x": return ClaudePlan.max20x.rawValue
        case "team", "teams": return ClaudePlan.team.rawValue
        case "enterprise": return "Enterprise"
        default: return nil
        }
    }
}

enum CopilotPlan: String, CaseIterable, Codable, Sendable {
    case free = "Free"
    case pro = "Pro"
    case proPlus = "Pro+"
    case business = "Business"
    case enterprise = "Enterprise"
    case custom = "Custom"
}

enum CursorPlan: String, CaseIterable, Codable, Sendable {
    case free = "Free"
    case pro = "Pro"
    case proPlus = "Pro+"
    case ultra = "Ultra"
    case teams = "Teams"
    case custom = "Custom"

    /// Approximate monthly premium request estimate (varies by model).
    /// Claude Sonnet ~225, GPT-5 ~500, Gemini ~550 per $20.
    var monthlyRequestEstimate: Double {
        switch self {
        case .free: return 50
        case .pro: return 500
        case .proPlus: return 1500
        case .ultra: return 5000
        case .teams: return 1000
        case .custom: return 0
        }
    }

    static func migrateLegacyRawValue(_ rawValue: String) -> String {
        switch rawValue {
        case "Business":
            return CursorPlan.teams.rawValue
        default:
            return rawValue
        }
    }

    static func resolveAndMigrateStoredPlan(in defaults: UserDefaults = .standard) -> CursorPlan {
        let storedRawValue = defaults.string(forKey: "cursorPlan") ?? CursorPlan.pro.rawValue
        let migratedRawValue = migrateLegacyRawValue(storedRawValue)

        if migratedRawValue != storedRawValue {
            defaults.set(migratedRawValue, forKey: "cursorPlan")
        }

        if let resolvedPlan = CursorPlan(rawValue: migratedRawValue) {
            return resolvedPlan
        }

        defaults.set(CursorPlan.pro.rawValue, forKey: "cursorPlan")
        return .pro
    }
}
