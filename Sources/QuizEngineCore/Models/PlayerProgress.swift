//
//  PlayerProgress.swift
//  QuizEngineCore
//
//  Created by Claude on 18.1.26..
//

import Foundation

// MARK: - Streak Tier

/// Represents a single tier in the daily streak reward system.
/// This is the single source of truth for streak reward tiers used throughout the app.
public struct StreakTier: Identifiable, Equatable, Sendable {
    public let id: Int
    public let dayRange: ClosedRange<Int>
    public let reward: Int
    public let label: String

    public init(id: Int, dayRange: ClosedRange<Int>, reward: Int, label: String) {
        self.id = id
        self.dayRange = dayRange
        self.reward = reward
        self.label = label
    }

    /// The day number that starts this tier
    public var startDay: Int { dayRange.lowerBound }

    /// Check if a given streak day falls within this tier
    public func contains(day: Int) -> Bool {
        dayRange.contains(day)
    }
}

/// All streak tiers in the reward system - single source of truth
public let allStreakTiers: [StreakTier] = [
    StreakTier(id: 0, dayRange: 0...1, reward: 10, label: "1"),
    StreakTier(id: 1, dayRange: 2...3, reward: 15, label: "2-3"),
    StreakTier(id: 2, dayRange: 4...6, reward: 20, label: "4-6"),
    StreakTier(id: 3, dayRange: 7...13, reward: 30, label: "7-13"),
    StreakTier(id: 4, dayRange: 14...29, reward: 40, label: "14-29"),
    StreakTier(id: 5, dayRange: 30...Int.max, reward: 50, label: "30+")
]

// MARK: - Question Difficulty

/// Type-safe representation of question difficulty levels
public enum QuestionDifficulty: Int, Codable, CaseIterable, Sendable {
    case easy = 1
    case medium = 2
    case hard = 3

    public var displayName: String {
        switch self {
        case .easy: return String(localized: "advanced_stats.difficulty.easy")
        case .medium: return String(localized: "advanced_stats.difficulty.medium")
        case .hard: return String(localized: "advanced_stats.difficulty.hard")
        }
    }

    public var shortName: String {
        switch self {
        case .easy: return String(localized: "player_progress.difficulty.easy_short")
        case .medium: return String(localized: "player_progress.difficulty.medium_short")
        case .hard: return String(localized: "player_progress.difficulty.hard_short")
        }
    }

    /// Initialize from raw difficulty value, defaulting to easy for unknown values
    public static func from(_ rawValue: Int) -> QuestionDifficulty {
        QuestionDifficulty(rawValue: rawValue) ?? .easy
    }
}

// MARK: - Daily Statistics

/// Tracks aggregated statistics for a single day
/// Used for trend analysis and performance insights
public struct DailyStat: Codable, Equatable, Sendable {
    /// Total questions answered on this day
    public var questionsAnswered: Int

    /// Total correct answers on this day
    public var questionsCorrect: Int

    /// Number of game sessions played on this day
    public var gamesPlayed: Int

    /// Cumulative response time in milliseconds (for average calculation)
    public var totalResponseTimeMs: Int

    /// Questions answered by difficulty level (key: difficulty rawValue as String)
    public var questionsByDifficulty: [String: Int]

    /// Correct answers by difficulty level (key: difficulty rawValue as String)
    public var correctByDifficulty: [String: Int]

    public init(
        questionsAnswered: Int = 0,
        questionsCorrect: Int = 0,
        gamesPlayed: Int = 0,
        totalResponseTimeMs: Int = 0,
        questionsByDifficulty: [String: Int] = [:],
        correctByDifficulty: [String: Int] = [:]
    ) {
        self.questionsAnswered = questionsAnswered
        self.questionsCorrect = questionsCorrect
        self.gamesPlayed = gamesPlayed
        self.totalResponseTimeMs = totalResponseTimeMs
        self.questionsByDifficulty = questionsByDifficulty
        self.correctByDifficulty = correctByDifficulty
    }

    /// Accuracy percentage for this day (0-100)
    public var accuracy: Double {
        guard questionsAnswered > 0 else { return 0 }
        return Double(questionsCorrect) / Double(questionsAnswered) * 100
    }

    /// Average response time in seconds
    public var averageResponseTimeSeconds: Double {
        guard questionsAnswered > 0 else { return 0 }
        return Double(totalResponseTimeMs) / Double(questionsAnswered) / 1000.0
    }

    /// Get accuracy for a specific difficulty level
    public func accuracyForDifficulty(_ difficulty: QuestionDifficulty) -> Double {
        let key = String(difficulty.rawValue)
        let total = questionsByDifficulty[key] ?? 0
        let correct = correctByDifficulty[key] ?? 0
        guard total > 0 else { return 0 }
        return Double(correct) / Double(total) * 100
    }

    /// Merges another DailyStat into this one (for aggregating session data)
    public mutating func merge(with other: DailyStat) {
        questionsAnswered += other.questionsAnswered
        questionsCorrect += other.questionsCorrect
        gamesPlayed += other.gamesPlayed
        totalResponseTimeMs += other.totalResponseTimeMs

        for (key, value) in other.questionsByDifficulty {
            questionsByDifficulty[key, default: 0] += value
        }
        for (key, value) in other.correctByDifficulty {
            correctByDifficulty[key, default: 0] += value
        }
    }
}

// MARK: - Hourly Performance

/// Tracks performance statistics for a specific hour of day
/// Used to determine optimal playing times
public struct HourlyPerformance: Codable, Equatable, Sendable {
    /// Total questions answered during this hour
    public var questionsAnswered: Int

    /// Correct answers during this hour
    public var questionsCorrect: Int

    /// Number of sessions that included this hour
    public var sessionCount: Int

    public init(questionsAnswered: Int = 0, questionsCorrect: Int = 0, sessionCount: Int = 0) {
        self.questionsAnswered = questionsAnswered
        self.questionsCorrect = questionsCorrect
        self.sessionCount = sessionCount
    }

    public var accuracy: Double {
        guard questionsAnswered > 0 else { return 0 }
        return Double(questionsCorrect) / Double(questionsAnswered) * 100
    }
}

// MARK: - Category Statistics

/// Tracks user progress within a specific category
public struct CategoryStat: Codable, Equatable, Sendable {
    /// Total number of questions answered in this category (includes wrong answers)
    public var questionsAnswered: Int

    /// Total number of correct answers in this category
    public var questionsCorrect: Int

    /// Set of question IDs (integers) that were answered correctly (used for completion %)
    public var correctlyAnsweredIDs: Set<Int>

    /// Best score achieved in a single session for this category
    public var bestScore: Int

    /// Total questions in the category at the time the user last reached 100% completion.
    /// Used to detect when new questions have been added after reaching 100%.
    public var questionsCountAtHundredPercent: Int?

    public init(questionsAnswered: Int = 0, questionsCorrect: Int = 0, correctlyAnsweredIDs: Set<Int> = [], bestScore: Int = 0, questionsCountAtHundredPercent: Int? = nil) {
        self.questionsAnswered = questionsAnswered
        self.questionsCorrect = questionsCorrect
        self.correctlyAnsweredIDs = correctlyAnsweredIDs
        self.bestScore = bestScore
        self.questionsCountAtHundredPercent = questionsCountAtHundredPercent
    }

    /// Calculate accuracy percentage
    public var accuracy: Double {
        guard questionsAnswered > 0 else { return 0 }
        return Double(questionsCorrect) / Double(questionsAnswered) * 100
    }

    /// Get completion percentage for a given total question count in category
    public func completionPercentage(totalQuestions: Int) -> Double {
        guard totalQuestions > 0 else { return 0 }
        return Double(correctlyAnsweredIDs.count) / Double(totalQuestions) * 100
    }

    /// Get progression tier based on completion percentage
    public func progressionTier(totalQuestions: Int) -> String {
        let percentage = completionPercentage(totalQuestions: totalQuestions)
        switch percentage {
        case 0..<21: return String(localized: "player_progress.tier.beginner")
        case 21..<51: return String(localized: "player_progress.tier.student")
        case 51..<76: return String(localized: "player_progress.tier.advanced")
        case 76..<96: return String(localized: "player_progress.tier.expert")
        case 96..<100: return String(localized: "player_progress.tier.master")
        case 100: return String(localized: "player_progress.tier.legend")
        default: return String(localized: "player_progress.tier.beginner")
        }
    }
}

// MARK: - Player Progress

/// A durable receipt for an already-applied multiplayer result.
///
/// The receipt is deliberately value-only so Core does not depend on the
/// multiplayer product. Its fingerprint prevents a reused match identifier
/// from silently changing a player's statistics or reward.
public struct MultiplayerMatchReceipt: Codable, Equatable, Sendable {
    public let matchID: String
    public let fingerprint: String

    public init(matchID: String, fingerprint: String) {
        self.matchID = matchID
        self.fingerprint = fingerprint
    }
}

public enum MultiplayerResultRecordingOutcome: Equatable, Sendable {
    case recorded
    case alreadyRecorded
    case conflictingReceipt
    case rejected
    case persistenceFailed(PersistenceError)
}

/// The semantic source of a durable coin-reward receipt.
public enum RewardReceiptKind: String, Codable, Equatable, Sendable {
    case rewardedAdCoins
    case premiumBonusCoins
}

/// A durable record that a reward transaction has already been applied.
///
/// Transaction APIs own fingerprint construction and ledger retention. Keeping the
/// persisted value vendor-neutral lets an app use provider or StoreKit transaction
/// identifiers without importing either SDK into QuizEngine.
public struct RewardReceipt: Codable, Equatable, Sendable {
    public let receiptID: String
    public let kind: RewardReceiptKind
    public let fingerprint: String
    public let recordedAt: Date?

    public init(
        receiptID: String,
        kind: RewardReceiptKind,
        fingerprint: String,
        recordedAt: Date? = nil
    ) {
        self.receiptID = receiptID
        self.kind = kind
        self.fingerprint = fingerprint
        self.recordedAt = recordedAt
    }
}

public struct PlayerProgress: Codable, Equatable, Sendable {
    public var coins: Int
    public var currentStreak: Int
    public var longestStreak: Int
    public var lastAppOpenDate: Date?
    public var lastDailyRewardClaimedDate: Date?

    // Power-up usage tracking (resets each session, not persisted meaningfully but included for completeness)
    public var totalCoinsEarned: Int
    public var totalCoinsSpent: Int

    /// Free activations available for each power-up. Missing entries mean zero credits.
    public var powerUpCredits: [PowerUp: Int]

    // MARK: - Phase 2 Category Progress Tracking

    /// Category-specific statistics (Phase 2D)
    public var categoryStats: [String: CategoryStat]

    /// Set of unlocked premium packs (Phase 2 premium feature)
    public var unlockedPacks: Set<String>

    /// Global set of question IDs (integers) seen (for analytics, Phase 4A)
    public var seenQuestionIDs: Set<Int>

    // MARK: - Phase 3 Achievement Tracking

    /// IDs of unlocked achievements
    public var unlockedAchievements: Set<String>

    /// Categories manually unlocked by the player (via coins)
    public var manuallyUnlockedCategories: Set<String>

    /// Total number of games played (incremented at end of each session)
    public var lifetimeGamesPlayed: Int

    /// Total questions answered across all games
    public var lifetimeQuestionsAnswered: Int

    /// Total questions answered correctly across all games
    public var lifetimeQuestionsCorrect: Int

    /// Best score achieved in a single session (global best)
    public var bestSingleSessionScore: Int

    /// Longest consecutive correct answers in a single session (global best)
    public var bestSingleSessionStreak: Int

    /// Set of all power-up types ever used (for "used all types" achievement)
    public var powerUpTypesUsed: Set<String>

    /// Total number of times any power-up was activated (for "used 20 power-ups" achievement)
    public var lifetimePowerUpsUsed: Int?

    // MARK: - Reward Ad Tracking

    /// Last time the user watched a rewarded ad for coins (6-hour cooldown)
    public var lastRewardAdWatchedDate: Date?

    // MARK: - Advanced Statistics (Phase E8)

    /// Daily statistics keyed by date string "yyyy-MM-dd"
    /// Maintains a rolling 30-day window for trend analysis
    public var dailyStats: [String: DailyStat]

    /// Performance statistics by hour of day (0-23)
    /// Used for "best time to play" analysis
    public var hourlyPerformance: [Int: HourlyPerformance]

    /// Average response time across all sessions (in milliseconds)
    /// Updated incrementally to avoid storing all individual times
    public var lifetimeAverageResponseTimeMs: Int

    /// Total response time samples used for lifetime average calculation
    public var lifetimeResponseTimeSamples: Int

    /// Whether the 500 bonus coins from Premium purchase have already been awarded.
    /// Prevents duplicate coin grants on restore, transaction listener re-fire, etc.
    public var hasReceivedPremiumBonusCoins: Bool

    /// The app open date before the most recent one.
    /// Used by AchievementService to evaluate the "comeback" achievement,
    /// since `lastAppOpenDate` is already updated to today by the time achievements are checked.
    public var previousAppOpenDate: Date?

    // MARK: - Play Streak (game-based, separate from app-open streak)

    /// Consecutive days the user has *played a game* (not just opened the app).
    /// Used for streak achievements. The app-open streak (`currentStreak`) remains
    /// separate and drives the daily reward system.
    public var currentPlayStreak: Int

    /// Longest play streak ever achieved. Used for achievement evaluation so that
    /// a streak milestone is never "missed" due to evaluation timing.
    public var longestPlayStreak: Int

    /// Date the user last completed a game session. Used to determine
    /// whether the play streak should increment, stay, or reset.
    public var lastPlayedDate: Date?

    // MARK: - Multiplayer Statistics

    public var multiplayerGamesPlayed: Int
    public var multiplayerGamesWon: Int
    public var multiplayerGamesLost: Int
    public var multiplayerGamesDraw: Int
    public var bestMultiplayerScore: Int
    public var multiplayerWinStreak: Int
    public var longestMultiplayerWinStreak: Int
    public var multiplayerTotalResponseTimeMs: Int
    public var multiplayerTotalQuestionsAnswered: Int
    public var multiplayerTotalQuestionsCorrect: Int

    /// Bounded durable history used to make multiplayer terminal rewards
    /// idempotent across presentation retries and process recreation.
    public var multiplayerMatchReceipts: [MultiplayerMatchReceipt]

    /// Bounded durable history for receipt-backed rewarded-ad and Premium rewards.
    public var rewardReceipts: [RewardReceipt]

    // MARK: - Memberwise Init

    public init(
        coins: Int,
        currentStreak: Int,
        longestStreak: Int,
        lastAppOpenDate: Date?,
        lastDailyRewardClaimedDate: Date?,
        totalCoinsEarned: Int,
        totalCoinsSpent: Int,
        categoryStats: [String: CategoryStat],
        unlockedPacks: Set<String>,
        seenQuestionIDs: Set<Int>,
        unlockedAchievements: Set<String>,
        manuallyUnlockedCategories: Set<String>,
        lifetimeGamesPlayed: Int,
        lifetimeQuestionsAnswered: Int,
        lifetimeQuestionsCorrect: Int,
        bestSingleSessionScore: Int,
        bestSingleSessionStreak: Int,
        powerUpTypesUsed: Set<String>,
        lifetimePowerUpsUsed: Int?,
        lastRewardAdWatchedDate: Date?,
        dailyStats: [String: DailyStat],
        hourlyPerformance: [Int: HourlyPerformance],
        lifetimeAverageResponseTimeMs: Int,
        lifetimeResponseTimeSamples: Int,
        hasReceivedPremiumBonusCoins: Bool = false,
        previousAppOpenDate: Date? = nil,
        currentPlayStreak: Int = 0,
        longestPlayStreak: Int = 0,
        lastPlayedDate: Date? = nil,
        multiplayerGamesPlayed: Int = 0,
        multiplayerGamesWon: Int = 0,
        multiplayerGamesLost: Int = 0,
        multiplayerGamesDraw: Int = 0,
        bestMultiplayerScore: Int = 0,
        multiplayerWinStreak: Int = 0,
        longestMultiplayerWinStreak: Int = 0,
        multiplayerTotalResponseTimeMs: Int = 0,
        multiplayerTotalQuestionsAnswered: Int = 0,
        multiplayerTotalQuestionsCorrect: Int = 0,
        multiplayerMatchReceipts: [MultiplayerMatchReceipt] = [],
        rewardReceipts: [RewardReceipt] = [],
        powerUpCredits: [PowerUp: Int] = [:]
    ) {
        self.coins = coins
        self.currentStreak = currentStreak
        self.longestStreak = longestStreak
        self.lastAppOpenDate = lastAppOpenDate
        self.lastDailyRewardClaimedDate = lastDailyRewardClaimedDate
        self.totalCoinsEarned = totalCoinsEarned
        self.totalCoinsSpent = totalCoinsSpent
        self.categoryStats = categoryStats
        self.unlockedPacks = unlockedPacks
        self.seenQuestionIDs = seenQuestionIDs
        self.unlockedAchievements = unlockedAchievements
        self.manuallyUnlockedCategories = manuallyUnlockedCategories
        self.lifetimeGamesPlayed = lifetimeGamesPlayed
        self.lifetimeQuestionsAnswered = lifetimeQuestionsAnswered
        self.lifetimeQuestionsCorrect = lifetimeQuestionsCorrect
        self.bestSingleSessionScore = bestSingleSessionScore
        self.bestSingleSessionStreak = bestSingleSessionStreak
        self.powerUpTypesUsed = powerUpTypesUsed
        self.lifetimePowerUpsUsed = lifetimePowerUpsUsed
        self.lastRewardAdWatchedDate = lastRewardAdWatchedDate
        self.dailyStats = dailyStats
        self.hourlyPerformance = hourlyPerformance
        self.lifetimeAverageResponseTimeMs = lifetimeAverageResponseTimeMs
        self.lifetimeResponseTimeSamples = lifetimeResponseTimeSamples
        self.hasReceivedPremiumBonusCoins = hasReceivedPremiumBonusCoins
        self.previousAppOpenDate = previousAppOpenDate
        self.currentPlayStreak = currentPlayStreak
        self.longestPlayStreak = longestPlayStreak
        self.lastPlayedDate = lastPlayedDate
        self.multiplayerGamesPlayed = multiplayerGamesPlayed
        self.multiplayerGamesWon = multiplayerGamesWon
        self.multiplayerGamesLost = multiplayerGamesLost
        self.multiplayerGamesDraw = multiplayerGamesDraw
        self.bestMultiplayerScore = bestMultiplayerScore
        self.multiplayerWinStreak = multiplayerWinStreak
        self.longestMultiplayerWinStreak = longestMultiplayerWinStreak
        self.multiplayerTotalResponseTimeMs = multiplayerTotalResponseTimeMs
        self.multiplayerTotalQuestionsAnswered = multiplayerTotalQuestionsAnswered
        self.multiplayerTotalQuestionsCorrect = multiplayerTotalQuestionsCorrect
        self.multiplayerMatchReceipts = multiplayerMatchReceipts
        self.rewardReceipts = rewardReceipts
        self.powerUpCredits = powerUpCredits
    }

    public static let `default` = PlayerProgress(
        coins: 100,
        currentStreak: 0,
        longestStreak: 0,
        lastAppOpenDate: nil,
        lastDailyRewardClaimedDate: nil,
        totalCoinsEarned: 100,
        totalCoinsSpent: 0,
        categoryStats: [:],
        unlockedPacks: [],
        seenQuestionIDs: [],
        unlockedAchievements: [],
        manuallyUnlockedCategories: [],
        lifetimeGamesPlayed: 0,
        lifetimeQuestionsAnswered: 0,
        lifetimeQuestionsCorrect: 0,
        bestSingleSessionScore: 0,
        bestSingleSessionStreak: 0,
        powerUpTypesUsed: [],
        lifetimePowerUpsUsed: nil,
        lastRewardAdWatchedDate: nil,
        dailyStats: [:],
        hourlyPerformance: [:],
        lifetimeAverageResponseTimeMs: 0,
        lifetimeResponseTimeSamples: 0,
        hasReceivedPremiumBonusCoins: false,
        previousAppOpenDate: nil,
        currentPlayStreak: 0,
        longestPlayStreak: 0,
        lastPlayedDate: nil,
        powerUpCredits: [:]
    )

    public static func fresh(initialCoins: Int) -> PlayerProgress {
        var progress = PlayerProgress.default
        progress.coins = initialCoins
        progress.totalCoinsEarned = initialCoins
        return progress
    }

    // MARK: - Custom Codable (Backward Compatibility)

    /// Custom decoder that uses `decodeIfPresent` for every field added after initial release.
    /// This ensures that saved data from older app versions can still be decoded without
    /// falling back to `PlayerProgress.default` (which would wipe user progress).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Core fields (present since v1)
        coins = try container.decodeIfPresent(Int.self, forKey: .coins) ?? 100
        currentStreak = try container.decodeIfPresent(Int.self, forKey: .currentStreak) ?? 0
        longestStreak = try container.decodeIfPresent(Int.self, forKey: .longestStreak) ?? 0
        lastAppOpenDate = try container.decodeIfPresent(Date.self, forKey: .lastAppOpenDate)
        lastDailyRewardClaimedDate = try container.decodeIfPresent(Date.self, forKey: .lastDailyRewardClaimedDate)
        totalCoinsEarned = try container.decodeIfPresent(Int.self, forKey: .totalCoinsEarned) ?? 100
        totalCoinsSpent = try container.decodeIfPresent(Int.self, forKey: .totalCoinsSpent) ?? 0
        powerUpCredits = try container.decodeIfPresent([PowerUp: Int].self, forKey: .powerUpCredits) ?? [:]
        guard powerUpCredits.values.allSatisfy({ $0 >= 0 }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .powerUpCredits,
                in: container,
                debugDescription: "Power-up credit balances cannot be negative."
            )
        }

        // Category progress
        categoryStats = try container.decodeIfPresent([String: CategoryStat].self, forKey: .categoryStats) ?? [:]
        unlockedPacks = try container.decodeIfPresent(Set<String>.self, forKey: .unlockedPacks) ?? []
        seenQuestionIDs = try container.decodeIfPresent(Set<Int>.self, forKey: .seenQuestionIDs) ?? []

        // Achievement tracking
        unlockedAchievements = try container.decodeIfPresent(Set<String>.self, forKey: .unlockedAchievements) ?? []
        manuallyUnlockedCategories = try container.decodeIfPresent(Set<String>.self, forKey: .manuallyUnlockedCategories) ?? []

        // Lifetime stats
        lifetimeGamesPlayed = try container.decodeIfPresent(Int.self, forKey: .lifetimeGamesPlayed) ?? 0
        lifetimeQuestionsAnswered = try container.decodeIfPresent(Int.self, forKey: .lifetimeQuestionsAnswered) ?? 0
        lifetimeQuestionsCorrect = try container.decodeIfPresent(Int.self, forKey: .lifetimeQuestionsCorrect) ?? 0
        bestSingleSessionScore = try container.decodeIfPresent(Int.self, forKey: .bestSingleSessionScore) ?? 0
        bestSingleSessionStreak = try container.decodeIfPresent(Int.self, forKey: .bestSingleSessionStreak) ?? 0
        powerUpTypesUsed = try container.decodeIfPresent(Set<String>.self, forKey: .powerUpTypesUsed) ?? []
        lifetimePowerUpsUsed = try container.decodeIfPresent(Int.self, forKey: .lifetimePowerUpsUsed)

        // Reward ad tracking
        lastRewardAdWatchedDate = try container.decodeIfPresent(Date.self, forKey: .lastRewardAdWatchedDate)

        // Advanced statistics
        dailyStats = try container.decodeIfPresent([String: DailyStat].self, forKey: .dailyStats) ?? [:]
        hourlyPerformance = try container.decodeIfPresent([Int: HourlyPerformance].self, forKey: .hourlyPerformance) ?? [:]
        lifetimeAverageResponseTimeMs = try container.decodeIfPresent(Int.self, forKey: .lifetimeAverageResponseTimeMs) ?? 0
        lifetimeResponseTimeSamples = try container.decodeIfPresent(Int.self, forKey: .lifetimeResponseTimeSamples) ?? 0

        // Premium bonus tracking
        hasReceivedPremiumBonusCoins = try container.decodeIfPresent(Bool.self, forKey: .hasReceivedPremiumBonusCoins) ?? false
        previousAppOpenDate = try container.decodeIfPresent(Date.self, forKey: .previousAppOpenDate)

        // Play streak (game-based)
        currentPlayStreak = try container.decodeIfPresent(Int.self, forKey: .currentPlayStreak) ?? 0
        longestPlayStreak = try container.decodeIfPresent(Int.self, forKey: .longestPlayStreak) ?? 0
        lastPlayedDate = try container.decodeIfPresent(Date.self, forKey: .lastPlayedDate)

        // Multiplayer statistics
        multiplayerGamesPlayed = try container.decodeIfPresent(Int.self, forKey: .multiplayerGamesPlayed) ?? 0
        multiplayerGamesWon = try container.decodeIfPresent(Int.self, forKey: .multiplayerGamesWon) ?? 0
        multiplayerGamesLost = try container.decodeIfPresent(Int.self, forKey: .multiplayerGamesLost) ?? 0
        multiplayerGamesDraw = try container.decodeIfPresent(Int.self, forKey: .multiplayerGamesDraw) ?? 0
        bestMultiplayerScore = try container.decodeIfPresent(Int.self, forKey: .bestMultiplayerScore) ?? 0
        multiplayerWinStreak = try container.decodeIfPresent(Int.self, forKey: .multiplayerWinStreak) ?? 0
        longestMultiplayerWinStreak = try container.decodeIfPresent(Int.self, forKey: .longestMultiplayerWinStreak) ?? 0
        multiplayerTotalResponseTimeMs = try container.decodeIfPresent(Int.self, forKey: .multiplayerTotalResponseTimeMs) ?? 0
        multiplayerTotalQuestionsAnswered = try container.decodeIfPresent(Int.self, forKey: .multiplayerTotalQuestionsAnswered) ?? 0
        multiplayerTotalQuestionsCorrect = try container.decodeIfPresent(Int.self, forKey: .multiplayerTotalQuestionsCorrect) ?? 0
        multiplayerMatchReceipts = try container.decodeIfPresent([MultiplayerMatchReceipt].self, forKey: .multiplayerMatchReceipts) ?? []
        guard multiplayerMatchReceipts.count <= 256,
              Set(multiplayerMatchReceipts.map(\.matchID)).count == multiplayerMatchReceipts.count,
              multiplayerMatchReceipts.allSatisfy({ !$0.matchID.isEmpty && !$0.fingerprint.isEmpty }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .multiplayerMatchReceipts,
                in: container,
                debugDescription: "Multiplayer match receipts must be unique, bounded, and non-empty."
            )
        }

        rewardReceipts = try container.decodeIfPresent([RewardReceipt].self, forKey: .rewardReceipts) ?? []
        guard rewardReceipts.count <= 256,
              Set(rewardReceipts.map(\.receiptID)).count == rewardReceipts.count,
              rewardReceipts.allSatisfy({ !$0.receiptID.isEmpty && !$0.fingerprint.isEmpty }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rewardReceipts,
                in: container,
                debugDescription: "Reward receipts must be unique, bounded, and non-empty."
            )
        }
    }

    // MARK: - Date Formatting

    /// Returns the date key for today
    public static var todayKey: String {
        dateKey(for: Date(), calendar: .current)
    }

    /// Returns the current hour (0-23)
    public static var currentHour: Int {
        hour(for: Date(), calendar: .current)
    }

    /// Returns a stable local-calendar key for daily statistics.
    public static func dateKey(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Returns the local hour for an explicitly supplied date and calendar.
    public static func hour(for date: Date, calendar: Calendar) -> Int {
        calendar.component(.hour, from: date)
    }

    // MARK: - Streak Helpers

    public func dailyRewardAmount() -> Int {
        dailyRewardAmount(using: allStreakTiers)
    }

    public func dailyRewardAmount(using tiers: [StreakTier]) -> Int {
        if let tier = tiers.first(where: { $0.contains(day: currentStreak) }) {
            return tier.reward
        }
        return tiers.last?.reward ?? 0
    }

    /// Returns the index of the current streak tier (0-based)
    public func currentStreakTierIndex() -> Int {
        currentStreakTierIndex(using: allStreakTiers)
    }

    public func currentStreakTierIndex(using tiers: [StreakTier]) -> Int {
        tiers.firstIndex { $0.contains(day: currentStreak) } ?? 0
    }

    public func canClaimDailyReward(
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Bool {
        guard let lastClaimed = lastDailyRewardClaimedDate else {
            return true
        }
        guard now >= lastClaimed else { return false }
        return !calendar.isDate(lastClaimed, inSameDayAs: now)
    }

    public mutating func updateStreakOnAppOpen(
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let today = now

        guard let lastOpen = lastAppOpenDate else {
            // First time opening app
            currentStreak = 1
            lastAppOpenDate = today
            return
        }

        guard today >= lastOpen else { return }

        if calendar.isDate(lastOpen, inSameDayAs: today) {
            // Already opened today, no change
            return
        }

        // Preserve the previous open date before overwriting.
        // AchievementService uses this to evaluate the "comeback" achievement.
        previousAppOpenDate = lastOpen

        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        if let yesterday, calendar.isDate(lastOpen, inSameDayAs: yesterday) {
            // Consecutive day - increment streak
            currentStreak += 1
            if currentStreak > longestStreak {
                longestStreak = currentStreak
            }
        } else {
            // Missed a day - reset streak
            currentStreak = 1
        }

        lastAppOpenDate = today
    }
}
