import XCTest
import os
import QuizEngineCore
import QuizEngineTestSupport
@testable import QuizEngineGame

@MainActor
final class QuizEngineGameTests: XCTestCase {
    private let questions = [
        Question(id: 1, question: "First", answers: [Answer(text: "A", correct: true)], categories: ["alpha"]),
        Question(id: 2, question: "Second", answers: [Answer(text: "B", correct: true)], categories: ["beta"])
    ]

    private func makeRules(
        economy: QuizEconomyRules = QuizRulesConfiguration.serbianCompatible.economy,
        solo: QuizSoloRules = QuizRulesConfiguration.serbianCompatible.solo,
        powerUps: QuizPowerUpRules = QuizRulesConfiguration.serbianCompatible.powerUps,
        extraLife: QuizExtraLifeRules = QuizRulesConfiguration.serbianCompatible.extraLife,
        soloInterstitial: QuizInterstitialEligibilityRules = QuizRulesConfiguration.serbianCompatible.soloInterstitialEligibility
    ) throws -> QuizRulesConfiguration {
        let defaults = QuizRulesConfiguration.serbianCompatible
        return try QuizRulesConfiguration(
            economy: economy,
            solo: solo,
            powerUps: powerUps,
            extraLife: extraLife,
            sessions: defaults.sessions,
            soloInterstitialEligibility: soloInterstitial,
            multiplayer: defaults.multiplayer
        )
    }

    func testInitializationPreservesQuestionOrderAndStartsAtFirstQuestion() {
        let viewModel = QuizViewModel(questions: questions, gameMode: .singlePlayer, selectedCategory: nil)
        viewModel.stopTimer()

        XCTAssertEqual(viewModel.questionData.map(\.id), [1, 2])
        XCTAssertEqual(viewModel.questionNumber, 0)
        XCTAssertEqual(viewModel.score, 0)
        XCTAssertEqual(viewModel.livesRemaining, 3)
        XCTAssertTrue(viewModel.isCompetitiveMode)
    }

    func testCategoryAndPracticeModeClassificationIsUnchanged() {
        let category = QuizViewModel(questions: questions, gameMode: .singlePlayer, selectedCategory: "alpha")
        let practice = QuizViewModel(questions: questions, gameMode: .practice, selectedCategory: "alpha")
        category.stopTimer()
        practice.stopTimer()

        XCTAssertTrue(category.isCategoryMode)
        XCTAssertFalse(category.isCompetitiveMode)
        XCTAssertTrue(practice.isPracticeMode)
        XCTAssertFalse(practice.isCategoryMode)
    }

    func testScoringAwardsTenPointsThenTwentyAfterFiveAnswerStreak() {
        let scheduler = TestScheduler()
        let viewModel = QuizViewModel(
            questions: Array(repeating: questions[0], count: 6),
            gameMode: .singlePlayer,
            selectedCategory: nil,
            scheduler: scheduler
        )
        viewModel.stopTimer()

        for _ in 0..<6 {
            viewModel.increaseScoreForCorrectAnswer()
            viewModel.stopTimer()
            scheduler.advance(by: 1)
        }

        XCTAssertEqual(viewModel.score, 70)
        XCTAssertEqual(viewModel.correctAnswersInRow, 6)
        XCTAssertEqual(viewModel.coinsEarnedThisSession, 6)
    }

    func testPracticeWrongAnswerDoesNotConsumeLife() {
        let viewModel = QuizViewModel(questions: questions, gameMode: .practice, selectedCategory: "alpha")
        viewModel.reduceLivesRemaining()
        viewModel.stopTimer()

        XCTAssertEqual(viewModel.livesRemaining, 3)
        XCTAssertEqual(viewModel.questionsAnsweredThisSession, 1)
        XCTAssertEqual(viewModel.missedQuestions.map(\.id), [1])
    }

    func testDelayedQuestionTransitionUsesInjectedScheduler() {
        let scheduler = TestScheduler()
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 1)
        )
        viewModel.stopTimer()

        viewModel.increaseScoreForCorrectAnswer()
        XCTAssertEqual(viewModel.questionNumber, 0)

        scheduler.advance(by: 1)

        XCTAssertEqual(viewModel.questionNumber, 1)
    }

    func testInjectedClockAndSchedulerDriveTimeoutWithoutWallWaiting() throws {
        let defaults = QuizRulesConfiguration.serbianCompatible.solo
        let rules = try makeRules(
            solo: QuizSoloRules(
                timerDurationSeconds: 3,
                startingLives: defaults.startingLives,
                scoring: defaults.scoring
            )
        )
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = TestScheduler()
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            rules: rules,
            clock: clock,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 10)
        )

        clock.advance(by: 3)
        scheduler.advance(by: 1)

        XCTAssertEqual(viewModel.timeRemaining, 3)
        XCTAssertEqual(viewModel.livesRemaining, 2)
        XCTAssertTrue(viewModel.shouldShowWrongAnswerView)
        viewModel.updateRemainingTimeAndHandleNavigationIfNeeded()
        viewModel.updateRemainingTimeAndHandleNavigationIfNeeded()
        XCTAssertEqual(viewModel.livesRemaining, 2)
    }

    func testClockRollbackCannotIncreaseSoloTimer() {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = TestScheduler()
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            clock: clock,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 11)
        )

        clock.advance(by: 2)
        scheduler.advance(by: 1)
        XCTAssertEqual(viewModel.timeRemaining, 13)

        clock.advance(by: -10)
        scheduler.advance(by: 1)
        XCTAssertEqual(viewModel.timeRemaining, 13)
        viewModel.stopTimer()
    }

    func testSoloBackgroundPausesAndResumesRemainingTime() {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = TestScheduler()
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            clock: clock,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 12)
        )

        clock.advance(by: 2.25)
        scheduler.advance(by: 1)
        XCTAssertEqual(viewModel.timeRemaining, 13)
        viewModel.handleAppBackgrounded()

        clock.advance(by: 100)
        scheduler.advance(by: 100)
        XCTAssertEqual(viewModel.timeRemaining, 13)
        XCTAssertEqual(viewModel.livesRemaining, 3)

        viewModel.handleAppForegrounded()
        clock.advance(by: 0.74)
        scheduler.advance(by: 0.74)
        XCTAssertEqual(viewModel.timeRemaining, 13)
        clock.advance(by: 0.01)
        scheduler.advance(by: 0.26)
        XCTAssertEqual(viewModel.timeRemaining, 12)
        viewModel.stopTimer()
    }

    func testFreezeDurationPausesAcrossBackgroundAndResumesAtExactBoundary() throws {
        let defaults = QuizRulesConfiguration.serbianCompatible
        let rules = try makeRules(
            powerUps: QuizPowerUpRules(
                rules: defaults.powerUps.rules,
                fiftyFiftyIncorrectAnswersRemoved: 2,
                timeFreezeDurationSeconds: 4,
                streakShieldMinimumStreak: 5
            )
        )
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = TestScheduler()
        let manager = try makeProgressManager(store: FakePersistenceStore(), rules: rules)
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            rules: rules,
            clock: clock,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 13)
        )
        viewModel.progressManager = manager

        viewModel.useTimeFreeze()
        XCTAssertTrue(viewModel.isTimeFrozen)
        clock.advance(by: 1)
        viewModel.handleAppBackgrounded()
        clock.advance(by: 100)
        scheduler.advance(by: 100)
        XCTAssertTrue(viewModel.isTimeFrozen)

        viewModel.handleAppForegrounded()
        clock.advance(by: 2.9)
        scheduler.advance(by: 2.9)
        XCTAssertTrue(viewModel.isTimeFrozen)
        clock.advance(by: 0.1)
        scheduler.advance(by: 0.1)
        XCTAssertFalse(viewModel.isTimeFrozen)
        viewModel.stopTimer()
    }

    func testRollbackDuringPausedFreezeCannotRestoreConsumedDuration() throws {
        let defaults = QuizRulesConfiguration.serbianCompatible
        let rules = try makeRules(
            powerUps: QuizPowerUpRules(
                rules: defaults.powerUps.rules,
                fiftyFiftyIncorrectAnswersRemoved: 2,
                timeFreezeDurationSeconds: 10,
                streakShieldMinimumStreak: 5
            )
        )
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = TestScheduler()
        let manager = try makeProgressManager(store: FakePersistenceStore(), rules: rules)
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            rules: rules,
            clock: clock,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 21)
        )
        viewModel.progressManager = manager

        viewModel.useTimeFreeze()
        clock.advance(by: 2)
        viewModel.handleAppBackgrounded()
        viewModel.handleAppForegrounded()
        clock.advance(by: -5)
        viewModel.handleAppBackgrounded()
        viewModel.handleAppForegrounded()

        clock.advance(by: 7.9)
        scheduler.advance(by: 7.9)
        XCTAssertTrue(viewModel.isTimeFrozen)
        clock.advance(by: 0.1)
        scheduler.advance(by: 0.1)
        XCTAssertFalse(viewModel.isTimeFrozen)
        viewModel.stopTimer()
    }

    func testRestartCancelsStaleTimerAndResetsDeterministically() throws {
        let defaults = QuizRulesConfiguration.serbianCompatible.solo
        let rules = try makeRules(
            solo: QuizSoloRules(
                timerDurationSeconds: 3,
                startingLives: defaults.startingLives,
                scoring: defaults.scoring
            )
        )
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = TestScheduler()
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            rules: rules,
            clock: clock,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 14)
        )

        viewModel.restartGame()
        clock.advance(by: 3)
        scheduler.advance(by: 1)

        XCTAssertEqual(viewModel.livesRemaining, 2)
        XCTAssertEqual(viewModel.questionNumber, 0)
    }

    func testRestartRejectsCallbacksDeliveredAfterCancellation() {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = CancellationIgnoringTestScheduler()
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            clock: clock,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 19)
        )

        viewModel.increaseScoreForCorrectAnswer()
        viewModel.restartGame()
        clock.advance(by: 1)
        scheduler.runPendingBatch()

        XCTAssertEqual(viewModel.questionNumber, 0)
        XCTAssertEqual(viewModel.timeRemaining, 14)
        XCTAssertEqual(scheduler.pendingTaskCount, 1)
        viewModel.stopTimer()
    }

    func testClockRollbackCannotRecordNegativeResponseTime() throws {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = TestScheduler()
        let manager = try makeProgressManager(
            store: FakePersistenceStore(),
            clock: clock
        )
        let viewModel = QuizViewModel(
            questions: [questions[0]],
            gameMode: .singlePlayer,
            selectedCategory: nil,
            clock: clock,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 18)
        )
        viewModel.progressManager = manager

        clock.advance(by: -10)
        viewModel.increaseScoreForCorrectAnswer()
        scheduler.advance(by: 1)

        XCTAssertEqual(manager.progress.lifetimeAverageResponseTimeMs, 0)
        XCTAssertEqual(manager.progress.lifetimeResponseTimeSamples, 1)
    }

    func testIdenticalSeededSoloDependenciesProduceIdenticalOrdersDecisionsAndRewards() throws {
        let deterministicQuestions = [
            Question(
                id: 1,
                question: "One",
                answers: [
                    Answer(text: "A", correct: true),
                    Answer(text: "B", correct: false),
                    Answer(text: "C", correct: false),
                    Answer(text: "D", correct: false)
                ],
                categories: ["alpha"]
            ),
            Question(
                id: 2,
                question: "Two",
                answers: [
                    Answer(text: "E", correct: true),
                    Answer(text: "F", correct: false),
                    Answer(text: "G", correct: false),
                    Answer(text: "H", correct: false)
                ],
                categories: ["beta"]
            )
        ]
        let firstAd = FakeInterstitialAdProvider(ready: true)
        let secondAd = FakeInterstitialAdProvider(ready: true)
        let first = QuizViewModel(
            questions: deterministicQuestions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            interstitialAd: firstAd,
            scheduler: TestScheduler(),
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 15)
        )
        let second = QuizViewModel(
            questions: deterministicQuestions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            interstitialAd: secondAd,
            scheduler: TestScheduler(),
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 15)
        )
        let firstManager = try makeProgressManager(store: FakePersistenceStore())
        let secondManager = try makeProgressManager(store: FakePersistenceStore())
        first.progressManager = firstManager
        second.progressManager = secondManager

        XCTAssertEqual(first.questionData, second.questionData)
        first.useFiftyFifty()
        second.useFiftyFifty()
        XCTAssertEqual(first.hiddenAnswerIndices, second.hiddenAnswerIndices)
        first.increaseScoreForCorrectAnswer()
        second.increaseScoreForCorrectAnswer()
        XCTAssertEqual(first.score, second.score)
        XCTAssertEqual(first.coinsEarnedThisSession, second.coinsEarnedThisSession)
        XCTAssertEqual(firstManager.coins, secondManager.coins)
        first.showInterstitialAdIfEligible()
        second.showInterstitialAdIfEligible()
        XCTAssertEqual(firstAd.showCount, secondAd.showCount)
        first.restartGame()
        second.restartGame()
        XCTAssertEqual(first.questionData.map(\.id), second.questionData.map(\.id))
        first.stopTimer()
        second.stopTimer()
    }

    func testFakeProvidersAreInjectableWithoutExternalServices() {
        let analytics = RecordingAnalytics()
        let haptics = RecordingHaptics()
        let purchaseStatus = FakePurchaseStatus()
        let interstitial = FakeInterstitialAdProvider(ready: true)
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            analytics: analytics,
            interstitialAd: interstitial,
            purchaseStatus: purchaseStatus,
            haptics: haptics,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 2)
        )
        viewModel.stopTimer()

        XCTAssertEqual(analytics.gameStarts.count, 1)
        XCTAssertEqual(interstitial.loadCount, 1)
        XCTAssertTrue(haptics.notifications.isEmpty)
    }

    func testPowerUpCreditFundsGameplayWithZeroCoinsAndReportsSource() throws {
        let store = FakePersistenceStore()
        let manager = try makeProgressManager(store: store)
        XCTAssertTrue(manager.spendCoins(manager.coins))
        XCTAssertTrue(manager.grantPowerUpCredits(1, for: .fiftyFifty))
        let analytics = RecordingAnalytics()
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            analytics: analytics,
            scheduler: TestScheduler(),
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 3)
        )
        viewModel.progressManager = manager
        viewModel.stopTimer()

        XCTAssertTrue(viewModel.canUsePowerUp(.fiftyFifty))
        viewModel.useFiftyFifty()

        XCTAssertEqual(manager.coins, 0)
        XCTAssertEqual(manager.powerUpCredits(for: .fiftyFifty), 0)
        XCTAssertEqual(
            viewModel.lastPowerUpFunding,
            PowerUpSpendResult(powerUp: .fiftyFifty, fundingSource: .freeCredit, coinsSpent: 0)
        )
        XCTAssertEqual(analytics.powerUpFunding.count, 1)
        XCTAssertEqual(analytics.powerUpFunding[0].0, .fiftyFifty)
        XCTAssertEqual(analytics.powerUpFunding[0].1, .freeCredit)
        XCTAssertEqual(analytics.powerUpFunding[0].2, 0)
    }

    func testZeroCreditGameplayFallsBackToExistingCoinCost() throws {
        let manager = try makeProgressManager(store: FakePersistenceStore())
        let analytics = RecordingAnalytics()
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            analytics: analytics,
            scheduler: TestScheduler(),
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 4)
        )
        viewModel.progressManager = manager
        viewModel.stopTimer()

        viewModel.useTimeFreeze()

        XCTAssertEqual(manager.coins, 100 - PowerUp.timeFreeze.cost)
        XCTAssertEqual(
            viewModel.lastPowerUpFunding,
            PowerUpSpendResult(
                powerUp: .timeFreeze,
                fundingSource: .coins,
                coinsSpent: PowerUp.timeFreeze.cost
            )
        )
        XCTAssertEqual(analytics.powerUpFunding[0].1, .coins)
        XCTAssertEqual(analytics.powerUpFunding[0].2, PowerUp.timeFreeze.cost)
    }

    func testCustomRulesDriveSoloInitializationScoringCoinsAndRestart() throws {
        let scheduler = TestScheduler()
        let rules = try makeRules(
            economy: QuizEconomyRules(
                initialCoins: 100,
                correctAnswerCoinReward: 3,
                dailyRewardTiers: allStreakTiers,
                rewardAd: QuizRewardAdRules(coinReward: 25, cooldownSeconds: 21_600)
            ),
            solo: QuizSoloRules(
                timerDurationSeconds: 22,
                startingLives: 4,
                scoring: QuizScoringRules(baseCorrectPoints: 7, streakCorrectPoints: 19, streakThreshold: 2)
            )
        )
        let manager = try makeProgressManager(store: FakePersistenceStore(), rules: rules)
        let viewModel = QuizViewModel(
            questions: Array(repeating: questions[0], count: 3),
            gameMode: .singlePlayer,
            selectedCategory: nil,
            rules: rules,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 80)
        )
        viewModel.progressManager = manager
        viewModel.stopTimer()

        XCTAssertEqual(viewModel.livesRemaining, 4)
        XCTAssertEqual(viewModel.timeRemaining, 22)
        for _ in 0..<3 {
            viewModel.increaseScoreForCorrectAnswer()
            viewModel.stopTimer()
            scheduler.advance(by: 1)
        }
        XCTAssertEqual(viewModel.score, 33)
        XCTAssertEqual(viewModel.coinsEarnedThisSession, 9)
        XCTAssertEqual(manager.coins, 109)

        viewModel.restartGame()
        viewModel.stopTimer()
        XCTAssertEqual(viewModel.livesRemaining, 4)
        XCTAssertEqual(viewModel.timeRemaining, 22)
        XCTAssertEqual(viewModel.score, 0)
    }

    func testCustomPowerUpEligibilityEffectsAndExtraLifeLimits() throws {
        let defaults = QuizRulesConfiguration.serbianCompatible
        var powerUpMap = defaults.powerUps.rules
        powerUpMap[.fiftyFifty] = QuizPowerUpRule(
            coinCost: 6,
            allowedModes: [.singlePlayer],
            maximumUsesPerSession: 1
        )
        powerUpMap[.timeFreeze] = QuizPowerUpRule(
            coinCost: 4,
            allowedModes: [.singlePlayer],
            maximumUsesPerSession: 2
        )
        powerUpMap[.skipQuestion] = QuizPowerUpRule(
            coinCost: 0,
            isEnabled: false,
            allowedModes: [],
            maximumUsesPerSession: 0
        )
        let rules = try makeRules(
            powerUps: QuizPowerUpRules(
                rules: powerUpMap,
                fiftyFiftyIncorrectAnswersRemoved: 1,
                timeFreezeDurationSeconds: 4,
                streakShieldMinimumStreak: 3
            ),
            extraLife: QuizExtraLifeRules(
                coinCost: 7,
                maximumUsesPerSession: 1,
                allowsCoins: true,
                allowsRewardedAd: false
            )
        )
        let manager = try makeProgressManager(store: FakePersistenceStore(), rules: rules)
        XCTAssertTrue(manager.grantPowerUpCredits(1, for: .skipQuestion))
        let scheduler = TestScheduler()
        let fourAnswerQuestion = Question(
            id: 10,
            question: "Four",
            answers: [
                Answer(text: "Correct", correct: true),
                Answer(text: "Wrong 1", correct: false),
                Answer(text: "Wrong 2", correct: false),
                Answer(text: "Wrong 3", correct: false)
            ],
            categories: ["alpha"]
        )
        let viewModel = QuizViewModel(
            questions: [fourAnswerQuestion, fourAnswerQuestion],
            gameMode: .singlePlayer,
            selectedCategory: nil,
            rules: rules,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 81)
        )
        viewModel.progressManager = manager
        viewModel.stopTimer()

        XCTAssertFalse(viewModel.canUsePowerUp(.skipQuestion))
        XCTAssertEqual(manager.powerUpCredits(for: .skipQuestion), 1)
        viewModel.useFiftyFifty()
        XCTAssertEqual(viewModel.hiddenAnswerIndices.count, 1)
        XCTAssertFalse(viewModel.canUsePowerUp(.fiftyFifty))

        viewModel.useTimeFreeze()
        XCTAssertTrue(viewModel.isTimeFrozen)
        scheduler.advance(by: 3.9)
        XCTAssertTrue(viewModel.isTimeFrozen)
        scheduler.advance(by: 0.1)
        XCTAssertFalse(viewModel.isTimeFrozen)
        viewModel.stopTimer()
        XCTAssertFalse(viewModel.canUsePowerUp(.timeFreeze))
        viewModel.goToNextQuestion()
        XCTAssertTrue(viewModel.canUsePowerUp(.timeFreeze))
        viewModel.useTimeFreeze()
        XCTAssertFalse(viewModel.canUsePowerUp(.timeFreeze))

        let coinsBeforeLife = manager.coins
        XCTAssertTrue(viewModel.useExtraLifeWithCoins())
        XCTAssertEqual(manager.coins, coinsBeforeLife - 7)
        XCTAssertFalse(viewModel.useExtraLifeWithCoins())
    }

    func testExtraLifeLimitIsSharedAcrossCoinAndRewardedAdFunding() throws {
        let rewardAd = FakeRewardAdProvider(isLoaded: true)
        let manager = try makeProgressManager(store: FakePersistenceStore())
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            rewardAd: rewardAd
        )
        viewModel.progressManager = manager
        viewModel.stopTimer()

        XCTAssertTrue(viewModel.isRewardAdAvailable)
        XCTAssertTrue(viewModel.useExtraLifeWithCoins())
        XCTAssertFalse(viewModel.isRewardAdAvailable)

        viewModel.showRewardAd()
        XCTAssertEqual(rewardAd.showCount, 0)
        XCTAssertTrue(viewModel.shouldPresentResultView)
    }

    func testCancelledRewardedAdDoesNotGrantOrConsumeExtraLife() {
        let rewardAd = FakeRewardAdProvider(isLoaded: true)
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            rewardAd: rewardAd
        )
        viewModel.stopTimer()
        let livesBeforeAd = viewModel.livesRemaining

        viewModel.showRewardAd()
        rewardAd.completeReward(earned: false)

        XCTAssertEqual(rewardAd.showCount, 1)
        XCTAssertEqual(viewModel.livesRemaining, livesBeforeAd)
        XCTAssertTrue(viewModel.shouldPresentResultView)
    }

    func testCustomInterstitialEligibilityStillHonorsEntitlements() throws {
        let always = try makeRules(soloInterstitial: QuizInterstitialEligibilityRules(numerator: 1, denominator: 1))
        let never = try makeRules(soloInterstitial: QuizInterstitialEligibilityRules(numerator: 0, denominator: 1))
        let alwaysAd = FakeInterstitialAdProvider(ready: true)
        let neverAd = FakeInterstitialAdProvider(ready: true)
        let premiumAd = FakeInterstitialAdProvider(ready: true)

        let alwaysViewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            rules: always,
            interstitialAd: alwaysAd
        )
        let neverViewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            rules: never,
            interstitialAd: neverAd
        )
        let premiumViewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            rules: always,
            interstitialAd: premiumAd,
            purchaseStatus: FakePurchaseStatus(isPremium: true)
        )
        alwaysViewModel.stopTimer()
        neverViewModel.stopTimer()
        premiumViewModel.stopTimer()

        alwaysViewModel.showInterstitialAdIfEligible()
        neverViewModel.showInterstitialAdIfEligible()
        premiumViewModel.showInterstitialAdIfEligible()
        XCTAssertEqual(alwaysAd.showCount, 1)
        XCTAssertEqual(neverAd.showCount, 0)
        XCTAssertEqual(premiumAd.showCount, 0)
    }

    func testFailedPowerUpPersistenceDoesNotApplyGameplayOrAnalytics() throws {
        let store = FakePersistenceStore()
        let manager = try makeProgressManager(store: store)
        XCTAssertTrue(manager.grantPowerUpCredits(1, for: .fiftyFifty))
        let analytics = RecordingAnalytics()
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            analytics: analytics,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 5)
        )
        viewModel.progressManager = manager
        viewModel.stopTimer()
        store.failurePoint = .replacePrimary

        viewModel.useFiftyFifty()

        XCTAssertEqual(manager.powerUpCredits(for: .fiftyFifty), 1)
        XCTAssertTrue(viewModel.usedPowerUps.isEmpty)
        XCTAssertNil(viewModel.lastPowerUpFunding)
        XCTAssertTrue(analytics.powerUpFunding.isEmpty)
    }

    func testEnrichedAnalyticsBridgesToLegacyPowerUpCallback() throws {
        let analytics = LegacyPowerUpAnalytics()
        let coinManager = try makeProgressManager(store: FakePersistenceStore())
        let coinViewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            analytics: analytics,
            scheduler: TestScheduler(),
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 6)
        )
        coinViewModel.progressManager = coinManager
        coinViewModel.stopTimer()

        coinViewModel.useSkipQuestion()

        XCTAssertEqual(analytics.events.count, 1)
        XCTAssertEqual(analytics.events[0].0, .skipQuestion)
        XCTAssertEqual(analytics.events[0].1, PowerUp.skipQuestion.cost)

        let creditManager = try makeProgressManager(store: FakePersistenceStore())
        XCTAssertTrue(creditManager.spendCoins(creditManager.coins))
        XCTAssertTrue(creditManager.grantPowerUpCredits(1, for: .fiftyFifty))
        let creditViewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            analytics: analytics,
            scheduler: TestScheduler(),
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 7)
        )
        creditViewModel.progressManager = creditManager
        creditViewModel.stopTimer()

        creditViewModel.useFiftyFifty()

        XCTAssertEqual(analytics.events.count, 2)
        XCTAssertEqual(analytics.events[1].0, .fiftyFifty)
        XCTAssertEqual(analytics.events[1].1, 0)
    }

    func testRapidAnswerTapsLockRulesBeforePresentationFlags() {
        let scheduler = TestScheduler()
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            scheduler: scheduler
        )
        viewModel.stopTimer()

        // A legacy view is still allowed to write this compatibility flag. It
        // cannot bypass the state reducer or duplicate the answer reward.
        viewModel.shouldAllowTap = false
        viewModel.increaseScoreForCorrectAnswer()
        viewModel.reduceLivesRemaining()

        XCTAssertEqual(viewModel.score, 10)
        XCTAssertEqual(viewModel.livesRemaining, 3)
        XCTAssertEqual(viewModel.sessionState.phase, .feedback(.correct))
        XCTAssertFalse(viewModel.sessionState.acceptsAnswerInput)
        XCTAssertEqual(
            viewModel.consumeSessionEffects().filter {
                if case .answerLocked = $0 { return true }
                return false
            }.count,
            1
        )
    }

    func testTapAtDeadlineLosesToDeterministicTimeout() throws {
        let defaults = QuizRulesConfiguration.serbianCompatible.solo
        let rules = try makeRules(
            solo: QuizSoloRules(
                timerDurationSeconds: 1,
                startingLives: defaults.startingLives,
                scoring: defaults.scoring
            )
        )
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 10))
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            rules: rules,
            clock: clock,
            scheduler: TestScheduler()
        )

        clock.advance(by: 1)
        viewModel.increaseScoreForCorrectAnswer()

        XCTAssertEqual(viewModel.score, 0)
        XCTAssertEqual(viewModel.livesRemaining, 2)
        XCTAssertEqual(viewModel.sessionState.phase, .feedback(.timedOut))
    }

    func testSkipLocksOutConflictingPowerUpsAndDelayedWork() throws {
        let question = Question(
            id: 10,
            question: "Four",
            answers: [
                Answer(text: "Correct", correct: true),
                Answer(text: "Wrong 1", correct: false),
                Answer(text: "Wrong 2", correct: false),
                Answer(text: "Wrong 3", correct: false)
            ],
            categories: ["alpha"]
        )
        let manager = try makeProgressManager(store: FakePersistenceStore())
        XCTAssertTrue(manager.grantPowerUpCredits(1, for: .skipQuestion))
        XCTAssertTrue(manager.grantPowerUpCredits(1, for: .fiftyFifty))
        let scheduler = TestScheduler()
        let viewModel = QuizViewModel(
            questions: [question, question],
            gameMode: .singlePlayer,
            selectedCategory: nil,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 42)
        )
        viewModel.progressManager = manager
        viewModel.stopTimer()

        viewModel.useSkipQuestion()
        viewModel.useFiftyFifty()
        scheduler.advance(by: 0.3)

        XCTAssertEqual(manager.powerUpCredits(for: .skipQuestion), 0)
        XCTAssertEqual(manager.powerUpCredits(for: .fiftyFifty), 1)
        XCTAssertTrue(viewModel.hiddenAnswerIndices.isEmpty)
        XCTAssertEqual(viewModel.questionNumber, 1)
    }

    func testExitAndRepeatedTerminalCallbacksAreIdempotent() {
        let analytics = RecordingAnalytics()
        let scheduler = CancellationIgnoringTestScheduler()
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            analytics: analytics,
            scheduler: scheduler
        )

        viewModel.increaseScoreForCorrectAnswer()
        viewModel.exitGame()
        viewModel.exitGame()
        viewModel.endGame()
        scheduler.runPendingBatch()

        XCTAssertEqual(viewModel.sessionState.phase, .terminal(.exited))
        XCTAssertEqual(viewModel.questionNumber, 0)
        XCTAssertTrue(analytics.gameEnds.isEmpty)
        XCTAssertFalse(viewModel.shouldPresentResultView)
    }

    func testRestartDiscardsUndeliveredEffectsFromThePriorGeneration() {
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            scheduler: TestScheduler()
        )
        viewModel.stopTimer()
        viewModel.increaseScoreForCorrectAnswer()
        viewModel.restartGame()

        let effects = viewModel.consumeSessionEffects()
        XCTAssertFalse(effects.contains {
            if case .answerLocked = $0 { return true }
            return false
        })
        XCTAssertTrue(effects.contains {
            if case .pendingWorkCancelled = $0 { return true }
            return false
        })
        XCTAssertEqual(viewModel.sessionState.phase, .answering)
    }

    func testTerminalSessionCannotAdvanceOrRecordAnotherSeenQuestion() throws {
        let manager = try makeProgressManager(store: FakePersistenceStore())
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            scheduler: TestScheduler()
        )
        viewModel.progressManager = manager
        viewModel.exitGame()
        viewModel.goToNextQuestion()

        XCTAssertEqual(viewModel.questionNumber, 0)
        XCTAssertEqual(viewModel.sessionState.phase, .terminal(.exited))
        XCTAssertFalse(manager.progress.seenQuestionIDs.contains(questions[1].id))
    }

    func testRestartingEmptySessionKeepsTerminalPresentationAndDoesNotStartTimer() {
        let scheduler = TestScheduler()
        let viewModel = QuizViewModel(
            questions: [],
            gameMode: .singlePlayer,
            selectedCategory: nil,
            scheduler: scheduler
        )

        viewModel.restartGame()

        XCTAssertEqual(viewModel.sessionState.phase, .terminal(.emptySession))
        XCTAssertTrue(viewModel.shouldPresentResultView)
        XCTAssertEqual(scheduler.pendingTaskCount, 0)
    }

    func testCompletedTerminalProcessingAndRewardedAdRequestsAreExactlyOnce() throws {
        let analytics = RecordingAnalytics()
        let rewardAd = FakeRewardAdProvider(isLoaded: true)
        let manager = try makeProgressManager(store: FakePersistenceStore())
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            analytics: analytics,
            rewardAd: rewardAd,
            scheduler: TestScheduler()
        )
        viewModel.progressManager = manager
        viewModel.stopTimer()

        viewModel.endGame()
        viewModel.endGame()
        XCTAssertEqual(analytics.gameEnds.count, 1)
        XCTAssertEqual(manager.lifetimeGamesPlayed, 1)

        let adAnalytics = RecordingAnalytics()
        let adViewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            analytics: adAnalytics,
            rewardAd: rewardAd,
            scheduler: TestScheduler()
        )
        adViewModel.stopTimer()
        adViewModel.showRewardAd()
        adViewModel.showRewardAd()
        XCTAssertEqual(rewardAd.showCount, 1)
        rewardAd.completeReward(earned: true)
        rewardAd.repeatLastCompletion(earned: true)
        XCTAssertEqual(adViewModel.livesRemaining, 4)
        XCTAssertEqual(adAnalytics.extraLives, [.ad])
    }

    private func makeProgressManager(
        store: FakePersistenceStore,
        rules: QuizRulesConfiguration = .serbianCompatible,
        clock: any QuizEngineClock = TestClock(
            now: Date(timeIntervalSinceReferenceDate: 0)
        )
    ) throws -> PlayerProgressManager {
        let resource = QuestionResource(bundle: .main, fileName: "unused")
        let variant = try QuizVariantDefinition(
            categories: [
                QuizCategoryDefinition(
                    id: "alpha",
                    displayNameKey: "category.alpha",
                    iconName: "a.circle",
                    displayOrder: 0,
                    unlockRequirement: .free
                ),
                QuizCategoryDefinition(
                    id: "beta",
                    displayNameKey: "category.beta",
                    iconName: "b.circle",
                    displayOrder: 1,
                    unlockRequirement: .free
                )
            ],
            achievements: [],
            questionResource: resource,
            rules: rules
        )
        return try PlayerProgressManager(
            variant: variant,
            questionDataService: QuestionDataService(resource: resource, rules: rules),
            persistenceStore: store,
            clock: clock
        )
    }
}

private final class LegacyPowerUpAnalytics: AnalyticsProvider {
    private let state = OSAllocatedUnfairLock(initialState: [(PowerUp, Int)]())

    var events: [(PowerUp, Int)] {
        state.withLock { $0 }
    }

    func logPowerUpUsed(type: PowerUp, coinsSpent: Int) {
        state.withLock { $0.append((type, coinsSpent)) }
    }
}
