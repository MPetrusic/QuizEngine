import Foundation

/// Method used to obtain extra life
public enum ExtraLifeMethod: String, Sendable {
    case ad = "ad"
    case coins = "coins"
}

/// Protocol for analytics event logging.
/// Each app provides its own implementation (e.g., Firebase, or a no-op for testing).
/// All methods have default empty implementations so callers can use optional chaining.
public protocol AnalyticsProvider: AnyObject, Sendable {

    // MARK: - Game Events

    func logGameStarted(category: String?, mode: GameMode)
    func logGameEnded(score: Int, livesRemaining: Int, questionsAnswered: Int, coinsEarned: Int, category: String?, mode: GameMode)

    // MARK: - Power-Up Events

    func logPowerUpUsed(type: PowerUp, coinsSpent: Int)
    func logPowerUpUsed(type: PowerUp, fundingSource: PowerUpFundingSource, coinsSpent: Int)

    // MARK: - Extra Life Events

    func logExtraLifeUsed(method: ExtraLifeMethod)

    // MARK: - Daily Reward Events

    func logDailyRewardClaimed(streakDay: Int, amount: Int)

    // MARK: - Purchase Events

    func logCoinPurchase(productId: String, coinsReceived: Int)
    func logPremiumPurchase(productId: String)

    // MARK: - Achievement Events

    func logAchievementUnlocked(achievementId: String, coinReward: Int)

    // MARK: - Category Events

    func logCategorySelected(categoryId: String?, mode: GameMode)
    func logCategoryUnlocked(categoryId: String, coinsSpent: Int)

    // MARK: - Multiplayer Events

    func logMultiplayerInviteSent(transportType: String)
    func logMultiplayerInviteAccepted(transportType: String)
    func logMultiplayerInviteDeclined(transportType: String)
    func logMultiplayerRandomMatchStarted()
    func logMultiplayerMatchStarted(transportType: String, role: String)
    func logMultiplayerMatchCompleted(result: String, myScore: Int, opponentScore: Int, questionsCompleted: Int, durationSeconds: Int, transportType: String)
    func logMultiplayerDisconnect(questionsCompleted: Int, reason: String, transportType: String)
}

// Default empty implementations so all methods are optional for callers
public extension AnalyticsProvider {
    func logGameStarted(category: String?, mode: GameMode) {}
    func logGameEnded(score: Int, livesRemaining: Int, questionsAnswered: Int, coinsEarned: Int, category: String?, mode: GameMode) {}
    func logPowerUpUsed(type: PowerUp, coinsSpent: Int) {}
    func logPowerUpUsed(type: PowerUp, fundingSource: PowerUpFundingSource, coinsSpent: Int) {
        logPowerUpUsed(type: type, coinsSpent: coinsSpent)
    }
    func logExtraLifeUsed(method: ExtraLifeMethod) {}
    func logDailyRewardClaimed(streakDay: Int, amount: Int) {}
    func logCoinPurchase(productId: String, coinsReceived: Int) {}
    func logPremiumPurchase(productId: String) {}
    func logAchievementUnlocked(achievementId: String, coinReward: Int) {}
    func logCategorySelected(categoryId: String?, mode: GameMode) {}
    func logCategoryUnlocked(categoryId: String, coinsSpent: Int) {}
    func logMultiplayerInviteSent(transportType: String) {}
    func logMultiplayerInviteAccepted(transportType: String) {}
    func logMultiplayerInviteDeclined(transportType: String) {}
    func logMultiplayerRandomMatchStarted() {}
    func logMultiplayerMatchStarted(transportType: String, role: String) {}
    func logMultiplayerMatchCompleted(result: String, myScore: Int, opponentScore: Int, questionsCompleted: Int, durationSeconds: Int, transportType: String) {}
    func logMultiplayerDisconnect(questionsCompleted: Int, reason: String, transportType: String) {}
}
