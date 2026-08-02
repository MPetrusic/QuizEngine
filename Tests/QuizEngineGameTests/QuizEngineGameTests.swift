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
}
