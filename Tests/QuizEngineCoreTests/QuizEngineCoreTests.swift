import XCTest
@testable import QuizEngineCore
import QuizEngineTestSupport

@MainActor
final class QuizEngineCoreTests: XCTestCase {
    private var service: QuestionDataService {
        QuestionDataService(bundle: .module, fileName: "alternate_questions")
    }

    private var achievementRules: [AchievementDefinition] {
        [
            .init(id: "streak", type: .streak, coinReward: 1, rule: .playStreak(minimum: 3)),
            .init(id: "score", type: .score, coinReward: 1, rule: .bestScore(minimum: 100)),
            .init(id: "answers", type: .accuracy, coinReward: 1, rule: .bestAnswerStreak(minimum: 5)),
            .init(id: "any_category", type: .category, coinReward: 1, rule: .anyCategoryCorrect(minimum: 2)),
            .init(id: "nature", type: .category, coinReward: 1, rule: .categoryCorrect(categoryID: "nature", minimum: 2)),
            .init(id: "two_categories", type: .category, coinReward: 1, rule: .categoriesCorrect(categoryCount: 2, minimumPerCategory: 2)),
            .init(id: "games", type: .lifetime, coinReward: 1, rule: .lifetimeGames(minimum: 10)),
            .init(id: "questions", type: .lifetime, coinReward: 1, rule: .lifetimeQuestions(minimum: 20)),
            .init(id: "coins", type: .lifetime, coinReward: 1, rule: .totalCoinsEarned(minimum: 30)),
            .init(id: "power_types", type: .powerUp, coinReward: 1, rule: .powerUpTypesUsed(minimum: 2)),
            .init(id: "power_count", type: .powerUp, coinReward: 1, rule: .lifetimePowerUpsUsed(minimum: 4)),
            .init(id: "comeback", type: .special, coinReward: 1, rule: .comeback(minimumDaysAway: 30)),
            .init(id: "night", type: .special, coinReward: 1, rule: .localHour(startInclusive: 0, endExclusive: 5))
        ]
    }

    private func makeAlternateVariant(
        categories: [QuizCategoryDefinition]? = nil,
        achievements: [AchievementDefinition]? = nil,
        fileName: String = "alternate_questions",
        rules: QuizRulesConfiguration = .serbianCompatible
    ) throws -> QuizVariantDefinition {
        try QuizVariantDefinition(
            categories: categories ?? [
                .init(id: "space", displayNameKey: "category.space", iconName: "moon", displayOrder: 1, unlockRequirement: .coins(amount: 25)),
                .init(id: "nature", displayNameKey: "category.nature", iconName: "leaf", displayOrder: 0, unlockRequirement: .free),
                .init(id: "future", displayNameKey: "category.future", iconName: "sparkles", displayOrder: 2, unlockRequirement: .categoryCompletion(categoryID: "nature", percentage: 50))
            ],
            achievements: achievements ?? achievementRules,
            questionResource: QuestionResource(bundle: .module, fileName: fileName),
            rules: rules
        )
    }

    private func makeRules(
        economy: QuizEconomyRules = QuizRulesConfiguration.serbianCompatible.economy,
        solo: QuizSoloRules = QuizRulesConfiguration.serbianCompatible.solo,
        powerUps: QuizPowerUpRules = QuizRulesConfiguration.serbianCompatible.powerUps,
        extraLife: QuizExtraLifeRules = QuizRulesConfiguration.serbianCompatible.extraLife,
        sessions: QuizSessionRules = QuizRulesConfiguration.serbianCompatible.sessions,
        soloInterstitial: QuizInterstitialEligibilityRules = QuizRulesConfiguration.serbianCompatible.soloInterstitialEligibility,
        multiplayer: QuizMultiplayerRules = QuizRulesConfiguration.serbianCompatible.multiplayer
    ) throws -> QuizRulesConfiguration {
        try QuizRulesConfiguration(
            economy: economy,
            solo: solo,
            powerUps: powerUps,
            extraLife: extraLife,
            sessions: sessions,
            soloInterstitialEligibility: soloInterstitial,
            multiplayer: multiplayer
        )
    }

    private var contentCategories: [QuizCategoryDefinition] {
        [
            .init(id: "space", displayNameKey: "category.space", iconName: "moon", displayOrder: 0, unlockRequirement: .free),
            .init(id: "nature", displayNameKey: "category.nature", iconName: "leaf", displayOrder: 1, unlockRequirement: .free)
        ]
    }

    private func validQuestion(
        id: Int = 1,
        categories: [String] = ["space"],
        answers: [Answer]? = nil,
        difficulty: Int = 1
    ) -> Question {
        Question(
            id: id,
            question: "Question \(id)",
            answers: answers ?? [
                .init(text: "Mercury", correct: true),
                .init(text: "Venus", correct: false),
                .init(text: "Earth", correct: false),
                .init(text: "Mars", correct: false)
            ],
            categories: categories,
            difficulty: difficulty
        )
    }

    func testContentValidationRejectsNonPositiveAndDuplicateQuestionIDs() {
        let result = QuizContentValidator.validate(
            QuestionData(questions: [
                validQuestion(id: 0),
                validQuestion(id: 0),
                validQuestion(id: 8),
                validQuestion(id: 8)
            ]),
            categories: contentCategories
        )

        XCTAssertEqual(
            result.issues,
            [
                .nonPositiveQuestionID(questionIndex: 0, id: 0),
                .nonPositiveQuestionID(questionIndex: 1, id: 0),
                .duplicateQuestionID(questionIndex: 1, id: 0),
                .duplicateQuestionID(questionIndex: 3, id: 8)
            ]
        )
    }

    func testContentValidationDoesNotImposeAnAppSpecificContentCount() {
        let result = QuizContentValidator.validate(
            QuestionData(questions: []),
            categories: contentCategories
        )

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.issues, [])
    }

    func testContentValidationRejectsMissingAndUnknownCategories() {
        let result = QuizContentValidator.validate(
            QuestionData(questions: [
                validQuestion(id: 1, categories: []),
                validQuestion(id: 2, categories: ["space", "SPACE", "unknown"])
            ]),
            categories: contentCategories
        )

        XCTAssertEqual(
            result.issues,
            [
                .missingCategories(questionIndex: 0),
                .unknownCategory(questionIndex: 1, categoryID: "SPACE"),
                .unknownCategory(questionIndex: 1, categoryID: "unknown")
            ]
        )
    }

    func testContentValidationRejectsAnswerCountBlankAndNormalizedDuplicateAnswers() {
        let result = QuizContentValidator.validate(
            QuestionData(questions: [
                validQuestion(id: 1, answers: [
                    .init(text: "Correct", correct: true),
                    .init(text: "Other", correct: false),
                    .init(text: "Third", correct: false)
                ]),
                validQuestion(id: 2, answers: [
                    .init(text: "Correct", correct: true),
                    .init(text: "  \n", correct: false),
                    .init(text: "Other", correct: false),
                    .init(text: "Third", correct: false)
                ]),
                validQuestion(id: 3, answers: [
                    .init(text: "New York", correct: true),
                    .init(text: "  new\t york ", correct: false),
                    .init(text: "Other", correct: false),
                    .init(text: "Third", correct: false)
                ])
            ]),
            categories: contentCategories
        )

        XCTAssertEqual(
            result.issues,
            [
                .invalidAnswerCount(questionIndex: 0, count: 3),
                .emptyAnswerText(questionIndex: 1, answerIndex: 1, text: "  \n"),
                .duplicateAnswerText(questionIndex: 2, answerIndex: 1, text: "  new\t york ")
            ]
        )
    }

    func testContentValidationRejectsInvalidCorrectAnswerCountsAndDifficultyBounds() {
        let result = QuizContentValidator.validate(
            QuestionData(questions: [
                validQuestion(
                    id: 1,
                    answers: [
                        .init(text: "A", correct: false),
                        .init(text: "B", correct: false),
                        .init(text: "C", correct: false),
                        .init(text: "D", correct: false)
                    ],
                    difficulty: 0
                ),
                validQuestion(
                    id: 2,
                    answers: [
                        .init(text: "A", correct: true),
                        .init(text: "B", correct: true),
                        .init(text: "C", correct: false),
                        .init(text: "D", correct: false)
                    ],
                    difficulty: 4
                )
            ]),
            categories: contentCategories
        )

        XCTAssertEqual(
            result.issues,
            [
                .invalidCorrectAnswerCount(questionIndex: 0, count: 0),
                .invalidDifficulty(questionIndex: 0, difficulty: 0),
                .invalidCorrectAnswerCount(questionIndex: 1, count: 2),
                .invalidDifficulty(questionIndex: 1, difficulty: 4)
            ]
        )
    }

    func testContentValidationRejectsDuplicateCategories() {
        let result = QuizContentValidator.validate(
            QuestionData(questions: [
                validQuestion(id: 1, categories: ["space", "space"])
            ]),
            categories: contentCategories
        )

        XCTAssertEqual(
            result.issues,
            [.duplicateCategory(questionIndex: 0, categoryID: "space")]
        )
    }

    func testQuestionStructureRulesDefineTheSingleSharedStructuralContract() {
        // These constants are the ones both the local validator and the multiplayer wire
        // validator resolve against; a second definition anywhere is the defect this guards.
        XCTAssertEqual(QuizQuestionStructureRules.requiredAnswerCount, 4)
        XCTAssertEqual(QuizQuestionStructureRules.requiredCorrectAnswerCount, 1)
        XCTAssertEqual(QuizQuestionStructureRules.difficultyRange, 1...3)

        XCTAssertTrue(QuizQuestionStructureRules.isBlank(""))
        XCTAssertTrue(QuizQuestionStructureRules.isBlank("  \n\t"))
        XCTAssertFalse(QuizQuestionStructureRules.isBlank("a"))

        XCTAssertEqual(
            QuizQuestionStructureRules.normalizedAnswerText("  New\t York "),
            QuizQuestionStructureRules.normalizedAnswerText("new york")
        )
        XCTAssertNotEqual(
            QuizQuestionStructureRules.normalizedAnswerText("New York"),
            QuizQuestionStructureRules.normalizedAnswerText("New Yorks")
        )

        for difficulty in [Int.min, 0, 4, Int.max] {
            XCTAssertFalse(QuizQuestionStructureRules.isValidDifficulty(difficulty), "\(difficulty)")
        }
        for difficulty in 1...3 {
            XCTAssertTrue(QuizQuestionStructureRules.isValidDifficulty(difficulty), "\(difficulty)")
        }
        for count in [0, 1, 2, 3, 5, 16] {
            XCTAssertFalse(QuizQuestionStructureRules.isValidAnswerCount(count), "\(count)")
        }
        XCTAssertTrue(QuizQuestionStructureRules.isValidAnswerCount(4))
    }

    func testQuestionStructureRulesReportEveryIssueInDeterministicOrder() {
        let issues = QuizQuestionStructureRules.issues(
            in: Question(
                id: -1,
                question: "Question",
                answers: [
                    Answer(text: "Same", correct: true),
                    Answer(text: " same ", correct: false),
                    Answer(text: "  ", correct: false)
                ],
                categories: ["space", "space", "  ", "unknown"],
                difficulty: 7
            ),
            allowedCategoryIDs: ["space", "nature"]
        )

        XCTAssertEqual(
            issues,
            [
                .nonPositiveID(id: -1),
                .duplicateCategory(categoryIndex: 1, categoryID: "space"),
                .blankCategory(categoryIndex: 2, categoryID: "  "),
                .unknownCategory(categoryIndex: 3, categoryID: "unknown"),
                .invalidAnswerCount(count: 3),
                .duplicateAnswerText(answerIndex: 1, text: " same "),
                .blankAnswerText(answerIndex: 2, text: "  "),
                .invalidDifficulty(difficulty: 7)
            ]
        )
    }

    func testContentValidationAcceptsValidContentAtDifficultyBounds() {
        let result = QuizContentValidator.validate(
            QuestionData(questions: [
                validQuestion(id: 1, categories: ["space", "nature"], difficulty: 1),
                validQuestion(id: 2, categories: ["nature"], difficulty: 3)
            ]),
            categories: contentCategories
        )

        XCTAssertTrue(result.isValid)
        XCTAssertEqual(result.issues, [])
    }

    func testContentValidationReportsAggregateIssuesInDeterministicOrder() {
        let result = QuizContentValidator.validate(
            QuestionData(questions: [
                validQuestion(
                    id: -1,
                    categories: ["unknown"],
                    answers: [
                        .init(text: "Same", correct: true),
                        .init(text: "same", correct: false),
                        .init(text: "", correct: false)
                    ],
                    difficulty: 9
                ),
                validQuestion(id: 3, categories: [])
            ]),
            categories: contentCategories
        )

        XCTAssertEqual(
            result.issues,
            [
                .nonPositiveQuestionID(questionIndex: 0, id: -1),
                .unknownCategory(questionIndex: 0, categoryID: "unknown"),
                .invalidAnswerCount(questionIndex: 0, count: 3),
                .duplicateAnswerText(questionIndex: 0, answerIndex: 1, text: "same"),
                .emptyAnswerText(questionIndex: 0, answerIndex: 2, text: ""),
                .invalidDifficulty(questionIndex: 0, difficulty: 9),
                .missingCategories(questionIndex: 1)
            ]
        )
    }

    func testExplicitQuestionResourceLoadsAlternateFile() throws {
        let data = try service.getQuestionData()
        XCTAssertEqual(data.questions.count, 3)
        XCTAssertEqual(try service.getAllCategories(), ["nature", "space"])
    }

    func testMissingQuestionResourceReportsConfiguredFilename() {
        let missing = QuestionDataService(bundle: .module, fileName: "not_the_default_name")
        XCTAssertThrowsError(try missing.getQuestionData()) { error in
            guard case QuestionDataError.fileNotFound(let name) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(name, "not_the_default_name")
        }
    }

    func testVariantSortsCategoriesAndSupportsDifferentIdentifiers() throws {
        let variant = try makeAlternateVariant()
        XCTAssertEqual(variant.categories.map(\.id), ["nature", "space", "future"])
        XCTAssertEqual(variant.category(id: "SPACE")?.coinCost, 25)
        XCTAssertNil(variant.category(id: "history"))
    }

    func testVariantValidationRejectsInvalidConfiguration() throws {
        let duplicate = try makeAlternateVariant().categories + [
            .init(id: "nature", displayNameKey: "category.duplicate", iconName: "leaf", displayOrder: 3, unlockRequirement: .free)
        ]
        XCTAssertThrowsError(try makeAlternateVariant(categories: duplicate)) { error in
            XCTAssertEqual(error as? QuizVariantValidationError, .duplicateCategoryID("nature"))
        }

        let duplicateOrder = [
            QuizCategoryDefinition(id: "nature", displayNameKey: "category.nature", iconName: "leaf", displayOrder: 0, unlockRequirement: .free),
            QuizCategoryDefinition(id: "space", displayNameKey: "category.space", iconName: "moon", displayOrder: 0, unlockRequirement: .free)
        ]
        XCTAssertThrowsError(try makeAlternateVariant(categories: duplicateOrder)) { error in
            XCTAssertEqual(error as? QuizVariantValidationError, .duplicateCategoryDisplayOrder(0))
        }

        let invalidUnlock = [
            QuizCategoryDefinition(id: "nature", displayNameKey: "category.nature", iconName: "leaf", displayOrder: 0, unlockRequirement: .categoryCompletion(categoryID: "missing", percentage: 50))
        ]
        XCTAssertThrowsError(try makeAlternateVariant(categories: invalidUnlock))

        let invalidAchievement = [
            AchievementDefinition(id: "missing_category", type: .category, coinReward: 1, rule: .categoryCorrect(categoryID: "missing", minimum: 1))
        ]
        XCTAssertThrowsError(try makeAlternateVariant(achievements: invalidAchievement))
        XCTAssertThrowsError(try makeAlternateVariant(fileName: " "))
    }

    func testSerbianCompatibleRulesSnapshotExistingBehavior() throws {
        let rules = QuizRulesConfiguration.serbianCompatible

        XCTAssertEqual(rules.economy.initialCoins, 100)
        XCTAssertEqual(rules.economy.correctAnswerCoinReward, 1)
        XCTAssertEqual(rules.economy.dailyRewardTiers, allStreakTiers)
        XCTAssertEqual(rules.economy.rewardAd, QuizRewardAdRules(coinReward: 25, cooldownSeconds: 21_600))
        XCTAssertEqual(rules.solo.timerDurationSeconds, 15)
        XCTAssertEqual(rules.solo.startingLives, 3)
        XCTAssertEqual(rules.solo.scoring, QuizScoringRules(baseCorrectPoints: 10, streakCorrectPoints: 20, streakThreshold: 5))
        XCTAssertEqual(rules.powerUps.rule(for: .fiftyFifty)?.coinCost, PowerUp.fiftyFifty.cost)
        XCTAssertEqual(rules.powerUps.rule(for: .skipQuestion)?.coinCost, PowerUp.skipQuestion.cost)
        XCTAssertEqual(rules.powerUps.rule(for: .timeFreeze)?.coinCost, PowerUp.timeFreeze.cost)
        XCTAssertEqual(rules.powerUps.rule(for: .streakShield)?.coinCost, PowerUp.streakShield.cost)
        XCTAssertEqual(rules.extraLife, QuizExtraLifeRules(coinCost: 50, maximumUsesPerSession: 1, allowsCoins: true, allowsRewardedAd: true))
        XCTAssertNil(rules.sessions.competitiveQuestionLimit)
        XCTAssertNil(rules.sessions.categoryQuestionLimit)
        XCTAssertEqual(rules.sessions.practiceQuestionCount, 20)
        XCTAssertEqual(rules.sessions.practiceUnansweredRatio, 0.8)
        XCTAssertEqual(rules.sessions.multiplayerQuestionCount, 15)
        XCTAssertEqual(rules.soloInterstitialEligibility, QuizInterstitialEligibilityRules(numerator: 2, denominator: 5))
        XCTAssertEqual(rules.multiplayer.timerDurationMilliseconds, 10_000)
        XCTAssertEqual(rules.multiplayer.tieThresholdMilliseconds, 10)
        XCTAssertEqual(rules.multiplayer.rewards.minimumQuestionsForAnyReward, 0)
        XCTAssertEqual(rules.multiplayer.rewards.minimumQuestionsForOutcomeBonus, 5)
        XCTAssertEqual(rules.multiplayer.rewards.questionsForFullOutcomeBonus, 10)
        XCTAssertEqual(rules.multiplayer.rewards.partialRewardDivisor, 2)

        let legacyVariant = try QuizVariantDefinition(
            categories: [],
            achievements: [],
            questionResource: QuestionResource(bundle: .module, fileName: "alternate_questions")
        )
        XCTAssertEqual(legacyVariant.rules, rules)
    }

    func testRulesValidationRejectsInvalidDomainValues() throws {
        let defaults = QuizRulesConfiguration.serbianCompatible

        XCTAssertThrowsError(
            try makeRules(
                economy: QuizEconomyRules(
                    initialCoins: -1,
                    correctAnswerCoinReward: defaults.economy.correctAnswerCoinReward,
                    dailyRewardTiers: defaults.economy.dailyRewardTiers,
                    rewardAd: defaults.economy.rewardAd
                )
            )
        ) { error in
            XCTAssertEqual(error as? QuizRulesValidationError, .negativeValue("economy.initialCoins"))
        }

        var incompletePowerUps = defaults.powerUps.rules
        incompletePowerUps.removeValue(forKey: .skipQuestion)
        XCTAssertThrowsError(
            try makeRules(
                powerUps: QuizPowerUpRules(
                    rules: incompletePowerUps,
                    fiftyFiftyIncorrectAnswersRemoved: 2,
                    timeFreezeDurationSeconds: 10,
                    streakShieldMinimumStreak: 5
                )
            )
        ) { error in
            XCTAssertEqual(error as? QuizRulesValidationError, .missingPowerUpRule(.skipQuestion))
        }

        XCTAssertThrowsError(
            try makeRules(
                economy: QuizEconomyRules(
                    initialCoins: 100,
                    correctAnswerCoinReward: 1,
                    dailyRewardTiers: [
                        StreakTier(id: 0, dayRange: 0...1, reward: 10, label: "1"),
                        StreakTier(id: 1, dayRange: 3...Int.max, reward: 20, label: "3+")
                    ],
                    rewardAd: defaults.economy.rewardAd
                )
            )
        ) { error in
            guard case .invalidDailyRewardTiers = error as? QuizRulesValidationError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(
            try makeRules(soloInterstitial: QuizInterstitialEligibilityRules(numerator: 2, denominator: 1))
        ) { error in
            XCTAssertEqual(error as? QuizRulesValidationError, .invalidProbability("soloInterstitialEligibility"))
        }

        XCTAssertThrowsError(
            try makeRules(
                sessions: QuizSessionRules(
                    competitiveQuestionLimit: 0,
                    categoryQuestionLimit: nil,
                    practiceQuestionCount: 20,
                    practiceUnansweredRatio: 0.8,
                    multiplayerQuestionCount: 15
                )
            )
        ) { error in
            XCTAssertEqual(error as? QuizRulesValidationError, .invalidSessionLimit("sessions.competitiveQuestionLimit"))
        }

        let invalidRewards = QuizMultiplayerRewardRules(
            correctAnswerCoins: 1,
            standardOutcomeRewards: defaults.multiplayer.rewards.standardOutcomeRewards,
            premiumOutcomeRewards: defaults.multiplayer.rewards.premiumOutcomeRewards,
            minimumQuestionsForAnyReward: 6,
            minimumQuestionsForOutcomeBonus: 5,
            questionsForFullOutcomeBonus: 10,
            partialRewardDivisor: 2
        )
        XCTAssertThrowsError(
            try makeRules(
                multiplayer: QuizMultiplayerRules(
                    timerDurationMilliseconds: 10_000,
                    tieThresholdMilliseconds: 10,
                    scoring: defaults.multiplayer.scoring,
                    rewards: invalidRewards,
                    interstitialEligibility: defaults.multiplayer.interstitialEligibility
                )
            )
        ) { error in
            XCTAssertEqual(error as? QuizRulesValidationError, .invalidMultiplayerThresholds)
        }
    }

    func testRulesValidationRejectsInvalidDurationsEligibilitySizesAndThresholds() throws {
        let defaults = QuizRulesConfiguration.serbianCompatible

        XCTAssertThrowsError(
            try makeRules(
                economy: QuizEconomyRules(
                    initialCoins: 100,
                    correctAnswerCoinReward: 1,
                    dailyRewardTiers: allStreakTiers,
                    rewardAd: QuizRewardAdRules(coinReward: 25, cooldownSeconds: 0)
                )
            )
        ) { error in
            XCTAssertEqual(error as? QuizRulesValidationError, .nonPositiveValue("economy.rewardAd.cooldownSeconds"))
        }

        var emptyEligibility = defaults.powerUps.rules
        emptyEligibility[.fiftyFifty] = QuizPowerUpRule(
            coinCost: 35,
            allowedModes: [],
            maximumUsesPerSession: 1
        )
        XCTAssertThrowsError(
            try makeRules(
                powerUps: QuizPowerUpRules(
                    rules: emptyEligibility,
                    fiftyFiftyIncorrectAnswersRemoved: 2,
                    timeFreezeDurationSeconds: 10,
                    streakShieldMinimumStreak: 5
                )
            )
        ) { error in
            XCTAssertEqual(error as? QuizRulesValidationError, .invalidPowerUpEligibility(.fiftyFifty))
        }

        XCTAssertThrowsError(
            try makeRules(
                extraLife: QuizExtraLifeRules(
                    coinCost: 0,
                    maximumUsesPerSession: 1,
                    allowsCoins: false,
                    allowsRewardedAd: false
                )
            )
        )

        XCTAssertThrowsError(
            try makeRules(
                sessions: QuizSessionRules(
                    competitiveQuestionLimit: nil,
                    categoryQuestionLimit: nil,
                    practiceQuestionCount: 20,
                    practiceUnansweredRatio: 1.01,
                    multiplayerQuestionCount: 15
                )
            )
        ) { error in
            XCTAssertEqual(error as? QuizRulesValidationError, .invalidSessionLimit("sessions.practiceUnansweredRatio"))
        }

        XCTAssertThrowsError(
            try makeRules(
                multiplayer: QuizMultiplayerRules(
                    timerDurationMilliseconds: 100,
                    tieThresholdMilliseconds: 101,
                    scoring: defaults.multiplayer.scoring,
                    rewards: defaults.multiplayer.rewards,
                    interstitialEligibility: defaults.multiplayer.interstitialEligibility
                )
            )
        ) { error in
            XCTAssertEqual(error as? QuizRulesValidationError, .invalidMultiplayerThresholds)
        }
    }

    func testCustomRulesDriveFreshEconomyCooldownAndSessionSelection() throws {
        let defaults = QuizRulesConfiguration.serbianCompatible
        let twoQuestionMultiplayer = QuizMultiplayerRules(
            timerDurationMilliseconds: defaults.multiplayer.timerDurationMilliseconds,
            tieThresholdMilliseconds: defaults.multiplayer.tieThresholdMilliseconds,
            scoring: defaults.multiplayer.scoring,
            rewards: QuizMultiplayerRewardRules(
                correctAnswerCoins: defaults.multiplayer.rewards.correctAnswerCoins,
                standardOutcomeRewards: defaults.multiplayer.rewards.standardOutcomeRewards,
                premiumOutcomeRewards: defaults.multiplayer.rewards.premiumOutcomeRewards,
                minimumQuestionsForAnyReward: 0,
                minimumQuestionsForOutcomeBonus: 1,
                questionsForFullOutcomeBonus: 2,
                partialRewardDivisor: defaults.multiplayer.rewards.partialRewardDivisor
            ),
            interstitialEligibility: defaults.multiplayer.interstitialEligibility
        )
        let customRules = try makeRules(
            economy: QuizEconomyRules(
                initialCoins: 250,
                correctAnswerCoinReward: 4,
                dailyRewardTiers: [StreakTier(id: 0, dayRange: 0...Int.max, reward: 7, label: "all")],
                rewardAd: QuizRewardAdRules(coinReward: 9, cooldownSeconds: 30)
            ),
            powerUps: QuizPowerUpRules(
                rules: defaults.powerUps.rules.merging([
                    .timeFreeze: QuizPowerUpRule(
                        coinCost: 11,
                        allowedModes: [.singlePlayer, .practice],
                        maximumUsesPerSession: 1
                    )
                ]) { _, replacement in replacement },
                fiftyFiftyIncorrectAnswersRemoved: 2,
                timeFreezeDurationSeconds: 10,
                streakShieldMinimumStreak: 5
            ),
            sessions: QuizSessionRules(
                competitiveQuestionLimit: 2,
                categoryQuestionLimit: 1,
                practiceQuestionCount: 2,
                practiceUnansweredRatio: 1,
                multiplayerQuestionCount: 2
            ),
            multiplayer: twoQuestionMultiplayer
        )
        let variant = try makeAlternateVariant(rules: customRules)
        let questionService = QuestionDataService(
            variant: variant,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 90)
        )
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let manager = try PlayerProgressManager(
            variant: variant,
            questionDataService: questionService,
            persistenceStore: FakePersistenceStore(),
            clock: clock,
            calendar: utcCalendar
        )

        XCTAssertEqual(manager.coins, 250)
        XCTAssertEqual(manager.dailyRewardAmount, 7)
        XCTAssertEqual(manager.powerUpCost(for: .timeFreeze), 11)
        XCTAssertEqual(manager.consumePowerUp(.timeFreeze)?.coinsSpent, 11)
        XCTAssertEqual(try questionService.getQuestionsForCompetitiveMode().count, 2)
        XCTAssertEqual(try questionService.getQuestionsForCategoryMode(category: "nature").count, 1)
        XCTAssertEqual(
            try questionService.getQuestionsForPracticeMode(category: nil, correctlyAnsweredIDs: []).questions.count,
            2
        )
        XCTAssertEqual(try questionService.getQuestionsForMultiplayerMatch().count, 2)

        XCTAssertEqual(
            manager.recordRewardedAdReward(
                RewardedAdRewardRequest(
                    receiptID: "custom-rules-ad-1",
                    rewardVersion: "rewarded-ad-v1",
                    coinAmount: 9
                )
            ),
            .recorded
        )
        XCTAssertEqual(manager.coins, 248)
        XCTAssertFalse(manager.canWatchRewardAd())
        XCTAssertEqual(manager.timeUntilNextRewardAd(), 30)
        clock.advance(by: 30)
        XCTAssertTrue(manager.canWatchRewardAd())
    }

    func testConfiguredPracticeSelectionHandlesMaximumSessionSizeWithoutOverflow() throws {
        let defaults = QuizRulesConfiguration.serbianCompatible
        let rules = try makeRules(
            sessions: QuizSessionRules(
                competitiveQuestionLimit: nil,
                categoryQuestionLimit: nil,
                practiceQuestionCount: Int.max,
                practiceUnansweredRatio: 1,
                multiplayerQuestionCount: defaults.sessions.multiplayerQuestionCount
            )
        )
        let service = QuestionDataService(
            resource: QuestionResource(bundle: .module, fileName: "alternate_questions"),
            rules: rules,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 91)
        )

        let result = try service.getQuestionsForPracticeMode(
            category: nil,
            correctlyAnsweredIDs: []
        )

        XCTAssertEqual(result.questions.count, 3)
        XCTAssertEqual(result.totalInCategory, 3)
        XCTAssertEqual(result.correctlyAnsweredCount, 0)
    }

    func testLegacyMissingCoinFieldKeepsOneHundredDespiteCustomFreshBalance() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["lifetimeGamesPlayed": 3],
            format: .binary,
            options: 0
        )
        let customRules = try makeRules(
            economy: QuizEconomyRules(
                initialCoins: 999,
                correctAnswerCoinReward: 1,
                dailyRewardTiers: allStreakTiers,
                rewardAd: QuizRewardAdRules(coinReward: 25, cooldownSeconds: 21_600)
            )
        )
        let variant = try makeAlternateVariant(rules: customRules)
        let manager = try PlayerProgressManager(
            variant: variant,
            questionDataService: QuestionDataService(variant: variant),
            persistenceStore: FakePersistenceStore(primaryData: data)
        )

        XCTAssertEqual(manager.coins, 100)
        XCTAssertEqual(manager.progress.totalCoinsEarned, 100)
        XCTAssertEqual(manager.progress.lifetimeGamesPlayed, 3)
    }

    func testConfiguredRewardsDoNotOverflowPersistedBalances() throws {
        let defaults = QuizRulesConfiguration.serbianCompatible
        let rules = try makeRules(
            economy: QuizEconomyRules(
                initialCoins: Int.max,
                correctAnswerCoinReward: 1,
                dailyRewardTiers: [StreakTier(id: 0, dayRange: 0...Int.max, reward: 1, label: "all")],
                rewardAd: defaults.economy.rewardAd
            )
        )
        let variant = try makeAlternateVariant(rules: rules)
        let manager = try PlayerProgressManager(
            variant: variant,
            questionDataService: QuestionDataService(variant: variant),
            persistenceStore: FakePersistenceStore(),
            clock: TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000)),
            calendar: utcCalendar
        )

        XCTAssertNil(manager.claimDailyReward())
        manager.recordMultiplayerResult(
            won: true,
            draw: false,
            score: 10,
            questionsCompleted: 1,
            questionsCorrect: 1,
            coinsEarned: 1,
            responseTimes: [100]
        )

        XCTAssertEqual(manager.coins, Int.max)
        XCTAssertEqual(manager.progress.totalCoinsEarned, Int.max)
        XCTAssertEqual(manager.progress.multiplayerGamesPlayed, 0)
        XCTAssertNil(manager.progress.lastDailyRewardClaimedDate)
    }

    func testMultiplayerReceiptRecordsRewardsExactlyOnceAndSurvivesReload() throws {
        let variant = try makeAlternateVariant()
        let store = FakePersistenceStore()
        let manager = try PlayerProgressManager(
            variant: variant,
            questionDataService: QuestionDataService(variant: variant),
            persistenceStore: store
        )

        let first = manager.recordMultiplayerResult(
            matchID: "match-1", fingerprint: "result-a", won: true, draw: false,
            score: 10, questionsCompleted: 2, questionsCorrect: 2,
            coinsEarned: 5, responseTimes: [100, 200]
        )
        XCTAssertEqual(first, .recorded)
        XCTAssertEqual(manager.recordMultiplayerResult(
            matchID: "match-1", fingerprint: "result-a", won: true, draw: false,
            score: 10, questionsCompleted: 2, questionsCorrect: 2,
            coinsEarned: 5, responseTimes: [100, 200]
        ), .alreadyRecorded)
        XCTAssertEqual(manager.recordMultiplayerResult(
            matchID: "match-1", fingerprint: "tampered", won: false, draw: false,
            score: 0, questionsCompleted: 0, questionsCorrect: 0,
            coinsEarned: 0, responseTimes: []
        ), .conflictingReceipt)
        XCTAssertEqual(manager.progress.multiplayerGamesPlayed, 1)
        XCTAssertEqual(manager.progress.coins, 105)

        let reloaded = try PlayerProgressManager(
            variant: variant,
            questionDataService: QuestionDataService(variant: variant),
            persistenceStore: store
        )
        XCTAssertEqual(reloaded.recordMultiplayerResult(
            matchID: "match-1", fingerprint: "result-a", won: true, draw: false,
            score: 10, questionsCompleted: 2, questionsCorrect: 2,
            coinsEarned: 5, responseTimes: [100, 200]
        ), .alreadyRecorded)
        XCTAssertEqual(reloaded.progress.multiplayerGamesPlayed, 1)

        XCTAssertEqual(reloaded.recordMultiplayerResult(
            matchID: "match-negative", fingerprint: "loss", won: false, draw: false,
            score: -5, questionsCompleted: 1, questionsCorrect: 0,
            coinsEarned: 0, responseTimes: [100]
        ), .recorded)
        XCTAssertEqual(reloaded.progress.multiplayerGamesLost, 1)
    }

    func testEveryAchievementRuleUnlocksAtExactAndAboveThresholdAndReportsProgress() throws {
        let variant = try makeAlternateVariant()
        let achievementService = AchievementService(variant: variant)
        let calendar = utcCalendar
        let outsideNightWindow = date(hour: 12, calendar: calendar)

        for definition in variant.achievements {
            XCTAssertFalse(
                achievementService.checkAchievements(
                    progress: belowThresholdProgress,
                    date: outsideNightWindow,
                    calendar: calendar
                ).contains(where: { $0.id == definition.id }),
                "Expected \(definition.id) to remain locked below threshold"
            )

            let exact = progress(for: definition.rule, increase: 0, date: outsideNightWindow, calendar: calendar)
            let exactDate = evaluationDate(for: definition.rule, calendar: calendar, above: false)
            XCTAssertTrue(
                achievementService.checkAchievements(progress: exact, date: exactDate, calendar: calendar)
                    .contains(where: { $0.id == definition.id }),
                "Expected \(definition.id) to unlock at threshold"
            )

            let above = progress(for: definition.rule, increase: 1, date: outsideNightWindow, calendar: calendar)
            let aboveDate = evaluationDate(for: definition.rule, calendar: calendar, above: true)
            XCTAssertTrue(
                achievementService.checkAchievements(progress: above, date: aboveDate, calendar: calendar)
                    .contains(where: { $0.id == definition.id }),
                "Expected \(definition.id) to unlock above threshold"
            )

            if let progress = achievementService.getProgress(for: definition, progress: exact) {
                XCTAssertEqual(progress.current, progress.target, "Expected exact progress for \(definition.id)")
            } else {
                switch definition.rule {
                case .comeback, .localHour:
                    break
                default:
                    XCTFail("Expected numeric progress for \(definition.id)")
                }
            }
        }
    }

    func testAchievementRulesIgnoreStaleCategoryProgress() throws {
        let variant = try makeAlternateVariant()
        let service = AchievementService(variant: variant)
        var progress = PlayerProgress.default
        progress.categoryStats = [
            "stale": CategoryStat(correctlyAnsweredIDs: Set(1...100)),
            "nature": CategoryStat(correctlyAnsweredIDs: [1])
        ]

        let anyCategory = AchievementDefinition(id: "any", type: .category, coinReward: 1, rule: .anyCategoryCorrect(minimum: 2))
        let categories = AchievementDefinition(id: "categories", type: .category, coinReward: 1, rule: .categoriesCorrect(categoryCount: 2, minimumPerCategory: 1))
        XCTAssertEqual(service.getProgress(for: anyCategory, progress: progress)?.current, 1)
        XCTAssertEqual(service.getProgress(for: categories, progress: progress)?.current, 1)
    }

    func testCategoryUnlockRulesUseVariantDefinitionsAndRejectUnknownPremiumIDs() throws {
        let variant = try makeAlternateVariant()
        let persistence = try TemporaryPersistence()
        let manager = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            purchaseStatus: PremiumPurchaseStatus(),
            persistenceURL: persistence.progressURL
        )

        XCTAssertTrue(manager.isCategoryUnlocked("nature"))
        XCTAssertTrue(manager.isCategoryUnlocked("space"))
        XCTAssertFalse(manager.isCategoryUnlocked("unknown"))
        XCTAssertEqual(manager.getUnlockProgress(for: "space").coinCost, 25)
        XCTAssertFalse(manager.getUnlockProgress(for: "unknown").isUnlocked)
    }

    func testLegacyProgressPlistPreservesStoredIdentifiersAndDefaultsNewFields() throws {
        let legacy: [String: Any] = [
            "coins": 321,
            "unlockedAchievements": ["legacy_achievement"],
            "manuallyUnlockedCategories": ["legacy_category"],
            "lifetimeGamesPlayed": 9
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: legacy, format: .xml, options: 0)
        let decoded = try PropertyListDecoder().decode(PlayerProgress.self, from: data)

        XCTAssertEqual(decoded.coins, 321)
        XCTAssertEqual(decoded.unlockedAchievements, ["legacy_achievement"])
        XCTAssertEqual(decoded.manuallyUnlockedCategories, ["legacy_category"])
        XCTAssertEqual(decoded.lifetimeGamesPlayed, 9)
        XCTAssertEqual(decoded.multiplayerGamesPlayed, 0)
        XCTAssertTrue(decoded.powerUpCredits.isEmpty)
    }

    func testPowerUpCreditsAreIndependentAndConsumedBeforeCoins() throws {
        let manager = try makeManager(store: FakePersistenceStore())

        for powerUp in PowerUp.allCases {
            XCTAssertTrue(manager.grantPowerUpCredits(1, for: powerUp))
            XCTAssertEqual(manager.powerUpCredits(for: powerUp), 1)
        }

        for powerUp in PowerUp.allCases {
            XCTAssertEqual(
                manager.consumePowerUp(powerUp),
                PowerUpSpendResult(
                    powerUp: powerUp,
                    fundingSource: .freeCredit,
                    coinsSpent: 0
                )
            )
            XCTAssertEqual(manager.powerUpCredits(for: powerUp), 0)
        }
        XCTAssertEqual(manager.coins, 100)
        XCTAssertEqual(manager.progress.totalCoinsSpent, 0)

        XCTAssertEqual(
            manager.consumePowerUp(.fiftyFifty),
            PowerUpSpendResult(
                powerUp: .fiftyFifty,
                fundingSource: .coins,
                coinsSpent: PowerUp.fiftyFifty.cost
            )
        )
        XCTAssertEqual(manager.coins, 100 - PowerUp.fiftyFifty.cost)
        XCTAssertEqual(manager.progress.totalCoinsSpent, PowerUp.fiftyFifty.cost)
        XCTAssertEqual(manager.progress.lifetimePowerUpsUsed, 5)
    }

    func testPowerUpConsumptionFailsWhenCreditsAndCoinsAreUnavailable() throws {
        let manager = try makeManager(store: FakePersistenceStore())
        XCTAssertTrue(manager.spendCoins(manager.coins))

        XCTAssertFalse(manager.canFundPowerUp(.skipQuestion))
        XCTAssertNil(manager.consumePowerUp(.skipQuestion))
        XCTAssertEqual(manager.coins, 0)
        XCTAssertEqual(manager.powerUpCredits(for: .skipQuestion), 0)
        XCTAssertNil(manager.progress.lifetimePowerUpsUsed)
    }

    func testPowerUpCreditsSurviveSaveAndReload() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)
        XCTAssertTrue(manager.grantPowerUpCredits(3, for: .fiftyFifty))
        XCTAssertTrue(manager.grantPowerUpCredits(4, for: .skipQuestion))

        let reloaded = try makeManager(store: store)

        XCTAssertEqual(reloaded.powerUpCredits(for: .fiftyFifty), 3)
        XCTAssertEqual(reloaded.powerUpCredits(for: .skipQuestion), 4)
        XCTAssertEqual(reloaded.powerUpCredits(for: .timeFreeze), 0)
        XCTAssertEqual(reloaded.coins, 100)
    }

    func testPowerUpCreditGrantRejectsInvalidAmountsAndOverflow() throws {
        var maxCreditProgress = PlayerProgress.default
        maxCreditProgress.powerUpCredits[.skipQuestion] = Int.max
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(maxCreditProgress)
        )
        let manager = try makeManager(store: store)

        XCTAssertFalse(manager.grantPowerUpCredits(0, for: .skipQuestion))
        XCTAssertFalse(manager.grantPowerUpCredits(-1, for: .skipQuestion))
        XCTAssertFalse(manager.grantPowerUpCredits(1, for: .skipQuestion))
        XCTAssertEqual(manager.powerUpCredits(for: .skipQuestion), Int.max)
        XCTAssertEqual(manager.coins, 100)
    }

    func testVersionedProgressWithoutPowerUpCreditsDefaultsToEmptyWallet() throws {
        let encoded = try PersistenceDocumentCodec.encode(PlayerProgress.default)
        var document = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: encoded, options: [], format: nil) as? [String: Any]
        )
        var payload = try XCTUnwrap(document["payload"] as? [String: Any])
        payload.removeValue(forKey: "powerUpCredits")
        document["payload"] = payload
        let versionedData = try PropertyListSerialization.data(
            fromPropertyList: document,
            format: .binary,
            options: 0
        )

        let manager = try makeManager(store: FakePersistenceStore(primaryData: versionedData))

        XCTAssertEqual(
            manager.persistenceStatus,
            .loaded(schemaVersion: QuizEnginePersistenceSchema.current)
        )
        XCTAssertTrue(manager.progress.powerUpCredits.isEmpty)
    }

    func testNegativePersistedPowerUpCreditIsRejectedAsMalformed() throws {
        var invalidProgress = PlayerProgress.default
        invalidProgress.powerUpCredits[.fiftyFifty] = -1
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(invalidProgress)
        )

        XCTAssertThrowsError(try makeManager(store: store)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .malformedData(path: store.primaryURL.path)
            )
        }
    }

    func testQuestionSelectionUsesInjectedRandomNumberGenerator() throws {
        let first = QuestionDataService(
            bundle: .module,
            fileName: "alternate_questions",
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 123)
        )
        let second = QuestionDataService(
            bundle: .module,
            fileName: "alternate_questions",
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 123)
        )

        XCTAssertEqual(
            try first.getQuestionsForCompetitiveMode().map(\.id),
            try second.getQuestionsForCompetitiveMode().map(\.id)
        )
    }

    func testIdenticalSeedsProduceIdenticalSelectionAcrossEverySessionBuilder() throws {
        let first = QuestionDataService(
            bundle: .module,
            fileName: "alternate_questions",
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 4_242)
        )
        let second = QuestionDataService(
            bundle: .module,
            fileName: "alternate_questions",
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 4_242)
        )

        XCTAssertEqual(
            try first.getQuestionsForCompetitiveMode().map(\.id),
            try second.getQuestionsForCompetitiveMode().map(\.id)
        )
        XCTAssertEqual(
            try first.getQuestionsForCategoryMode(category: "nature").map(\.id),
            try second.getQuestionsForCategoryMode(category: "nature").map(\.id)
        )
        XCTAssertEqual(
            try first.getQuestionsForPracticeMode(
                category: nil,
                correctlyAnsweredIDs: [1]
            ).questions.map(\.id),
            try second.getQuestionsForPracticeMode(
                category: nil,
                correctlyAnsweredIDs: [1]
            ).questions.map(\.id)
        )
        XCTAssertEqual(
            try first.getQuestionsForMultiplayerMatch(count: 2).map(\.id),
            try second.getQuestionsForMultiplayerMatch(count: 2).map(\.id)
        )
    }

    func testClockRollbackCannotAdvanceCalendarRulesOrCooldowns() throws {
        let calendar = utcCalendar
        let initialDate = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 4, hour: 12)
        )!
        let clock = TestClock(now: initialDate)
        let variant = try makeAlternateVariant()
        let manager = try PlayerProgressManager(
            variant: variant,
            questionDataService: QuestionDataService(variant: variant),
            persistenceStore: FakePersistenceStore(),
            clock: clock,
            calendar: calendar
        )

        manager.handleAppOpen()
        manager.updatePlayStreak()
        XCTAssertNotNil(manager.claimDailyReward())
        XCTAssertEqual(
            manager.recordRewardedAdReward(
                RewardedAdRewardRequest(
                    receiptID: "clock-rollback-ad-1",
                    rewardVersion: "rewarded-ad-v1",
                    coinAmount: variant.rules.economy.rewardAd.coinReward
                )
            ),
            .recorded
        )
        let coinsAfterRewards = manager.coins

        clock.setNow(initialDate.addingTimeInterval(-86_400))
        manager.handleAppOpen()
        manager.updatePlayStreak()

        XCTAssertEqual(manager.currentStreak, 1)
        XCTAssertEqual(manager.progress.currentPlayStreak, 1)
        XCTAssertNil(manager.claimDailyReward())
        XCTAssertFalse(manager.canWatchRewardAd())
        XCTAssertEqual(
            manager.timeUntilNextRewardAd(),
            variant.rules.economy.rewardAd.cooldownSeconds
        )
        XCTAssertEqual(manager.coins, coinsAfterRewards)
    }

    func testCalendarDayRulesCrossSpringAndFallDSTWithoutElapsedDayAssumptions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let variant = try makeAlternateVariant()

        for (start, next) in [
            (
                DateComponents(year: 2026, month: 3, day: 7, hour: 12),
                DateComponents(year: 2026, month: 3, day: 8, hour: 12)
            ),
            (
                DateComponents(year: 2026, month: 10, day: 31, hour: 12),
                DateComponents(year: 2026, month: 11, day: 1, hour: 12)
            )
        ] {
            let clock = TestClock(now: calendar.date(from: start)!)
            let manager = try PlayerProgressManager(
                variant: variant,
                questionDataService: QuestionDataService(variant: variant),
                persistenceStore: FakePersistenceStore(),
                clock: clock,
                calendar: calendar
            )
            manager.handleAppOpen()
            manager.updatePlayStreak()
            XCTAssertNotNil(manager.claimDailyReward())

            clock.setNow(calendar.date(from: next)!)
            manager.handleAppOpen()
            manager.updatePlayStreak()

            XCTAssertEqual(manager.currentStreak, 2)
            XCTAssertEqual(manager.progress.currentPlayStreak, 2)
            XCTAssertNotNil(manager.claimDailyReward())
        }
    }

    func testInjectedCalendarAndTimeZoneDriveStatisticsAndAchievements() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let date = tokyo.date(
            from: DateComponents(year: 2026, month: 8, day: 5, hour: 2)
        )!
        let clock = TestClock(now: date)
        let variant = try makeAlternateVariant()
        let achievementService = AchievementService(
            variant: variant,
            clock: clock,
            calendar: tokyo
        )
        let session = PlayerProgressManager.SessionStatistics(clock: clock, calendar: tokyo)

        XCTAssertEqual(PlayerProgress.dateKey(for: date, calendar: tokyo), "2026-08-05")
        XCTAssertEqual(PlayerProgress.hour(for: date, calendar: tokyo), 2)
        XCTAssertEqual(session.sessionHour, 2)
        XCTAssertTrue(
            achievementService.checkAchievements(progress: .default)
                .contains(where: { $0.id == "night" })
        )
    }

    func testProgressManagerUsesTemporaryPersistenceAndInjectedTime() throws {
        let persistence = try TemporaryPersistence()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let clock = TestClock(now: calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 12))!)
        let variant = try makeAlternateVariant()

        let manager = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            persistenceURL: persistence.progressURL,
            clock: clock,
            calendar: calendar
        )
        manager.handleAppOpen()
        XCTAssertEqual(manager.currentStreak, 1)
        XCTAssertEqual(manager.claimDailyReward(), 10)

        clock.advance(by: 24 * 60 * 60)
        manager.handleAppOpen()
        XCTAssertEqual(manager.currentStreak, 2)
        XCTAssertEqual(manager.claimDailyReward(), 15)

        let reloaded = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            persistenceURL: persistence.progressURL,
            clock: clock,
            calendar: calendar
        )
        XCTAssertEqual(reloaded.currentStreak, 2)
        XCTAssertEqual(reloaded.coins, 125)
    }

    func testUserPreferencesCanUseTemporaryPersistence() throws {
        let persistence = try TemporaryPersistence()
        let preferences = UserPreferences(hapticsEnabled: false)

        UserPreferencesLoader.write(preferences: preferences, to: persistence.preferencesURL)

        XCTAssertFalse(UserPreferencesLoader.load(from: persistence.preferencesURL).hapticsEnabled)
    }

    func testVersionedProgressWriteReloadsThroughInjectedStore() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)

        manager.addCoins(25)

        XCTAssertEqual(manager.persistenceStatus, .saved)
        XCTAssertNil(manager.lastPersistenceError)
        XCTAssertNotNil(store.primaryData)

        let reloaded = try makeManager(store: store)
        XCTAssertEqual(reloaded.coins, 125)
        XCTAssertEqual(
            reloaded.persistenceStatus,
            .loaded(schemaVersion: QuizEnginePersistenceSchema.current)
        )

        let propertyList = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: try XCTUnwrap(store.primaryData), options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(propertyList["schemaVersion"] as? Int, QuizEnginePersistenceSchema.current)
    }

    func testFileStoreLeavesBackupAndCleansTemporaryFilesAfterReplacement() throws {
        let persistence = try TemporaryPersistence()
        let variant = try makeAlternateVariant()
        let manager = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            persistenceURL: persistence.progressURL
        )

        manager.addCoins(1)
        manager.addCoins(1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.progressURL.path + ".backup"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.progressURL.path + ".tmp"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.progressURL.path + ".backup.tmp"))

        try Data("stale primary temp".utf8).write(to: URL(fileURLWithPath: persistence.progressURL.path + ".tmp"))
        try Data("stale backup temp".utf8).write(to: URL(fileURLWithPath: persistence.progressURL.path + ".backup.tmp"))
        try Data("stale marker temp".utf8).write(to: URL(fileURLWithPath: persistence.progressURL.path + ".import-marker.tmp"))
        _ = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            persistenceURL: persistence.progressURL
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.progressURL.path + ".tmp"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.progressURL.path + ".backup.tmp"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.progressURL.path + ".import-marker.tmp"))
    }

    func testLegacyProgressLoadsAndNextSavePromotesToVersionedEnvelope() throws {
        var legacyProgress = PlayerProgress.default
        legacyProgress.coins = 321
        let legacyData = try PropertyListEncoder().encode(legacyProgress)
        let store = FakePersistenceStore(primaryData: legacyData)

        let manager = try makeManager(store: store)
        XCTAssertEqual(manager.coins, 321)
        XCTAssertEqual(manager.persistenceStatus, .loadedLegacy)

        manager.addCoins(1)

        let propertyList = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: try XCTUnwrap(store.primaryData), options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(propertyList["schemaVersion"] as? Int, QuizEnginePersistenceSchema.current)
        XCTAssertEqual(manager.coins, 322)
    }

    func testCompatibilityInitializerExposesMalformedPersistenceWithoutThrowing() throws {
        let persistence = try TemporaryPersistence()
        try Data("malformed".utf8).write(to: persistence.progressURL)
        let variant = try makeAlternateVariant()

        let manager = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            persistenceURL: persistence.progressURL
        )

        XCTAssertEqual(manager.progress, .default)
        guard case .failed(.malformedData) = manager.persistenceStatus else {
            return XCTFail("Expected a typed malformed-data status")
        }
        XCTAssertEqual(manager.lastPersistenceError, .malformedData(path: persistence.progressURL.path))
    }

    func testCompatibilityMutatorDoesNotOverwriteUnrecoverablePersistence() throws {
        let persistence = try TemporaryPersistence()
        let malformedData = Data("malformed".utf8)
        try malformedData.write(to: persistence.progressURL)
        let manager = PlayerProgressManager(
            variant: try makeAlternateVariant(),
            questionDataService: service,
            persistenceURL: persistence.progressURL
        )

        manager.addCoins(20)

        XCTAssertEqual(manager.progress, .default)
        XCTAssertEqual(try Data(contentsOf: persistence.progressURL), malformedData)
        XCTAssertEqual(manager.lastPersistenceError, .malformedData(path: persistence.progressURL.path))
    }

    func testThrowingInitializerReportsMalformedPersistence() throws {
        let store = FakePersistenceStore(primaryData: Data("malformed".utf8))

        XCTAssertThrowsError(try makeManager(store: store)) { error in
            guard case PersistenceError.malformedData = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCorruptPrimaryRecoversFromValidBackup() throws {
        var backupProgress = PlayerProgress.default
        backupProgress.coins = 777
        let store = FakePersistenceStore(
            primaryData: Data("corrupt".utf8),
            backupData: try PersistenceDocumentCodec.encode(backupProgress)
        )

        let manager = try makeManager(store: store)

        XCTAssertEqual(manager.coins, 777)
        XCTAssertEqual(
            manager.persistenceStatus,
            .recoveredFromBackup(schemaVersion: QuizEnginePersistenceSchema.current)
        )
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            backupProgress
        )
    }

    func testCorruptPrimaryRecoversFromLegacyBackup() throws {
        var backupProgress = PlayerProgress.default
        backupProgress.coins = 778
        let legacyBackup = try PropertyListEncoder().encode(backupProgress)
        let store = FakePersistenceStore(
            primaryData: Data("corrupt".utf8),
            backupData: legacyBackup
        )

        let manager = try makeManager(store: store)

        XCTAssertEqual(manager.coins, 778)
        XCTAssertEqual(manager.persistenceStatus, .recoveredFromBackup(schemaVersion: QuizEnginePersistenceSchema.legacy))
    }

    func testMissingPrimaryUsesFreshStateAndPreservesStaleBackup() throws {
        var backupProgress = PlayerProgress.default
        backupProgress.coins = 456
        let backupData = try PersistenceDocumentCodec.encode(backupProgress)
        let store = FakePersistenceStore(backupData: backupData)

        let manager = try makeManager(store: store)

        XCTAssertEqual(manager.coins, PlayerProgress.default.coins)
        XCTAssertEqual(manager.persistenceStatus, .fresh)
        XCTAssertNil(store.primaryData)
        XCTAssertEqual(store.backupData, backupData)
    }

    func testCorruptPrimaryAndBackupReportsTypedRecoveryFailure() throws {
        let store = FakePersistenceStore(
            primaryData: Data("corrupt-primary".utf8),
            backupData: Data("corrupt-backup".utf8)
        )

        XCTAssertThrowsError(try makeManager(store: store)) { error in
            guard case PersistenceError.backupRecoveryFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInterruptedImportRestoresPreviousProgressAndClearsPendingMarker() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        var interruptedProgress = PlayerProgress.default
        interruptedProgress.coins = 999
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(interruptedProgress),
            backupData: try PersistenceDocumentCodec.encode(previousProgress),
            transactionMarkerData: try PropertyListEncoder().encode(
                ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: "legacy-import",
                    sourceFingerprint: "snapshot-1",
                    state: .pending,
                    hadPrimary: true,
                    timestamp: Date(timeIntervalSinceReferenceDate: 10),
                    targetProgress: interruptedProgress,
                    previousProgress: previousProgress
                )
            )
        )

        let manager = try makeManager(store: store)

        XCTAssertEqual(manager.coins, 111)
        XCTAssertEqual(manager.persistenceStatus, .recoveredInterruptedImport)
        XCTAssertNil(store.transactionMarkerData)

        let request = try PlayerProgressImportRequest(
            identifier: "legacy-import",
            sourceFingerprint: "snapshot-1",
            progress: interruptedProgress
        )
        XCTAssertEqual(try manager.importProgress(request), .imported)
        XCTAssertEqual(manager.coins, 999)
    }

    func testInterruptedFreshImportRemovesNewPrimaryAndDoesNotAdoptStaleBackup() throws {
        var staleProgress = PlayerProgress.default
        staleProgress.coins = 222
        var interruptedProgress = PlayerProgress.default
        interruptedProgress.coins = 999
        let staleBackup = try PersistenceDocumentCodec.encode(staleProgress)
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(interruptedProgress),
            backupData: staleBackup,
            transactionMarkerData: try PropertyListEncoder().encode(
                ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: "fresh-import",
                    sourceFingerprint: "snapshot-1",
                    state: .pending,
                    hadPrimary: false,
                    timestamp: Date(timeIntervalSinceReferenceDate: 10),
                    targetProgress: interruptedProgress
                )
            )
        )

        let manager = try makeManager(store: store)

        XCTAssertEqual(manager.progress, .default)
        XCTAssertEqual(manager.persistenceStatus, .recoveredInterruptedImport)
        XCTAssertNil(store.primaryData)
        XCTAssertEqual(store.backupData, staleBackup)
        XCTAssertNil(store.transactionMarkerData)
    }

    func testPendingImportKeepsIntactPrimaryWhenBackupWasNotUpdated() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        var staleBackupProgress = PlayerProgress.default
        staleBackupProgress.coins = 222
        var targetProgress = PlayerProgress.default
        targetProgress.coins = 999
        let staleBackup = try PersistenceDocumentCodec.encode(staleBackupProgress)
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(previousProgress),
            backupData: staleBackup,
            transactionMarkerData: try PropertyListEncoder().encode(
                ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: "pending-import",
                    sourceFingerprint: "snapshot-1",
                    state: .pending,
                    hadPrimary: true,
                    timestamp: Date(timeIntervalSinceReferenceDate: 10),
                    targetProgress: targetProgress,
                    previousProgress: previousProgress
                )
            )
        )

        let manager = try makeManager(store: store)

        XCTAssertEqual(manager.coins, 111)
        XCTAssertEqual(manager.persistenceStatus, .recoveredInterruptedImport)
        XCTAssertEqual(store.backupData, staleBackup)
        XCTAssertNil(store.transactionMarkerData)
    }

    func testInterruptedImportRejectsBackupThatDoesNotMatchPreviousProgress() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        var staleBackupProgress = PlayerProgress.default
        staleBackupProgress.coins = 222
        var targetProgress = PlayerProgress.default
        targetProgress.coins = 999
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(targetProgress),
            backupData: try PersistenceDocumentCodec.encode(staleBackupProgress),
            transactionMarkerData: try PropertyListEncoder().encode(
                ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: "stale-backup-import",
                    sourceFingerprint: "snapshot-1",
                    state: .pending,
                    hadPrimary: true,
                    timestamp: Date(timeIntervalSinceReferenceDate: 10),
                    targetProgress: targetProgress,
                    previousProgress: previousProgress
                )
            )
        )

        XCTAssertThrowsError(try makeManager(store: store)) { error in
            guard case PersistenceError.backupRecoveryFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            targetProgress
        )
    }

    func testWriteFailureDoesNotReportCompletionOrChangeInMemoryProgress() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        let store = FakePersistenceStore(primaryData: try PersistenceDocumentCodec.encode(previousProgress))
        let manager = try makeManager(store: store)
        store.failurePoint = .replacePrimary

        manager.addCoins(20)

        XCTAssertEqual(manager.coins, 111)
        XCTAssertEqual(manager.lastPersistenceError, .writeFailed(path: store.primaryURL.path, reason: "Injected failure"))
        XCTAssertNil(store.transactionMarkerData)
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            previousProgress
        )
    }

    func testPartialReplacementRestoresPreviousProgressAndReportsFailure() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        let store = FakePersistenceStore(primaryData: try PersistenceDocumentCodec.encode(previousProgress))
        let manager = try makeManager(store: store)
        store.failurePoint = .partialReplacePrimary

        manager.addCoins(20)

        XCTAssertEqual(manager.coins, 111)
        XCTAssertEqual(
            manager.lastPersistenceError,
            .writeFailed(path: store.primaryURL.path, reason: "Injected partial replacement failure")
        )
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            previousProgress
        )
        XCTAssertTrue(store.operations.contains("restoreBackup"))
    }

    func testInsufficientStorageIsReportedAsTypedFailure() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)
        store.failurePoint = .insufficientStorage

        manager.addCoins(20)

        XCTAssertEqual(
            manager.lastPersistenceError,
            .insufficientStorage(path: store.primaryURL.path)
        )
        XCTAssertEqual(manager.coins, PlayerProgress.default.coins)
    }

    func testReadBackMismatchRestoresBackupAndRollsBackMutation() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        var mismatchedProgress = previousProgress
        mismatchedProgress.coins = 999
        let store = FakePersistenceStore(primaryData: try PersistenceDocumentCodec.encode(previousProgress))
        let manager = try makeManager(store: store)
        store.readBackOverride = try PersistenceDocumentCodec.encode(mismatchedProgress)

        manager.addCoins(20)

        XCTAssertEqual(manager.coins, 111)
        XCTAssertEqual(manager.persistenceStatus, .failed(.readBackVerificationFailed(path: store.primaryURL.path)))
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            previousProgress
        )
    }

    func testFailedPowerUpPersistenceRollsBackCreditCoinAndUsageMutations() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)
        XCTAssertTrue(manager.grantPowerUpCredits(1, for: .fiftyFifty))

        store.failurePoint = .replacePrimary
        XCTAssertNil(manager.consumePowerUp(.fiftyFifty))
        XCTAssertEqual(manager.powerUpCredits(for: .fiftyFifty), 1)
        XCTAssertEqual(manager.coins, 100)
        XCTAssertEqual(manager.progress.totalCoinsSpent, 0)
        XCTAssertNil(manager.progress.lifetimePowerUpsUsed)
        XCTAssertFalse(manager.progress.powerUpTypesUsed.contains(PowerUp.fiftyFifty.rawValue))

        store.failurePoint = .replacePrimary
        XCTAssertNil(manager.consumePowerUp(.timeFreeze))
        XCTAssertEqual(manager.powerUpCredits(for: .timeFreeze), 0)
        XCTAssertEqual(manager.coins, 100)
        XCTAssertEqual(manager.progress.totalCoinsSpent, 0)
        XCTAssertNil(manager.progress.lifetimePowerUpsUsed)
        XCTAssertFalse(manager.progress.powerUpTypesUsed.contains(PowerUp.timeFreeze.rawValue))
    }

    func testPowerUpReadBackMismatchRollsBackCreditAndUsage() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)
        XCTAssertTrue(manager.grantPowerUpCredits(1, for: .skipQuestion))
        let persistedBeforeConsumption = try XCTUnwrap(store.primaryData)
        store.readBackOverride = persistedBeforeConsumption

        XCTAssertNil(manager.consumePowerUp(.skipQuestion))

        XCTAssertEqual(manager.powerUpCredits(for: .skipQuestion), 1)
        XCTAssertEqual(manager.coins, 100)
        XCTAssertEqual(manager.progress.totalCoinsSpent, 0)
        XCTAssertNil(manager.progress.lifetimePowerUpsUsed)
        XCTAssertEqual(
            manager.lastPersistenceError,
            .readBackVerificationFailed(path: store.primaryURL.path)
        )
    }

    func testPowerUpConsumptionRejectsCounterOverflowWithoutMutation() throws {
        var usageOverflowProgress = PlayerProgress.default
        usageOverflowProgress.powerUpCredits[.fiftyFifty] = 1
        usageOverflowProgress.lifetimePowerUpsUsed = Int.max
        let usageStore = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(usageOverflowProgress)
        )
        let usageManager = try makeManager(store: usageStore)

        XCTAssertFalse(usageManager.canFundPowerUp(.fiftyFifty))
        XCTAssertNil(usageManager.consumePowerUp(.fiftyFifty))
        XCTAssertEqual(usageManager.powerUpCredits(for: .fiftyFifty), 1)
        XCTAssertEqual(usageManager.progress.lifetimePowerUpsUsed, Int.max)
        XCTAssertEqual(usageManager.coins, 100)

        var spendingOverflowProgress = PlayerProgress.default
        spendingOverflowProgress.totalCoinsSpent = Int.max
        let spendingStore = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(spendingOverflowProgress)
        )
        let spendingManager = try makeManager(store: spendingStore)

        XCTAssertFalse(spendingManager.canFundPowerUp(.timeFreeze))
        XCTAssertNil(spendingManager.consumePowerUp(.timeFreeze))
        XCTAssertFalse(spendingManager.spendCoins(1))
        XCTAssertEqual(spendingManager.coins, 100)
        XCTAssertEqual(spendingManager.progress.totalCoinsSpent, Int.max)
        XCTAssertNil(spendingManager.progress.lifetimePowerUpsUsed)
    }

    func testFailedBooleanMutationsDoNotReportSuccess() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)

        store.failurePoint = .replacePrimary
        XCTAssertFalse(manager.spendCoins(10))
        XCTAssertEqual(manager.coins, PlayerProgress.default.coins)

        store.failurePoint = .replacePrimary
        XCTAssertNil(manager.claimDailyReward())
        XCTAssertEqual(manager.coins, PlayerProgress.default.coins)
    }

    func testImportTransactionCompletesExactlyOnceAndRejectsConflicts() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)
        var importedProgress = PlayerProgress.default
        importedProgress.coins = 888
        let request = try PlayerProgressImportRequest(
            identifier: "legacy-import",
            sourceFingerprint: "snapshot-1",
            progress: importedProgress
        )

        XCTAssertEqual(try manager.importProgress(request), .imported)
        XCTAssertEqual(manager.coins, 888)
        let pendingMarkerIndex = try XCTUnwrap(store.operations.firstIndex(of: "replaceMarker"))
        let primaryIndex = try XCTUnwrap(store.operations.firstIndex(of: "replacePrimary"))
        let completedMarkerIndex = try XCTUnwrap(store.operations.lastIndex(of: "replaceMarker"))
        XCTAssertLessThan(pendingMarkerIndex, primaryIndex)
        XCTAssertLessThan(primaryIndex, completedMarkerIndex)
        XCTAssertEqual(try manager.importProgress(request), .alreadyImported)

        let conflictingRequest = try PlayerProgressImportRequest(
            identifier: "legacy-import",
            sourceFingerprint: "snapshot-2",
            progress: PlayerProgress.default
        )
        XCTAssertThrowsError(try manager.importProgress(conflictingRequest)) { error in
            XCTAssertEqual(error as? PersistenceError, .conflictingImport(identifier: "legacy-import"))
        }
        XCTAssertEqual(manager.coins, 888)
    }

    func testPowerUpCreditImportIsExactlyOnceAndNeverConvertsValueToCoins() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)
        XCTAssertTrue(manager.grantPowerUpCredits(2, for: .timeFreeze))
        var importedProgress = manager.progress
        importedProgress.powerUpCredits[.fiftyFifty] = 7
        importedProgress.powerUpCredits[.skipQuestion] = 9
        let request = try PlayerProgressImportRequest(
            identifier: "legacy-hint-skip-import",
            sourceFingerprint: "hints-7-skips-9",
            progress: importedProgress
        )

        XCTAssertEqual(try manager.importProgress(request), .imported)
        XCTAssertEqual(try manager.importProgress(request), .alreadyImported)
        XCTAssertEqual(manager.powerUpCredits(for: .fiftyFifty), 7)
        XCTAssertEqual(manager.powerUpCredits(for: .skipQuestion), 9)
        XCTAssertEqual(manager.powerUpCredits(for: .timeFreeze), 2)
        XCTAssertEqual(manager.coins, 100)
        XCTAssertEqual(manager.progress.totalCoinsEarned, 100)
        XCTAssertEqual(manager.progress.totalCoinsSpent, 0)

        XCTAssertEqual(manager.consumePowerUp(.fiftyFifty)?.fundingSource, .freeCredit)
        XCTAssertEqual(manager.powerUpCredits(for: .fiftyFifty), 6)
        XCTAssertEqual(try manager.importProgress(request), .alreadyImported)
        XCTAssertEqual(manager.powerUpCredits(for: .fiftyFifty), 6)
        XCTAssertEqual(manager.coins, 100)

        let reloaded = try makeManager(store: store)
        XCTAssertEqual(reloaded.powerUpCredits(for: .fiftyFifty), 6)
        XCTAssertEqual(reloaded.powerUpCredits(for: .skipQuestion), 9)
        XCTAssertEqual(reloaded.coins, 100)
    }

    func testPowerUpCreditImportRejectsConflictingSourceOrTarget() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)
        var importedProgress = manager.progress
        importedProgress.powerUpCredits[.fiftyFifty] = 3
        let request = try PlayerProgressImportRequest(
            identifier: "power-up-credit-import",
            sourceFingerprint: "snapshot-1",
            progress: importedProgress
        )
        XCTAssertEqual(try manager.importProgress(request), .imported)

        var conflictingProgress = importedProgress
        conflictingProgress.powerUpCredits[.fiftyFifty] = 30
        let conflictingSource = try PlayerProgressImportRequest(
            identifier: request.identifier,
            sourceFingerprint: "snapshot-2",
            progress: conflictingProgress
        )
        XCTAssertThrowsError(try manager.importProgress(conflictingSource)) { error in
            XCTAssertEqual(error as? PersistenceError, .conflictingImport(identifier: request.identifier))
        }

        let conflictingTarget = try PlayerProgressImportRequest(
            identifier: request.identifier,
            sourceFingerprint: request.sourceFingerprint,
            progress: conflictingProgress
        )
        XCTAssertThrowsError(try manager.importProgress(conflictingTarget)) { error in
            XCTAssertEqual(error as? PersistenceError, .conflictingImport(identifier: request.identifier))
        }
        XCTAssertEqual(manager.powerUpCredits(for: .fiftyFifty), 3)
        XCTAssertEqual(manager.coins, 100)
    }

    func testCompletedImportCannotAcknowledgeARevertedDestination() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        var importedProgress = PlayerProgress.default
        importedProgress.coins = 888
        let request = try PlayerProgressImportRequest(
            identifier: "completed-import",
            sourceFingerprint: "snapshot-1",
            progress: importedProgress
        )
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(previousProgress),
            transactionMarkerData: try PropertyListEncoder().encode(
                ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: request.identifier,
                    sourceFingerprint: request.sourceFingerprint,
                    state: .completed,
                    hadPrimary: true,
                    timestamp: Date(timeIntervalSinceReferenceDate: 10),
                    targetProgress: importedProgress,
                    previousProgress: previousProgress
                )
            )
        )
        XCTAssertThrowsError(try makeManager(store: store)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .readBackVerificationFailed(path: store.primaryURL.path)
            )
        }
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            previousProgress
        )
    }

    func testFailedImportNeverWritesCompletionMarker() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)
        var importedProgress = PlayerProgress.default
        importedProgress.coins = 888
        let request = try PlayerProgressImportRequest(
            identifier: "failed-import",
            sourceFingerprint: "snapshot-1",
            progress: importedProgress
        )
        store.failurePoint = .replacePrimary

        XCTAssertThrowsError(try manager.importProgress(request))
        XCTAssertNil(store.transactionMarkerData)
        XCTAssertEqual(store.operations.filter { $0 == "replaceMarker" }.count, 1)
        XCTAssertEqual(manager.progress, .default)
    }

    func testFailedImportPreservesPrimaryWhenBackupWasNotUpdated() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(previousProgress)
        )
        let manager = try makeManager(store: store)
        var importedProgress = PlayerProgress.default
        importedProgress.coins = 888
        let request = try PlayerProgressImportRequest(
            identifier: "failed-existing-import",
            sourceFingerprint: "snapshot-1",
            progress: importedProgress
        )
        store.failurePoint = .replacePrimary

        XCTAssertThrowsError(try manager.importProgress(request)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .writeFailed(path: store.primaryURL.path, reason: "Injected failure")
            )
        }
        XCTAssertNil(store.transactionMarkerData)
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            previousProgress
        )
    }

    func testPreferencesSupportLegacyDataAndVersionedStoreWrites() throws {
        let store = FakePersistenceStore(
            primaryData: try PropertyListEncoder().encode(UserPreferences(hapticsEnabled: false))
        )

        XCTAssertEqual(try UserPreferencesLoader.load(from: store), UserPreferences(hapticsEnabled: false))

        try UserPreferencesLoader.write(
            preferences: UserPreferences(hapticsEnabled: true),
            to: store
        )

        let propertyList = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: try XCTUnwrap(store.primaryData), options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(propertyList["schemaVersion"] as? Int, QuizEnginePersistenceSchema.current)
        XCTAssertEqual(try UserPreferencesLoader.load(from: store), UserPreferences(hapticsEnabled: true))
    }

    func testPreferencesRecoverFromValidBackupWhenPrimaryIsMalformed() throws {
        let preferences = UserPreferences(hapticsEnabled: false)
        let store = FakePersistenceStore(
            primaryData: Data("corrupt".utf8),
            backupData: try PersistenceDocumentCodec.encode(preferences)
        )

        XCTAssertEqual(try UserPreferencesLoader.load(from: store), preferences)
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                UserPreferences.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            preferences
        )
    }

    func testPreferencesReadBackFailureRestoresPreviousValue() throws {
        let previous = UserPreferences(hapticsEnabled: false)
        let replacement = UserPreferences(hapticsEnabled: true)
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(previous)
        )
        store.readBackOverride = try PersistenceDocumentCodec.encode(previous)

        XCTAssertThrowsError(try UserPreferencesLoader.write(preferences: replacement, to: store)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .readBackVerificationFailed(path: store.primaryURL.path)
            )
        }
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                UserPreferences.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            previous
        )
    }

    func testPreferencesUseFreshStateWhenPrimaryIsMissing() throws {
        let preferences = UserPreferences(hapticsEnabled: false)
        let backupData = try PersistenceDocumentCodec.encode(preferences)
        let store = FakePersistenceStore(backupData: backupData)

        XCTAssertEqual(try UserPreferencesLoader.load(from: store), UserPreferences(hapticsEnabled: true))
        XCTAssertNil(store.primaryData)
        XCTAssertEqual(store.backupData, backupData)
    }

    func testUnsupportedSchemaIsTypedAndDoesNotLoadAsDefault() throws {
        let data = try PropertyListEncoder().encode(
            PersistenceEnvelope(schemaVersion: 999, payload: PlayerProgress.default)
        )
        let store = FakePersistenceStore(primaryData: data)

        XCTAssertThrowsError(try makeManager(store: store)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .unsupportedSchema(path: store.primaryURL.path, version: 999)
            )
        }
    }

    func testImportRequestRejectsMissingIdentityFields() {
        XCTAssertThrowsError(
            try PlayerProgressImportRequest(
                identifier: "",
                sourceFingerprint: "fingerprint",
                progress: .default
            )
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .invalidImportRequest)
        }

        XCTAssertThrowsError(
            try PlayerProgressImportRequest(
                identifier: " \n",
                sourceFingerprint: "fingerprint",
                progress: .default
            )
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .invalidImportRequest)
        }

        var negativeCredits = PlayerProgress.default
        negativeCredits.powerUpCredits[.skipQuestion] = -1
        XCTAssertThrowsError(
            try PlayerProgressImportRequest(
                identifier: "legacy-import",
                sourceFingerprint: "fingerprint",
                progress: negativeCredits
            )
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .invalidImportRequest)
        }
    }

    func testMalformedImportMarkerDoesNotRecoverOrProceed() throws {
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(PlayerProgress.default),
            transactionMarkerData: try PropertyListEncoder().encode(
                ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: " ",
                    sourceFingerprint: "fingerprint",
                    state: .pending,
                    hadPrimary: true,
                    timestamp: Date(timeIntervalSinceReferenceDate: 10),
                    targetProgress: .default,
                    previousProgress: .default
                )
            )
        )

        XCTAssertThrowsError(try makeManager(store: store)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .malformedImportMarker(path: store.transactionMarkerURL.path)
            )
        }
        XCTAssertNotNil(store.transactionMarkerData)
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(hour: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: hour))!
    }

    private func evaluationDate(for rule: AchievementRule, calendar: Calendar, above: Bool) -> Date {
        if case .localHour(let start, let end) = rule {
            return date(hour: above && start + 1 < end ? start + 1 : start, calendar: calendar)
        }
        return date(hour: 12, calendar: calendar)
    }

    private func progress(
        for rule: AchievementRule,
        increase: Int,
        date: Date,
        calendar: Calendar
    ) -> PlayerProgress {
        var progress = PlayerProgress.default
        switch rule {
        case .playStreak(let minimum):
            progress.currentPlayStreak = minimum + increase
            progress.longestPlayStreak = minimum + increase
        case .bestScore(let minimum): progress.bestSingleSessionScore = minimum + increase
        case .bestAnswerStreak(let minimum): progress.bestSingleSessionStreak = minimum + increase
        case .anyCategoryCorrect(let minimum): progress.categoryStats["nature"] = CategoryStat(correctlyAnsweredIDs: Set(1...(minimum + increase)))
        case .categoryCorrect(let categoryID, let minimum): progress.categoryStats[categoryID] = CategoryStat(correctlyAnsweredIDs: Set(1...(minimum + increase)))
        case .categoriesCorrect(let count, let minimum):
            for categoryID in ["nature", "space", "future"].prefix(count) {
                progress.categoryStats[categoryID] = CategoryStat(correctlyAnsweredIDs: Set(1...(minimum + increase)))
            }
        case .lifetimeGames(let minimum): progress.lifetimeGamesPlayed = minimum + increase
        case .lifetimeQuestions(let minimum): progress.lifetimeQuestionsAnswered = minimum + increase
        case .totalCoinsEarned(let minimum): progress.totalCoinsEarned = minimum + increase
        case .powerUpTypesUsed(let minimum): progress.powerUpTypesUsed = Set((0..<(minimum + increase)).map(String.init))
        case .lifetimePowerUpsUsed(let minimum): progress.lifetimePowerUpsUsed = minimum + increase
        case .comeback(let minimumDaysAway): progress.previousAppOpenDate = calendar.date(byAdding: .day, value: -(minimumDaysAway + increase), to: date)
        case .localHour: break
        }
        return progress
    }

    private var belowThresholdProgress: PlayerProgress {
        var progress = PlayerProgress.default
        progress.currentPlayStreak = 0
        progress.longestPlayStreak = 0
        progress.bestSingleSessionScore = 0
        progress.bestSingleSessionStreak = 0
        progress.categoryStats = [:]
        progress.lifetimeGamesPlayed = 0
        progress.lifetimeQuestionsAnswered = 0
        progress.totalCoinsEarned = 0
        progress.powerUpTypesUsed = []
        progress.lifetimePowerUpsUsed = 0
        progress.previousAppOpenDate = nil
        return progress
    }

    private func makeManager(store: any QuizEnginePersistenceStore) throws -> PlayerProgressManager {
        try PlayerProgressManager(
            variant: try makeAlternateVariant(),
            questionDataService: service,
            persistenceStore: store,
            clock: TestClock(now: Date(timeIntervalSinceReferenceDate: 0))
        )
    }
}

private final class PremiumPurchaseStatus: PurchaseStatusProvider {
    let isPremium = true
    let adsRemoved = true
}
