import XCTest
import QuizEngineCore
import QuizEngineTestSupport
@testable import QuizEngineMultiplayer

@MainActor
final class QuizEngineMultiplayerTests: XCTestCase {
    private func makeRules(multiplayer: QuizMultiplayerRules) throws -> QuizRulesConfiguration {
        let defaults = QuizRulesConfiguration.serbianCompatible
        return try QuizRulesConfiguration(
            economy: defaults.economy,
            solo: defaults.solo,
            powerUps: defaults.powerUps,
            extraLife: defaults.extraLife,
            sessions: defaults.sessions,
            soloInterstitialEligibility: defaults.soloInterstitialEligibility,
            multiplayer: multiplayer
        )
    }

    func testGameConfigurationRoundTripsVariantQuestionsWithoutChangingIdentifiers() throws {
        let questions = [
            Question(
                id: 901,
                question: "Alternate variant question",
                answers: [Answer(text: "Correct", correct: true), Answer(text: "Wrong", correct: false)],
                categories: ["alternate-category"],
                difficulty: 3
            )
        ]
        let message = MultiplayerMessage.gameConfig(GameConfigPayload(questions: questions, seed: 42))

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(MultiplayerMessage.self, from: data)

        guard case .gameConfig(let configuration) = decoded else {
            return XCTFail("Expected game configuration")
        }
        XCTAssertEqual(configuration.seed, 42)
        XCTAssertEqual(configuration.questions, questions)
        XCTAssertEqual(configuration.questions.first?.categories, ["alternate-category"])
    }

    func testSeededAnswerShuffleIsDeterministicAcrossPeers() {
        let answers = ["A", "B", "C", "D"]
        var hostRNG = SeededRandomNumberGenerator(seed: 12345)
        var guestRNG = SeededRandomNumberGenerator(seed: 12345)

        XCTAssertEqual(answers.shuffled(using: &hostRNG), answers.shuffled(using: &guestRNG))
    }

    func testIdenticalSeededViewModelsProduceIdenticalMatchSeedAndAnswerOrder() {
        let question = Question(
            id: 1,
            question: "Question",
            answers: [
                Answer(text: "A", correct: true),
                Answer(text: "B", correct: false),
                Answer(text: "C", correct: false),
                Answer(text: "D", correct: false)
            ],
            categories: ["alpha"]
        )
        let firstCoordinator = hostCoordinator()
        let secondCoordinator = hostCoordinator()
        let first = MultiplayerQuizViewModel(
            gameCoordinator: firstCoordinator,
            clock: TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000)),
            scheduler: TestScheduler(),
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 16)
        )
        let second = MultiplayerQuizViewModel(
            gameCoordinator: secondCoordinator,
            clock: TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000)),
            scheduler: TestScheduler(),
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 16)
        )

        first.setupAsHost(questions: [question], localDisplayName: "Host")
        second.setupAsHost(questions: [question], localDisplayName: "Host")

        XCTAssertEqual(first.questions, second.questions)
        XCTAssertEqual(first.shuffledAnswers, second.shuffledAnswers)
        first.endMatch()
        second.endMatch()
    }

    func testMultiplayerTimerUsesInjectedClockAndSchedulerWithoutWaiting() {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = TestScheduler()
        let viewModel = timedViewModel(clock: clock, scheduler: scheduler)

        clock.advance(by: 10)
        scheduler.advance(by: 0.01)

        XCTAssertEqual(viewModel.timeRemainingMs, 0)
        XCTAssertEqual(viewModel.myAnswerIndex, MultiplayerQuizViewModel.timeoutAnswerIndex)
        viewModel.endMatch()
    }

    func testAnswerAtLogicalDeadlineCannotBeatPendingTimeoutCallback() {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = TestScheduler()
        let viewModel = timedViewModel(clock: clock, scheduler: scheduler)

        clock.advance(by: 10)
        viewModel.submitAnswer(answerIndex: 0)

        XCTAssertEqual(viewModel.timeRemainingMs, 0)
        XCTAssertEqual(viewModel.myAnswerIndex, MultiplayerQuizViewModel.timeoutAnswerIndex)
        viewModel.endMatch()
    }

    func testClockRollbackCannotIncreaseMultiplayerTimer() {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = TestScheduler()
        let viewModel = timedViewModel(clock: clock, scheduler: scheduler)

        clock.advance(by: 2)
        scheduler.advance(by: 0.01)
        XCTAssertEqual(viewModel.timeRemainingMs, 8_000)

        clock.advance(by: -10)
        scheduler.advance(by: 0.01)
        XCTAssertEqual(viewModel.timeRemainingMs, 8_000)
        viewModel.endMatch()
    }

    func testMultiplayerBackgroundExcludesPausedDuration() {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = TestScheduler()
        let viewModel = timedViewModel(clock: clock, scheduler: scheduler)

        clock.advance(by: 2)
        scheduler.advance(by: 0.01)
        XCTAssertEqual(viewModel.timeRemainingMs, 8_000)
        viewModel.handleAppBackgrounded()

        clock.advance(by: 100)
        scheduler.advance(by: 100)
        XCTAssertEqual(viewModel.timeRemainingMs, 8_000)

        viewModel.handleAppForegrounded()
        clock.advance(by: 1)
        scheduler.advance(by: 0.01)
        XCTAssertEqual(viewModel.timeRemainingMs, 7_000)
        viewModel.endMatch()
    }

    func testMultiplayerRejectsTimerCallbacksDeliveredAfterCancellation() {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = CancellationIgnoringTestScheduler()
        let coordinator = MultiplayerGameCoordinator(scheduler: TestScheduler())
        coordinator.startGame(
            transport: FakeTransport(),
            opponent: MultiplayerPlayer(id: "host", displayName: "Host"),
            role: .guest
        )
        let viewModel = MultiplayerQuizViewModel(
            gameCoordinator: coordinator,
            clock: clock,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 20)
        )
        viewModel.handleGameConfig(
            GameConfigPayload(
                questions: [
                    Question(
                        id: 1,
                        question: "Question",
                        answers: [
                            Answer(text: "A", correct: true),
                            Answer(text: "B", correct: false)
                        ],
                        categories: ["alpha"]
                    )
                ],
                seed: 20
            ),
            localDisplayName: "Guest"
        )

        viewModel.startRound()
        viewModel.startRound()
        clock.advance(by: 1)
        scheduler.runPendingBatch()

        XCTAssertEqual(viewModel.timeRemainingMs, 9_000)
        XCTAssertEqual(scheduler.pendingTaskCount, 1)
        viewModel.endMatch()
    }

    func testConnectionManagerStartsGenericInboundTransportWithoutVendorTypes() {
        let manager = MultiplayerConnectionManager()
        let transport = FakeTransport()
        var prepared = false

        manager.startConnecting(using: transport) {
            prepared = true
        }

        XCTAssertTrue(prepared)
        guard case .connecting = manager.connectionState else {
            return XCTFail("Expected generic inbound connection state")
        }
    }

    func testCoordinatorTimeoutUsesInjectedScheduler() {
        let scheduler = TestScheduler()
        let coordinator = MultiplayerGameCoordinator(scheduler: scheduler)
        let transport = FakeTransport()
        let opponent = MultiplayerPlayer(id: "opponent", displayName: "Opponent")

        coordinator.startGame(
            transport: transport,
            opponent: opponent,
            role: .guest
        )
        scheduler.advance(by: 10)

        guard case .disconnected = coordinator.sessionState else {
            return XCTFail("Expected the guest configuration timeout to disconnect")
        }
    }

    func testSerbianCompatibleMultiplayerScoringAndRewardsAreUnchanged() {
        let rules = QuizRulesConfiguration.serbianCompatible.multiplayer

        XCTAssertEqual(
            MultiplayerRuleEvaluator.points(
                hostCorrect: true,
                guestCorrect: true,
                hostMilliseconds: 100,
                guestMilliseconds: 105,
                hostSkipped: false,
                guestSkipped: false,
                rules: rules
            ).host,
            MultiplayerQuizViewModel.pointsTieCorrect
        )
        let faster = MultiplayerRuleEvaluator.points(
            hostCorrect: true,
            guestCorrect: true,
            hostMilliseconds: 100,
            guestMilliseconds: 200,
            hostSkipped: false,
            guestSkipped: false,
            rules: rules
        )
        XCTAssertEqual(faster.host, MultiplayerQuizViewModel.pointsFasterCorrect)
        XCTAssertEqual(faster.guest, MultiplayerQuizViewModel.pointsSlowerCorrect)
        let wrong = MultiplayerRuleEvaluator.points(
            hostCorrect: false,
            guestCorrect: false,
            hostMilliseconds: 100,
            guestMilliseconds: 100,
            hostSkipped: false,
            guestSkipped: true,
            rules: rules
        )
        XCTAssertEqual(wrong.host, MultiplayerQuizViewModel.pointsWrong)
        XCTAssertEqual(wrong.guest, 0)

        XCTAssertEqual(
            MultiplayerRuleEvaluator.totalCoins(
                correctAnswers: 3,
                questionsCompleted: 4,
                result: .won,
                isPremium: false,
                rules: rules.rewards
            ),
            3
        )
        XCTAssertEqual(
            MultiplayerRuleEvaluator.totalCoins(
                correctAnswers: 3,
                questionsCompleted: 5,
                result: .won,
                isPremium: false,
                rules: rules.rewards
            ),
            5
        )
        XCTAssertEqual(
            MultiplayerRuleEvaluator.totalCoins(
                correctAnswers: 3,
                questionsCompleted: 10,
                result: .won,
                isPremium: false,
                rules: rules.rewards
            ),
            8
        )
        XCTAssertEqual(
            MultiplayerRuleEvaluator.totalCoins(
                correctAnswers: 3,
                questionsCompleted: 10,
                result: .won,
                isPremium: true,
                rules: rules.rewards
            ),
            11
        )
    }

    func testCustomMultiplayerScoringAndStrictAntiFarmingThresholds() throws {
        let rewards = QuizMultiplayerRewardRules(
            correctAnswerCoins: 4,
            standardOutcomeRewards: QuizMultiplayerOutcomeRewards(win: 12, loss: 6, draw: 8, opponentDisconnected: 2),
            premiumOutcomeRewards: QuizMultiplayerOutcomeRewards(win: 20, loss: 10, draw: 14, opponentDisconnected: 4),
            minimumQuestionsForAnyReward: 5,
            minimumQuestionsForOutcomeBonus: 5,
            questionsForFullOutcomeBonus: 8,
            partialRewardDivisor: 3
        )
        let multiplayer = QuizMultiplayerRules(
            timerDurationMilliseconds: 7_000,
            tieThresholdMilliseconds: 50,
            scoring: QuizMultiplayerScoringRules(
                fasterCorrectPoints: 30,
                slowerCorrectPoints: 2,
                tiedCorrectPoints: 11,
                wrongAnswerPoints: -9
            ),
            rewards: rewards,
            interstitialEligibility: QuizInterstitialEligibilityRules(numerator: 0, denominator: 1)
        )
        let rules = try makeRules(multiplayer: multiplayer)
        let tied = MultiplayerRuleEvaluator.points(
            hostCorrect: true,
            guestCorrect: true,
            hostMilliseconds: 100,
            guestMilliseconds: 149,
            hostSkipped: false,
            guestSkipped: false,
            rules: multiplayer
        )
        XCTAssertEqual(tied.host, 11)
        XCTAssertEqual(tied.guest, 11)
        XCTAssertEqual(
            MultiplayerRuleEvaluator.totalCoins(
                correctAnswers: 4,
                questionsCompleted: 4,
                result: .won,
                isPremium: false,
                rules: rewards
            ),
            0
        )
        XCTAssertEqual(
            MultiplayerRuleEvaluator.totalCoins(
                correctAnswers: 4,
                questionsCompleted: 5,
                result: .won,
                isPremium: false,
                rules: rewards
            ),
            20
        )
        XCTAssertEqual(
            MultiplayerRuleEvaluator.totalCoins(
                correctAnswers: 4,
                questionsCompleted: 8,
                result: .opponentDisconnected,
                isPremium: true,
                rules: rewards
            ),
            20
        )

        let viewModel = MultiplayerQuizViewModel(
            gameCoordinator: MultiplayerGameCoordinator(scheduler: TestScheduler()),
            rules: rules,
            scheduler: TestScheduler(),
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 92)
        )
        XCTAssertEqual(viewModel.timeRemainingMs, 7_000)
        XCTAssertEqual(viewModel.rules.multiplayer.rewards.minimumQuestionsForAnyReward, 5)
        viewModel.endMatch()
    }

    func testCustomMultiplayerInterstitialEligibilityHonorsEntitlements() throws {
        let defaults = QuizRulesConfiguration.serbianCompatible
        let alwaysMultiplayer = QuizMultiplayerRules(
            timerDurationMilliseconds: defaults.multiplayer.timerDurationMilliseconds,
            tieThresholdMilliseconds: defaults.multiplayer.tieThresholdMilliseconds,
            scoring: defaults.multiplayer.scoring,
            rewards: defaults.multiplayer.rewards,
            interstitialEligibility: QuizInterstitialEligibilityRules(numerator: 1, denominator: 1)
        )
        let rules = try makeRules(multiplayer: alwaysMultiplayer)
        let standardAd = FakeInterstitialAdProvider(ready: true)
        let premiumAd = FakeInterstitialAdProvider(ready: true)
        let standard = MultiplayerQuizViewModel(
            gameCoordinator: MultiplayerGameCoordinator(scheduler: TestScheduler()),
            rules: rules,
            interstitialAd: standardAd,
            scheduler: TestScheduler()
        )
        let premium = MultiplayerQuizViewModel(
            gameCoordinator: MultiplayerGameCoordinator(scheduler: TestScheduler()),
            rules: rules,
            interstitialAd: premiumAd,
            purchaseStatus: FakePurchaseStatus(isPremium: true),
            scheduler: TestScheduler()
        )

        standard.showInterstitialAdIfEligible()
        premium.showInterstitialAdIfEligible()
        XCTAssertEqual(standardAd.showCount, 1)
        XCTAssertEqual(premiumAd.showCount, 0)
        standard.endMatch()
        premium.endMatch()
    }

    private func hostCoordinator() -> MultiplayerGameCoordinator {
        let coordinator = MultiplayerGameCoordinator(scheduler: TestScheduler())
        coordinator.startGame(
            transport: FakeTransport(),
            opponent: MultiplayerPlayer(id: "guest", displayName: "Guest"),
            role: .host
        )
        return coordinator
    }

    private func timedViewModel(
        clock: TestClock,
        scheduler: TestScheduler
    ) -> MultiplayerQuizViewModel {
        let coordinator = hostCoordinator()
        let viewModel = MultiplayerQuizViewModel(
            gameCoordinator: coordinator,
            clock: clock,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 17)
        )
        viewModel.setupAsHost(
            questions: [
                Question(
                    id: 1,
                    question: "Question",
                    answers: [
                        Answer(text: "A", correct: true),
                        Answer(text: "B", correct: false)
                    ],
                    categories: ["alpha"]
                )
            ],
            localDisplayName: "Host"
        )
        viewModel.startRound()
        return viewModel
    }
}
