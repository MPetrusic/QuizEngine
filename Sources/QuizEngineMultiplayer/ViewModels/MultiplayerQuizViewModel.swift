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
    private let analytics: (any AnalyticsProvider)?
    private let interstitialAd: (any InterstitialAdProvider)?
    private let purchaseStatus: (any PurchaseStatusProvider)?

    private var timerTask: (any QuizEngineScheduledTask)?
    private var roundAdvanceTask: (any QuizEngineScheduledTask)?
    private var gameConfigRetryTask: (any QuizEngineScheduledTask)?
    private var cancellables = Set<AnyCancellable>()
    private var seed: UInt64 = 0
    private var randomNumberGenerator: any RandomNumberGenerator
    private let clock: any QuizEngineClock
    private let scheduler: any QuizEngineScheduler
    private var matchStartTime: Date?

    // Host-only timing
    private var questionStartTime: Date?
    private var hostAnswerTime: Date?
    private var guestAnswerTime: Date?
    private var hostAnswer: AnswerPayload?
    private var guestAnswer: AnswerPayload?

    // MARK: - Init

    public init(
        gameCoordinator: MultiplayerGameCoordinator,
        analytics: (any AnalyticsProvider)? = nil,
        interstitialAd: (any InterstitialAdProvider)? = nil,
        purchaseStatus: (any PurchaseStatusProvider)? = nil,
        clock: any QuizEngineClock = SystemQuizEngineClock(),
        scheduler: any QuizEngineScheduler = MainQueueQuizEngineScheduler(),
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.gameCoordinator = gameCoordinator
        self.analytics = analytics
        self.interstitialAd = interstitialAd
        self.purchaseStatus = purchaseStatus
        self.clock = clock
        self.scheduler = scheduler
        self.randomNumberGenerator = randomNumberGenerator
        self.isHost = gameCoordinator.role == .host
        self.opponentDisplayName = gameCoordinator.opponent?.displayName ?? String(localized: "multiplayer_quiz_view_model.opponent.fallback_name")
        interstitialAd?.load()
        setupObservers()
    }

    // MARK: - Game Setup

    public func setupAsHost(questions: [Question], localDisplayName: String) {
        self.questions = questions
        self.myDisplayName = localDisplayName
        self.seed = UInt64.random(in: 1...UInt64.max, using: &randomNumberGenerator)
        self.matchStartTime = clock.now

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
        try? gameCoordinator.transport?.send(message: .gameConfig(config))

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
            try? self.gameCoordinator.transport?.send(message: .gameConfig(config))
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

        // Ignore duplicate gameConfig (host retries delivery)
        guard questions.isEmpty else {
            print("[MultiplayerQuizViewModel] Ignoring duplicate gameConfig — already have questions")
            return
        }

        self.questions = config.questions
        self.seed = config.seed
        self.myDisplayName = localDisplayName
        self.matchStartTime = clock.now

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
        timeRemainingMs = Self.timerDurationMs

        gameCoordinator.prepareForNextRound()
        gameCoordinator.transitionToLoadingRound()

        // Shuffle answers deterministically
        var answerRng = SeededRandomNumberGenerator(seed: seed &+ UInt64(currentQuestionIndex))
        shuffledAnswers = questions[currentQuestionIndex].answers.shuffled(using: &answerRng)

        // Signal ready
        gameCoordinator.sendPlayerReady()
    }

    public func startRound() {
        timeRemainingMs = Self.timerDurationMs
        timerActive = true
        questionStartTime = clock.now
        gameCoordinator.transitionToPlaying()
        startTimer()
    }

    // MARK: - Answer Submission

    public func submitAnswer(answerIndex: Int) {
        guard myAnswerIndex == nil, !showingRoundResult else { return }

        let responseTimeMs = Self.timerDurationMs - timeRemainingMs
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
        submitAnswer(answerIndex: Self.timeoutAnswerIndex)
    }

    // MARK: - Round Resolution (Host)

    private func handleBothAnswersReceived(opponentAnswer: AnswerPayload) {
        guard isHost else { return }

        let myAns = hostAnswer!
        let oppAns = opponentAnswer

        let hostMs = myAns.responseTimeMs
        let guestMs = oppAns.responseTimeMs

        let correctIndex = shuffledAnswers.firstIndex(where: { $0.correct }) ?? -1
        let hostCorrect = myAns.answerIndex == correctIndex
        let guestCorrect = oppAns.answerIndex == correctIndex
        let hostSkipped = myAns.answerIndex == Self.skipAnswerIndex || myAns.answerIndex == Self.timeoutAnswerIndex
        let guestSkipped = oppAns.answerIndex == Self.skipAnswerIndex || oppAns.answerIndex == Self.timeoutAnswerIndex

        let (hostPts, guestPts) = calculatePoints(
            hostCorrect: hostCorrect, guestCorrect: guestCorrect,
            hostMs: hostMs, guestMs: guestMs,
            hostSkipped: hostSkipped, guestSkipped: guestSkipped
        )

        let newHostTotal = (isHost ? myScore : opponentScore) + hostPts
        let newGuestTotal = (isHost ? opponentScore : myScore) + guestPts

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

    private func calculatePoints(hostCorrect: Bool, guestCorrect: Bool, hostMs: Int, guestMs: Int, hostSkipped: Bool, guestSkipped: Bool) -> (Int, Int) {
        let hostPts: Int
        let guestPts: Int

        if hostCorrect && guestCorrect {
            let diff = abs(hostMs - guestMs)
            if diff < Self.tieThresholdMs {
                hostPts = Self.pointsTieCorrect
                guestPts = Self.pointsTieCorrect
            } else if hostMs < guestMs {
                hostPts = Self.pointsFasterCorrect
                guestPts = Self.pointsSlowerCorrect
            } else {
                hostPts = Self.pointsSlowerCorrect
                guestPts = Self.pointsFasterCorrect
            }
        } else {
            if hostCorrect {
                hostPts = Self.pointsFasterCorrect
            } else if hostSkipped {
                hostPts = 0
            } else {
                hostPts = Self.pointsWrong
            }

            if guestCorrect {
                guestPts = Self.pointsFasterCorrect
            } else if guestSkipped {
                guestPts = 0
            } else {
                guestPts = Self.pointsWrong
            }
        }

        return (hostPts, guestPts)
    }

    // MARK: - Apply Round Result

    private func applyRoundResult(_ result: QuestionResultPayload) {
        stopTimer()
        roundResult = result
        roundResults.append(result)

        // Map host/guest scores to my/opponent
        if isHost {
            myScore = result.hostTotalScore
            opponentScore = result.guestTotalScore
            if result.hostCorrect { myCorrectCount += 1; coinsEarned += Self.coinPerCorrectAnswer }
            if result.guestCorrect { opponentCorrectCount += 1 }
            myResponseTimes.append(result.hostResponseTimeMs)
            opponentResponseTimes.append(result.guestResponseTimeMs)
            opponentAnswerIndex = guestAnswer?.answerIndex
            opponentResponseTimeMs = result.guestResponseTimeMs
        } else {
            myScore = result.guestTotalScore
            opponentScore = result.hostTotalScore
            if result.guestCorrect { myCorrectCount += 1; coinsEarned += Self.coinPerCorrectAnswer }
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

        let duration = matchStartTime.map { Int(clock.now.timeIntervalSince($0)) } ?? 0

        analytics?.logMultiplayerMatchCompleted(
            result: resultString,
            myScore: myScore,
            opponentScore: opponentScore,
            questionsCompleted: currentQuestionIndex + 1,
            durationSeconds: duration,
            transportType: "nearby"
        )
    }

    private func calculateEndOfMatchCoins(payload: GameEndPayload) {
        let questionsCompleted = currentQuestionIndex + 1
        let isPremium = purchaseStatus?.isPremium ?? false

        guard questionsCompleted >= 5 else {
            return
        }

        let fullReward = questionsCompleted >= 10
        var bonus = 0

        switch gameResult {
        case .won, .opponentDisconnected:
            bonus = isPremium ? Self.coinWinBonusPremium : Self.coinWinBonus
        case .lost:
            bonus = isPremium ? Self.coinLoseBonusPremium : Self.coinLoseBonus
        case .draw:
            bonus = isPremium ? Self.coinDrawBonusPremium : Self.coinDrawBonus
        case .none:
            break
        }

        if !fullReward {
            bonus /= 2
        }

        coinsEarned += bonus
    }

    // MARK: - Timer

    private func startTimer() {
        timerTask?.cancel()
        timerActive = true
        guard let startTime = questionStartTime else { return }
        scheduleTimerTick(from: startTime)
    }

    private func scheduleTimerTick(from startTime: Date) {
        timerTask = scheduler.schedule(after: TimeInterval(Self.timerTickMs) / 1000) { [weak self] in
            guard let self, self.timerActive else { return }
            let elapsedMs = Int(self.clock.now.timeIntervalSince(startTime) * 1000)
            let remaining = Self.timerDurationMs - elapsedMs
            if remaining <= 0 {
                self.timeRemainingMs = 0
                self.timerActive = false
                self.handleTimeout()
                return
            }
            self.timeRemainingMs = remaining
            self.scheduleTimerTick(from: startTime)
        }
    }

    private func stopTimer() {
        timerActive = false
        timerTask?.cancel()
        timerTask = nil
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
    }

    /// Handles session state changes from the coordinator's state machine.
    private func handleSessionStateChange(_ state: MultiplayerSessionState) {
        objectWillChange.send()

        switch state {
        case .opponentPaused:
            stopTimer()

        case .reconnecting:
            stopTimer()

        case .disconnected(let payload), .gameOver(let payload):
            stopTimer()
            if !isGameOver {
                handleGameEnd(payload)
            }

        case .playing:
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
        guard !(purchaseStatus?.isPremium ?? false),
              !(purchaseStatus?.adsRemoved ?? false),
              isAdReady(),
              Int.random(in: 0...1, using: &randomNumberGenerator) == 0 else { return }
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
}
