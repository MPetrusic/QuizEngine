import Foundation

public enum PowerUp: CaseIterable, Sendable {
    case fiftyFifty
    case skipQuestion
    case timeFreeze
    case streakShield

    public var cost: Int {
        switch self {
        case .fiftyFifty: return 35
        case .skipQuestion: return 40
        case .timeFreeze: return 25
        case .streakShield: return 25
        }
    }

    public var icon: String {
        switch self {
        case .fiftyFifty: return "circle.grid.cross.right.filled"
        case .skipQuestion: return "forward.fill"
        case .timeFreeze: return "snowflake"
        case .streakShield: return "shield.fill"
        }
    }

    public var label: String {
        switch self {
        case .fiftyFifty: return "50/50"
        case .skipQuestion: return String(localized: "quiz_view_model.power_up.skip_question_label")
        case .timeFreeze: return String(localized: "quiz_view_model.power_up.time_freeze_label")
        case .streakShield: return String(localized: "quiz_view_model.power_up.streak_shield_label")
        }
    }

    /// Power-ups that appear in the standard bar (always visible)
    public static var standardPowerUps: [PowerUp] {
        [.fiftyFifty, .skipQuestion, .timeFreeze]
    }
}
