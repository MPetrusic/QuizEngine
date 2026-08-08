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

    func testTerminalRecordFingerprintUsesStableCanonicalEncoding() {
        let record = MultiplayerTerminalRecord(
            matchID: "match-1",
            localRole: .guest,
            terminalReason: .completed,
            hostFinalScore: -5,
            guestFinalScore: 10,
            questionsCompleted: 1,
            questionsCorrect: 1,
            awardedCoins: 3,
            responseTimes: [150, 200]
        )

        XCTAssertEqual(
            record.fingerprint,
            "qeb01-v1|8:match_id|7:match-1|10:local_role|5:guest|15:terminal_reason|9:completed|16:host_final_score|2:-5|17:guest_final_score|2:10|19:questions_completed|1:1|17:questions_correct|1:1|13:awarded_coins|1:3|17:response_times_ms|7:150,200"
        )
        XCTAssertEqual(
            record.fingerprint,
            MultiplayerTerminalRecord(
                matchID: "match-1",
                localRole: .guest,
                terminalReason: .completed,
                hostFinalScore: -5,
                guestFinalScore: 10,
                questionsCompleted: 1,
                questionsCorrect: 1,
                awardedCoins: 3,
                responseTimes: [150, 200]
            ).fingerprint
        )
        XCTAssertNotEqual(
            record.fingerprint,
            MultiplayerTerminalRecord(
                matchID: "match-1",
                localRole: .host,
                terminalReason: .completed,
                hostFinalScore: -5,
                guestFinalScore: 10,
                questionsCompleted: 1,
                questionsCorrect: 1,
                awardedCoins: 3,
                responseTimes: [150, 200]
            ).fingerprint
        )
    }

    func testTerminalCommitFailureRemainsPendingAndDoesNotMutateProgress() async throws {
        let store = FakePersistenceStore()
        let analytics = RecordingAnalytics()
        let matchID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let harness = try await makeTerminalHarness(store: store, analytics: analytics, matchID: matchID)
        let before = ProgressSnapshot(harness.manager.progress)
        store.failurePoint = .replacePrimary

        await deliverTerminal(to: harness)

        XCTAssertEqual(ProgressSnapshot(harness.manager.progress), before)
        XCTAssertEqual(harness.manager.progress.multiplayerMatchReceipts.count, 0)
        XCTAssertEqual(store.replacePrimaryAttemptCount, 1)
        XCTAssertEqual(analytics.multiplayerCompletions.count, 0)
        assertPending(harness.viewModel, failure: .persistenceFailed)
    }

    func testPendingTerminalCommitRetriesOnceAndRecordsRewardOnce() async throws {
        let store = FakePersistenceStore()
        let analytics = RecordingAnalytics()
        let matchID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
        let harness = try await makeTerminalHarness(store: store, analytics: analytics, matchID: matchID)
        store.failurePoint = .replacePrimary
        await deliverTerminal(to: harness)

        harness.viewModel.retryPendingTerminalCommit()

        assertRecordedProgress(harness.manager.progress, initialCoins: 100)
        XCTAssertEqual(harness.manager.progress.multiplayerMatchReceipts.count, 1)
        XCTAssertEqual(store.replacePrimaryAttemptCount, 2)
        XCTAssertEqual(analytics.multiplayerCompletions.count, 1)
        XCTAssertEqual(
            harness.viewModel.terminalCommitState,
            .committed(receiptID: matchID.uuidString.lowercased())
        )
        XCTAssertNil(harness.viewModel.terminalCommitFailure)

        harness.viewModel.retryPendingTerminalCommit()
        assertRecordedProgress(harness.manager.progress, initialCoins: 100)
        XCTAssertEqual(harness.manager.progress.multiplayerMatchReceipts.count, 1)
        XCTAssertEqual(store.replacePrimaryAttemptCount, 2)
        XCTAssertEqual(analytics.multiplayerCompletions.count, 1)
    }

    func testDuplicateTerminalDuringCommitDoesNotStartSecondWrite() async throws {
        let store = FakePersistenceStore()
        let analytics = RecordingAnalytics()
        let matchID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
        let harness = try await makeTerminalHarness(store: store, analytics: analytics, matchID: matchID)
        var observedCommittingState = false
        store.onReplacePrimaryAttempt = {
            if case .committing = harness.viewModel.terminalCommitState {
                observedCommittingState = true
            }
            harness.viewModel.retryPendingTerminalCommit()
        }

        await deliverTerminal(to: harness)
        store.onReplacePrimaryAttempt = nil

        XCTAssertTrue(observedCommittingState)
        assertRecordedProgress(harness.manager.progress, initialCoins: 100)
        XCTAssertEqual(harness.manager.progress.multiplayerMatchReceipts.count, 1)
        XCTAssertEqual(store.replacePrimaryAttemptCount, 1)
        XCTAssertEqual(analytics.multiplayerCompletions.count, 1)
        XCTAssertEqual(
            harness.viewModel.terminalCommitState,
            .committed(receiptID: matchID.uuidString.lowercased())
        )
        XCTAssertNil(harness.viewModel.terminalCommitFailure)
    }

    func testDuplicateTerminalAfterCommitDoesNotAwardOrLogAgain() async throws {
        let store = FakePersistenceStore()
        let analytics = RecordingAnalytics()
        let matchID = UUID(uuidString: "00000000-0000-0000-0000-000000000104")!
        let harness = try await makeTerminalHarness(store: store, analytics: analytics, matchID: matchID)
        let terminalData = try terminalPayloadData(matchID: matchID, hostScore: -5, guestScore: 10)
        harness.transport.emitRaw(terminalData, from: harness.opponent)
        await drainTransportEvents()

        harness.transport.emitRaw(terminalData, from: harness.opponent)
        await drainTransportEvents()
        harness.viewModel.retryPendingTerminalCommit()

        assertRecordedProgress(harness.manager.progress, initialCoins: 100)
        XCTAssertEqual(harness.manager.progress.multiplayerMatchReceipts.count, 1)
        XCTAssertEqual(store.replacePrimaryAttemptCount, 1)
        XCTAssertEqual(analytics.multiplayerCompletions.count, 1)
        XCTAssertEqual(
            harness.viewModel.terminalCommitState,
            .committed(receiptID: matchID.uuidString.lowercased())
        )
        XCTAssertNil(harness.viewModel.terminalCommitFailure)
    }

    func testRecreatedViewModelWithSameReceiptDoesNotAwardAgain() async throws {
        let store = FakePersistenceStore()
        let firstAnalytics = RecordingAnalytics()
        let matchID = UUID(uuidString: "00000000-0000-0000-0000-000000000105")!
        let first = try await makeTerminalHarness(store: store, analytics: firstAnalytics, matchID: matchID)
        await deliverTerminal(to: first)
        assertRecordedProgress(first.manager.progress, initialCoins: 100)

        let secondAnalytics = RecordingAnalytics()
        let second = try await makeTerminalHarness(store: store, analytics: secondAnalytics, matchID: matchID)
        await deliverTerminal(to: second)

        assertRecordedProgress(second.manager.progress, initialCoins: 100)
        XCTAssertEqual(second.manager.progress.multiplayerMatchReceipts.count, 1)
        XCTAssertEqual(store.replacePrimaryAttemptCount, 1)
        XCTAssertEqual(firstAnalytics.multiplayerCompletions.count, 1)
        XCTAssertEqual(secondAnalytics.multiplayerCompletions.count, 0)
        XCTAssertEqual(
            second.viewModel.terminalCommitState,
            .committed(receiptID: matchID.uuidString.lowercased())
        )
        XCTAssertNil(second.viewModel.terminalCommitFailure)
    }

    func testConflictingTerminalFingerprintIsSurfacedAndNeverApplied() async throws {
        let store = FakePersistenceStore()
        let firstAnalytics = RecordingAnalytics()
        let matchID = UUID(uuidString: "00000000-0000-0000-0000-000000000106")!
        let first = try await makeTerminalHarness(store: store, analytics: firstAnalytics, matchID: matchID)
        await deliverTerminal(to: first)
        let recorded = ProgressSnapshot(first.manager.progress)

        let conflictingAnalytics = RecordingAnalytics()
        let conflicting = try await makeTerminalHarness(
            store: store,
            analytics: conflictingAnalytics,
            matchID: matchID,
            hostScore: -5,
            guestScore: 11
        )
        await deliverTerminal(to: conflicting, hostScore: -5, guestScore: 11)

        XCTAssertEqual(ProgressSnapshot(conflicting.manager.progress), recorded)
        XCTAssertEqual(conflicting.manager.progress.multiplayerMatchReceipts.count, 1)
        XCTAssertEqual(store.replacePrimaryAttemptCount, 1)
        XCTAssertEqual(firstAnalytics.multiplayerCompletions.count, 1)
        XCTAssertEqual(conflictingAnalytics.multiplayerCompletions.count, 0)
        assertPending(conflicting.viewModel, failure: .conflictingReceipt)
    }

    func testTerminalCommitOverflowIsRejectedWithoutPartialMutation() async throws {
        var overflowProgress = PlayerProgress.default
        overflowProgress.coins = Int.max
        overflowProgress.totalCoinsEarned = Int.max
        let store = FakePersistenceStore(primaryData: try PropertyListEncoder().encode(overflowProgress))
        let analytics = RecordingAnalytics()
        let matchID = UUID(uuidString: "00000000-0000-0000-0000-000000000107")!
        let harness = try await makeTerminalHarness(store: store, analytics: analytics, matchID: matchID)
        let before = ProgressSnapshot(harness.manager.progress)

        await deliverTerminal(to: harness)

        XCTAssertEqual(ProgressSnapshot(harness.manager.progress), before)
        XCTAssertEqual(harness.manager.progress.multiplayerMatchReceipts.count, 0)
        XCTAssertEqual(store.replacePrimaryAttemptCount, 0)
        XCTAssertEqual(analytics.multiplayerCompletions.count, 0)
        assertPending(harness.viewModel, failure: .rejected)
    }

    func testTerminalCommitAnalyticsOccursOnlyAfterDurableSave() async throws {
        let store = FakePersistenceStore()
        let analytics = RecordingAnalytics()
        let matchID = UUID(uuidString: "00000000-0000-0000-0000-000000000108")!
        let harness = try await makeTerminalHarness(store: store, analytics: analytics, matchID: matchID)
        store.failurePoint = .replacePrimary

        await deliverTerminal(to: harness)
        XCTAssertEqual(analytics.multiplayerCompletions.count, 0)
        XCTAssertEqual(store.replacePrimaryAttemptCount, 1)
        assertPending(harness.viewModel, failure: .persistenceFailed)

        harness.viewModel.retryPendingTerminalCommit()

        assertRecordedProgress(harness.manager.progress, initialCoins: 100)
        XCTAssertEqual(harness.manager.progress.multiplayerMatchReceipts.count, 1)
        XCTAssertEqual(store.replacePrimaryAttemptCount, 2)
        XCTAssertEqual(
            analytics.multiplayerCompletions,
            [
                .init(
                    result: "won",
                    myScore: 10,
                    opponentScore: -5,
                    questionsCompleted: 1,
                    durationSeconds: 0,
                    transportType: "test"
                )
            ]
        )
        XCTAssertEqual(
            harness.viewModel.terminalCommitState,
            .committed(receiptID: matchID.uuidString.lowercased())
        )
        XCTAssertNil(harness.viewModel.terminalCommitFailure)
    }

    func testHardenedHandshakeRequiresExactContentAndCapabilities() async throws {
        let scheduler = TestScheduler()
        let coordinator = MultiplayerGameCoordinator(scheduler: scheduler)
        let transport = FakeTransport()
        let opponent = MultiplayerPlayer(id: "host", displayName: "Host")
        let configuration = try hardenedConfiguration(contentVersion: "content-a")
        coordinator.startGame(transport: transport, opponent: opponent, role: .guest, matchConfiguration: configuration)

        let envelope = MultiplayerWireEnvelope(
            matchID: UUID(), sequence: 0,
            payload: .hello(.init(
                protocolVersion: MultiplayerMatchConfiguration.protocolVersion,
                contentVersion: "content-a",
                capabilities: MultiplayerMatchConfiguration.requiredQE6Capabilities
            ))
        )
        transport.emitRaw(try MultiplayerWireCodec.encode(envelope), from: opponent)
        await drainTransportEvents()

        XCTAssertTrue(coordinator.handshakeAccepted)
        XCTAssertEqual(coordinator.handshakeStatus, .accepted)
        XCTAssertEqual(transport.sentRawPayloads.count, 1)
    }

    func testHardenedHandshakeRejectsContentMismatchAndMalformedPayloadOnce() async throws {
        let coordinator = MultiplayerGameCoordinator(scheduler: TestScheduler())
        let transport = FakeTransport()
        let opponent = MultiplayerPlayer(id: "host", displayName: "Host")
        let configuration = try hardenedConfiguration(contentVersion: "content-a")
        coordinator.startGame(transport: transport, opponent: opponent, role: .guest, matchConfiguration: configuration)
        transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: UUID(), sequence: 0,
            payload: .hello(.init(protocolVersion: 1, contentVersion: "content-b", capabilities: MultiplayerMatchConfiguration.requiredQE6Capabilities))
        )), from: opponent)
        await drainTransportEvents()
        XCTAssertEqual(coordinator.terminalFailure, .contentMismatch)
        let terminal = coordinator.gameEndResult
        transport.emitRaw(Data(repeating: 0, count: MultiplayerWireCodec.maximumPayloadBytes + 1), from: opponent)
        await drainTransportEvents()
        XCTAssertEqual(coordinator.gameEndResult, terminal)
    }

    func testHardenedPayloadReplayAndFutureRoundAreHarmless() async throws {
        let coordinator = MultiplayerGameCoordinator(scheduler: TestScheduler())
        let transport = FakeTransport()
        let opponent = MultiplayerPlayer(id: "host", displayName: "Host")
        let configuration = try hardenedConfiguration(contentVersion: "content-a")
        coordinator.startGame(transport: transport, opponent: opponent, role: .guest, matchConfiguration: configuration)
        let matchID = UUID()
        transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: matchID, sequence: 0,
            payload: .hello(.init(protocolVersion: 1, contentVersion: "content-a", capabilities: MultiplayerMatchConfiguration.requiredQE6Capabilities))
        )), from: opponent)
        await drainTransportEvents()

        let config = GameConfigPayload(questions: [
            Question(id: 10, question: "Q", answers: [Answer(text: "A", correct: true), Answer(text: "B", correct: false)], categories: ["alpha"])
        ], seed: 1)
        let messageID = UUID()
        let valid = MultiplayerWireEnvelope(matchID: matchID, sequence: 1, messageID: messageID, payload: .gameConfig(.init(config)))
        transport.emitRaw(try MultiplayerWireCodec.encode(valid), from: opponent)
        await drainTransportEvents()
        transport.emitRaw(try MultiplayerWireCodec.encode(valid), from: opponent)
        transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: matchID, sequence: 3, payload: .playerReady(roundIndex: 99)
        )), from: opponent)
        transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: matchID, sequence: 2, payload: .playerReady(roundIndex: 0)
        )), from: opponent)
        await drainTransportEvents()
        coordinator.questionsCompleted = 1
        coordinator.lastHostScore = 10
        coordinator.lastGuestScore = 5
        transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: matchID, sequence: 4,
            payload: .gameEnd(.init(hostFinalScore: 999, guestFinalScore: 5, reason: .completed))
        )), from: opponent)
        await drainTransportEvents()

        XCTAssertEqual(coordinator.receivedGameConfig, config)
        XCTAssertTrue(coordinator.opponentReady)
        XCTAssertNil(coordinator.terminalFailure)
        XCTAssertNil(coordinator.gameEndResult)

        transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: UUID(), sequence: 5, payload: .pause
        )), from: opponent)
        await drainTransportEvents()
        XCTAssertNil(coordinator.terminalFailure)
    }

    func testHardenedGameConfigurationRejectsUnplayableFields() async throws {
        let coordinator = MultiplayerGameCoordinator(scheduler: TestScheduler())
        let transport = FakeTransport()
        let opponent = MultiplayerPlayer(id: "host", displayName: "Host")
        let configuration = try hardenedConfiguration(contentVersion: "content-a")
        coordinator.startGame(transport: transport, opponent: opponent, role: .guest, matchConfiguration: configuration)
        let matchID = UUID()
        transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: matchID, sequence: 0,
            payload: .hello(.init(protocolVersion: 1, contentVersion: "content-a", capabilities: MultiplayerMatchConfiguration.requiredQE6Capabilities))
        )), from: opponent)
        await drainTransportEvents()

        let invalid = GameConfigPayload(questions: [
            Question(id: 10, question: "", answers: [Answer(text: "A", correct: true), Answer(text: "B", correct: false)], categories: [])
        ], seed: 1)
        transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: matchID, sequence: 1, payload: .gameConfig(.init(invalid))
        )), from: opponent)
        await drainTransportEvents()

        XCTAssertEqual(coordinator.terminalFailure, .malformedPayload)
    }

    func testHardenedWrongSenderIsIgnoredAndLegacyTransportIsRejected() async throws {
        let configuration = try hardenedConfiguration(contentVersion: "content-a")
        let coordinator = MultiplayerGameCoordinator(scheduler: TestScheduler())
        let transport = FakeTransport()
        coordinator.startGame(
            transport: transport,
            opponent: MultiplayerPlayer(id: "host", displayName: "Host"),
            role: .guest,
            matchConfiguration: configuration
        )
        transport.emitRaw(Data(), from: MultiplayerPlayer(id: "attacker", displayName: "Attacker"))
        await drainTransportEvents()
        XCTAssertNil(coordinator.terminalFailure)

        let legacyCoordinator = MultiplayerGameCoordinator(scheduler: TestScheduler())
        legacyCoordinator.startGame(
            transport: LegacyTransport(),
            opponent: MultiplayerPlayer(id: "host", displayName: "Host"),
            role: .guest,
            matchConfiguration: configuration
        )
        XCTAssertEqual(legacyCoordinator.terminalFailure, .unsupportedWireTransport)
    }

    private func hardenedConfiguration(contentVersion: String) throws -> MultiplayerMatchConfiguration {
        try MultiplayerMatchConfiguration(contentVersion: contentVersion, analyticsTransportLabel: "test")
    }

    private func makeTerminalHarness(
        store: FakePersistenceStore,
        analytics: RecordingAnalytics,
        matchID: UUID,
        hostScore: Int = -5,
        guestScore: Int = 10
    ) async throws -> TerminalHarness {
        let variant = try QuizEngineTestFixtures.variant(
            questionResource: QuestionResource(bundle: .main, fileName: "unused")
        )
        let manager = try PlayerProgressManager(
            variant: variant,
            questionDataService: QuestionDataService(variant: variant),
            persistenceStore: store,
            clock: TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        )
        let coordinator = MultiplayerGameCoordinator(scheduler: TestScheduler())
        let transport = FakeTransport(localPlayer: MultiplayerPlayer(id: "guest", displayName: "Guest"))
        let opponent = MultiplayerPlayer(id: "host", displayName: "Host")
        coordinator.startGame(
            transport: transport,
            opponent: opponent,
            role: .guest,
            matchConfiguration: try hardenedConfiguration(contentVersion: "content-a")
        )
        let viewModel = MultiplayerQuizViewModel(
            gameCoordinator: coordinator,
            analytics: analytics,
            progressManager: manager,
            clock: TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000)),
            scheduler: TestScheduler(),
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 101)
        )
        transport.emitRaw(
            try MultiplayerWireCodec.encode(
                .init(
                    matchID: matchID,
                    sequence: 0,
                    payload: .hello(
                        .init(
                            protocolVersion: MultiplayerMatchConfiguration.protocolVersion,
                            contentVersion: "content-a",
                            capabilities: MultiplayerMatchConfiguration.requiredQE6Capabilities
                        )
                    )
                )
            ),
            from: opponent
        )
        await drainTransportEvents()
        XCTAssertEqual(coordinator.matchID, matchID)
        XCTAssertTrue(coordinator.handshakeAccepted)

        viewModel.handleGameConfig(
            GameConfigPayload(
                questions: QuizEngineTestFixtures.questions(count: 15),
                seed: 5
            ),
            localDisplayName: "Guest"
        )
        transport.emitRaw(
            try MultiplayerWireCodec.encode(
                .init(
                    matchID: matchID,
                    sequence: 1,
                    payload: .questionResult(
                        .init(
                            questionIndex: 0,
                            correctAnswerIndex: 0,
                            hostCorrect: false,
                            guestCorrect: true,
                            hostResponseTimeMs: 200,
                            guestResponseTimeMs: 150,
                            hostPointsAwarded: -5,
                            guestPointsAwarded: 10,
                            hostTotalScore: hostScore,
                            guestTotalScore: guestScore
                        )
                    )
                )
            ),
            from: opponent
        )
        await drainTransportEvents()
        XCTAssertEqual(viewModel.myCorrectCount, 1)
        XCTAssertEqual(viewModel.myResponseTimes, [150])
        XCTAssertEqual(coordinator.questionsCompleted, 1)

        return TerminalHarness(
            manager: manager,
            coordinator: coordinator,
            viewModel: viewModel,
            transport: transport,
            opponent: opponent,
            matchID: matchID
        )
    }

    private func deliverTerminal(
        to harness: TerminalHarness,
        hostScore: Int = -5,
        guestScore: Int = 10
    ) async {
        do {
            harness.transport.emitRaw(
                try terminalPayloadData(
                    matchID: harness.matchID,
                    hostScore: hostScore,
                    guestScore: guestScore
                ),
                from: harness.opponent
            )
        } catch {
            XCTFail("Could not encode terminal payload: \(error)")
        }
        await drainTransportEvents()
    }

    private func terminalPayloadData(
        matchID: UUID,
        hostScore: Int,
        guestScore: Int
    ) throws -> Data {
        try MultiplayerWireCodec.encode(
            .init(
                matchID: matchID,
                sequence: 2,
                payload: .gameEnd(
                    .init(
                        hostFinalScore: hostScore,
                        guestFinalScore: guestScore,
                        reason: .completed
                    )
                )
            )
        )
    }

    private func assertPending(
        _ viewModel: MultiplayerQuizViewModel,
        failure expectedFailure: ExpectedTerminalFailure,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .pending = viewModel.terminalCommitState else {
            return XCTFail("Expected a retained pending terminal record", file: file, line: line)
        }
        switch (expectedFailure, viewModel.terminalCommitFailure) {
        case (.persistenceFailed, .persistenceFailed): break
        case (.conflictingReceipt, .conflictingReceipt): break
        case (.rejected, .rejected): break
        default: XCTFail("Unexpected terminal commit failure", file: file, line: line)
        }
    }

    private func assertRecordedProgress(
        _ progress: PlayerProgress,
        initialCoins: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(progress.coins, initialCoins + 1, file: file, line: line)
        XCTAssertEqual(progress.totalCoinsEarned, initialCoins + 1, file: file, line: line)
        XCTAssertEqual(progress.multiplayerGamesPlayed, 1, file: file, line: line)
        XCTAssertEqual(progress.multiplayerGamesWon, 1, file: file, line: line)
        XCTAssertEqual(progress.multiplayerGamesLost, 0, file: file, line: line)
        XCTAssertEqual(progress.multiplayerGamesDraw, 0, file: file, line: line)
        XCTAssertEqual(progress.bestMultiplayerScore, 10, file: file, line: line)
        XCTAssertEqual(progress.multiplayerWinStreak, 1, file: file, line: line)
        XCTAssertEqual(progress.longestMultiplayerWinStreak, 1, file: file, line: line)
        XCTAssertEqual(progress.multiplayerTotalResponseTimeMs, 150, file: file, line: line)
        XCTAssertEqual(progress.multiplayerTotalQuestionsAnswered, 1, file: file, line: line)
        XCTAssertEqual(progress.multiplayerTotalQuestionsCorrect, 1, file: file, line: line)
    }

    private func drainTransportEvents() async {
        for _ in 0..<12 { await Task.yield() }
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

@MainActor
private struct TerminalHarness {
    let manager: PlayerProgressManager
    let coordinator: MultiplayerGameCoordinator
    let viewModel: MultiplayerQuizViewModel
    let transport: FakeTransport
    let opponent: MultiplayerPlayer
    let matchID: UUID
}

private enum ExpectedTerminalFailure {
    case persistenceFailed
    case conflictingReceipt
    case rejected
}

private struct ProgressSnapshot: Equatable {
    let coins: Int
    let totalCoinsEarned: Int
    let gamesPlayed: Int
    let gamesWon: Int
    let gamesLost: Int
    let gamesDraw: Int
    let bestScore: Int
    let winStreak: Int
    let longestWinStreak: Int
    let totalResponseTime: Int
    let questionsAnswered: Int
    let questionsCorrect: Int
    let receiptCount: Int

    init(_ progress: PlayerProgress) {
        coins = progress.coins
        totalCoinsEarned = progress.totalCoinsEarned
        gamesPlayed = progress.multiplayerGamesPlayed
        gamesWon = progress.multiplayerGamesWon
        gamesLost = progress.multiplayerGamesLost
        gamesDraw = progress.multiplayerGamesDraw
        bestScore = progress.bestMultiplayerScore
        winStreak = progress.multiplayerWinStreak
        longestWinStreak = progress.longestMultiplayerWinStreak
        totalResponseTime = progress.multiplayerTotalResponseTimeMs
        questionsAnswered = progress.multiplayerTotalQuestionsAnswered
        questionsCorrect = progress.multiplayerTotalQuestionsCorrect
        receiptCount = progress.multiplayerMatchReceipts.count
    }
}

@MainActor
private final class LegacyTransport: MultiplayerTransport {
    let localPlayer = MultiplayerPlayer(id: "legacy", displayName: "Legacy")
    var connectionState: TransportConnectionState = .connected
    let eventStream: AsyncStream<MultiplayerTransportEvent> = AsyncStream { $0.finish() }
    func startSearching() {}
    func stopSearching() {}
    func invite(player: MultiplayerPlayer) {}
    func acceptInvite(from player: MultiplayerPlayer) {}
    func declineInvite(from player: MultiplayerPlayer) {}
    func send(message: MultiplayerMessage) throws {}
    func disconnect() { connectionState = .disconnected }
    func resetEventStream() {}
}
