import Foundation
import QuizEngineCore

@MainActor
public final class MultiplayerGameCoordinator: ObservableObject, MultiplayerGameCoordinating {
    private static let hardDisconnectGracePeriod: TimeInterval = 3
    private static let softDisconnectGracePeriod: TimeInterval = 10
    private static let pauseTimeout: TimeInterval = 60
    private static let readyTimeout: TimeInterval = 10
    private static let questionResultTimeout: TimeInterval = 5
    private static let gameConfigTimeout: TimeInterval = 10
    private static let gameEndTimeout: TimeInterval = 5
    private static let maximumReplayCache = 128

    @Published public private(set) var opponent: MultiplayerPlayer?
    @Published public private(set) var role: MultiplayerRole?
    @Published public private(set) var sessionState: MultiplayerSessionState = .waitingForConfig
    @Published public private(set) var opponentAnswer: AnswerPayload?
    @Published public private(set) var questionResult: QuestionResultPayload?
    @Published public private(set) var gameEndResult: GameEndPayload?
    @Published public private(set) var opponentReady = false
    @Published public private(set) var receivedGameConfig: GameConfigPayload?
    @Published public private(set) var handshakeStatus: MultiplayerHandshakeStatus = .idle
    @Published public private(set) var terminalFailure: MultiplayerSessionFailure?
    @Published public private(set) var handshakeAccepted = false
    @Published public private(set) var matchID: UUID?

    public var questionsCompleted = 0
    public var lastHostScore = 0
    public var lastGuestScore = 0
    public private(set) var transport: (any MultiplayerTransport)?
    public var isHardenedMatch: Bool { matchConfiguration != nil }
    public var matchConfigurationAnalyticsLabel: String? { matchConfiguration?.analyticsTransportLabel }

    private let analytics: (any AnalyticsProvider)?
    private let scheduler: any QuizEngineScheduler
    private var eventListenerTask: Task<Void, Never>?
    private var rawListenerTask: Task<Void, Never>?
    private var reconnectionTask: (any QuizEngineScheduledTask)?
    private var pauseTimeoutTask: (any QuizEngineScheduledTask)?
    private var readyTimeoutTask: (any QuizEngineScheduledTask)?
    private var questionResultTimeoutTask: (any QuizEngineScheduledTask)?
    private var gameConfigTimeoutTask: (any QuizEngineScheduledTask)?
    private var gameEndTimeoutTask: (any QuizEngineScheduledTask)?
    private var stateBeforeInterruption: MultiplayerSessionState?
    private var hasPendingOpponentReady = false
    private var lastSentAnswer: AnswerPayload?
    private var readyRetryCount = 0
    private var questionResultRetryCount = 0
    private var lifecycleGeneration: UInt = 0
    private var isGameActive = false
    private var matchConfiguration: MultiplayerMatchConfiguration?
    private var nextSequence: UInt64 = 0
    private var seenMessageIDs: [UUID] = []
    private var seenSequences: [UInt64] = []

    public init(
        analytics: (any AnalyticsProvider)? = nil,
        scheduler: any QuizEngineScheduler = MainQueueQuizEngineScheduler()
    ) {
        self.analytics = analytics
        self.scheduler = scheduler
    }

    /// Legacy bridge. It keeps existing transports compiling and behaving as
    /// before, but it intentionally does not claim QE-6 wire hardening.
    public func startGame(
        transport: any MultiplayerTransport,
        opponent: MultiplayerPlayer,
        role: MultiplayerRole,
        bufferedMessages: [MultiplayerMessage] = []
    ) {
        beginGame(transport: transport, opponent: opponent, role: role, configuration: nil)
        for message in bufferedMessages { handleLegacyMessage(message) }
        startLegacyListening()
        if role == .guest, receivedGameConfig == nil { startGameConfigTimeout() }
    }

    /// Starts the QE-6 hardened raw-payload path.
    public func startGame(
        transport: any MultiplayerTransport,
        opponent: MultiplayerPlayer,
        role: MultiplayerRole,
        matchConfiguration: MultiplayerMatchConfiguration
    ) {
        beginGame(transport: transport, opponent: opponent, role: role, configuration: matchConfiguration)
        guard transport.supportsRawPayloads else {
            fail(.unsupportedWireTransport)
            return
        }
        startLegacyListening()
        startRawListening()
        handshakeStatus = .negotiating
        if role == .host {
            matchID = UUID()
            sendHandshake(MultiplayerWirePayload.hello)
        }
        startGameConfigTimeout()
    }

    public func endGame() {
        lifecycleGeneration &+= 1
        isGameActive = false
        cancelAllTimeoutTasks()
        eventListenerTask?.cancel()
        rawListenerTask?.cancel()
        eventListenerTask = nil
        rawListenerTask = nil
        transport?.disconnect()
        transport = nil
    }

    public func transitionToLoadingRound() {
        transition(to: .loadingRound)
        if hasPendingOpponentReady {
            hasPendingOpponentReady = false
            opponentReady = true
        }
    }
    public func transitionToPlaying() { transition(to: .playing) }
    public func transitionToWaitingForOpponent() { transition(to: .waitingForOpponent) }
    public func transitionToWaitingForResult() { transition(to: .waitingForResult) }
    public func transitionToShowingResult() { transition(to: .showingResult) }

    public func sendPlayerReady() {
        guard canSend else { return }
        if isHardenedMatch {
            sendWire(.playerReady(roundIndex: questionsCompleted))
        } else {
            try? transport?.send(message: .playerReady)
        }
        startReadyTimeout()
    }

    public func sendGameConfig(_ config: GameConfigPayload) {
        guard canSend else { return }
        if isHardenedMatch { sendWire(.gameConfig(.init(config))) }
        else { try? transport?.send(message: .gameConfig(config)) }
    }

    public func sendAnswer(_ answer: AnswerPayload) {
        guard canSend else { return }
        lastSentAnswer = answer
        if isHardenedMatch { sendWire(.answerSubmitted(answer)) }
        else { try? transport?.send(message: .answerSubmitted(answer)) }
        if role == .guest { startQuestionResultTimeout() }
    }

    public func sendQuestionResult(_ result: QuestionResultPayload) {
        guard canSend else { return }
        if isHardenedMatch { sendWire(.questionResult(result)) }
        else { try? transport?.send(message: .questionResult(result)) }
    }

    public func sendGameEnd(_ result: GameEndPayload) {
        guard canSend else { return }
        if isHardenedMatch { sendWire(.gameEnd(result)) }
        else { try? transport?.send(message: .gameEnd(result)) }
        finish(result)
    }

    public func prepareForNextRound() {
        opponentAnswer = nil
        questionResult = nil
        opponentReady = false
        lastSentAnswer = nil
        readyRetryCount = 0
        questionResultRetryCount = 0
        readyTimeoutTask?.cancel()
        questionResultTimeoutTask?.cancel()
        gameEndTimeoutTask?.cancel()
    }

    public func sendPause() {
        guard canSend else { return }
        if isHardenedMatch { sendWire(.pause) } else { try? transport?.send(message: .pause) }
    }

    public func sendResume() {
        guard canSend else { return }
        if isHardenedMatch { sendWire(.resume) } else { try? transport?.send(message: .resume) }
    }

    public func startGameEndTimeout() {
        gameEndTimeoutTask?.cancel()
        let generation = lifecycleGeneration
        gameEndTimeoutTask = scheduler.schedule(after: Self.gameEndTimeout) { [weak self] in
            guard let self, self.lifecycleGeneration == generation, self.gameEndResult == nil else { return }
            self.finish(GameEndPayload(hostFinalScore: self.lastHostScore, guestFinalScore: self.lastGuestScore, reason: .completed))
        }
    }

    private var canSend: Bool {
        isGameActive && !sessionState.isTerminal && (!isHardenedMatch || handshakeAccepted)
    }

    private func beginGame(
        transport: any MultiplayerTransport,
        opponent: MultiplayerPlayer,
        role: MultiplayerRole,
        configuration: MultiplayerMatchConfiguration?
    ) {
        endGame()
        lifecycleGeneration &+= 1
        self.transport = transport
        self.opponent = opponent
        self.role = role
        matchConfiguration = configuration
        isGameActive = true
        sessionState = .waitingForConfig
        opponentAnswer = nil
        questionResult = nil
        gameEndResult = nil
        opponentReady = false
        receivedGameConfig = nil
        terminalFailure = nil
        handshakeStatus = configuration == nil ? .idle : .negotiating
        handshakeAccepted = false
        matchID = nil
        stateBeforeInterruption = nil
        hasPendingOpponentReady = false
        lastSentAnswer = nil
        readyRetryCount = 0
        questionResultRetryCount = 0
        questionsCompleted = 0
        lastHostScore = 0
        lastGuestScore = 0
        nextSequence = 0
        seenMessageIDs = []
        seenSequences = []
    }

    private func transition(to newState: MultiplayerSessionState) {
        guard !sessionState.isTerminal else { return }
        sessionState = newState
        if newState.isTerminal {
            lifecycleGeneration &+= 1
            isGameActive = false
            cancelAllTimeoutTasks()
        }
    }

    private func finish(_ payload: GameEndPayload) {
        guard !sessionState.isTerminal else { return }
        gameEndResult = payload
        transition(to: .gameOver(payload))
    }

    private func fail(_ failure: MultiplayerSessionFailure) {
        guard !sessionState.isTerminal else { return }
        terminalFailure = failure
        handshakeStatus = .rejected(failure)
        let payload = GameEndPayload(hostFinalScore: lastHostScore, guestFinalScore: lastGuestScore, reason: .disconnected)
        gameEndResult = payload
        transition(to: .disconnected(payload))
        transport?.disconnect()
    }

    private func disconnect(_ payload: GameEndPayload) {
        guard !sessionState.isTerminal else { return }
        gameEndResult = payload
        transition(to: .disconnected(payload))
    }

    private func startLegacyListening() {
        guard let transport else { return }
        eventListenerTask = Task { [weak self] in
            for await event in transport.eventStream {
                guard !Task.isCancelled else { return }
                self?.handleTransportEvent(event)
            }
        }
    }

    private func startRawListening() {
        guard let transport else { return }
        rawListenerTask = Task { [weak self] in
            for await event in transport.rawPayloadEventStream {
                guard !Task.isCancelled else { return }
                self?.handleRawPayload(event)
            }
        }
    }

    private func handleTransportEvent(_ event: MultiplayerTransportEvent) {
        guard isGameActive else { return }
        switch event {
        case .messageReceived(let message, let sender):
            guard !isHardenedMatch else { return }
            guard sender.id == opponent?.id else { return }
            handleLegacyMessage(message)
        case .disconnected:
            handleDisconnect(hard: true)
        case .reconnecting:
            handleDisconnect(hard: false)
        case .reconnected:
            handleReconnect()
        case .error, .playerDiscovered, .playerLost, .inviteReceived, .connected:
            break
        }
    }

    private func handleRawPayload(_ event: MultiplayerRawPayloadEvent) {
        guard isGameActive, isHardenedMatch else { return }
        guard event.sender.id == opponent?.id else { return }
        let envelope: MultiplayerWireEnvelope
        do { envelope = try MultiplayerWireCodec.decode(event.data) }
        catch { fail(.malformedPayload); return }
        handleEnvelope(envelope)
    }

    private func handleEnvelope(_ envelope: MultiplayerWireEnvelope) {
        guard let configuration = matchConfiguration else { return }
        switch envelope.payload {
        case .hello(let handshake):
            guard role == .guest else { return }
            if handshakeAccepted, envelope.matchID == matchID {
                guard validate(handshake, configuration: configuration) else { return }
                sendHandshake(MultiplayerWirePayload.acknowledged)
                return
            }
            guard matchID == nil else { return }
            guard validate(handshake, configuration: configuration) else { return }
            matchID = envelope.matchID
            handshakeAccepted = true
            handshakeStatus = .accepted
            gameConfigTimeoutTask?.cancel()
            sendHandshake(MultiplayerWirePayload.acknowledged)
            startGameConfigTimeout()
            return
        case .acknowledged(let handshake):
            guard role == .host, envelope.matchID == matchID else { return }
            guard validate(handshake, configuration: configuration) else { return }
            guard !handshakeAccepted else { return }
            handshakeAccepted = true
            handshakeStatus = .accepted
            gameConfigTimeoutTask?.cancel()
            return
        default:
            break
        }

        guard handshakeAccepted else { fail(.unexpectedMessage); return }
        guard envelope.matchID == matchID else { return }
        guard !seenMessageIDs.contains(envelope.messageID) else { return }
        guard !seenSequences.contains(envelope.sequence) else { return }
        seenMessageIDs.append(envelope.messageID)
        if seenMessageIDs.count > Self.maximumReplayCache { seenMessageIDs.removeFirst() }
        seenSequences.append(envelope.sequence)
        if seenSequences.count > Self.maximumReplayCache { seenSequences.removeFirst() }
        handleSecurePayload(envelope.payload)
    }

    private func validate(_ handshake: MultiplayerHandshakePayload, configuration: MultiplayerMatchConfiguration) -> Bool {
        guard handshake.protocolVersion == configuration.protocolVersion else { fail(.protocolMismatch); return false }
        guard handshake.contentVersion == configuration.contentVersion else { fail(.contentMismatch); return false }
        guard handshake.capabilities.isSuperset(of: configuration.requiredCapabilities) else { fail(.capabilityMismatch); return false }
        return true
    }

    private func sendHandshake(_ kind: (MultiplayerHandshakePayload) -> MultiplayerWirePayload) {
        guard let configuration = matchConfiguration, let matchID else { return }
        sendEnvelope(matchID: matchID, payload: kind(.init(
            protocolVersion: configuration.protocolVersion,
            contentVersion: configuration.contentVersion,
            capabilities: configuration.requiredCapabilities
        )))
    }

    private func sendWire(_ payload: MultiplayerWirePayload) {
        guard let matchID else { return }
        sendEnvelope(matchID: matchID, payload: payload)
    }

    private func sendEnvelope(matchID: UUID, payload: MultiplayerWirePayload) {
        let envelope = MultiplayerWireEnvelope(matchID: matchID, sequence: nextSequence, payload: payload)
        nextSequence &+= 1
        guard let data = try? MultiplayerWireCodec.encode(envelope) else { fail(.malformedPayload); return }
        do { try transport?.sendRawPayload(data) }
        catch { fail(.unexpectedMessage) }
    }

    private func handleSecurePayload(_ payload: MultiplayerWirePayload) {
        switch payload {
        case .gameConfig(let wireConfig):
            guard role == .guest else { return }
            guard receivedGameConfig == nil else { return }
            let config = wireConfig.makeGameConfig()
            guard valid(config) else { fail(.malformedPayload); return }
            receivedGameConfig = config
            gameConfigTimeoutTask?.cancel()
        case .playerReady(let roundIndex):
            guard roundIndex == questionsCompleted else { return }
            receiveReady()
        case .answerSubmitted(let answer):
            guard valid(answer), answer.questionIndex == questionsCompleted, opponentAnswer == nil else { return }
            opponentAnswer = answer
        case .questionResult(let result):
            guard role == .guest, valid(result), result.questionIndex == questionsCompleted, questionResult == nil else { return }
            questionResult = result
            questionResultTimeoutTask?.cancel()
        case .gameEnd(let result):
            guard role == .guest else { return }
            guard result.reason != .completed || questionsCompleted > 0 else { return }
            if questionsCompleted > 0,
               (result.hostFinalScore != lastHostScore || result.guestFinalScore != lastGuestScore) {
                return
            }
            finish(result)
        case .pause:
            receivePause()
        case .resume:
            receiveResume()
        case .hello, .acknowledged:
            fail(.unexpectedMessage)
        }
    }

    private func valid(_ config: GameConfigPayload) -> Bool {
        guard !config.questions.isEmpty, config.questions.count <= 100,
              Set(config.questions.map(\.id)).count == config.questions.count else { return false }
        return config.questions.allSatisfy { question in
            question.id > 0 && !question.question.isEmpty && question.question.utf8.count <= 4_096 &&
            question.answers.count >= 2 && question.answers.count <= 16 &&
            question.answers.filter(\.correct).count == 1 &&
            question.answers.allSatisfy { !$0.text.isEmpty && $0.text.utf8.count <= 4_096 } &&
            !question.categories.isEmpty && question.categories.count <= 8 &&
            question.categories.allSatisfy { !$0.isEmpty && $0.utf8.count <= 128 } &&
            (question.imageName?.utf8.count ?? 0) <= 256 &&
            (question.description?.utf8.count ?? 0) <= 8_192
        }
    }

    private func valid(_ answer: AnswerPayload) -> Bool {
        answer.answerIndex >= -2 && answer.answerIndex <= 15 && answer.responseTimeMs >= 0 && answer.responseTimeMs <= 3_600_000
    }

    private func valid(_ result: QuestionResultPayload) -> Bool {
        result.correctAnswerIndex >= 0 && result.correctAnswerIndex <= 15 &&
        result.hostResponseTimeMs >= 0 && result.hostResponseTimeMs <= 3_600_000 &&
        result.guestResponseTimeMs >= 0 && result.guestResponseTimeMs <= 3_600_000
    }

    private func handleLegacyMessage(_ message: MultiplayerMessage) {
        guard !sessionState.isTerminal else { return }
        switch message {
        case .playerReady: receiveReady()
        case .answerSubmitted(let answer): opponentAnswer = answer
        case .questionResult(let result): questionResult = result; questionResultTimeoutTask?.cancel()
        case .gameEnd(let result): finish(result)
        case .pause: receivePause()
        case .resume: receiveResume()
        case .gameConfig(let config): receivedGameConfig = config; gameConfigTimeoutTask?.cancel()
        case .heartbeat, .playerInfo: break
        }
    }

    private func receiveReady() {
        readyTimeoutTask?.cancel()
        if case .showingResult = sessionState { hasPendingOpponentReady = true }
        else { opponentReady = true }
    }

    private func receivePause() {
        if sessionState != .opponentPaused && sessionState != .reconnecting { stateBeforeInterruption = sessionState }
        transition(to: .opponentPaused)
        startPauseTimeout()
    }

    private func receiveResume() {
        pauseTimeoutTask?.cancel()
        let previous = stateBeforeInterruption ?? .playing
        stateBeforeInterruption = nil
        transition(to: previous)
    }

    private func handleDisconnect(hard: Bool) {
        guard !sessionState.isTerminal else { return }
        if sessionState != .reconnecting && sessionState != .opponentPaused { stateBeforeInterruption = sessionState }
        transition(to: .reconnecting)
        reconnectionTask?.cancel()
        let generation = lifecycleGeneration
        reconnectionTask = scheduler.schedule(after: hard ? Self.hardDisconnectGracePeriod : Self.softDisconnectGracePeriod) { [weak self] in
            guard let self, self.lifecycleGeneration == generation else { return }
            if let label = self.matchConfiguration?.analyticsTransportLabel {
                self.analytics?.logMultiplayerDisconnect(
                    questionsCompleted: self.questionsCompleted,
                    reason: "opponentLeft",
                    transportType: label
                )
            }
            self.finish(GameEndPayload(hostFinalScore: self.lastHostScore, guestFinalScore: self.lastGuestScore, reason: .opponentLeft))
        }
    }

    private func handleReconnect() {
        reconnectionTask?.cancel()
        let previous = stateBeforeInterruption ?? .playing
        stateBeforeInterruption = nil
        transition(to: previous)
    }

    private func startPauseTimeout() {
        pauseTimeoutTask?.cancel()
        let generation = lifecycleGeneration
        pauseTimeoutTask = scheduler.schedule(after: Self.pauseTimeout) { [weak self] in
            guard let self, self.lifecycleGeneration == generation else { return }
            self.handleDisconnect(hard: false)
        }
    }

    private func startReadyTimeout() {
        readyTimeoutTask?.cancel()
        let generation = lifecycleGeneration
        readyTimeoutTask = scheduler.schedule(after: Self.readyTimeout) { [weak self] in
            guard let self, self.lifecycleGeneration == generation, !self.opponentReady else { return }
            if self.readyRetryCount < 2 {
                self.readyRetryCount += 1
                self.sendPlayerReady()
            } else {
                self.disconnect(GameEndPayload(hostFinalScore: self.lastHostScore, guestFinalScore: self.lastGuestScore, reason: .disconnected))
            }
        }
    }

    private func startQuestionResultTimeout() {
        questionResultTimeoutTask?.cancel()
        let generation = lifecycleGeneration
        questionResultTimeoutTask = scheduler.schedule(after: Self.questionResultTimeout) { [weak self] in
            guard let self, self.lifecycleGeneration == generation, self.questionResult == nil else { return }
            if self.questionResultRetryCount < 2, let answer = self.lastSentAnswer {
                self.questionResultRetryCount += 1
                self.sendAnswer(answer)
            } else {
                self.handleDisconnect(hard: true)
            }
        }
    }

    private func startGameConfigTimeout() {
        gameConfigTimeoutTask?.cancel()
        let generation = lifecycleGeneration
        gameConfigTimeoutTask = scheduler.schedule(after: Self.gameConfigTimeout) { [weak self] in
            guard let self, self.lifecycleGeneration == generation, self.receivedGameConfig == nil else { return }
            self.disconnect(GameEndPayload(hostFinalScore: 0, guestFinalScore: 0, reason: .disconnected))
        }
    }

    private func cancelAllTimeoutTasks() {
        reconnectionTask?.cancel(); reconnectionTask = nil
        pauseTimeoutTask?.cancel(); pauseTimeoutTask = nil
        readyTimeoutTask?.cancel(); readyTimeoutTask = nil
        questionResultTimeoutTask?.cancel(); questionResultTimeoutTask = nil
        gameConfigTimeoutTask?.cancel(); gameConfigTimeoutTask = nil
        gameEndTimeoutTask?.cancel(); gameEndTimeoutTask = nil
    }
}
