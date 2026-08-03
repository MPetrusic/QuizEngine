import XCTest
import QuizEngineCore
import QuizEngineTestSupport
@testable import QuizEngineGame

@MainActor
final class QuizEngineGameTests: XCTestCase {
    private let questions = [
        Question(id: 1, question: "First", answers: [Answer(text: "A", correct: true)], categories: ["alpha"]),
        Question(id: 2, question: "Second", answers: [Answer(text: "B", correct: true)], categories: ["beta"])
    ]

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
        let viewModel = QuizViewModel(questions: questions, gameMode: .singlePlayer, selectedCategory: nil)
        viewModel.stopTimer()

        for _ in 0..<6 {
            viewModel.increaseScoreForCorrectAnswer()
            viewModel.stopTimer()
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

    private func makeProgressManager(store: FakePersistenceStore) throws -> PlayerProgressManager {
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
            questionResource: resource
        )
        return try PlayerProgressManager(
            variant: variant,
            questionDataService: QuestionDataService(resource: resource),
            persistenceStore: store,
            clock: TestClock(now: Date(timeIntervalSinceReferenceDate: 0))
        )
    }
}

private final class LegacyPowerUpAnalytics: AnalyticsProvider, @unchecked Sendable {
    private(set) var events: [(PowerUp, Int)] = []

    func logPowerUpUsed(type: PowerUp, coinsSpent: Int) {
        events.append((type, coinsSpent))
    }
}
