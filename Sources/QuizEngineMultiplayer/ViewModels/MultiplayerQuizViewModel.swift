//
//  MultiplayerQuizViewModel.swift
//  QuizEngineMultiplayer
//

import Foundation
import Combine
import SwiftUI
import QuizEngineCore

@MainActor
public final class MultiplayerQuizViewModel: ObservableObject {

    // MARK: - Constants

    public static let questionsPerMatch = 15
    public static let timerDurationMs = 10_000
    public static let timerTickMs = 10
    private static let timerPrecisionToleranceMs = 0.001
    public static let tieThresholdMs = 10
    public static let roundResultDisplayDurationSeconds: Double = 3.0

    // Scoring
    public static let pointsFasterCorrect = 10
    public static let pointsSlowerCorrect = 0
    public static let pointsTieCorrect = 5
    public static let pointsWrong = -5

    // Coin rewards
    public static let coinPerCorrectAnswer = 1
    public static let coinWinBonus = 5
    public static let coinLoseBonus = 2
    public static let coinDrawBonus = 3
    public static let coinWinBonusPremium = 8
    public static let coinLoseBonusPremium = 3
    public static let coinDrawBonusPremium = 5

    // MARK: - Published Properties

    @Published public private(set) var questions: [Question] = []
    @Published public private(set) var currentQuestionIndex = 0
    @Published public private(set) var shuffledAnswers: [Answer] = []
    @Published public private(set) var timeRemainingMs: Int = timerDurationMs
    @Published public private(set) var timerActive = false

    @Published public private(set) var myScore = 0
    @Published public private(set) var opponentScore = 0
    @Published public private(set) var myCorrectCount = 0
    @Published public private(set) var opponentCorrectCount = 0

    @Published public private(set) var myDisplayName = ""
    @Published public private(set) var opponentDisplayName = ""
    @Published public private(set) var isHost = false

    @Published public private(set) var myAnswerIndex: Int?
    @Published public private(set) var opponentAnswerIndex: Int?
    @Published public private(set) var myResponseTimeMs: Int?
    @Published public private(set) var opponentResponseTimeMs: Int?
    @Published public private(set) var roundResult: QuestionResultPayload?
    @Published public private(set) var showingRoundResult = false

    @Published public private(set) var isGameOver = false
    @Published public private(set) var gameResult: MultiplayerGameResult?

    @Published public private(set) var coinsEarned = 0

    // MARK: - Computed State (derived from coordinator's session state)

    /// The current blocking overlay to display, if any.
    public var currentOverlay: MultiplayerOverlayType? {
        gameCoordinator.sessionState.blockingOverlay
    }

    /// Whether the connection is lost or degraded.
    public var connectionLost: Bool {
        switch gameCoordinator.sessionState {
        case .reconnecting, .disconnected: return true
        default: return false
        }
    }

    /// Whether the opponent has paused the game.
    public var opponentPaused: Bool {
        if case .opponentPaused = gameCoordinator.sessionState { return true }
        return false
    }

    /// Whether we are waiting for the opponent's answer.
    public var waitingForOpponent: Bool {
        if case .waitingForOpponent = gameCoordinator.sessionState { return true }
        return false
    }

    /// Whether we are waiting for the host's question result.
    public var waitingForResult: Bool {
        if case .waitingForResult = gameCoordinator.sessionState { return true }
        return false
    }

    // MARK: - Stats

    public private(set) var myResponseTimes: [Int] = []
    public private(set) var opponentResponseTimes: [Int] = []
    public private(set) var roundResults: [QuestionResultPayload] = []

    public var currentQuestion: Question? {
        guard currentQuestionIndex < questions.count else { return nil }
        return questions[currentQuestionIndex]
    }

    /// Host name is always first (left side)
    public var hostDisplayName: String { isHost ? myDisplayName : opponentDisplayName }
    public var guestDisplayName: String { isHost ? opponentDisplayName : myDisplayName }
    public var hostScore: Int { isHost ? myScore : opponentScore }
    public var guestScore: Int { isHost ? opponentScore : myScore }

    // MARK: - Ad Support

    @Published public private(set) var adDismissed = false

    // MARK: - Private Properties

    public let gameCoordinator: MultiplayerGameCoordinator
    public let rules: QuizRulesConfiguration
    private let analytics: (any AnalyticsProvider)?
    private let interstitialAd: (any InterstitialAdProvider)?
    private let purchaseStatus: (any PurchaseStatusProvider)?
    private let progressManager: PlayerProgressManager?

    private var timerTask: (any QuizEngineScheduledTask)?
    private var timerGeneration: UInt = 0
    private var roundAdvanceTask: (any QuizEngineScheduledTask)?
    private var gameConfigRetryTask: (any QuizEngineScheduledTask)?
    private var cancellables = Set<AnyCancellable>()
    private var seed: UInt64 = 0
    private var randomNumberGenerator: any RandomNumberGenerator
    private let clock: any QuizEngineClock
    private let scheduler: any QuizEngineScheduler
    private var activeMatchDuration: TimeInterval = 0
    private var activeMatchSegmentStartTime: Date?
    private var timerSegmentStartingRemainingMs: Double
    private var timerRemainingExactMs: Double

    // Host-only timing
    private var questionStartTime: Date?
    private var hostAnswerTime: Date?
    private var guestAnswerTime: Date?
    private var hostAnswer: AnswerPayload?
    private var guestAnswer: AnswerPayload?
    private var pendingHostSetup: (questions: [Question], localDisplayName: String)?
    private var terminalEffectsRecorded = false

    // MARK: - Init

    public convenience init(
        gameCoordinator: MultiplayerGameCoordinator,
        analytics: (any AnalyticsProvider)? = nil,
        interstitialAd: (any InterstitialAdProvider)? = nil,
        purchaseStatus: (any PurchaseStatusProvider)? = nil,
        progressManager: PlayerProgressManager? = nil,
        clock: any QuizEngineClock = SystemQuizEngineClock(),
        scheduler: any QuizEngineScheduler = MainQueueQuizEngineScheduler(),
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.init(
            gameCoordinator: gameCoordinator,
            rules: .serbianCompatible,
            analytics: analytics,
            interstitialAd: interstitialAd,
            purchaseStatus: purchaseStatus,
            progressManager: progressManager,
            clock: clock,
            scheduler: scheduler,
            randomNumberGenerator: randomNumberGenerator
        )
    }

    public init(
        gameCoordinator: MultiplayerGameCoordinator,
        rules: QuizRulesConfiguration,
        analytics: (any AnalyticsProvider)? = nil,
        interstitialAd: (any InterstitialAdProvider)? = nil,
        purchaseStatus: (any PurchaseStatusProvider)? = nil,
        progressManager: PlayerProgressManager? = nil,
        clock: any QuizEngineClock = SystemQuizEngineClock(),
        scheduler: any QuizEngineScheduler = MainQueueQuizEngineScheduler(),
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.gameCoordinator = gameCoordinator
        self.rules = rules
        self.analytics = analytics
        self.interstitialAd = interstitialAd
        self.purchaseStatus = purchaseStatus
        self.progressManager = progressManager
        self.clock = clock
        self.scheduler = scheduler
        self.randomNumberGenerator = randomNumberGenerator
        self.timeRemainingMs = rules.multiplayer.timerDurationMilliseconds
        self.timerSegmentStartingRemainingMs = Double(rules.multiplayer.timerDurationMilliseconds)
        self.timerRemainingExactMs = Double(rules.multiplayer.timerDurationMilliseconds)
        self.isHost = gameCoordinator.role == .host
        self.opponentDisplayName = gameCoordinator.opponent?.displayName ?? String(localized: "multiplayer_quiz_view_model.opponent.fallback_name")
        interstitialAd?.load()
        setupObservers()
    }

    // MARK: - Game Setup

    public func setupAsHost(questions: [Question], localDisplayName: String) {
        if gameCoordinator.isHardenedMatch, !gameCoordinator.handshakeAccepted {
            pendingHostSetup = (questions, localDisplayName)
            return
        }
        completeHostSetup(questions: questions, localDisplayName: localDisplayName)
    }

    private func completeHostSetup(questions: [Question], localDisplayName: String) {
        guard !questions.isEmpty else { return }
        self.questions = questions
        self.myDisplayName = localDisplayName
        self.seed = UInt64.random(in: 1...UInt64.max, using: &randomNumberGenerator)
        resetMatchDuration()

        let config = GameConfigPayload(questions: questions, seed: seed)
        sendGameConfigWithRetry(config)

        loadCurrentQuestion()
    }

    /// Sends gameConfig to the guest with retries to handle the race condition
    /// where the guest's coordinator may not be listening yet.
    private func sendGameConfigWithRetry(_ config: GameConfigPayload) {
        let maxRetries = 3
        let retryDelayMs = 500

        print("[MultiplayerQuizViewModel] Host sending gameConfig with \(config.questions.count) questions")
        gameCoordinator.sendGameConfig(config)

        gameConfigRetryTask?.cancel()
        scheduleGameConfigRetry(config, attempt: 1, maxRetries: maxRetries, retryDelayMs: retryDelayMs)
    }

    private func scheduleGameConfigRetry(
        _ config: GameConfigPayload,
        attempt: Int,
        maxRetries: Int,
        retryDelayMs: Int
    ) {
        guard attempt <= maxRetries else { return }
        gameConfigRetryTask = scheduler.schedule(
            after: TimeInterval(retryDelayMs * attempt) / 1000
        ) { [weak self] in
            guard let self, !self.isGameOver, !self.gameCoordinator.opponentReady else { return }
            print("[MultiplayerQuizViewModel] Host re-sending gameConfig (retry \(attempt)/\(maxRetries))")
            self.gameCoordinator.sendGameConfig(config)
            self.scheduleGameConfigRetry(
                config,
                attempt: attempt + 1,
                maxRetries: maxRetries,
                retryDelayMs: retryDelayMs
            )
        }
    }

    public func handleGameConfig(_ config: GameConfigPayload, localDisplayName: String) {
        print("[MultiplayerQuizViewModel] handleGameConfig called with \(config.questions.count) questions")

        guard !config.questions.isEmpty else {
            print("[MultiplayerQuizViewModel] Received empty questions — ending game")
            isGameOver = true
            gameResult = .opponentDisconnected
            return
        }

        if gameCoordinator.isHardenedMatch,
           config.questions.count != rules.sessions.multiplayerQuestionCount {
            return
        }

        // Ignore duplicate gameConfig (host retries delivery)
        guard questions.isEmpty else {
            print("[MultiplayerQuizViewModel] Ignoring duplicate gameConfig — already have questions")
            return
        }

        self.questions = config.questions
        self.seed = config.seed
        self.myDisplayName = localDisplayName
        resetMatchDuration()

        print("[MultiplayerQuizViewModel] questions.count = \(self.questions.count), calling loadCurrentQuestion")
        loadCurrentQuestion()
    }

    // MARK: - Question Flow

    private func loadCurrentQuestion() {
        guard currentQuestionIndex < questions.count else {
            return
        }

        // Reset per-round state
        myAnswerIndex = nil
        opponentAnswerIndex = nil
        myResponseTimeMs = nil
        opponentResponseTimeMs = nil
        roundResult = nil
        showingRoundResult = false
        hostAnswer = nil
        guestAnswer = nil
        hostAnswerTime = nil
        guestAnswerTime = nil
        timeRemainingMs = rules.multiplayer.timerDurationMilliseconds
        timerRemainingExactMs = Double(rules.multiplayer.timerDurationMilliseconds)
        timerSegmentStartingRemainingMs = timerRemainingExactMs

        gameCoordinator.prepareForNextRound()
        gameCoordinator.transitionToLoadingRound()

        // Shuffle answers deterministically
        var answerRng = SeededRandomNumberGenerator(seed: seed &+ UInt64(currentQuestionIndex))
        shuffledAnswers = questions[currentQuestionIndex].answers.shuffled(using: &answerRng)

        // Signal ready
        gameCoordinator.sendPlayerReady()
    }

    public func startRound() {
        timeRemainingMs = rules.multiplayer.timerDurationMilliseconds
        timerRemainingExactMs = Double(rules.multiplayer.timerDurationMilliseconds)
        timerSegmentStartingRemainingMs = timerRemainingExactMs
        timerActive = true
        gameCoordinator.transitionToPlaying()
        startTimer()
    }

    // MARK: - Answer Submission

    public func submitAnswer(answerIndex: Int) {
        submitAnswer(answerIndex: answerIndex, enforcesDeadline: true)
    }

    private func submitAnswer(answerIndex: Int, enforcesDeadline: Bool) {
        guard myAnswerIndex == nil, !showingRoundResult else { return }
        if enforcesDeadline {
            synchronizeTimer()
            guard myAnswerIndex == nil,
                  !showingRoundResult,
                  timerRemainingExactMs > 0 else { return }
        }

        let responseTimeMs = max(
            0,
            rules.multiplayer.timerDurationMilliseconds - timeRemainingMs
        )
        myAnswerIndex = answerIndex
        myResponseTimeMs = responseTimeMs
        stopTimer()

        let payload = AnswerPayload(
            questionIndex: currentQuestionIndex,
            answerIndex: answerIndex,
            responseTimeMs: responseTimeMs
        )

        if isHost {
            hostAnswer = payload
            hostAnswerTime = clock.now
        }

        gameCoordinator.sendAnswer(payload)

        if gameCoordinator.opponentAnswer == nil {
            gameCoordinator.transitionToWaitingForOpponent()
        }

        // If host and already have opponent answer, resolve
        if isHost, let opponentAns = gameCoordinator.opponentAnswer {
            handleBothAnswersReceived(opponentAnswer: opponentAns)
        }
    }

    /// Answer index sentinel values for non-answer submissions
    public static let timeoutAnswerIndex = -1
    public static let skipAnswerIndex = -2

    public func skipQuestion() {
        guard myAnswerIndex == nil, !showingRoundResult else { return }
        submitAnswer(answerIndex: Self.skipAnswerIndex)
    }

    private func handleTimeout() {
        guard myAnswerIndex == nil else { return }
        submitAnswer(answerIndex: Self.timeoutAnswerIndex, enforcesDeadline: false)
    }

    // MARK: - Round Resolution (Host)

    private func handleBothAnswersReceived(opponentAnswer: AnswerPayload) {
        guard isHost else { return }
        guard let myAns = hostAnswer, roundResult == nil else { return }
        let oppAns = opponentAnswer

        let hostMs = myAns.responseTimeMs
        let guestMs = oppAns.responseTimeMs

        let correctIndex = shuffledAnswers.firstIndex(where: { $0.correct }) ?? -1
        let hostCorrect = myAns.answerIndex == correctIndex
        let guestCorrect = oppAns.answerIndex == correctIndex
        let hostSkipped = myAns.answerIndex == Self.skipAnswerIndex || myAns.answerIndex == Self.timeoutAnswerIndex
        let guestSkipped = oppAns.answerIndex == Self.skipAnswerIndex || oppAns.answerIndex == Self.timeoutAnswerIndex

        let points = MultiplayerRuleEvaluator.points(
            hostCorrect: hostCorrect,
            guestCorrect: guestCorrect,
            hostMilliseconds: hostMs,
            guestMilliseconds: guestMs,
            hostSkipped: hostSkipped,
            guestSkipped: guestSkipped,
            rules: rules.multiplayer
        )
        let hostPts = points.host
        let guestPts = points.guest

        let newHostTotal = Self.saturatingAdd(isHost ? myScore : opponentScore, hostPts)
        let newGuestTotal = Self.saturatingAdd(isHost ? opponentScore : myScore, guestPts)

        let result = QuestionResultPayload(
            questionIndex: currentQuestionIndex,
            correctAnswerIndex: correctIndex,
            hostCorrect: hostCorrect,
            guestCorrect: guestCorrect,
            hostResponseTimeMs: hostMs,
            guestResponseTimeMs: guestMs,
            hostPointsAwarded: hostPts,
            guestPointsAwarded: guestPts,
            hostTotalScore: newHostTotal,
            guestTotalScore: newGuestTotal
        )

        gameCoordinator.sendQuestionResult(result)
        applyRoundResult(result)
    }

    // MARK: - Apply Round Result

    private func applyRoundResult(_ result: QuestionResultPayload) {
        guard roundResult == nil, result.questionIndex == currentQuestionIndex else { return }
        stopTimer()
        roundResult = result
        roundResults.append(result)

        // Map host/guest scores to my/opponent
        if isHost {
            myScore = result.hostTotalScore
            opponentScore = result.guestTotalScore
            if result.hostCorrect { myCorrectCount += 1 }
            if result.guestCorrect { opponentCorrectCount += 1 }
            myResponseTimes.append(result.hostResponseTimeMs)
            opponentResponseTimes.append(result.guestResponseTimeMs)
            opponentAnswerIndex = guestAnswer?.answerIndex
            opponentResponseTimeMs = result.guestResponseTimeMs
        } else {
            myScore = result.guestTotalScore
            opponentScore = result.hostTotalScore
            if result.guestCorrect { myCorrectCount += 1 }
            if result.hostCorrect { opponentCorrectCount += 1 }
            myResponseTimes.append(result.guestResponseTimeMs)
            opponentResponseTimes.append(result.hostResponseTimeMs)
            opponentAnswerIndex = gameCoordinator.opponentAnswer?.answerIndex
            opponentResponseTimeMs = result.hostResponseTimeMs
        }

        // Update coordinator scores for disconnect handling
        gameCoordinator.lastHostScore = result.hostTotalScore
        gameCoordinator.lastGuestScore = result.guestTotalScore
        gameCoordinator.questionsCompleted = currentQuestionIndex + 1
        updateCorrectAnswerCoins(questionsCompleted: currentQuestionIndex + 1)

        showingRoundResult = true
        gameCoordinator.transitionToShowingResult()

        // Auto-advance after display duration
        roundAdvanceTask?.cancel()
        roundAdvanceTask = scheduler.schedule(after: Self.roundResultDisplayDurationSeconds) { [weak self] in
            guard let self, self.showingRoundResult else { return }
            self.advanceToNextQuestion()
        }
    }

    private func advanceToNextQuestion() {
        showingRoundResult = false

        if currentQuestionIndex + 1 >= questions.count {
            if isHost {
                let endPayload = GameEndPayload(
                    hostFinalScore: isHost ? myScore : opponentScore,
                    guestFinalScore: isHost ? opponentScore : myScore,
                    reason: .completed
                )
                gameCoordinator.sendGameEnd(endPayload)
                handleGameEnd(endPayload)
            } else {
                gameCoordinator.startGameEndTimeout()
            }
        } else {
            currentQuestionIndex += 1
            loadCurrentQuestion()
        }
    }

    // MARK: - Game End

    private func handleGameEnd(_ payload: GameEndPayload) {
        guard !isGameOver else { return }
        isGameOver = true
        pauseMatchDuration()
        stopTimer()

        let myFinal = isHost ? payload.hostFinalScore : payload.guestFinalScore
        let oppFinal = isHost ? payload.guestFinalScore : payload.hostFinalScore

        myScore = myFinal
        opponentScore = oppFinal

        switch payload.reason {
        case .completed:
            if myFinal > oppFinal {
                gameResult = .won
            } else if myFinal < oppFinal {
                gameResult = .lost
            } else {
                gameResult = .draw
            }
        case .opponentLeft, .disconnected:
            gameResult = .opponentDisconnected
        }

        calculateEndOfMatchCoins(payload: payload)
        recordTerminalEffectsIfNeeded(payload: payload)
    }

    private func recordTerminalEffectsIfNeeded(payload: GameEndPayload) {
        guard !terminalEffectsRecorded else { return }
        terminalEffectsRecorded = true

        if let progressManager, let matchID = gameCoordinator.matchID {
            let fingerprint = [
                matchID.uuidString,
                String(myScore),
                String(opponentScore),
                String(currentQuestionIndex + 1),
                String(myCorrectCount),
                String(coinsEarned),
                String(describing: gameResult)
            ].joined(separator: "|")
            let outcome = progressManager.recordMultiplayerResult(
                matchID: matchID.uuidString,
                fingerprint: fingerprint,
                won: gameResult == .won,
                draw: gameResult == .draw,
                score: myScore,
                questionsCompleted: currentQuestionIndex + 1,
                questionsCorrect: myCorrectCount,
                coinsEarned: coinsEarned,
                responseTimes: myResponseTimes
            )
            // The durable receipt is also the analytics idempotency boundary:
            // a recreated view model must not report an already-applied match.
            guard outcome == .recorded else { return }
        }
        logMatchAnalytics()
    }

    private func logMatchAnalytics() {
        let resultString: String
        switch gameResult {
        case .won: resultString = "won"
        case .lost: resultString = "lost"
        case .draw: resultString = "draw"
        case .opponentDisconnected: resultString = "opponent_disconnected"
        case .none: return
        }

        let duration = Self.clampedWholeSeconds(activeMatchDuration)

        guard let transportLabel = gameCoordinator.matchConfigurationAnalyticsLabel else { return }
        analytics?.logMultiplayerMatchCompleted(
            result: resultString,
            myScore: myScore,
            opponentScore: opponentScore,
            questionsCompleted: currentQuestionIndex + 1,
            durationSeconds: duration,
            transportType: transportLabel
        )
    }

    private func calculateEndOfMatchCoins(payload: GameEndPayload) {
        let questionsCompleted = currentQuestionIndex + 1
        coinsEarned = MultiplayerRuleEvaluator.totalCoins(
            correctAnswers: myCorrectCount,
            questionsCompleted: questionsCompleted,
            result: gameResult,
            isPremium: purchaseStatus?.isPremium ?? false,
            rules: rules.multiplayer.rewards
        )
    }

    private func updateCorrectAnswerCoins(questionsCompleted: Int) {
        coinsEarned = MultiplayerRuleEvaluator.correctAnswerCoins(
            correctAnswers: myCorrectCount,
            questionsCompleted: questionsCompleted,
            rules: rules.multiplayer.rewards
        )
    }

    // MARK: - Timer

    private func startTimer() {
        timerTask?.cancel()
        timerGeneration &+= 1
        guard timerRemainingExactMs > 0 else {
            timeRemainingMs = 0
            timerActive = false
            handleTimeout()
            return
        }
        timerActive = true
        questionStartTime = clock.now
        timerSegmentStartingRemainingMs = timerRemainingExactMs
        scheduleTimerTick(generation: timerGeneration)
    }

    private func scheduleTimerTick(generation: UInt) {
        timerTask = scheduler.schedule(after: TimeInterval(Self.timerTickMs) / 1000) { [weak self] in
            guard let self,
                  self.timerActive,
                  self.timerGeneration == generation else { return }
            self.synchronizeTimer()
            if self.timerActive, self.timerGeneration == generation {
                self.scheduleTimerTick(generation: generation)
            }
        }
    }

    private func stopTimer() {
        synchronizeTimer(allowTimeout: false)
        timerActive = false
        timerGeneration &+= 1
        timerTask?.cancel()
        timerTask = nil
        questionStartTime = nil
    }

    private func synchronizeTimer(allowTimeout: Bool = true) {
        guard timerActive, let startTime = questionStartTime else { return }
        let elapsedMs = max(0, clock.now.timeIntervalSince(startTime)) * 1_000
        let computedRemaining = max(0, timerSegmentStartingRemainingMs - elapsedMs)
        timerRemainingExactMs = min(timerRemainingExactMs, computedRemaining)
        timeRemainingMs = Int(ceil(max(0, timerRemainingExactMs - Self.timerPrecisionToleranceMs)))

        guard allowTimeout, timerRemainingExactMs <= Self.timerPrecisionToleranceMs else { return }
        timerRemainingExactMs = 0
        timeRemainingMs = 0
        timerActive = false
        timerGeneration &+= 1
        timerTask?.cancel()
        timerTask = nil
        questionStartTime = nil
        handleTimeout()
    }

    /// Centralized timer decision — timer should only run when playing and player hasn't answered.
    private func evaluateTimerState(forState state: MultiplayerSessionState? = nil) {
        let currentState = state ?? gameCoordinator.sessionState
        let shouldRun: Bool
        switch currentState {
        case .playing:
            shouldRun = myAnswerIndex == nil && !showingRoundResult
        default:
            shouldRun = false
        }

        if shouldRun && !timerActive {
            startTimer()
        } else if !shouldRun && timerActive {
            stopTimer()
        }
    }

    // MARK: - Formatted Timer

    public var formattedTimeRemaining: String {
        let seconds = Double(timeRemainingMs) / 1000.0
        return String(format: "%.2f", seconds)
    }

    // MARK: - Observers

    private func setupObservers() {
        gameCoordinator.$sessionState
            .sink { [weak self] state in
                guard let self else { return }
                self.handleSessionStateChange(state)
            }
            .store(in: &cancellables)

        gameCoordinator.$opponentReady
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self else { return }
                guard case .loadingRound = self.gameCoordinator.sessionState else { return }
                self.startRound()
            }
            .store(in: &cancellables)

        gameCoordinator.$opponentAnswer
            .compactMap { $0 }
            .sink { [weak self] answer in
                guard let self, !self.gameCoordinator.sessionState.isTerminal else { return }

                if self.isHost {
                    self.guestAnswer = answer
                    self.guestAnswerTime = self.clock.now
                    if self.hostAnswer != nil {
                        self.handleBothAnswersReceived(opponentAnswer: answer)
                    }
                }
            }
            .store(in: &cancellables)

        gameCoordinator.$questionResult
            .compactMap { $0 }
            .sink { [weak self] result in
                guard let self, !self.isHost else { return }
                self.applyRoundResult(result)
            }
            .store(in: &cancellables)

        gameCoordinator.$gameEndResult
            .compactMap { $0 }
            .sink { [weak self] result in
                self?.handleGameEnd(result)
            }
            .store(in: &cancellables)

        gameCoordinator.$receivedGameConfig
            .compactMap { $0 }
            .sink { [weak self] config in
                guard let self else {
                    print("[MultiplayerQuizViewModel] receivedGameConfig sink: self is nil")
                    return
                }
                print("[MultiplayerQuizViewModel] receivedGameConfig received with \(config.questions.count) questions, isHost=\(self.isHost)")
                guard !self.isHost else {
                    print("[MultiplayerQuizViewModel] Ignoring gameConfig - we are the host")
                    return
                }
                let localName = self.gameCoordinator.transport?.localPlayer.displayName ?? ""
                print("[MultiplayerQuizViewModel] Guest handling gameConfig, localName=\(localName)")
                self.handleGameConfig(config, localDisplayName: localName)
            }
            .store(in: &cancellables)

        gameCoordinator.$handshakeAccepted
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self, let pending = self.pendingHostSetup else { return }
                self.pendingHostSetup = nil
                self.completeHostSetup(questions: pending.questions, localDisplayName: pending.localDisplayName)
            }
            .store(in: &cancellables)
    }

    /// Handles session state changes from the coordinator's state machine.
    private func handleSessionStateChange(_ state: MultiplayerSessionState) {
        objectWillChange.send()

        switch state {
        case .opponentPaused:
            pauseMatchDuration()
            stopTimer()

        case .reconnecting:
            pauseMatchDuration()
            stopTimer()

        case .disconnected(let payload), .gameOver(let payload):
            pauseMatchDuration()
            stopTimer()
            if !isGameOver {
                handleGameEnd(payload)
            }

        case .playing:
            resumeMatchDuration()
            evaluateTimerState(forState: state)

        case .waitingForConfig, .loadingRound, .waitingForOpponent, .waitingForResult, .showingResult:
            break
        }
    }

    // MARK: - App Lifecycle

    public func handleAppBackgrounded() {
        guard !isGameOver else { return }
        guard !gameCoordinator.sessionState.isTerminal else { return }
        switch gameCoordinator.sessionState {
        case .reconnecting, .disconnected:
            return
        default:
            break
        }
        pauseMatchDuration()
        gameCoordinator.sendPause()
        stopTimer()
    }

    public func handleAppForegrounded() {
        guard !isGameOver else { return }
        switch gameCoordinator.sessionState {
        case .reconnecting, .disconnected, .gameOver:
            return
        case .opponentPaused:
            gameCoordinator.sendResume()
        default:
            gameCoordinator.sendResume()
            resumeMatchDuration()
            evaluateTimerState()
        }
    }

    // MARK: - Ads

    public func showInterstitialAd() {
        interstitialAd?.show()
    }

    public func isAdReady() -> Bool {
        interstitialAd?.isReady() ?? false
    }

    public func showInterstitialAdIfEligible() {
        let eligibility = rules.multiplayer.interstitialEligibility
        guard !(purchaseStatus?.isPremium ?? false),
              !(purchaseStatus?.adsRemoved ?? false),
              isAdReady(),
              eligibility.numerator > 0,
              Int.random(in: 0..<eligibility.denominator, using: &randomNumberGenerator) < eligibility.numerator else { return }
        showInterstitialAd()
    }

    /// Call this from the app-side ad delegate when the ad is dismissed.
    public func markAdDismissed() {
        adDismissed = true
    }

    // MARK: - Cleanup

    public func endMatch() {
        stopTimer()
        roundAdvanceTask?.cancel()
        roundAdvanceTask = nil
        gameConfigRetryTask?.cancel()
        gameConfigRetryTask = nil
        gameCoordinator.endGame()
        cancellables.removeAll()
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return result }
        return rhs >= 0 ? Int.max : Int.min
    }

    private func resetMatchDuration() {
        activeMatchDuration = 0
        activeMatchSegmentStartTime = clock.now
    }

    private func pauseMatchDuration() {
        guard let startTime = activeMatchSegmentStartTime else { return }
        activeMatchDuration += max(0, clock.now.timeIntervalSince(startTime))
        activeMatchSegmentStartTime = nil
    }

    private func resumeMatchDuration() {
        guard activeMatchSegmentStartTime == nil else { return }
        activeMatchSegmentStartTime = clock.now
    }

    private static func clampedWholeSeconds(_ seconds: TimeInterval) -> Int {
        let seconds = max(0, seconds)
        guard seconds < Double(Int.max) else { return Int.max }
        return Int(seconds)
    }

}
