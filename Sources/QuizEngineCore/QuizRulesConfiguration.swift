import Foundation

public enum QuizRulesValidationError: Error, Equatable, Sendable, LocalizedError {
    case negativeValue(String)
    case nonPositiveValue(String)
    case invalidProbability(String)
    case missingPowerUpRule(PowerUp)
    case invalidPowerUpEligibility(PowerUp)
    case invalidDailyRewardTiers(String)
    case invalidSessionLimit(String)
    case invalidMultiplayerThresholds

    public var errorDescription: String? {
        switch self {
        case .negativeValue(let field):
            return "Rule value must not be negative: \(field)"
        case .nonPositiveValue(let field):
            return "Rule value must be positive: \(field)"
        case .invalidProbability(let field):
            return "Interstitial probability must use a positive denominator and a numerator within 0...denominator: \(field)"
        case .missingPowerUpRule(let powerUp):
            return "Missing power-up rule: \(powerUp.rawValue)"
        case .invalidPowerUpEligibility(let powerUp):
            return "Invalid power-up eligibility: \(powerUp.rawValue)"
        case .invalidDailyRewardTiers(let reason):
            return "Invalid daily reward tiers: \(reason)"
        case .invalidSessionLimit(let field):
            return "Session limit must be positive when present: \(field)"
        case .invalidMultiplayerThresholds:
            return "Multiplayer timing and reward thresholds must be internally consistent and within the configured match size"
        }
    }
}

public struct QuizScoringRules: Equatable, Sendable {
    public let baseCorrectPoints: Int
    public let streakCorrectPoints: Int
    public let streakThreshold: Int

    public init(baseCorrectPoints: Int, streakCorrectPoints: Int, streakThreshold: Int) {
        self.baseCorrectPoints = baseCorrectPoints
        self.streakCorrectPoints = streakCorrectPoints
        self.streakThreshold = streakThreshold
    }
}

public struct QuizSoloRules: Equatable, Sendable {
    public let timerDurationSeconds: Int
    public let startingLives: Int
    public let scoring: QuizScoringRules

    public init(timerDurationSeconds: Int, startingLives: Int, scoring: QuizScoringRules) {
        self.timerDurationSeconds = timerDurationSeconds
        self.startingLives = startingLives
        self.scoring = scoring
    }
}

public struct QuizPowerUpRule: Equatable, Sendable {
    public let coinCost: Int
    public let isEnabled: Bool
    public let allowedModes: Set<GameMode>
    public let maximumUsesPerSession: Int

    public init(
        coinCost: Int,
        isEnabled: Bool = true,
        allowedModes: Set<GameMode>,
        maximumUsesPerSession: Int
    ) {
        self.coinCost = coinCost
        self.isEnabled = isEnabled
        self.allowedModes = allowedModes
        self.maximumUsesPerSession = maximumUsesPerSession
    }
}

public struct QuizPowerUpRules: Equatable, Sendable {
    public let rules: [PowerUp: QuizPowerUpRule]
    public let fiftyFiftyIncorrectAnswersRemoved: Int
    public let timeFreezeDurationSeconds: TimeInterval
    public let streakShieldMinimumStreak: Int

    public init(
        rules: [PowerUp: QuizPowerUpRule],
        fiftyFiftyIncorrectAnswersRemoved: Int,
        timeFreezeDurationSeconds: TimeInterval,
        streakShieldMinimumStreak: Int
    ) {
        self.rules = rules
        self.fiftyFiftyIncorrectAnswersRemoved = fiftyFiftyIncorrectAnswersRemoved
        self.timeFreezeDurationSeconds = timeFreezeDurationSeconds
        self.streakShieldMinimumStreak = streakShieldMinimumStreak
    }

    public func rule(for powerUp: PowerUp) -> QuizPowerUpRule? {
        rules[powerUp]
    }
}

public struct QuizExtraLifeRules: Equatable, Sendable {
    public let coinCost: Int
    public let maximumUsesPerSession: Int
    public let allowsCoins: Bool
    public let allowsRewardedAd: Bool

    public init(
        coinCost: Int,
        maximumUsesPerSession: Int,
        allowsCoins: Bool,
        allowsRewardedAd: Bool
    ) {
        self.coinCost = coinCost
        self.maximumUsesPerSession = maximumUsesPerSession
        self.allowsCoins = allowsCoins
        self.allowsRewardedAd = allowsRewardedAd
    }
}

public struct QuizRewardAdRules: Equatable, Sendable {
    public let coinReward: Int
    public let cooldownSeconds: TimeInterval

    public init(coinReward: Int, cooldownSeconds: TimeInterval) {
        self.coinReward = coinReward
        self.cooldownSeconds = cooldownSeconds
    }
}

public struct QuizEconomyRules: Equatable, Sendable {
    public let initialCoins: Int
    public let correctAnswerCoinReward: Int
    public let dailyRewardTiers: [StreakTier]
    public let rewardAd: QuizRewardAdRules

    public init(
        initialCoins: Int,
        correctAnswerCoinReward: Int,
        dailyRewardTiers: [StreakTier],
        rewardAd: QuizRewardAdRules
    ) {
        self.initialCoins = initialCoins
        self.correctAnswerCoinReward = correctAnswerCoinReward
        self.dailyRewardTiers = dailyRewardTiers
        self.rewardAd = rewardAd
    }
}

public struct QuizInterstitialEligibilityRules: Equatable, Sendable {
    public let numerator: Int
    public let denominator: Int

    public init(numerator: Int, denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

/// How a session orders the questions it has drawn.
///
/// Ordering is a variant choice rather than an engine constant, for the same
/// reason every other rule in this file is: a consumer that wants an easy-to-hard
/// ramp and a consumer that wants a pure shuffle are both right, and neither
/// should have to fork the builders to get it.
public enum QuizDifficultyProgression: String, Equatable, Sendable, CaseIterable, Codable {
    /// Shuffle only. The behaviour of every builder through `0.2.2`, and the
    /// default, so an existing consumer sees no change.
    case none
    /// Easiest first, hardest last, in proportion to the session's own length.
    case easyToHard
}

public struct QuizSessionRules: Equatable, Sendable {
    public let competitiveQuestionLimit: Int?
    public let categoryQuestionLimit: Int?
    public let practiceQuestionCount: Int
    public let practiceUnansweredRatio: Double
    public let multiplayerQuestionCount: Int
    /// Applies to the competitive, category, and practice builders.
    ///
    /// **Multiplayer is deliberately excluded.** A fixed match shared by two
    /// players has no meaningful ramp, and both sides must see one identical
    /// order regardless of either player's history.
    public let difficultyProgression: QuizDifficultyProgression

    /// `difficultyProgression` is defaulted so this stays source-compatible for
    /// every consumer built against `0.2.2` or earlier.
    public init(
        competitiveQuestionLimit: Int?,
        categoryQuestionLimit: Int?,
        practiceQuestionCount: Int,
        practiceUnansweredRatio: Double,
        multiplayerQuestionCount: Int,
        difficultyProgression: QuizDifficultyProgression = .none
    ) {
        self.competitiveQuestionLimit = competitiveQuestionLimit
        self.categoryQuestionLimit = categoryQuestionLimit
        self.practiceQuestionCount = practiceQuestionCount
        self.practiceUnansweredRatio = practiceUnansweredRatio
        self.multiplayerQuestionCount = multiplayerQuestionCount
        self.difficultyProgression = difficultyProgression
    }
}

public struct QuizMultiplayerScoringRules: Equatable, Sendable {
    public let fasterCorrectPoints: Int
    public let slowerCorrectPoints: Int
    public let tiedCorrectPoints: Int
    public let wrongAnswerPoints: Int

    public init(
        fasterCorrectPoints: Int,
        slowerCorrectPoints: Int,
        tiedCorrectPoints: Int,
        wrongAnswerPoints: Int
    ) {
        self.fasterCorrectPoints = fasterCorrectPoints
        self.slowerCorrectPoints = slowerCorrectPoints
        self.tiedCorrectPoints = tiedCorrectPoints
        self.wrongAnswerPoints = wrongAnswerPoints
    }
}

public struct QuizMultiplayerOutcomeRewards: Equatable, Sendable {
    public let win: Int
    public let loss: Int
    public let draw: Int
    public let opponentDisconnected: Int

    public init(win: Int, loss: Int, draw: Int, opponentDisconnected: Int) {
        self.win = win
        self.loss = loss
        self.draw = draw
        self.opponentDisconnected = opponentDisconnected
    }
}

public struct QuizMultiplayerRewardRules: Equatable, Sendable {
    public let correctAnswerCoins: Int
    public let standardOutcomeRewards: QuizMultiplayerOutcomeRewards
    public let premiumOutcomeRewards: QuizMultiplayerOutcomeRewards
    public let minimumQuestionsForAnyReward: Int
    public let minimumQuestionsForOutcomeBonus: Int
    public let questionsForFullOutcomeBonus: Int
    public let partialRewardDivisor: Int

    public init(
        correctAnswerCoins: Int,
        standardOutcomeRewards: QuizMultiplayerOutcomeRewards,
        premiumOutcomeRewards: QuizMultiplayerOutcomeRewards,
        minimumQuestionsForAnyReward: Int,
        minimumQuestionsForOutcomeBonus: Int,
        questionsForFullOutcomeBonus: Int,
        partialRewardDivisor: Int
    ) {
        self.correctAnswerCoins = correctAnswerCoins
        self.standardOutcomeRewards = standardOutcomeRewards
        self.premiumOutcomeRewards = premiumOutcomeRewards
        self.minimumQuestionsForAnyReward = minimumQuestionsForAnyReward
        self.minimumQuestionsForOutcomeBonus = minimumQuestionsForOutcomeBonus
        self.questionsForFullOutcomeBonus = questionsForFullOutcomeBonus
        self.partialRewardDivisor = partialRewardDivisor
    }
}

public struct QuizMultiplayerRules: Equatable, Sendable {
    public let timerDurationMilliseconds: Int
    public let tieThresholdMilliseconds: Int
    public let scoring: QuizMultiplayerScoringRules
    public let rewards: QuizMultiplayerRewardRules
    public let interstitialEligibility: QuizInterstitialEligibilityRules

    public init(
        timerDurationMilliseconds: Int,
        tieThresholdMilliseconds: Int,
        scoring: QuizMultiplayerScoringRules,
        rewards: QuizMultiplayerRewardRules,
        interstitialEligibility: QuizInterstitialEligibilityRules
    ) {
        self.timerDurationMilliseconds = timerDurationMilliseconds
        self.tieThresholdMilliseconds = tieThresholdMilliseconds
        self.scoring = scoring
        self.rewards = rewards
        self.interstitialEligibility = interstitialEligibility
    }
}

public struct QuizRulesConfiguration: Equatable, Sendable {
    public let economy: QuizEconomyRules
    public let solo: QuizSoloRules
    public let powerUps: QuizPowerUpRules
    public let extraLife: QuizExtraLifeRules
    public let sessions: QuizSessionRules
    public let soloInterstitialEligibility: QuizInterstitialEligibilityRules
    public let multiplayer: QuizMultiplayerRules

    public init(
        economy: QuizEconomyRules,
        solo: QuizSoloRules,
        powerUps: QuizPowerUpRules,
        extraLife: QuizExtraLifeRules,
        sessions: QuizSessionRules,
        soloInterstitialEligibility: QuizInterstitialEligibilityRules,
        multiplayer: QuizMultiplayerRules
    ) throws {
        self.economy = economy
        self.solo = solo
        self.powerUps = powerUps
        self.extraLife = extraLife
        self.sessions = sessions
        self.soloInterstitialEligibility = soloInterstitialEligibility
        self.multiplayer = multiplayer
        try validate()
    }

    public static let serbianCompatible: QuizRulesConfiguration = {
        let modes: Set<GameMode> = [.singlePlayer, .practice]
        let powerUpRules: [PowerUp: QuizPowerUpRule] = [
            .fiftyFifty: .init(coinCost: 35, allowedModes: modes, maximumUsesPerSession: 1),
            .skipQuestion: .init(coinCost: 40, allowedModes: modes, maximumUsesPerSession: 1),
            .timeFreeze: .init(coinCost: 25, allowedModes: modes, maximumUsesPerSession: 1),
            .streakShield: .init(coinCost: 25, allowedModes: modes, maximumUsesPerSession: 1)
        ]
        do {
            return try QuizRulesConfiguration(
                economy: QuizEconomyRules(
                    initialCoins: 100,
                    correctAnswerCoinReward: 1,
                    dailyRewardTiers: [
                        StreakTier(id: 0, dayRange: 0...1, reward: 10, label: "1"),
                        StreakTier(id: 1, dayRange: 2...3, reward: 15, label: "2-3"),
                        StreakTier(id: 2, dayRange: 4...6, reward: 20, label: "4-6"),
                        StreakTier(id: 3, dayRange: 7...13, reward: 30, label: "7-13"),
                        StreakTier(id: 4, dayRange: 14...29, reward: 40, label: "14-29"),
                        StreakTier(id: 5, dayRange: 30...Int.max, reward: 50, label: "30+")
                    ],
                    rewardAd: QuizRewardAdRules(coinReward: 25, cooldownSeconds: 6 * 60 * 60)
                ),
                solo: QuizSoloRules(
                    timerDurationSeconds: 15,
                    startingLives: 3,
                    scoring: QuizScoringRules(baseCorrectPoints: 10, streakCorrectPoints: 20, streakThreshold: 5)
                ),
                powerUps: QuizPowerUpRules(
                    rules: powerUpRules,
                    fiftyFiftyIncorrectAnswersRemoved: 2,
                    timeFreezeDurationSeconds: 10,
                    streakShieldMinimumStreak: 5
                ),
                extraLife: QuizExtraLifeRules(
                    coinCost: 50,
                    maximumUsesPerSession: 1,
                    allowsCoins: true,
                    allowsRewardedAd: true
                ),
                sessions: QuizSessionRules(
                    competitiveQuestionLimit: nil,
                    categoryQuestionLimit: nil,
                    practiceQuestionCount: 20,
                    practiceUnansweredRatio: 0.8,
                    multiplayerQuestionCount: 15
                ),
                soloInterstitialEligibility: QuizInterstitialEligibilityRules(numerator: 2, denominator: 5),
                multiplayer: QuizMultiplayerRules(
                    timerDurationMilliseconds: 10_000,
                    tieThresholdMilliseconds: 10,
                    scoring: QuizMultiplayerScoringRules(
                        fasterCorrectPoints: 10,
                        slowerCorrectPoints: 0,
                        tiedCorrectPoints: 5,
                        wrongAnswerPoints: -5
                    ),
                    rewards: QuizMultiplayerRewardRules(
                        correctAnswerCoins: 1,
                        standardOutcomeRewards: QuizMultiplayerOutcomeRewards(win: 5, loss: 2, draw: 3, opponentDisconnected: 5),
                        premiumOutcomeRewards: QuizMultiplayerOutcomeRewards(win: 8, loss: 3, draw: 5, opponentDisconnected: 8),
                        minimumQuestionsForAnyReward: 0,
                        minimumQuestionsForOutcomeBonus: 5,
                        questionsForFullOutcomeBonus: 10,
                        partialRewardDivisor: 2
                    ),
                    interstitialEligibility: QuizInterstitialEligibilityRules(numerator: 1, denominator: 2)
                )
            )
        } catch {
            preconditionFailure("Invalid Serbian-compatible QuizEngine rules: \(error)")
        }
    }()

    private func validate() throws {
        try validateNonnegative(economy.initialCoins, "economy.initialCoins")
        try validateNonnegative(economy.correctAnswerCoinReward, "economy.correctAnswerCoinReward")
        try validatePositive(economy.rewardAd.coinReward, "economy.rewardAd.coinReward")
        try validatePositive(economy.rewardAd.cooldownSeconds, "economy.rewardAd.cooldownSeconds")
        try validateDailyRewardTiers(economy.dailyRewardTiers)

        try validatePositive(solo.timerDurationSeconds, "solo.timerDurationSeconds")
        try validatePositive(solo.startingLives, "solo.startingLives")
        try validateNonnegative(solo.scoring.baseCorrectPoints, "solo.scoring.baseCorrectPoints")
        try validateNonnegative(solo.scoring.streakCorrectPoints, "solo.scoring.streakCorrectPoints")
        try validatePositive(solo.scoring.streakThreshold, "solo.scoring.streakThreshold")

        for powerUp in PowerUp.allCases {
            guard let rule = powerUps.rules[powerUp] else {
                throw QuizRulesValidationError.missingPowerUpRule(powerUp)
            }
            try validateNonnegative(rule.coinCost, "powerUps.\(powerUp.rawValue).coinCost")
            if rule.isEnabled {
                guard !rule.allowedModes.isEmpty, rule.maximumUsesPerSession > 0 else {
                    throw QuizRulesValidationError.invalidPowerUpEligibility(powerUp)
                }
            } else if rule.maximumUsesPerSession != 0 {
                throw QuizRulesValidationError.invalidPowerUpEligibility(powerUp)
            }
        }
        try validatePositive(powerUps.fiftyFiftyIncorrectAnswersRemoved, "powerUps.fiftyFiftyIncorrectAnswersRemoved")
        try validatePositive(powerUps.timeFreezeDurationSeconds, "powerUps.timeFreezeDurationSeconds")
        try validatePositive(powerUps.streakShieldMinimumStreak, "powerUps.streakShieldMinimumStreak")

        try validateNonnegative(extraLife.coinCost, "extraLife.coinCost")
        try validateNonnegative(extraLife.maximumUsesPerSession, "extraLife.maximumUsesPerSession")
        if extraLife.maximumUsesPerSession > 0, !extraLife.allowsCoins, !extraLife.allowsRewardedAd {
            throw QuizRulesValidationError.nonPositiveValue("extraLife funding methods")
        }
        if extraLife.allowsCoins {
            try validatePositive(extraLife.coinCost, "extraLife.coinCost")
        }

        try validateOptionalLimit(sessions.competitiveQuestionLimit, "sessions.competitiveQuestionLimit")
        try validateOptionalLimit(sessions.categoryQuestionLimit, "sessions.categoryQuestionLimit")
        try validatePositive(sessions.practiceQuestionCount, "sessions.practiceQuestionCount")
        guard (0...1).contains(sessions.practiceUnansweredRatio) else {
            throw QuizRulesValidationError.invalidSessionLimit("sessions.practiceUnansweredRatio")
        }
        try validatePositive(sessions.multiplayerQuestionCount, "sessions.multiplayerQuestionCount")

        try validateProbability(soloInterstitialEligibility, "soloInterstitialEligibility")
        try validatePositive(multiplayer.timerDurationMilliseconds, "multiplayer.timerDurationMilliseconds")
        try validateNonnegative(multiplayer.tieThresholdMilliseconds, "multiplayer.tieThresholdMilliseconds")
        guard multiplayer.tieThresholdMilliseconds <= multiplayer.timerDurationMilliseconds else {
            throw QuizRulesValidationError.invalidMultiplayerThresholds
        }
        try validateProbability(multiplayer.interstitialEligibility, "multiplayer.interstitialEligibility")
        try validateMultiplayerRewards(multiplayer.rewards)
    }

    private func validateMultiplayerRewards(_ rewards: QuizMultiplayerRewardRules) throws {
        try validateNonnegative(rewards.correctAnswerCoins, "multiplayer.rewards.correctAnswerCoins")
        for (name, values) in [
            ("standard", rewards.standardOutcomeRewards),
            ("premium", rewards.premiumOutcomeRewards)
        ] {
            try validateNonnegative(values.win, "multiplayer.rewards.\(name).win")
            try validateNonnegative(values.loss, "multiplayer.rewards.\(name).loss")
            try validateNonnegative(values.draw, "multiplayer.rewards.\(name).draw")
            try validateNonnegative(values.opponentDisconnected, "multiplayer.rewards.\(name).opponentDisconnected")
        }
        try validatePositive(rewards.partialRewardDivisor, "multiplayer.rewards.partialRewardDivisor")
        guard rewards.minimumQuestionsForAnyReward >= 0,
              rewards.minimumQuestionsForOutcomeBonus >= rewards.minimumQuestionsForAnyReward,
              rewards.questionsForFullOutcomeBonus >= rewards.minimumQuestionsForOutcomeBonus,
              rewards.questionsForFullOutcomeBonus <= sessions.multiplayerQuestionCount else {
            throw QuizRulesValidationError.invalidMultiplayerThresholds
        }
    }

    private func validateDailyRewardTiers(_ tiers: [StreakTier]) throws {
        guard let first = tiers.first, first.dayRange.lowerBound == 0 else {
            throw QuizRulesValidationError.invalidDailyRewardTiers("tiers must start at day 0")
        }
        var seenIDs = Set<Int>()
        var previousUpperBound: Int?
        for tier in tiers {
            guard seenIDs.insert(tier.id).inserted else {
                throw QuizRulesValidationError.invalidDailyRewardTiers("duplicate tier id \(tier.id)")
            }
            guard tier.reward >= 0 else {
                throw QuizRulesValidationError.invalidDailyRewardTiers("negative reward for tier \(tier.id)")
            }
            guard !tier.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw QuizRulesValidationError.invalidDailyRewardTiers("empty label for tier \(tier.id)")
            }
            if let previousUpperBound {
                guard previousUpperBound < Int.max,
                      tier.dayRange.lowerBound == previousUpperBound + 1 else {
                    throw QuizRulesValidationError.invalidDailyRewardTiers("tiers must be ordered, contiguous, and non-overlapping")
                }
            }
            previousUpperBound = tier.dayRange.upperBound
        }
        guard previousUpperBound == Int.max else {
            throw QuizRulesValidationError.invalidDailyRewardTiers("tiers must cover all streak days")
        }
    }

    private func validateProbability(_ rules: QuizInterstitialEligibilityRules, _ field: String) throws {
        guard rules.denominator > 0, (0...rules.denominator).contains(rules.numerator) else {
            throw QuizRulesValidationError.invalidProbability(field)
        }
    }

    private func validateOptionalLimit(_ value: Int?, _ field: String) throws {
        if let value, value <= 0 {
            throw QuizRulesValidationError.invalidSessionLimit(field)
        }
    }

    private func validatePositive<T: BinaryInteger>(_ value: T, _ field: String) throws {
        guard value > 0 else { throw QuizRulesValidationError.nonPositiveValue(field) }
    }

    private func validatePositive(_ value: TimeInterval, _ field: String) throws {
        guard value.isFinite, value > 0 else { throw QuizRulesValidationError.nonPositiveValue(field) }
    }

    private func validateNonnegative<T: BinaryInteger>(_ value: T, _ field: String) throws {
        guard value >= 0 else { throw QuizRulesValidationError.negativeValue(field) }
    }

    private func validateNonnegative(_ value: TimeInterval, _ field: String) throws {
        guard value.isFinite, value >= 0 else { throw QuizRulesValidationError.negativeValue(field) }
    }
}
