//
//  MultiplayerGameCoordinator.swift
//  QuizEngineMultiplayer
//

import Foundation
import QuizEngineCore

@MainActor
public final class MultiplayerGameCoordinator: ObservableObject, MultiplayerGameCoordinating {

    // MARK: - Constants

    private static let hardDisconnectGracePeriod: TimeInterval = 3
    private static let softDisconnectGracePeriod: TimeInterval = 10
    private static let pauseTimeout: TimeInterval = 60
    private static let readyTimeout: TimeInterval = 10
    private static let maxReadyRetries = 2
    private static let questionResultTimeout: TimeInterval = 5
    private static let maxQuestionResultRetries = 2
    private static let gameConfigTimeout: TimeInterval = 10
    private static let gameEndTimeout: TimeInterval = 5

    // MARK: - Published Properties (MultiplayerGameCoordinating)

    @Published public private(set) var opponent: MultiplayerPlayer?
    @Published public private(set) var role: MultiplayerRole?
    @Published public private(set) var sessionState: MultiplayerSessionState = .waitingForConfig
    @Published public private(set) var opponentAnswer: AnswerPayload?
    @Published public private(set) var questionResult: QuestionResultPayload?
    @Published public private(set) var gameEndResult: GameEndPayload?
    @Published public private(set) var opponentReady: Bool = false
    @Published public private(set) var receivedGameConfig: GameConfigPayload?

    // MARK: - Internal State (for ViewModel to read)

    /// Number of questions completed so far — set by the ViewModel after each round
    public var questionsCompleted: Int = 0

    /// Last known scores — set by the ViewModel so coordinator can build disconnect gameEnd
    public var lastHostScore: Int = 0
    public var lastGuestScore: Int = 0

    // MARK: - Private Properties

    /// Transport reference — accessible by ViewModel for sending gameConfig
    public private(set) var transport: (any MultiplayerTransport)?
    private var eventListenerTask: Task<Void, Never>?
    private var reconnectionTask: Task<Void, Never>?
    private var pauseTimeoutTask: Task<Void, Never>?
    private var readyTimeoutTask: Task<Void, Never>?
    private var questionResultTimeoutTask: Task<Void, Never>?
    private var gameConfigTimeoutTask: Task<Void, Never>?
    private var gameEndTimeoutTask: Task<Void, Never>?
    private var readyRetryCount = 0
    private var questionResultRetryCount = 0
    private var lastSentAnswer: AnswerPayload?
    private var isGameActive = false

    /// Buffers an opponent's playerReady that arrived while we were still
    /// in `.showingResult`. Consumed when we transition to `.loadingRound`.
    private var hasPendingOpponentReady = false

    /// The state the session was in before an interruption (pause/reconnect).
    /// Used to restore when the interruption ends.
    private var stateBeforeInterruption: MultiplayerSessionState?

    // MARK: - Dependencies

    private let analytics: (any AnalyticsProvider)?

    // MARK: - Init

    public init(analytics: (any AnalyticsProvider)? = nil) {
        self.analytics = analytics
    }

    // MARK: - Lifecycle

    public func startGame(transport: any MultiplayerTransport, opponent: MultiplayerPlayer, role: MultiplayerRole, bufferedMessages: [MultiplayerMessage] = []) {
        self.transport = transport
        self.opponent = opponent
        self.role = role
        self.isGameActive = true
        resetState()

        // Guest starts in waitingForConfig; host will transition via ViewModel
        if role == .guest {
            sessionState = .waitingForConfig
        }

        // Process any messages that were buffered during the lobby phase
        for message in bufferedMessages {
            print("[MultiplayerGameCoordinator] Processing buffered message: \(message)")
            handleMessage(message)
        }

        startListening()

        // Guest: start a timeout waiting for gameConfig
        if role == .guest && receivedGameConfig == nil {
            startGameConfigTimeout()
        }
    }

    public func endGame() {
        isGameActive = false
        cancelAllTimeoutTasks()
        eventListenerTask?.cancel()
        eventListenerTask = nil
        transport?.disconnect()
        transport = nil
    }

    // MARK: - State Machine

    /// Transitions the session to a new state.
    /// Terminal states (.disconnected, .gameOver) cannot be exited once entered.
    private func transition(to newState: MultiplayerSessionState) {
        guard !sessionState.isTerminal else {
            print("[MultiplayerGameCoordinator] Ignoring transition to \(newState) — already in terminal state \(sessionState)")
            return
        }

        print("[MultiplayerGameCoordinator] State transition: \(sessionState) → \(newState)")
        sessionState = newState

        // On terminal state entry, cancel all pending tasks to prevent further mutations
        if newState.isTerminal {
            cancelAllTimeoutTasks()
            isGameActive = false
        }
    }

    /// ViewModel-callable state transitions
    public func transitionToLoadingRound() {
        transition(to: .loadingRound)
        if hasPendingOpponentReady {
            hasPendingOpponentReady = false
            readyTimeoutTask?.cancel()
            opponentReady = true
        }
    }
    public func transitionToPlaying() { transition(to: .playing) }
    public func transitionToWaitingForOpponent() { transition(to: .waitingForOpponent) }
    public func transitionToWaitingForResult() { transition(to: .waitingForResult) }
    public func transitionToShowingResult() { transition(to: .showingResult) }

    // MARK: - MultiplayerGameCoordinating Methods

    public func sendPlayerReady() {
        guard !sessionState.isTerminal else { return }
        try? transport?.send(message: .playerReady)
        startReadyTimeout()
    }

    public func sendAnswer(_ answer: AnswerPayload) {
        guard !sessionState.isTerminal else { return }
        lastSentAnswer = answer
        try? transport?.send(message: .answerSubmitted(answer))
        if role == .guest {
            startQuestionResultTimeout()
        }
    }

    public func sendQuestionResult(_ result: QuestionResultPayload) {
        guard !sessionState.isTerminal else { return }
        try? transport?.send(message: .questionResult(result))
    }

    public func sendGameEnd(_ result: GameEndPayload) {
        try? transport?.send(message: .gameEnd(result))
    }

    // MARK: - Round Management

    /// Call at the start of each new round to reset per-round state
    public func prepareForNextRound() {
        opponentAnswer = nil
        questionResult = nil
        opponentReady = false
        readyRetryCount = 0
        questionResultRetryCount = 0
        lastSentAnswer = nil
        readyTimeoutTask?.cancel()
        questionResultTimeoutTask?.cancel()
        gameEndTimeoutTask?.cancel()
    }

    /// Call to send pause message when our app goes to background
    public func sendPause() {
        guard !sessionState.isTerminal else { return }
        try? transport?.send(message: .pause)
    }

    /// Call to send resume message when our app returns to foreground
    public func sendResume() {
        guard !sessionState.isTerminal else { return }
        try? transport?.send(message: .resume)
    }

    /// Guest: start a timeout waiting for gameEnd after the last round.
    public func startGameEndTimeout() {
        gameEndTimeoutTask?.cancel()
        gameEndTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.gameEndTimeout))
            guard !Task.isCancelled, let self, self.gameEndResult == nil else { return }
            print("[MultiplayerGameCoordinator] gameEnd timeout — auto-ending game with local scores")
            let endPayload = GameEndPayload(
                hostFinalScore: self.lastHostScore,
                guestFinalScore: self.lastGuestScore,
                reason: .completed
            )
            self.transition(to: .gameOver(endPayload))
            self.gameEndResult = endPayload
        }
    }

    // MARK: - Private — Event Listening

    private func startListening() {
        guard let transport else {
            print("[MultiplayerGameCoordinator] startListening: no transport!")
            return
        }
        print("[MultiplayerGameCoordinator] startListening: beginning to iterate eventStream")
        eventListenerTask = Task { [weak self] in
            for await event in transport.eventStream {
                guard !Task.isCancelled else {
                    print("[MultiplayerGameCoordinator] eventListenerTask cancelled")
                    return
                }
                print("[MultiplayerGameCoordinator] received event: \(event)")
                self?.handleEvent(event)
            }
            print("[MultiplayerGameCoordinator] eventStream iteration ended")
        }
    }

    private func handleEvent(_ event: MultiplayerTransportEvent) {
        guard isGameActive else { return }

        switch event {
        case .messageReceived(let message, _):
            handleMessage(message)

        case .disconnected:
            handleDisconnect(isHardDisconnect: true)

        case .reconnecting:
            handleDisconnect(isHardDisconnect: false)

        case .reconnected:
            handleReconnect()

        case .error(let err):
            print("[MultiplayerGameCoordinator] Transport error: \(err.localizedDescription)")

        case .playerDiscovered, .playerLost, .inviteReceived, .connected:
            break
        }
    }

    private func handleMessage(_ message: MultiplayerMessage) {
        guard !sessionState.isTerminal else { return }
        print("[MultiplayerGameCoordinator] handleMessage: \(message)")

        switch message {
        case .playerReady:
            readyTimeoutTask?.cancel()
            if case .showingResult = sessionState {
                hasPendingOpponentReady = true
                print("[MultiplayerGameCoordinator] Buffered opponentReady (still showing result)")
            } else {
                opponentReady = true
                print("[MultiplayerGameCoordinator] opponentReady = true")
            }

        case .answerSubmitted(let answer):
            opponentAnswer = answer

        case .questionResult(let result):
            questionResultTimeoutTask?.cancel()
            questionResult = result

        case .gameEnd(let result):
            gameEndTimeoutTask?.cancel()
            transition(to: .gameOver(result))
            gameEndResult = result

        case .pause:
            if !sessionState.isTerminal && sessionState != .opponentPaused && sessionState != .reconnecting {
                stateBeforeInterruption = sessionState
            }
            transition(to: .opponentPaused)
            startPauseTimeout()

        case .resume:
            pauseTimeoutTask?.cancel()
            if let previous = stateBeforeInterruption {
                transition(to: previous)
                stateBeforeInterruption = nil
            } else {
                transition(to: .playing)
            }

        case .gameConfig(let config):
            print("[MultiplayerGameCoordinator] Received gameConfig with \(config.questions.count) questions")
            gameConfigTimeoutTask?.cancel()
            gameConfigTimeoutTask = nil
            receivedGameConfig = config

        case .heartbeat, .playerInfo:
            break
        }
    }

    // MARK: - Disconnect / Reconnect

    private func handleDisconnect(isHardDisconnect: Bool) {
        guard !sessionState.isTerminal else { return }

        if sessionState != .reconnecting && sessionState != .opponentPaused {
            stateBeforeInterruption = sessionState
        }
        transition(to: .reconnecting)

        let gracePeriod = isHardDisconnect
            ? Self.hardDisconnectGracePeriod
            : Self.softDisconnectGracePeriod

        reconnectionTask?.cancel()
        reconnectionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(gracePeriod))
            guard !Task.isCancelled else { return }
            self?.handleReconnectionTimeout()
        }
    }

    private func handleReconnect() {
        reconnectionTask?.cancel()
        reconnectionTask = nil

        if let previous = stateBeforeInterruption {
            transition(to: previous)
            stateBeforeInterruption = nil
        } else {
            transition(to: .playing)
        }
    }

    private func handleReconnectionTimeout() {
        guard !sessionState.isTerminal else { return }

        analytics?.logMultiplayerDisconnect(
            questionsCompleted: questionsCompleted,
            reason: "opponentLeft",
            transportType: "nearby"
        )

        let endPayload = GameEndPayload(
            hostFinalScore: lastHostScore,
            guestFinalScore: lastGuestScore,
            reason: .opponentLeft
        )
        transition(to: .disconnected(endPayload))
        gameEndResult = endPayload
    }

    // MARK: - Pause Timeout

    private func startPauseTimeout() {
        pauseTimeoutTask?.cancel()
        pauseTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pauseTimeout))
            guard !Task.isCancelled else { return }
            self?.stateBeforeInterruption = nil
            self?.handleDisconnect(isHardDisconnect: false)
        }
    }

    // MARK: - Ready Timeout

    private func startReadyTimeout() {
        readyTimeoutTask?.cancel()
        readyTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.readyTimeout))
            guard !Task.isCancelled, let self, !self.opponentReady else { return }

            if self.readyRetryCount < Self.maxReadyRetries {
                self.readyRetryCount += 1
                try? self.transport?.send(message: .playerReady)
                self.startReadyTimeout()
            } else {
                let endPayload = GameEndPayload(
                    hostFinalScore: self.lastHostScore,
                    guestFinalScore: self.lastGuestScore,
                    reason: .disconnected
                )
                self.transition(to: .disconnected(endPayload))
                self.gameEndResult = endPayload
            }
        }
    }

    // MARK: - Question Result Timeout (Guest only)

    private func startQuestionResultTimeout() {
        questionResultTimeoutTask?.cancel()
        questionResultTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.questionResultTimeout))
            guard !Task.isCancelled, let self, self.questionResult == nil else { return }

            if self.questionResultRetryCount < Self.maxQuestionResultRetries {
                self.questionResultRetryCount += 1
                if let answer = self.lastSentAnswer {
                    try? self.transport?.send(message: .answerSubmitted(answer))
                }
                self.startQuestionResultTimeout()
            } else {
                self.handleDisconnect(isHardDisconnect: true)
            }
        }
    }

    // MARK: - Game Config Timeout (Guest only)

    private func startGameConfigTimeout() {
        gameConfigTimeoutTask?.cancel()
        gameConfigTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.gameConfigTimeout))
            guard !Task.isCancelled, let self, self.receivedGameConfig == nil else { return }
            print("[MultiplayerGameCoordinator] gameConfig timeout — ending game")
            let endPayload = GameEndPayload(
                hostFinalScore: 0,
                guestFinalScore: 0,
                reason: .disconnected
            )
            self.transition(to: .disconnected(endPayload))
            self.gameEndResult = endPayload
        }
    }

    // MARK: - Helpers

    private func cancelAllTimeoutTasks() {
        reconnectionTask?.cancel()
        reconnectionTask = nil
        pauseTimeoutTask?.cancel()
        pauseTimeoutTask = nil
        readyTimeoutTask?.cancel()
        readyTimeoutTask = nil
        questionResultTimeoutTask?.cancel()
        questionResultTimeoutTask = nil
        gameConfigTimeoutTask?.cancel()
        gameConfigTimeoutTask = nil
        gameEndTimeoutTask?.cancel()
        gameEndTimeoutTask = nil
    }

    private func resetState() {
        sessionState = .waitingForConfig
        opponentAnswer = nil
        questionResult = nil
        gameEndResult = nil
        opponentReady = false
        hasPendingOpponentReady = false
        receivedGameConfig = nil
        readyRetryCount = 0
        questionResultRetryCount = 0
        lastSentAnswer = nil
        questionsCompleted = 0
        lastHostScore = 0
        lastGuestScore = 0
        stateBeforeInterruption = nil
    }
}
