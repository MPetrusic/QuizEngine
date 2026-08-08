import Foundation

public enum PowerUp: String, Codable, CaseIterable, Sendable {
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

/// The wallet source that funded a power-up activation.
public enum PowerUpFundingSource: String, Codable, Equatable, Sendable {
    case freeCredit
    case coins
}

/// Durable funding details for a successfully consumed power-up.
public struct PowerUpSpendResult: Equatable, Sendable {
    public let powerUp: PowerUp
    public let fundingSource: PowerUpFundingSource
    public let coinsSpent: Int

    public init(
        powerUp: PowerUp,
        fundingSource: PowerUpFundingSource,
        coinsSpent: Int
    ) {
        self.powerUp = powerUp
        self.fundingSource = fundingSource
        self.coinsSpent = coinsSpent
    }
}
