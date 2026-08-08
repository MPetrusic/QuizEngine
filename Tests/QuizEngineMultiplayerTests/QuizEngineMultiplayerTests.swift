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
        // Same match ID and same final scores, but a terminal record whose canonical fingerprint
        // differs because the round resolved with a different response time.
        let conflicting = try await makeTerminalHarness(
            store: store,
            analytics: conflictingAnalytics,
            matchID: matchID,
            guestResponseTimeMs: 160
        )
        await deliverTerminal(to: conflicting)

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

    func testHardenedPayloadReplayAndFutureRoundAreHarmless() async throws {
        let session = try await hardenedGuestSession()
        let config = canonicalGameConfig()
        let valid = MultiplayerWireEnvelope(
            matchID: session.matchID,
            sequence: 1,
            payload: .gameConfig(.init(config))
        )
        session.transport.emitRaw(try MultiplayerWireCodec.encode(valid), from: session.opponent)
        await drainTransportEvents()

        // A replayed envelope, a future round index, and a terminal payload that contradicts the
        // committed scores must all be harmless.
        session.transport.emitRaw(try MultiplayerWireCodec.encode(valid), from: session.opponent)
        session.transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: session.matchID, sequence: 3, payload: .playerReady(roundIndex: 99)
        )), from: session.opponent)
        session.transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: session.matchID, sequence: 2, payload: .playerReady(roundIndex: 0)
        )), from: session.opponent)
        await drainTransportEvents()

        session.coordinator.questionsCompleted = 1
        session.coordinator.lastHostScore = 10
        session.coordinator.lastGuestScore = 5
        session.transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: session.matchID, sequence: 4,
            payload: .gameEnd(.init(hostFinalScore: 999, guestFinalScore: 5, reason: .completed))
        )), from: session.opponent)
        session.transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: UUID(), sequence: 5, payload: .pause
        )), from: session.opponent)
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.receivedGameConfig, config)
        XCTAssertTrue(session.coordinator.opponentReady)
        XCTAssertNil(session.coordinator.terminalFailure)
        XCTAssertNil(session.coordinator.gameEndResult)
    }

    // MARK: - QEB-02 protocol negotiation

    func testHardenedHandshakeRejectsProtocolVersionMismatch() async throws {
        let session = try await hardenedGuestSession(negotiates: false)
        session.transport.emitRaw(try handshakeData(
            matchID: session.matchID,
            protocolVersion: MultiplayerMatchConfiguration.protocolVersion + 1
        ), from: session.opponent)
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.terminalFailure, .protocolMismatch)
        XCTAssertEqual(session.coordinator.handshakeStatus, .rejected(.protocolMismatch))
        XCTAssertFalse(session.coordinator.handshakeAccepted)
        XCTAssertTrue(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedHandshakeRejectsContentVersionMismatch() async throws {
        let session = try await hardenedGuestSession(negotiates: false)
        session.transport.emitRaw(try handshakeData(
            matchID: session.matchID,
            contentVersion: "content-b"
        ), from: session.opponent)
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.terminalFailure, .contentMismatch)
        XCTAssertFalse(session.coordinator.handshakeAccepted)
    }

    func testHardenedHandshakeRejectsMissingCapability() async throws {
        let session = try await hardenedGuestSession(negotiates: false)
        var capabilities = MultiplayerMatchConfiguration.requiredQE6Capabilities
        capabilities.remove(.idempotentTerminalReceiptV1)
        session.transport.emitRaw(try handshakeData(
            matchID: session.matchID,
            capabilities: capabilities
        ), from: session.opponent)
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.terminalFailure, .capabilityMismatch)
        XCTAssertFalse(session.coordinator.handshakeAccepted)
    }

    func testHardenedActiveMatchRejectsEmptyPayload() async throws {
        let session = try await hardenedGuestSession()
        XCTAssertFalse(session.coordinator.sessionState.isTerminal)

        session.transport.emitRaw(Data(), from: session.opponent)
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.terminalFailure, .malformedPayload)
        XCTAssertTrue(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedActiveMatchRejectsOversizedPayload() async throws {
        let session = try await hardenedGuestSession()
        XCTAssertFalse(session.coordinator.sessionState.isTerminal)

        session.transport.emitRaw(
            Data(repeating: 0, count: MultiplayerWireCodec.maximumPayloadBytes + 1),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.terminalFailure, .malformedPayload)
        XCTAssertTrue(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedTerminalFailureIsNotReplacedByLaterMalformedPayload() async throws {
        let session = try await hardenedGuestSession(negotiates: false)
        session.transport.emitRaw(
            try handshakeData(matchID: session.matchID, contentVersion: "content-b"),
            from: session.opponent
        )
        await drainTransportEvents()
        let terminal = session.coordinator.gameEndResult

        session.transport.emitRaw(
            Data(repeating: 0, count: MultiplayerWireCodec.maximumPayloadBytes + 1),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.terminalFailure, .contentMismatch)
        XCTAssertEqual(session.coordinator.gameEndResult, terminal)
    }

    func testHardenedInvalidSenderIsIgnoredWhileMatchIsActive() async throws {
        let session = try await hardenedGuestSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID,
                sequence: 1,
                payload: .gameConfig(.init(canonicalGameConfig()))
            )),
            from: MultiplayerPlayer(id: "attacker", displayName: "Attacker")
        )
        await drainTransportEvents()

        XCTAssertNil(session.coordinator.receivedGameConfig)
        XCTAssertNil(session.coordinator.terminalFailure)
        XCTAssertFalse(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedWrongMatchIDIsIgnored() async throws {
        let session = try await hardenedGuestSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: UUID(),
                sequence: 1,
                payload: .gameConfig(.init(canonicalGameConfig()))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertNil(session.coordinator.receivedGameConfig)
        XCTAssertNil(session.coordinator.terminalFailure)
        XCTAssertFalse(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedDuplicateMessageIDIsIgnored() async throws {
        let session = try await hardenedGuestSession()
        let messageID = UUID()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 1, messageID: messageID,
                payload: .gameConfig(.init(canonicalGameConfig()))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        // The same message ID at a later sequence must not be processed again.
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2, messageID: messageID,
                payload: .playerReady(roundIndex: 0)
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertFalse(session.coordinator.opponentReady)
        XCTAssertNil(session.coordinator.terminalFailure)
    }

    func testHardenedDuplicateSequenceIsIgnored() async throws {
        let session = try await hardenedGuestSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 1,
                payload: .gameConfig(.init(canonicalGameConfig()))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        // A different message at an already committed sequence is ignored.
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 1, payload: .playerReady(roundIndex: 0)
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertFalse(session.coordinator.opponentReady)
        XCTAssertNil(session.coordinator.terminalFailure)
    }

    func testHardenedFutureSequenceIsBufferedUntilTheMissingSequenceArrives() async throws {
        let session = try await hardenedGuestSession()

        // Sequence 2 arrives before sequence 1 and must not take effect yet.
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2, payload: .playerReady(roundIndex: 0)
            )),
            from: session.opponent
        )
        await drainTransportEvents()
        XCTAssertFalse(session.coordinator.opponentReady)
        XCTAssertNil(session.coordinator.receivedGameConfig)

        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 1,
                payload: .gameConfig(.init(canonicalGameConfig()))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.receivedGameConfig?.questions.count, 15)
        XCTAssertTrue(session.coordinator.opponentReady)
        XCTAssertNil(session.coordinator.terminalFailure)
    }

    func testHardenedUnresolvedSequenceGapTimesOut() async throws {
        let scheduler = TestScheduler()
        let session = try await hardenedGuestSession(scheduler: scheduler)
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2, payload: .playerReady(roundIndex: 0)
            )),
            from: session.opponent
        )
        await drainTransportEvents()
        XCTAssertNil(session.coordinator.terminalFailure)

        scheduler.advance(by: 5)

        XCTAssertEqual(session.coordinator.terminalFailure, .timedOut(.sequenceGap))
        XCTAssertTrue(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedExcessiveSequenceGapEndsMatch() async throws {
        let session = try await hardenedGuestSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID,
                sequence: 2 + MultiplayerSequenceBuffer.maximumSequenceGap,
                payload: .playerReady(roundIndex: 0)
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.terminalFailure, .sequenceGap)
        XCTAssertTrue(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedSequenceBufferOverflowEndsMatch() async throws {
        let session = try await hardenedGuestSession()
        // Fill the buffer while sequence 1 stays missing.
        for offset in 0..<MultiplayerSequenceBuffer.maximumBufferedMessages {
            session.transport.emitRaw(
                try MultiplayerWireCodec.encode(.init(
                    matchID: session.matchID,
                    sequence: UInt64(2 + offset),
                    payload: .playerReady(roundIndex: 0)
                )),
                from: session.opponent
            )
        }
        await drainTransportEvents()
        XCTAssertNil(session.coordinator.terminalFailure)

        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID,
                sequence: UInt64(2 + MultiplayerSequenceBuffer.maximumBufferedMessages),
                payload: .playerReady(roundIndex: 0)
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.terminalFailure, .sequenceBufferOverflow)
        XCTAssertTrue(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedRoundPayloadBeforeConfigurationIsUnexpectedPhase() async throws {
        let session = try await hardenedGuestSession()
        // An answer is legal once a round is loaded, but never before a configuration exists.
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 1,
                payload: .answerSubmitted(.init(questionIndex: 0, answerIndex: 0, responseTimeMs: 10))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.terminalFailure, .unexpectedPhase)
        XCTAssertTrue(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedGuestRejectsHandshakeItShouldNeverReceive() async throws {
        let session = try await hardenedGuestSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 1,
                payload: .acknowledged(.init(
                    protocolVersion: MultiplayerMatchConfiguration.protocolVersion,
                    contentVersion: "content-a",
                    capabilities: MultiplayerMatchConfiguration.requiredQE6Capabilities
                ))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.terminalFailure, .unexpectedMessage)
    }

    func testHardenedTransportSendFailureEndsMatchWithTypedFailure() async throws {
        let session = try await hardenedGuestSession()
        session.transport.rawSendFailure = MultiplayerTransportError.notConnected

        session.coordinator.sendPlayerReady()

        XCTAssertEqual(session.coordinator.terminalFailure, .transportFailure)
        XCTAssertTrue(session.coordinator.sessionState.isTerminal)
    }

    // MARK: - QEB-02 configuration validation

    func testHardenedGuestAcceptsCanonicalConfiguration() async throws {
        let session = try await hardenedGuestSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 1,
                payload: .gameConfig(.init(canonicalGameConfig()))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.receivedGameConfig?.questions.count, 15)
        XCTAssertEqual(session.coordinator.lastConfigurationRejections, [])
        XCTAssertNil(session.coordinator.terminalFailure)
    }

    func testHardenedGuestRejectsEachInvalidConfigurationFieldIndependently() async throws {
        XCTAssertEqual(Self.invalidConfigurationCases.count, 28)
        for testCase in Self.invalidConfigurationCases {
            let session = try await hardenedGuestSession()
            session.transport.emitRaw(
                try MultiplayerWireCodec.encode(.init(
                    matchID: session.matchID, sequence: 1,
                    payload: .gameConfig(.init(testCase.config))
                )),
                from: session.opponent
            )
            await drainTransportEvents()

            XCTAssertNil(
                session.coordinator.receivedGameConfig,
                "\(testCase.name) published an unplayable configuration"
            )
            XCTAssertEqual(
                session.coordinator.terminalFailure,
                .invalidConfiguration,
                "\(testCase.name) did not end the match"
            )
            XCTAssertEqual(
                session.coordinator.lastConfigurationRejections,
                testCase.rejections,
                "\(testCase.name) reported the wrong reason"
            )
        }
    }

    func testHardenedHostRejectsTheSameInvalidConfigurationsAsTheGuest() async throws {
        for testCase in Self.invalidConfigurationCases {
            let session = try await hardenedHostSession()
            session.coordinator.sendGameConfig(testCase.config)

            XCTAssertEqual(
                session.coordinator.terminalFailure,
                .invalidConfiguration,
                "\(testCase.name) was transmitted by the host"
            )
            XCTAssertEqual(
                session.coordinator.lastConfigurationRejections,
                testCase.rejections,
                "\(testCase.name) reported the wrong reason on the host"
            )
            // The handshake and the refused configuration are the only wire traffic.
            XCTAssertEqual(session.transport.sentRawPayloads.count, 1, testCase.name)
        }
    }

    func testHardenedHostSendsAndAdoptsACanonicalConfiguration() async throws {
        let session = try await hardenedHostSession()
        session.coordinator.sendGameConfig(canonicalGameConfig())

        XCTAssertNil(session.coordinator.terminalFailure)
        XCTAssertEqual(session.coordinator.activeQuestions.count, 15)
        XCTAssertEqual(session.transport.sentRawPayloads.count, 2)
    }

    // MARK: - QEB-02 round payload validation

    func testHardenedAnswerRejectsIndexBeyondTheQuestionsAnswerCount() async throws {
        let session = try await configuredGuestSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2,
                payload: .answerSubmitted(.init(questionIndex: 0, answerIndex: 4, responseTimeMs: 10))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertNil(session.coordinator.opponentAnswer)
        XCTAssertEqual(session.coordinator.terminalFailure, .invalidRoundPayload)
    }

    func testHardenedAnswerAcceptsSkipAndTimeoutSentinels() async throws {
        for sentinel in [-1, -2] {
            let session = try await configuredGuestSession()
            session.transport.emitRaw(
                try MultiplayerWireCodec.encode(.init(
                    matchID: session.matchID, sequence: 2,
                    payload: .answerSubmitted(
                        .init(questionIndex: 0, answerIndex: sentinel, responseTimeMs: 10)
                    )
                )),
                from: session.opponent
            )
            await drainTransportEvents()

            XCTAssertEqual(session.coordinator.opponentAnswer?.answerIndex, sentinel)
            XCTAssertNil(session.coordinator.terminalFailure)
        }
    }

    func testHardenedAnswerRejectsIndexBelowTheSkipSentinel() async throws {
        let session = try await configuredGuestSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2,
                payload: .answerSubmitted(.init(questionIndex: 0, answerIndex: -3, responseTimeMs: 10))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertNil(session.coordinator.opponentAnswer)
        XCTAssertEqual(session.coordinator.terminalFailure, .invalidRoundPayload)
    }

    func testHardenedAnswerRejectsResponseTimeOutsideTheConfiguredRoundTimer() async throws {
        let rules = QuizRulesConfiguration.serbianCompatible.multiplayer
        for responseTime in [-1, rules.timerDurationMilliseconds + 1] {
            let session = try await configuredGuestSession()
            session.transport.emitRaw(
                try MultiplayerWireCodec.encode(.init(
                    matchID: session.matchID, sequence: 2,
                    payload: .answerSubmitted(
                        .init(questionIndex: 0, answerIndex: 0, responseTimeMs: responseTime)
                    )
                )),
                from: session.opponent
            )
            await drainTransportEvents()

            XCTAssertNil(session.coordinator.opponentAnswer)
            XCTAssertEqual(session.coordinator.terminalFailure, .invalidRoundPayload, "\(responseTime)")
        }
    }

    func testHardenedStaleRoundIndexIsIgnoredRatherThanTerminal() async throws {
        let session = try await configuredGuestSession()
        session.coordinator.questionsCompleted = 1
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2,
                payload: .answerSubmitted(.init(questionIndex: 0, answerIndex: 0, responseTimeMs: 10))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertNil(session.coordinator.opponentAnswer)
        XCTAssertNil(session.coordinator.terminalFailure)
        XCTAssertFalse(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedQuestionResultRejectsCorrectIndexBeyondTheAnswerCount() async throws {
        let session = try await configuredGuestSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2,
                payload: .questionResult(roundResult(correctAnswerIndex: 4))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertNil(session.coordinator.questionResult)
        XCTAssertEqual(session.coordinator.terminalFailure, .invalidRoundPayload)
    }

    func testHardenedQuestionResultRejectsPointsTheScoringRulesCannotAward() async throws {
        let session = try await configuredGuestSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2,
                payload: .questionResult(
                    roundResult(guestPointsAwarded: 999, guestTotalScore: 999)
                )
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertNil(session.coordinator.questionResult)
        XCTAssertEqual(session.coordinator.terminalFailure, .invalidRoundPayload)
    }

    func testHardenedQuestionResultRejectsTotalsThatDoNotFollowFromAwardedPoints() async throws {
        let session = try await configuredGuestSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2,
                payload: .questionResult(roundResult(guestTotalScore: 40))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertNil(session.coordinator.questionResult)
        XCTAssertEqual(session.coordinator.terminalFailure, .invalidRoundPayload)
    }

    func testHardenedQuestionResultRejectsAScoreThatRewindsThePreviousTotal() async throws {
        let session = try await configuredGuestSession()
        session.coordinator.questionsCompleted = 1
        session.coordinator.lastGuestScore = 10
        session.coordinator.lastHostScore = 10
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2,
                payload: .questionResult(
                    roundResult(
                        questionIndex: 1,
                        hostPointsAwarded: 0,
                        guestPointsAwarded: 10,
                        hostTotalScore: 10,
                        guestTotalScore: 10
                    )
                )
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertNil(session.coordinator.questionResult)
        XCTAssertEqual(session.coordinator.terminalFailure, .invalidRoundPayload)
    }

    func testHardenedQuestionResultAcceptsAResultTheConfiguredRulesProduce() async throws {
        let session = try await configuredGuestSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2, payload: .questionResult(roundResult())
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.questionResult?.guestTotalScore, 10)
        XCTAssertNil(session.coordinator.terminalFailure)
    }

    func testHardenedGuestRejectsAQuestionResultOnlyAHostMaySend() async throws {
        let session = try await configuredHostSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 1, payload: .questionResult(roundResult())
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertNil(session.coordinator.questionResult)
        XCTAssertEqual(session.coordinator.terminalFailure, .unexpectedMessage)
    }

    func testHardenedHostRejectsAGameConfigurationOnlyAHostMaySend() async throws {
        let session = try await configuredHostSession()
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 1,
                payload: .gameConfig(.init(canonicalGameConfig()))
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.terminalFailure, .unexpectedMessage)
    }

    // MARK: - QEB-02 pause, resume, and lifecycle

    func testHardenedResumeWithoutPauseIsIgnored() async throws {
        let session = try await configuredGuestSession()
        session.coordinator.transitionToPlaying()

        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2, payload: .resume
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.sessionState, .playing)
        XCTAssertNil(session.coordinator.terminalFailure)
    }

    func testHardenedPauseAndResumeRestoreThePhaseThatWasInterrupted() async throws {
        let session = try await configuredGuestSession()
        session.coordinator.transitionToWaitingForOpponent()

        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2, payload: .pause
            )),
            from: session.opponent
        )
        await drainTransportEvents()
        XCTAssertEqual(session.coordinator.sessionState, .opponentPaused)

        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 3, payload: .resume
            )),
            from: session.opponent
        )
        await drainTransportEvents()

        XCTAssertEqual(session.coordinator.sessionState, .waitingForOpponent)
        XCTAssertNil(session.coordinator.terminalFailure)
    }

    func testHardenedDisconnectReachesOneTerminalResultInEveryPhaseForBothRoles() async throws {
        for role in [MultiplayerRole.host, .guest] {
            for phase in Self.interruptiblePhases {
                let scheduler = TestScheduler()
                let session = try await configuredSession(role: role, scheduler: scheduler)
                phase.apply(session.coordinator)

                session.transport.emit(.disconnected(from: session.opponent))
                await drainTransportEvents()
                XCTAssertEqual(session.coordinator.sessionState, .reconnecting, "\(role) \(phase.name)")

                scheduler.advance(by: 3)
                XCTAssertEqual(
                    session.coordinator.gameEndResult?.reason,
                    .opponentLeft,
                    "\(role) \(phase.name)"
                )
                XCTAssertTrue(session.coordinator.sessionState.isTerminal, "\(role) \(phase.name)")

                // A second disconnect after the terminal result changes nothing.
                let terminal = session.coordinator.gameEndResult
                session.transport.emit(.disconnected(from: session.opponent))
                await drainTransportEvents()
                scheduler.advance(by: 60)
                XCTAssertEqual(session.coordinator.gameEndResult, terminal, "\(role) \(phase.name)")
            }
        }
    }

    func testHardenedReconnectRestoresTheInterruptedPhaseForBothRoles() async throws {
        for role in [MultiplayerRole.host, .guest] {
            for phase in Self.interruptiblePhases {
                let scheduler = TestScheduler()
                let session = try await configuredSession(role: role, scheduler: scheduler)
                phase.apply(session.coordinator)
                let before = session.coordinator.sessionState

                session.transport.emit(.reconnecting(to: session.opponent))
                await drainTransportEvents()
                session.transport.emit(.reconnected(to: session.opponent))
                await drainTransportEvents()

                XCTAssertEqual(session.coordinator.sessionState, before, "\(role) \(phase.name)")
                scheduler.advance(by: 60)
                XCTAssertFalse(session.coordinator.sessionState.isTerminal, "\(role) \(phase.name)")
            }
        }
    }

    func testHardenedDisconnectWhileNegotiatingReachesOneTerminalResultForBothRoles() async throws {
        for role in [MultiplayerRole.host, .guest] {
            let scheduler = TestScheduler()
            let transport = FakeTransport()
            let opponent = MultiplayerPlayer(id: "peer", displayName: "Peer")
            let coordinator = MultiplayerGameCoordinator(scheduler: scheduler)
            coordinator.startGame(
                transport: transport,
                opponent: opponent,
                role: role,
                matchConfiguration: try hardenedConfiguration(contentVersion: "content-a")
            )
            XCTAssertEqual(coordinator.handshakeStatus, .negotiating, "\(role)")
            XCTAssertFalse(coordinator.handshakeAccepted, "\(role)")

            transport.emit(.disconnected(from: opponent))
            await drainTransportEvents()
            scheduler.advance(by: 3)

            XCTAssertEqual(coordinator.gameEndResult?.reason, .opponentLeft, "\(role)")
            XCTAssertTrue(coordinator.sessionState.isTerminal, "\(role)")

            let terminal = coordinator.gameEndResult
            scheduler.advance(by: 60)
            XCTAssertEqual(coordinator.gameEndResult, terminal, "\(role)")
        }
    }

    func testHardenedDisconnectWhilePausedReachesOneTerminalResultForBothRoles() async throws {
        for role in [MultiplayerRole.host, .guest] {
            let scheduler = TestScheduler()
            let session = try await configuredSession(role: role, scheduler: scheduler)
            session.transport.emitRaw(
                try MultiplayerWireCodec.encode(.init(
                    matchID: session.matchID,
                    sequence: role == .guest ? 2 : 1,
                    payload: .pause
                )),
                from: session.opponent
            )
            await drainTransportEvents()
            XCTAssertEqual(session.coordinator.sessionState, .opponentPaused, "\(role)")

            session.transport.emit(.disconnected(from: session.opponent))
            await drainTransportEvents()
            XCTAssertEqual(session.coordinator.sessionState, .reconnecting, "\(role)")

            scheduler.advance(by: 3)
            XCTAssertEqual(session.coordinator.gameEndResult?.reason, .opponentLeft, "\(role)")
            XCTAssertTrue(session.coordinator.sessionState.isTerminal, "\(role)")

            // The pause deadline that was still pending cannot produce a second outcome.
            let terminal = session.coordinator.gameEndResult
            scheduler.advance(by: 120)
            XCTAssertEqual(session.coordinator.gameEndResult, terminal, "\(role)")
        }
    }

    func testHardenedDisconnectInATerminalPhaseCannotReplaceTheResult() async throws {
        for role in [MultiplayerRole.host, .guest] {
            let scheduler = TestScheduler()
            let session = try await configuredSession(role: role, scheduler: scheduler)
            session.coordinator.sendGameEnd(
                GameEndPayload(hostFinalScore: 0, guestFinalScore: 0, reason: .completed)
            )
            let terminal = session.coordinator.gameEndResult

            session.transport.emit(.disconnected(from: session.opponent))
            await drainTransportEvents()
            scheduler.advance(by: 60)

            XCTAssertEqual(session.coordinator.gameEndResult, terminal, "\(role)")
            XCTAssertEqual(session.coordinator.gameEndResult?.reason, .completed, "\(role)")
        }
    }

    // MARK: - QEB-02 timeouts

    func testHardenedConfigurationTimeoutEndsMatch() async throws {
        let scheduler = TestScheduler()
        let session = try await hardenedGuestSession(scheduler: scheduler)

        scheduler.advance(by: 10)

        XCTAssertEqual(session.coordinator.terminalFailure, .timedOut(.gameConfiguration))
        XCTAssertEqual(session.coordinator.gameEndResult?.reason, .disconnected)
        XCTAssertTrue(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedReadyTimeoutRetriesTwiceThenEndsMatch() async throws {
        let scheduler = TestScheduler()
        let session = try await configuredGuestSession(scheduler: scheduler)
        let baseline = session.transport.sentRawPayloads.count

        session.coordinator.sendPlayerReady()
        XCTAssertEqual(session.transport.sentRawPayloads.count, baseline + 1)

        scheduler.advance(by: 10)
        XCTAssertEqual(session.transport.sentRawPayloads.count, baseline + 2)
        scheduler.advance(by: 10)
        XCTAssertEqual(session.transport.sentRawPayloads.count, baseline + 3)
        XCTAssertNil(session.coordinator.terminalFailure)

        scheduler.advance(by: 10)
        XCTAssertEqual(session.coordinator.terminalFailure, .timedOut(.ready))
        XCTAssertTrue(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedReadyTimeoutStopsRetryingOnceTheOpponentIsReady() async throws {
        let scheduler = TestScheduler()
        let session = try await configuredGuestSession(scheduler: scheduler)
        session.coordinator.sendPlayerReady()
        let afterSend = session.transport.sentRawPayloads.count

        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2, payload: .playerReady(roundIndex: 0)
            )),
            from: session.opponent
        )
        await drainTransportEvents()
        scheduler.advance(by: 60)

        XCTAssertTrue(session.coordinator.opponentReady)
        XCTAssertEqual(session.transport.sentRawPayloads.count, afterSend)
        XCTAssertNil(session.coordinator.terminalFailure)
    }

    func testHardenedQuestionResultTimeoutRetriesTwiceThenEndsMatch() async throws {
        let scheduler = TestScheduler()
        let session = try await configuredGuestSession(scheduler: scheduler)
        let baseline = session.transport.sentRawPayloads.count

        session.coordinator.sendAnswer(.init(questionIndex: 0, answerIndex: 0, responseTimeMs: 10))
        XCTAssertEqual(session.transport.sentRawPayloads.count, baseline + 1)

        scheduler.advance(by: 5)
        XCTAssertEqual(session.transport.sentRawPayloads.count, baseline + 2)
        scheduler.advance(by: 5)
        XCTAssertEqual(session.transport.sentRawPayloads.count, baseline + 3)
        XCTAssertFalse(session.coordinator.sessionState.isTerminal)

        // Retries are exhausted, so the session escalates to a disconnect that terminates once.
        scheduler.advance(by: 5)
        XCTAssertEqual(session.coordinator.sessionState, .reconnecting)
        scheduler.advance(by: 3)
        XCTAssertEqual(session.coordinator.gameEndResult?.reason, .opponentLeft)
        XCTAssertTrue(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedPauseTimeoutEndsMatch() async throws {
        let scheduler = TestScheduler()
        let session = try await configuredGuestSession(scheduler: scheduler)
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2, payload: .pause
            )),
            from: session.opponent
        )
        await drainTransportEvents()
        XCTAssertEqual(session.coordinator.sessionState, .opponentPaused)

        scheduler.advance(by: 60)
        XCTAssertEqual(session.coordinator.sessionState, .reconnecting)

        scheduler.advance(by: 10)
        XCTAssertEqual(session.coordinator.gameEndResult?.reason, .opponentLeft)
        XCTAssertTrue(session.coordinator.sessionState.isTerminal)
    }

    func testHardenedGameEndTimeoutCompletesMatchExactlyOnce() async throws {
        let scheduler = TestScheduler()
        let session = try await configuredGuestSession(scheduler: scheduler)
        session.coordinator.questionsCompleted = 15
        session.coordinator.lastHostScore = 20
        session.coordinator.lastGuestScore = 30
        session.coordinator.startGameEndTimeout()

        scheduler.advance(by: 5)
        XCTAssertEqual(
            session.coordinator.gameEndResult,
            GameEndPayload(hostFinalScore: 20, guestFinalScore: 30, reason: .completed)
        )

        // A late host payload cannot restate the outcome.
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2,
                payload: .gameEnd(.init(hostFinalScore: 99, guestFinalScore: 0, reason: .completed))
            )),
            from: session.opponent
        )
        await drainTransportEvents()
        XCTAssertEqual(session.coordinator.gameEndResult?.hostFinalScore, 20)
    }

    func testHardenedDuplicateAndReorderedGameEndProducesOneTerminalResult() async throws {
        let session = try await configuredGuestSession()
        session.coordinator.questionsCompleted = 1
        session.coordinator.lastHostScore = 10
        session.coordinator.lastGuestScore = 5
        let terminal = MultiplayerWireEnvelope(
            matchID: session.matchID, sequence: 3,
            payload: .gameEnd(.init(hostFinalScore: 10, guestFinalScore: 5, reason: .completed))
        )

        // The terminal payload arrives before the round message that precedes it, then twice more.
        session.transport.emitRaw(try MultiplayerWireCodec.encode(terminal), from: session.opponent)
        await drainTransportEvents()
        XCTAssertNil(session.coordinator.gameEndResult)

        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 2, payload: .playerReady(roundIndex: 1)
            )),
            from: session.opponent
        )
        await drainTransportEvents()
        XCTAssertEqual(session.coordinator.gameEndResult?.reason, .completed)

        session.transport.emitRaw(try MultiplayerWireCodec.encode(terminal), from: session.opponent)
        session.transport.emitRaw(try MultiplayerWireCodec.encode(.init(
            matchID: session.matchID, sequence: 4,
            payload: .gameEnd(.init(hostFinalScore: 99, guestFinalScore: 0, reason: .completed))
        )), from: session.opponent)
        await drainTransportEvents()

        XCTAssertEqual(
            session.coordinator.gameEndResult,
            GameEndPayload(hostFinalScore: 10, guestFinalScore: 5, reason: .completed)
        )
    }

    func testHardenedLateSchedulerCallbacksCannotChangeATerminalResult() async throws {
        let scheduler = CancellationIgnoringTestScheduler()
        let session = try await configuredGuestSession(scheduler: scheduler)
        session.coordinator.sendPlayerReady()
        session.coordinator.sendAnswer(.init(questionIndex: 0, answerIndex: 0, responseTimeMs: 10))

        session.coordinator.sendGameEnd(
            GameEndPayload(hostFinalScore: 1, guestFinalScore: 2, reason: .completed)
        )
        let terminal = session.coordinator.gameEndResult

        scheduler.runPendingBatch()
        scheduler.runPendingBatch()

        XCTAssertEqual(session.coordinator.gameEndResult, terminal)
        XCTAssertNil(session.coordinator.terminalFailure)
    }

    func testHardenedLateSchedulerCallbacksCannotAffectTheNextMatch() async throws {
        let scheduler = CancellationIgnoringTestScheduler()
        let session = try await configuredGuestSession(scheduler: scheduler)
        session.coordinator.sendPlayerReady()

        // A new match generation begins before the stale ready timeout is delivered. The second
        // match schedules no work of its own, so the batch contains only stale callbacks.
        let secondTransport = FakeTransport(localPlayer: MultiplayerPlayer(id: "host", displayName: "Host"))
        session.coordinator.startGame(
            transport: secondTransport,
            opponent: session.opponent,
            role: .host
        )
        scheduler.runPendingBatch()

        XCTAssertNil(session.coordinator.terminalFailure)
        XCTAssertFalse(session.coordinator.sessionState.isTerminal)
        XCTAssertEqual(session.coordinator.sessionState, .waitingForConfig)
        XCTAssertTrue(secondTransport.sentRawPayloads.isEmpty)
        XCTAssertTrue(secondTransport.sentMessages.isEmpty)
        XCTAssertEqual(session.coordinator.activeQuestions, [])
    }

    func testHardenedAnalyticsUsesTheAppSuppliedTransportLabel() async throws {
        let analytics = RecordingAnalytics()
        let scheduler = TestScheduler()
        let configuration = try MultiplayerMatchConfiguration(
            contentVersion: "content-a",
            analyticsTransportLabel: "app-chosen-label",
            expectedQuestionCount: 15,
            allowedCategoryIDs: ["nature"],
            multiplayerRules: QuizRulesConfiguration.serbianCompatible.multiplayer
        )
        let session = try await hardenedGuestSession(
            scheduler: scheduler,
            analytics: analytics,
            configuration: configuration
        )

        session.transport.emit(.disconnected(from: session.opponent))
        await drainTransportEvents()
        scheduler.advance(by: 3)

        XCTAssertEqual(analytics.disconnects.map(\.2), ["app-chosen-label"])
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

    // MARK: - QEB-02 harness

    /// A negotiated hardened session plus everything a test needs to drive its wire.
    private final class HardenedSession {
        let coordinator: MultiplayerGameCoordinator
        let transport: FakeTransport
        let opponent: MultiplayerPlayer
        let matchID: UUID

        init(
            coordinator: MultiplayerGameCoordinator,
            transport: FakeTransport,
            opponent: MultiplayerPlayer,
            matchID: UUID
        ) {
            self.coordinator = coordinator
            self.transport = transport
            self.opponent = opponent
            self.matchID = matchID
        }
    }

    private func handshakeData(
        matchID: UUID,
        sequence: UInt64 = 0,
        protocolVersion: Int = MultiplayerMatchConfiguration.protocolVersion,
        contentVersion: String = "content-a",
        capabilities: Set<MultiplayerCapability> = MultiplayerMatchConfiguration.requiredQE6Capabilities,
        acknowledgement: Bool = false
    ) throws -> Data {
        let handshake = MultiplayerHandshakePayload(
            protocolVersion: protocolVersion,
            contentVersion: contentVersion,
            capabilities: capabilities
        )
        return try MultiplayerWireCodec.encode(
            .init(
                matchID: matchID,
                sequence: sequence,
                payload: acknowledgement ? .acknowledged(handshake) : .hello(handshake)
            )
        )
    }

    /// A guest whose handshake has completed. Inbound sequence 0 is the host's opening message,
    /// so a test's first payload uses sequence 1.
    private func hardenedGuestSession(
        scheduler: any QuizEngineScheduler = TestScheduler(),
        analytics: (any AnalyticsProvider)? = nil,
        configuration: MultiplayerMatchConfiguration? = nil,
        negotiates: Bool = true
    ) async throws -> HardenedSession {
        let coordinator = MultiplayerGameCoordinator(analytics: analytics, scheduler: scheduler)
        let transport = FakeTransport(localPlayer: MultiplayerPlayer(id: "guest", displayName: "Guest"))
        let opponent = MultiplayerPlayer(id: "host", displayName: "Host")
        let matchID = UUID()
        coordinator.startGame(
            transport: transport,
            opponent: opponent,
            role: .guest,
            matchConfiguration: try configuration ?? hardenedConfiguration(contentVersion: "content-a")
        )
        if negotiates {
            transport.emitRaw(try handshakeData(matchID: matchID), from: opponent)
            await drainTransportEvents()
            XCTAssertTrue(coordinator.handshakeAccepted)
        }
        return HardenedSession(
            coordinator: coordinator,
            transport: transport,
            opponent: opponent,
            matchID: matchID
        )
    }

    /// A host whose handshake has completed. Inbound sequence 0 is the guest's acknowledgement,
    /// so a test's first payload uses sequence 1.
    private func hardenedHostSession(
        scheduler: any QuizEngineScheduler = TestScheduler(),
        analytics: (any AnalyticsProvider)? = nil
    ) async throws -> HardenedSession {
        let coordinator = MultiplayerGameCoordinator(analytics: analytics, scheduler: scheduler)
        let transport = FakeTransport(localPlayer: MultiplayerPlayer(id: "host", displayName: "Host"))
        let opponent = MultiplayerPlayer(id: "guest", displayName: "Guest")
        coordinator.startGame(
            transport: transport,
            opponent: opponent,
            role: .host,
            matchConfiguration: try hardenedConfiguration(contentVersion: "content-a")
        )
        let matchID = try XCTUnwrap(coordinator.matchID)
        transport.emitRaw(try handshakeData(matchID: matchID, acknowledgement: true), from: opponent)
        await drainTransportEvents()
        XCTAssertTrue(coordinator.handshakeAccepted)
        return HardenedSession(
            coordinator: coordinator,
            transport: transport,
            opponent: opponent,
            matchID: matchID
        )
    }

    /// A guest that has accepted the canonical configuration at inbound sequence 1, so a test's
    /// first round payload uses sequence 2.
    private func configuredGuestSession(
        scheduler: any QuizEngineScheduler = TestScheduler()
    ) async throws -> HardenedSession {
        let session = try await hardenedGuestSession(scheduler: scheduler)
        session.transport.emitRaw(
            try MultiplayerWireCodec.encode(.init(
                matchID: session.matchID, sequence: 1,
                payload: .gameConfig(.init(canonicalGameConfig()))
            )),
            from: session.opponent
        )
        await drainTransportEvents()
        XCTAssertEqual(session.coordinator.receivedGameConfig?.questions.count, 15)
        return session
    }

    /// A host that has sent the canonical configuration, so a test's first inbound round payload
    /// uses sequence 1.
    private func configuredHostSession(
        scheduler: any QuizEngineScheduler = TestScheduler()
    ) async throws -> HardenedSession {
        let session = try await hardenedHostSession(scheduler: scheduler)
        session.coordinator.sendGameConfig(canonicalGameConfig())
        XCTAssertEqual(session.coordinator.activeQuestions.count, 15)
        return session
    }

    private func configuredSession(
        role: MultiplayerRole,
        scheduler: any QuizEngineScheduler = TestScheduler()
    ) async throws -> HardenedSession {
        switch role {
        case .host: return try await configuredHostSession(scheduler: scheduler)
        case .guest: return try await configuredGuestSession(scheduler: scheduler)
        }
    }

    /// A round result the configured rules can actually produce: the guest answered correctly and
    /// faster, the host answered incorrectly.
    private func roundResult(
        questionIndex: Int = 0,
        correctAnswerIndex: Int = 0,
        hostCorrect: Bool = false,
        guestCorrect: Bool = true,
        hostResponseTimeMs: Int = 200,
        guestResponseTimeMs: Int = 150,
        hostPointsAwarded: Int = -5,
        guestPointsAwarded: Int = 10,
        hostTotalScore: Int = -5,
        guestTotalScore: Int = 10
    ) -> QuestionResultPayload {
        QuestionResultPayload(
            questionIndex: questionIndex,
            correctAnswerIndex: correctAnswerIndex,
            hostCorrect: hostCorrect,
            guestCorrect: guestCorrect,
            hostResponseTimeMs: hostResponseTimeMs,
            guestResponseTimeMs: guestResponseTimeMs,
            hostPointsAwarded: hostPointsAwarded,
            guestPointsAwarded: guestPointsAwarded,
            hostTotalScore: hostTotalScore,
            guestTotalScore: guestTotalScore
        )
    }

    private struct InterruptiblePhase {
        let name: String
        let apply: @MainActor (MultiplayerGameCoordinator) -> Void
    }

    /// Every non-terminal phase a match can be interrupted in.
    private static let interruptiblePhases: [InterruptiblePhase] = [
        .init(name: "waitingForConfig", apply: { _ in }),
        .init(name: "loadingRound", apply: { $0.transitionToLoadingRound() }),
        .init(name: "playing", apply: { $0.transitionToPlaying() }),
        .init(name: "waitingForOpponent", apply: { $0.transitionToWaitingForOpponent() }),
        .init(name: "waitingForResult", apply: { $0.transitionToWaitingForResult() }),
        .init(name: "showingResult", apply: { $0.transitionToShowingResult() })
    ]

    private struct InvalidConfigurationCase {
        let name: String
        let config: GameConfigPayload
        let rejections: [MultiplayerConfigurationRejection]
    }

    /// One defect per configuration, so no guard hides behind an earlier one.
    private static let invalidConfigurationCases: [InvalidConfigurationCase] = {
        func canonical() -> [Question] { QuizEngineTestFixtures.questions(count: 15) }

        func mutating(
            _ name: String,
            questionIndex: Int = 0,
            rejections: [MultiplayerConfigurationRejection],
            _ change: (inout Question) -> Void
        ) -> InvalidConfigurationCase {
            var questions = canonical()
            change(&questions[questionIndex])
            return InvalidConfigurationCase(
                name: name,
                config: GameConfigPayload(questions: questions, seed: 1),
                rejections: rejections
            )
        }

        func answers(_ count: Int, correct: Int = 1) -> [Answer] {
            (0..<count).map { Answer(text: "Answer \($0)", correct: $0 < correct) }
        }

        var cases: [InvalidConfigurationCase] = [
            InvalidConfigurationCase(
                name: "zero questions",
                config: GameConfigPayload(questions: [], seed: 1),
                rejections: [.questionCountMismatch(expected: 15, actual: 0)]
            ),
            InvalidConfigurationCase(
                name: "too few questions",
                config: GameConfigPayload(questions: QuizEngineTestFixtures.questions(count: 14), seed: 1),
                rejections: [.questionCountMismatch(expected: 15, actual: 14)]
            ),
            InvalidConfigurationCase(
                name: "too many questions",
                config: GameConfigPayload(questions: QuizEngineTestFixtures.questions(count: 16), seed: 1),
                rejections: [.questionCountMismatch(expected: 15, actual: 16)]
            ),
            mutating("nonpositive question ID", rejections: [.nonPositiveQuestionID(questionIndex: 0, id: 0)]) {
                $0.id = 0
            },
            mutating("negative question ID", rejections: [.nonPositiveQuestionID(questionIndex: 0, id: -4)]) {
                $0.id = -4
            },
            mutating(
                "duplicate question ID",
                questionIndex: 1,
                rejections: [.duplicateQuestionID(questionIndex: 1, id: 1)]
            ) { $0.id = 1 },
            mutating("blank question text", rejections: [.blankQuestionText(questionIndex: 0)]) {
                $0.question = "   "
            },
            mutating(
                "oversized question text",
                rejections: [.oversizedQuestionText(questionIndex: 0, bytes: 4_097)]
            ) { $0.question = String(repeating: "q", count: 4_097) },
            mutating("zero correct answers", rejections: [.invalidCorrectAnswerCount(questionIndex: 0, count: 0)]) {
                $0.answers = answers(4, correct: 0)
            },
            mutating("multiple correct answers", rejections: [.invalidCorrectAnswerCount(questionIndex: 0, count: 2)]) {
                $0.answers = answers(4, correct: 2)
            },
            mutating("blank answer text", rejections: [.blankAnswerText(questionIndex: 0, answerIndex: 2)]) {
                $0.answers[2] = Answer(text: " \n ", correct: false)
            },
            mutating(
                "normalized-duplicate answer text",
                rejections: [.duplicateAnswerText(questionIndex: 0, answerIndex: 2)]
            ) { $0.answers[2] = Answer(text: "  correct\t1 ", correct: false) },
            mutating(
                "oversized answer text",
                rejections: [.oversizedAnswerText(questionIndex: 0, answerIndex: 1, bytes: 4_097)]
            ) { $0.answers[1] = Answer(text: String(repeating: "a", count: 4_097), correct: false) },
            mutating("missing categories", rejections: [.missingCategories(questionIndex: 0)]) {
                $0.categories = []
            },
            mutating("blank category", rejections: [.blankCategory(questionIndex: 0, categoryIndex: 0)]) {
                $0.categories = ["  "]
            },
            mutating(
                "duplicate category",
                rejections: [.duplicateCategory(questionIndex: 0, categoryID: "nature")]
            ) { $0.categories = ["nature", "nature"] },
            mutating(
                "unknown category",
                rejections: [.unknownCategory(questionIndex: 0, categoryID: "not-a-category")]
            ) { $0.categories = ["not-a-category"] },
            mutating(
                "oversized category",
                rejections: [
                    .unknownCategory(questionIndex: 0, categoryID: String(repeating: "c", count: 129)),
                    .oversizedCategory(questionIndex: 0, categoryIndex: 0, bytes: 129)
                ]
            ) { $0.categories = [String(repeating: "c", count: 129)] },
            mutating("difficulty below the range", rejections: [.invalidDifficulty(questionIndex: 0, difficulty: 0)]) {
                $0.difficulty = 0
            },
            mutating("difficulty above the range", rejections: [.invalidDifficulty(questionIndex: 0, difficulty: 4)]) {
                $0.difficulty = 4
            },
            mutating(
                "oversized image name",
                rejections: [.oversizedImageName(questionIndex: 0, bytes: 257)]
            ) { $0.imageName = String(repeating: "i", count: 257) },
            mutating(
                "oversized description",
                rejections: [.oversizedDescription(questionIndex: 0, bytes: 8_193)]
            ) { $0.description = String(repeating: "d", count: 8_193) }
        ]

        // Every answer count other than exactly four, checked independently.
        for count in [0, 2, 3, 5, 16] {
            cases.append(
                mutating(
                    "\(count) answers",
                    rejections: [.invalidAnswerCount(questionIndex: 0, count: count)]
                        + (count == 0 ? [.invalidCorrectAnswerCount(questionIndex: 0, count: 0)] : [])
                ) { $0.answers = answers(count, correct: count == 0 ? 0 : 1) }
            )
        }

        // More canonical categories than a question may carry.
        cases.append(
            mutating(
                "too many categories",
                rejections: [.tooManyCategories(questionIndex: 0, count: 9)]
            ) {
                $0.categories = [
                    "nature", "space", "history", "culture", "sport", "science", "music", "film", "art"
                ]
            }
        )

        return cases
    }()

    private func hardenedConfiguration(
        contentVersion: String,
        expectedQuestionCount: Int = 15,
        allowedCategoryIDs: Set<String> = [
            "nature", "space", "history", "culture", "sport", "science", "music", "film", "art"
        ],
        multiplayerRules: QuizMultiplayerRules = QuizRulesConfiguration.serbianCompatible.multiplayer
    ) throws -> MultiplayerMatchConfiguration {
        try MultiplayerMatchConfiguration(
            contentVersion: contentVersion,
            analyticsTransportLabel: "test",
            expectedQuestionCount: expectedQuestionCount,
            allowedCategoryIDs: allowedCategoryIDs,
            multiplayerRules: multiplayerRules
        )
    }

    /// The canonical configuration every hardened test starts from. Individual tests mutate one
    /// field so each guard is proven independently.
    private func canonicalGameConfig(seed: UInt64 = 1) -> GameConfigPayload {
        GameConfigPayload(questions: QuizEngineTestFixtures.questions(count: 15), seed: seed)
    }

    private func makeTerminalHarness(
        store: FakePersistenceStore,
        analytics: RecordingAnalytics,
        matchID: UUID,
        guestResponseTimeMs: Int = 150
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

        // The configuration arrives over the hardened wire so this integration test exercises
        // validation and publication, not a direct view-model call.
        transport.emitRaw(
            try MultiplayerWireCodec.encode(
                .init(
                    matchID: matchID,
                    sequence: 1,
                    payload: .gameConfig(.init(canonicalGameConfig(seed: 5)))
                )
            ),
            from: opponent
        )
        await drainTransportEvents()
        XCTAssertEqual(coordinator.receivedGameConfig?.questions.count, 15)
        XCTAssertEqual(viewModel.questions.count, 15)

        transport.emitRaw(
            try MultiplayerWireCodec.encode(
                .init(
                    matchID: matchID,
                    sequence: 2,
                    payload: .questionResult(
                        .init(
                            questionIndex: 0,
                            correctAnswerIndex: 0,
                            hostCorrect: false,
                            guestCorrect: true,
                            hostResponseTimeMs: 200,
                            guestResponseTimeMs: guestResponseTimeMs,
                            hostPointsAwarded: -5,
                            guestPointsAwarded: 10,
                            hostTotalScore: -5,
                            guestTotalScore: 10
                        )
                    )
                )
            ),
            from: opponent
        )
        await drainTransportEvents()
        XCTAssertEqual(viewModel.myCorrectCount, 1)
        XCTAssertEqual(viewModel.myResponseTimes, [guestResponseTimeMs])
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
                sequence: 3,
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
