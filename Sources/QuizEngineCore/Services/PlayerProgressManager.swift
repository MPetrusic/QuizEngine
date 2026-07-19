//
//  PlayerProgressManager.swift
//  QuizEngineCore
//

import Foundation
import SwiftUI

@MainActor
public class PlayerProgressManager: ObservableObject {
    @Published public private(set) var progress: PlayerProgress
    @Published public var newlyUnlockedAchievements: [Achievement] = []

    public let variant: QuizVariantDefinition
    public let questionDataService: QuestionDataService
    private let achievementService: AchievementService
    private let analytics: (any AnalyticsProvider)?
    private let purchaseStatus: (any PurchaseStatusProvider)?
    private let persistenceURL: URL

    private static var plistURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("player_progress.plist")
    }

    public init(
        variant: QuizVariantDefinition,
        questionDataService: QuestionDataService,
        analytics: (any AnalyticsProvider)? = nil,
        purchaseStatus: (any PurchaseStatusProvider)? = nil,
        persistenceURL: URL? = nil
    ) {
        self.variant = variant
        self.questionDataService = questionDataService
        self.achievementService = AchievementService(variant: variant)
        self.analytics = analytics
        self.purchaseStatus = purchaseStatus
        self.persistenceURL = persistenceURL ?? Self.plistURL
        self.progress = Self.load(from: persistenceURL ?? Self.plistURL)
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> PlayerProgress {
        let decoder = PropertyListDecoder()

        guard let data = try? Data(contentsOf: url),
              let progress = try? decoder.decode(PlayerProgress.self, from: data)
        else {
            return PlayerProgress.default
        }

        return progress
    }

    private func save() {
        let encoder = PropertyListEncoder()

        if let data = try? encoder.encode(progress) {
            if FileManager.default.fileExists(atPath: persistenceURL.path) {
                try? data.write(to: persistenceURL)
            } else {
                FileManager.default.createFile(atPath: persistenceURL.path, contents: data, attributes: nil)
            }
        }
    }

    // MARK: - Coin Operations

    public func addCoins(_ amount: Int) {
        progress.coins += amount
        progress.totalCoinsEarned += amount
        save()
    }

    public func spendCoins(_ amount: Int) -> Bool {
        guard progress.coins >= amount else {
            return false
        }
        progress.coins -= amount
        progress.totalCoinsSpent += amount
        save()
        return true
    }

    public func canAfford(_ amount: Int) -> Bool {
        return progress.coins >= amount
    }

    /// Marks that the 500 premium bonus coins have been received.
    /// Call after awarding to prevent duplicate grants.
    public func markPremiumBonusCoinsReceived() {
        progress.hasReceivedPremiumBonusCoins = true
        save()
    }

    // MARK: - Streak Operations

    public func handleAppOpen() {
        progress.updateStreakOnAppOpen()
        save()
    }

    public func claimDailyReward() -> Int? {
        guard progress.canClaimDailyReward() else {
            return nil
        }

        let rewardAmount = progress.dailyRewardAmount()
        let streakDay = progress.currentStreak

        progress.coins += rewardAmount
        progress.totalCoinsEarned += rewardAmount
        progress.lastDailyRewardClaimedDate = Date()
        save()

        // Log analytics event
        analytics?.logDailyRewardClaimed(streakDay: streakDay, amount: rewardAmount)

        return rewardAmount
    }

    public func shouldShowDailyReward() -> Bool {
        return progress.canClaimDailyReward()
    }

    #if DEBUG
    // MARK: - Debug Helpers

    /// Sets the current streak to a specific value for testing purposes.
    /// Only available in DEBUG builds.
    /// - Parameter streak: The streak value to set (will be clamped to >= 0)
    public func debugSetStreak(_ streak: Int) {
        progress.currentStreak = max(0, streak)
        // Also reset the claim date so we can test claiming
        progress.lastDailyRewardClaimedDate = nil
        save()
    }

    /// Resets the daily reward claim status so it can be claimed again.
    /// Only available in DEBUG builds.
    public func debugResetDailyRewardClaim() {
        progress.lastDailyRewardClaimedDate = nil
        save()
    }
    #endif

    // MARK: - Category Progress Tracking

    /// Records a correct answer for category progress
    public func recordCorrectAnswer(questionID: Int, category: String) {
        var stat = progress.categoryStats[category] ?? CategoryStat()

        stat.questionsAnswered += 1
        stat.questionsCorrect += 1
        stat.correctlyAnsweredIDs.insert(questionID)

        progress.categoryStats[category] = stat
        progress.seenQuestionIDs.insert(questionID)

        save()
    }

    /// Records a wrong answer for category progress
    public func recordWrongAnswer(questionID: Int, category: String) {
        var stat = progress.categoryStats[category] ?? CategoryStat()

        stat.questionsAnswered += 1
        // Don't increment questionsCorrect
        // Don't add to correctlyAnsweredIDs

        progress.categoryStats[category] = stat
        progress.seenQuestionIDs.insert(questionID)

        save()
    }

    /// Records the total question count when the user achieves 100% in a category.
    /// Looks up the real category total itself, so it works correctly in both
    /// category mode and practice mode (where the session is only 20 questions).
    public func markCategoryHundredPercent(category: String) {
        guard var stat = progress.categoryStats[category],
              let totalQuestions = try? questionDataService.getQuestionCount(forCategory: category)
        else { return }
        guard stat.correctlyAnsweredIDs.count >= totalQuestions else { return }
        stat.questionsCountAtHundredPercent = totalQuestions
        progress.categoryStats[category] = stat
        save()
    }

    /// Updates best score for a category
    public func updateBestScore(category: String, sessionScore: Int) {
        var stat = progress.categoryStats[category] ?? CategoryStat()

        if sessionScore > stat.bestScore {
            stat.bestScore = sessionScore
            progress.categoryStats[category] = stat
            save()
        }
    }

    /// Get category statistics
    public func getCategoryStat(for category: String) -> CategoryStat? {
        return progress.categoryStats[category]
    }

    // MARK: - Session Statistics Tracking

    /// Updates the play streak (consecutive days with a completed game).
    /// Called at end of each competitive game session.
    /// Separate from the app-open streak which drives daily rewards.
    public func updatePlayStreak() {
        let calendar = Calendar.current
        let today = Date()

        guard let lastPlayed = progress.lastPlayedDate else {
            // First game ever
            progress.currentPlayStreak = 1
            progress.longestPlayStreak = 1
            progress.lastPlayedDate = today
            save()
            return
        }

        if calendar.isDateInToday(lastPlayed) {
            // Already played today, no change
            return
        }

        if calendar.isDateInYesterday(lastPlayed) {
            // Consecutive day — increment
            progress.currentPlayStreak += 1
        } else {
            // Missed a day — reset
            progress.currentPlayStreak = 1
        }

        if progress.currentPlayStreak > progress.longestPlayStreak {
            progress.longestPlayStreak = progress.currentPlayStreak
        }

        progress.lastPlayedDate = today
        save()
    }

    /// Records end-of-session statistics for achievement evaluation
    /// - Parameters:
    ///   - questionsAnswered: Number of questions answered in the session
    ///   - questionsCorrect: Number of questions answered correctly
    ///   - sessionScore: Final score for the session
    ///   - longestStreak: Longest consecutive correct answers during session
    ///   - usedPowerUps: Set of power-ups used during the session
    public func recordSessionStats(
        questionsAnswered: Int,
        questionsCorrect: Int,
        sessionScore: Int,
        longestStreak: Int,
        usedPowerUps: Set<PowerUp>
    ) {
        progress.lifetimeGamesPlayed += 1
        progress.lifetimeQuestionsAnswered += questionsAnswered
        progress.lifetimeQuestionsCorrect += questionsCorrect

        // Update global bests
        if sessionScore > progress.bestSingleSessionScore {
            progress.bestSingleSessionScore = sessionScore
        }

        if longestStreak > progress.bestSingleSessionStreak {
            progress.bestSingleSessionStreak = longestStreak
        }

        // Track power-up types used
        for powerUp in usedPowerUps {
            let key: String
            switch powerUp {
            case .fiftyFifty:
                key = "fiftyFifty"
            case .skipQuestion:
                key = "skipQuestion"
            case .timeFreeze:
                key = "timeFreeze"
            case .streakShield:
                key = "streakShield"
            }
            progress.powerUpTypesUsed.insert(key)
        }

        save()
    }

    /// Records that a power-up was used (called when power-up is activated)
    /// - Parameter powerUp: The power-up that was used
    public func recordPowerUpUsed(_ powerUp: PowerUp) {
        let key: String
        switch powerUp {
        case .fiftyFifty:
            key = "fiftyFifty"
        case .skipQuestion:
            key = "skipQuestion"
        case .timeFreeze:
            key = "timeFreeze"
        case .streakShield:
            key = "streakShield"
        }

        progress.powerUpTypesUsed.insert(key)
        progress.lifetimePowerUpsUsed = (progress.lifetimePowerUpsUsed ?? 0) + 1
        save()
    }

    // MARK: - Multiplayer Result Recording

    /// Records the result of a multiplayer match and updates stats.
    /// - Parameters:
    ///   - won: True if player won, false if lost (ignored if draw)
    ///   - draw: True if the match ended in a draw
    ///   - score: Player's final score
    ///   - questionsCompleted: Number of questions completed in the match
    ///   - coinsEarned: Total coins earned (per-question + bonus)
    ///   - responseTimes: Array of response times in ms for each answered question
    public func recordMultiplayerResult(
        won: Bool,
        draw: Bool,
        score: Int,
        questionsCompleted: Int,
        questionsCorrect: Int,
        coinsEarned: Int,
        responseTimes: [Int]
    ) {
        progress.multiplayerGamesPlayed += 1

        if draw {
            progress.multiplayerGamesDraw += 1
            progress.multiplayerWinStreak = 0
        } else if won {
            progress.multiplayerGamesWon += 1
            progress.multiplayerWinStreak += 1
            if progress.multiplayerWinStreak > progress.longestMultiplayerWinStreak {
                progress.longestMultiplayerWinStreak = progress.multiplayerWinStreak
            }
        } else {
            progress.multiplayerGamesLost += 1
            progress.multiplayerWinStreak = 0
        }

        if score > progress.bestMultiplayerScore {
            progress.bestMultiplayerScore = score
        }

        let totalMs = responseTimes.reduce(0, +)
        progress.multiplayerTotalResponseTimeMs += totalMs
        progress.multiplayerTotalQuestionsAnswered += questionsCompleted
        progress.multiplayerTotalQuestionsCorrect += questionsCorrect

        progress.coins += coinsEarned
        progress.totalCoinsEarned += coinsEarned
        save()
    }

    // MARK: - Question Seen Tracking

    /// Records that a question was shown to the user (for content freshness tracking)
    /// - Parameter questionID: The ID of the question that was shown
    public func recordQuestionSeen(questionID: Int) {
        guard !progress.seenQuestionIDs.contains(questionID) else { return }
        progress.seenQuestionIDs.insert(questionID)
        save()
    }

    /// Get count of seen questions for a category
    /// - Parameters:
    ///   - category: Category to filter by (nil = all categories)
    ///   - allQuestions: All questions to search within
    /// - Returns: Number of questions in the category that have been seen
    public func getSeenCount(forCategory category: String?, allQuestions: [Question]) -> Int {
        let categoryQuestions: [Question]
        if let category = category {
            categoryQuestions = allQuestions.filter { $0.categories.contains(category) }
        } else {
            categoryQuestions = allQuestions
        }
        return categoryQuestions.filter { progress.seenQuestionIDs.contains($0.id) }.count
    }

    /// Checks for newly unlocked achievements and updates progress
    /// Call this after recording session stats or other progress updates
    public func checkAndUnlockAchievements() {
        let unlocked = achievementService.checkAchievements(progress: progress)

        guard !unlocked.isEmpty else {
            newlyUnlockedAchievements = []
            return
        }

        // Unlock each achievement and award coins
        for achievement in unlocked {
            progress.unlockedAchievements.insert(achievement.id)
            progress.coins += achievement.coinReward
            progress.totalCoinsEarned += achievement.coinReward

            // Log analytics event
            analytics?.logAchievementUnlocked(
                achievementId: achievement.id,
                coinReward: achievement.coinReward
            )
        }

        save()

        // Publish newly unlocked for UI to display
        newlyUnlockedAchievements = unlocked
    }

    /// Clears the list of newly unlocked achievements (call after UI has shown them)
    public func clearNewlyUnlockedAchievements() {
        newlyUnlockedAchievements = []
    }

    // MARK: - Achievement Management

    /// Unlocks an achievement and awards coins
    /// - Parameters:
    ///   - id: Achievement ID
    ///   - coinReward: Number of coins to award
    /// - Returns: true if achievement was newly unlocked, false if already unlocked
    @discardableResult
    public func unlockAchievement(id: String, coinReward: Int) -> Bool {
        guard !progress.unlockedAchievements.contains(id) else {
            return false
        }

        progress.unlockedAchievements.insert(id)
        addCoins(coinReward)

        return true
    }

    /// Checks if an achievement is unlocked
    /// - Parameter id: Achievement ID
    /// - Returns: true if the achievement is unlocked
    public func isAchievementUnlocked(_ id: String) -> Bool {
        return progress.unlockedAchievements.contains(id)
    }

    /// Returns count of unlocked achievements
    public var unlockedAchievementCount: Int {
        progress.unlockedAchievements.count
    }

    // MARK: - Convenience Accessors

    public var coins: Int {
        progress.coins
    }

    public var currentStreak: Int {
        progress.currentStreak
    }

    public var longestStreak: Int {
        progress.longestStreak
    }

    public var dailyRewardAmount: Int {
        progress.dailyRewardAmount()
    }

    // NOTE: streakColor was removed — it uses Color.Theme.accentBright which is app-specific.
    // It will be added back as an app-side extension.

    public var lifetimeGamesPlayed: Int {
        progress.lifetimeGamesPlayed
    }

    public var lifetimeQuestionsAnswered: Int {
        progress.lifetimeQuestionsAnswered
    }

    public var lifetimeQuestionsCorrect: Int {
        progress.lifetimeQuestionsCorrect
    }

    public var bestSingleSessionScore: Int {
        progress.bestSingleSessionScore
    }

    public var bestSingleSessionStreak: Int {
        progress.bestSingleSessionStreak
    }

    public var hasUsedAllPowerUpTypes: Bool {
        progress.powerUpTypesUsed.count == 4
    }

    // MARK: - Multiplayer Convenience Accessors

    public var multiplayerGamesPlayed: Int {
        progress.multiplayerGamesPlayed
    }

    public var multiplayerGamesWon: Int {
        progress.multiplayerGamesWon
    }

    public var multiplayerGamesLost: Int {
        progress.multiplayerGamesLost
    }

    public var multiplayerGamesDraw: Int {
        progress.multiplayerGamesDraw
    }

    public var bestMultiplayerScore: Int {
        progress.bestMultiplayerScore
    }

    public var multiplayerWinStreak: Int {
        progress.multiplayerWinStreak
    }

    public var longestMultiplayerWinStreak: Int {
        progress.longestMultiplayerWinStreak
    }

    public var multiplayerTotalQuestionsAnswered: Int {
        progress.multiplayerTotalQuestionsAnswered
    }

    public var multiplayerTotalQuestionsCorrect: Int {
        progress.multiplayerTotalQuestionsCorrect
    }

    public var multiplayerWinRate: Double {
        guard progress.multiplayerGamesPlayed > 0 else { return 0 }
        return Double(progress.multiplayerGamesWon) / Double(progress.multiplayerGamesPlayed) * 100
    }

    public var multiplayerAccuracy: Double {
        guard progress.multiplayerTotalQuestionsAnswered > 0 else { return 0 }
        return Double(progress.multiplayerTotalQuestionsCorrect) / Double(progress.multiplayerTotalQuestionsAnswered) * 100
    }

    public var multiplayerAverageResponseTimeSeconds: Double {
        guard progress.multiplayerTotalQuestionsAnswered > 0 else { return 0 }
        return Double(progress.multiplayerTotalResponseTimeMs) / Double(progress.multiplayerTotalQuestionsAnswered) / 1000.0
    }

    public var multiplayerHasData: Bool {
        progress.multiplayerGamesPlayed > 0
    }

    // MARK: - Reward Ad Tracking

    /// Checks if the user can watch a rewarded ad for coins (6-hour cooldown)
    public func canWatchRewardAd() -> Bool {
        guard let lastWatched = progress.lastRewardAdWatchedDate else {
            return true
        }
        let hoursSince = Date().timeIntervalSince(lastWatched) / 3600
        return hoursSince >= 6
    }

    /// Records that the user watched a rewarded ad and awards coins
    /// - Parameter coinsAwarded: Number of coins to award (default: 25)
    public func recordRewardAdWatched(coinsAwarded: Int = 25) {
        progress.lastRewardAdWatchedDate = Date()
        addCoins(coinsAwarded)
    }

    /// Returns the time remaining until the next reward ad is available
    /// - Returns: TimeInterval in seconds, or nil if ad is available now
    public func timeUntilNextRewardAd() -> TimeInterval? {
        guard let lastWatched = progress.lastRewardAdWatchedDate else {
            return nil
        }
        let secondsSince = Date().timeIntervalSince(lastWatched)
        let cooldownSeconds: TimeInterval = 6 * 3600 // 6 hours
        let remaining = cooldownSeconds - secondsSince
        return remaining > 0 ? remaining : nil
    }

    // MARK: - Category Unlock System

    /// Checks if a category is unlocked (either free, earned, purchased, or Premium)
    /// - Parameter categoryID: The category identifier (lowercase English)
    /// - Returns: true if the category is playable
    public func isCategoryUnlocked(_ categoryID: String) -> Bool {
        let normalizedID = categoryID.lowercased()
        guard let requirement = variant.category(id: normalizedID)?.unlockRequirement else {
            return false
        }

        // Premium users have all categories unlocked
        if purchaseStatus?.isPremium ?? false {
            return true
        }

        // Check if manually unlocked (purchased with coins)
        if progress.manuallyUnlockedCategories.contains(normalizedID) {
            return true
        }

        return evaluateRequirement(requirement)
    }

    /// Gets the unlock progress for a category
    /// - Parameters:
    ///   - categoryID: The category identifier
    /// - Returns: UnlockProgress with current state and progress info
    public func getUnlockProgress(for categoryID: String) -> UnlockProgress {
        let normalizedID = categoryID.lowercased()

        guard let requirement = variant.category(id: normalizedID)?.unlockRequirement else {
            return UnlockProgress(
                isUnlocked: false,
                requirementDescription: "category_unlock_requirement.description.unlock",
                currentValue: 0,
                targetValue: 0,
                coinCost: nil
            )
        }

        // Already manually unlocked
        if progress.manuallyUnlockedCategories.contains(normalizedID) {
            return .unlocked()
        }

        // Free categories
        if case .free = requirement {
            return .free()
        }

        // Evaluate and return progress
        return buildUnlockProgress(for: requirement, categoryID: normalizedID)
    }

    /// Attempts to unlock a category with coins
    /// - Parameter categoryID: The category to unlock
    /// - Returns: true if unlock was successful, false if insufficient coins or no coin option
    @discardableResult
    public func unlockCategoryWithCoins(_ categoryID: String) -> Bool {
        let normalizedID = categoryID.lowercased()

        // Already unlocked?
        if isCategoryUnlocked(normalizedID) {
            return true
        }

        // Get coin cost
        guard let cost = variant.category(id: normalizedID)?.coinCost else {
            return false
        }

        // Try to spend coins
        guard spendCoins(cost) else {
            return false
        }

        // Mark as unlocked
        progress.manuallyUnlockedCategories.insert(normalizedID)
        save()

        // Log analytics event
        analytics?.logCategoryUnlocked(categoryId: normalizedID, coinsSpent: cost)

        return true
    }

    // MARK: - Private Unlock Evaluation Helpers

    /// Evaluates if a requirement is satisfied
    private func evaluateRequirement(_ requirement: UnlockRequirement) -> Bool {
        switch requirement {
        case .free:
            return true

        case .questionsCorrect(let count):
            return progress.lifetimeQuestionsCorrect >= count

        case .categoryCompletion(let categoryID, let percentage):
            guard let stat = progress.categoryStats[categoryID] else {
                return false
            }
            // Get total questions in the required category
            if let totalQuestions = try? questionDataService.getQuestionCount(forCategory: categoryID) {
                let completion = stat.completionPercentage(totalQuestions: totalQuestions)
                return completion >= percentage
            }
            return false

        case .coins:
            // Coin requirements are handled separately via unlockCategoryWithCoins
            return false

        case .anyOf(let options):
            // Return true if ANY non-coin requirement is met
            for option in options {
                if case .coins = option {
                    continue // Skip coin options in auto-evaluation
                }
                if evaluateRequirement(option) {
                    return true
                }
            }
            return false
        }
    }

    /// Builds unlock progress info for UI display
    private func buildUnlockProgress(for requirement: UnlockRequirement, categoryID: String) -> UnlockProgress {
        let coinCost = variant.category(id: categoryID)?.coinCost

        switch requirement {
        case .free:
            return .free()

        case .questionsCorrect(let count):
            return UnlockProgress(
                isUnlocked: progress.lifetimeQuestionsCorrect >= count,
                requirementDescription: "category_unlock_requirement.description.questions_correct",
                requirementValue: count,
                currentValue: progress.lifetimeQuestionsCorrect,
                targetValue: count,
                coinCost: coinCost
            )

        case .categoryCompletion(let requiredCategoryID, let percentage):
            let stat = progress.categoryStats[requiredCategoryID]
            let totalQuestions = (try? questionDataService.getQuestionCount(forCategory: requiredCategoryID)) ?? 0
            let currentCompletion = stat?.completionPercentage(totalQuestions: totalQuestions) ?? 0
            let currentCorrect = stat?.correctlyAnsweredIDs.count ?? 0
            let targetCorrect = Int(ceil(Double(totalQuestions) * percentage / 100.0))

            return UnlockProgress(
                isUnlocked: currentCompletion >= percentage,
                requirementDescription: "category_unlock_requirement.description.category_completion",
                requirementValue: Int(percentage),
                currentValue: currentCorrect,
                targetValue: targetCorrect,
                coinCost: coinCost
            )

        case .coins(let amount):
            return UnlockProgress(
                isUnlocked: false,
                requirementDescription: "category_unlock_requirement.description.coins",
                requirementValue: amount,
                currentValue: 0,
                targetValue: 0,
                coinCost: amount
            )

        case .anyOf(let options):
            // Find the primary (non-coin) requirement to show progress
            for option in options {
                if case .coins = option {
                    continue
                }
                let progress = buildUnlockProgress(for: option, categoryID: categoryID)
                // Override coin cost from the anyOf options
                return UnlockProgress(
                    isUnlocked: progress.isUnlocked,
                    requirementDescription: progress.requirementDescription,
                    requirementValue: progress.requirementValue,
                    currentValue: progress.currentValue,
                    targetValue: progress.targetValue,
                    coinCost: coinCost
                )
            }

            // Fallback if only coin option exists
            return UnlockProgress(
                isUnlocked: false,
                requirementDescription: "category_unlock_requirement.description.unlock",
                currentValue: 0,
                targetValue: 0,
                coinCost: coinCost
            )
        }
    }

    // MARK: - Advanced Statistics

    /// Session statistics collected during gameplay for end-of-session recording
    public struct SessionStatistics {
        public var questionsAnswered: Int
        public var questionsCorrect: Int
        public var totalResponseTimeMs: Int
        public var questionsByDifficulty: [QuestionDifficulty: Int]
        public var correctByDifficulty: [QuestionDifficulty: Int]
        public var sessionHour: Int

        public init() {
            self.questionsAnswered = 0
            self.questionsCorrect = 0
            self.totalResponseTimeMs = 0
            self.questionsByDifficulty = [:]
            self.correctByDifficulty = [:]
            self.sessionHour = Calendar.current.component(.hour, from: Date())
        }
    }

    /// Records detailed session statistics at end of game
    /// - Parameter sessionStats: Aggregated statistics from the game session
    public func recordAdvancedSessionStats(_ sessionStats: SessionStatistics) {
        let todayKey = PlayerProgress.todayKey

        // Update or create daily stat
        var dailyStat = progress.dailyStats[todayKey] ?? DailyStat()
        dailyStat.questionsAnswered += sessionStats.questionsAnswered
        dailyStat.questionsCorrect += sessionStats.questionsCorrect
        dailyStat.gamesPlayed += 1
        dailyStat.totalResponseTimeMs += sessionStats.totalResponseTimeMs

        // Merge difficulty stats
        for (difficulty, count) in sessionStats.questionsByDifficulty {
            let key = String(difficulty.rawValue)
            dailyStat.questionsByDifficulty[key, default: 0] += count
        }
        for (difficulty, count) in sessionStats.correctByDifficulty {
            let key = String(difficulty.rawValue)
            dailyStat.correctByDifficulty[key, default: 0] += count
        }

        progress.dailyStats[todayKey] = dailyStat

        // Update hourly performance
        let hour = sessionStats.sessionHour
        var hourlyPerf = progress.hourlyPerformance[hour] ?? HourlyPerformance()
        hourlyPerf.questionsAnswered += sessionStats.questionsAnswered
        hourlyPerf.questionsCorrect += sessionStats.questionsCorrect
        hourlyPerf.sessionCount += 1
        progress.hourlyPerformance[hour] = hourlyPerf

        // Update lifetime average response time (incremental average)
        if sessionStats.questionsAnswered > 0 {
            let totalSamples = progress.lifetimeResponseTimeSamples + sessionStats.questionsAnswered
            let currentTotal = progress.lifetimeAverageResponseTimeMs * progress.lifetimeResponseTimeSamples
            let newTotal = currentTotal + sessionStats.totalResponseTimeMs
            progress.lifetimeAverageResponseTimeMs = totalSamples > 0 ? newTotal / totalSamples : 0
            progress.lifetimeResponseTimeSamples = totalSamples
        }

        // Cleanup old daily stats (keep 30 days)
        cleanupOldDailyStats()

        save()
    }

    /// Removes daily stats older than 30 days
    private func cleanupOldDailyStats() {
        let calendar = Calendar.current
        let cutoffDate = calendar.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        let cutoffKey = PlayerProgress.dailyStatsDateFormatter.string(from: cutoffDate)

        progress.dailyStats = progress.dailyStats.filter { key, _ in
            key >= cutoffKey
        }
    }

    // MARK: - Advanced Statistics Computed Properties

    /// Returns daily stats for the last N days, sorted by date
    /// - Parameter days: Number of days to retrieve (default 7)
    /// - Returns: Array of (dateKey, DailyStat) tuples, oldest first
    public func getDailyStats(forLastDays days: Int = 7) -> [(date: String, stat: DailyStat)] {
        let calendar = Calendar.current
        var result: [(String, DailyStat)] = []

        for dayOffset in (0..<days).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: Date()) else { continue }
            let key = PlayerProgress.dailyStatsDateFormatter.string(from: date)
            let stat = progress.dailyStats[key] ?? DailyStat()
            result.append((key, stat))
        }

        return result
    }

    /// Returns accuracy trend for the last N days
    /// - Parameter days: Number of days (default 7)
    /// - Returns: Array of accuracy percentages (0-100), oldest first
    public func getAccuracyTrend(forLastDays days: Int = 7) -> [Double] {
        getDailyStats(forLastDays: days).map { $0.stat.accuracy }
    }

    /// Returns the best performing hour(s) of day based on accuracy
    /// - Returns: Tuple with best hour (0-23) and accuracy, or nil if no data
    public func getBestPerformingHour() -> (hour: Int, accuracy: Double)? {
        let validHours = progress.hourlyPerformance.filter { $0.value.questionsAnswered >= 5 }
        guard !validHours.isEmpty else { return nil }

        let best = validHours.max { $0.value.accuracy < $1.value.accuracy }
        guard let bestEntry = best else { return nil }

        return (bestEntry.key, bestEntry.value.accuracy)
    }

    /// Returns the most active hour(s) of day based on session count
    /// - Returns: Tuple with most active hour (0-23) and session count, or nil if no data
    public func getMostActiveHour() -> (hour: Int, sessions: Int)? {
        guard !progress.hourlyPerformance.isEmpty else { return nil }

        let most = progress.hourlyPerformance.max { $0.value.sessionCount < $1.value.sessionCount }
        guard let mostEntry = most else { return nil }

        return (mostEntry.key, mostEntry.value.sessionCount)
    }

    /// Returns accuracy breakdown by difficulty level
    /// - Returns: Dictionary mapping difficulty to accuracy percentage
    public func getAccuracyByDifficulty() -> [QuestionDifficulty: Double] {
        var totalByDifficulty: [QuestionDifficulty: Int] = [:]
        var correctByDifficulty: [QuestionDifficulty: Int] = [:]

        for (_, dailyStat) in progress.dailyStats {
            for difficulty in QuestionDifficulty.allCases {
                let key = String(difficulty.rawValue)
                totalByDifficulty[difficulty, default: 0] += dailyStat.questionsByDifficulty[key] ?? 0
                correctByDifficulty[difficulty, default: 0] += dailyStat.correctByDifficulty[key] ?? 0
            }
        }

        var result: [QuestionDifficulty: Double] = [:]
        for difficulty in QuestionDifficulty.allCases {
            let total = totalByDifficulty[difficulty] ?? 0
            let correct = correctByDifficulty[difficulty] ?? 0
            result[difficulty] = total > 0 ? Double(correct) / Double(total) * 100 : 0
        }

        return result
    }

    /// Returns category performance with accuracy for each played category
    /// - Returns: Array of (category, accuracy, questionsAnswered) sorted by accuracy descending
    public func getCategoryPerformance() -> [(category: String, accuracy: Double, questionsAnswered: Int, bestScore: Int)] {
        progress.categoryStats.compactMap { categoryID, stat in
            guard stat.questionsAnswered > 0 else { return nil }
            return (categoryID, stat.accuracy, stat.questionsAnswered, stat.bestScore)
        }
        .sorted { $0.accuracy > $1.accuracy }
    }

    /// Returns lifetime average response time in seconds
    public var lifetimeAverageResponseTimeSeconds: Double {
        guard progress.lifetimeResponseTimeSamples > 0 else { return 0 }
        return Double(progress.lifetimeAverageResponseTimeMs) / 1000.0
    }

    /// Returns overall lifetime accuracy
    public var lifetimeAccuracy: Double {
        guard progress.lifetimeQuestionsAnswered > 0 else { return 0 }
        return Double(progress.lifetimeQuestionsCorrect) / Double(progress.lifetimeQuestionsAnswered) * 100
    }

    /// Formats hour for display (e.g., 14 -> "14:00")
    public static func formatHour(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    /// Formats hour range for display (e.g., 14 -> "14:00 - 15:00")
    public static func formatHourRange(_ hour: Int) -> String {
        let nextHour = (hour + 1) % 24
        return String(format: "%02d:00 - %02d:00", hour, nextHour)
    }

    // MARK: - Reset (for testing)

    public func resetProgress() {
        progress = PlayerProgress.default
        save()
    }
}
