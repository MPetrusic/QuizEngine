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
    private static let sequenceGapTimeout: TimeInterval = 5
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
    private var sequenceBuffer = MultiplayerSequenceBuffer()
    private var sequenceGapTimeoutTask: (any QuizEngineScheduledTask)?

    /// The questions the match is being played with, from the configuration this peer sent or
    /// accepted. Round payloads are validated against the question they claim to describe.
    private(set) var activeQuestions: [Question] = []

    /// Why the last game configuration was refused. Retained for diagnostics and tests; the
    /// terminal outcome itself is `MultiplayerSessionFailure.invalidConfiguration`.
    private(set) var lastConfigurationRejections: [MultiplayerConfigurationRejection] = []

    /// The question the session is currently playing, if the round index is still in range.
    private var activeQuestion: Question? {
        guard questionsCompleted >= 0, questionsCompleted < activeQuestions.count else { return nil }
        return activeQuestions[questionsCompleted]
    }

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
        sequenceBuffer.reset()
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

    /// Sends the host's game configuration.
    ///
    /// A hardened configuration is validated before transmission with exactly the rules the guest
    /// applies on receipt, so an unplayable match ends here instead of after the guest has already
    /// loaded it.
    public func sendGameConfig(_ config: GameConfigPayload) {
        guard canSend else { return }
        guard let configuration = matchConfiguration else {
            try? transport?.send(message: .gameConfig(config))
            return
        }
        guard acceptConfiguration(config, configuration: configuration) else { return }
        sendWire(.gameConfig(.init(config)))
    }

    /// Validates a configuration against the match content policy and adopts it on success.
    private func acceptConfiguration(
        _ config: GameConfigPayload,
        configuration: MultiplayerMatchConfiguration
    ) -> Bool {
        let rejections = MultiplayerPayloadValidator.rejections(for: config, configuration: configuration)
        guard rejections.isEmpty else {
            lastConfigurationRejections = rejections
            fail(.invalidConfiguration)
            return false
        }
        lastConfigurationRejections = []
        activeQuestions = config.questions
        return true
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
        sequenceBuffer.reset()
        activeQuestions = []
        lastConfigurationRejections = []
    }

    private func transition(to newState: MultiplayerSessionState) {
        guard !sessionState.isTerminal else { return }
        sessionState = newState
        if newState.isTerminal {
            lifecycleGeneration &+= 1
            isGameActive = false
            cancelAllTimeoutTasks()
            // Nothing buffered may survive into a later match.
            sequenceBuffer.reset()
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

    /// Ends the session because a phase deadline elapsed.
    ///
    /// The first terminal outcome wins, so a callback that survives cancellation cannot replace an
    /// outcome that has already been recorded.
    private func endWithTimeout(
        _ timeout: MultiplayerTimeout,
        hostScore: Int? = nil,
        guestScore: Int? = nil
    ) {
        guard !sessionState.isTerminal else { return }
        terminalFailure = .timedOut(timeout)
        disconnect(
            GameEndPayload(
                hostFinalScore: hostScore ?? lastHostScore,
                guestFinalScore: guestScore ?? lastGuestScore,
                reason: .disconnected
            )
        )
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

    /// Applies the ordering policy, then dispatches whatever became contiguous.
    ///
    /// See `MultiplayerSequenceBuffer` for the policy itself. Nothing reaches payload handling out
    /// of order, so no handler needs its own reordering tolerance.
    private func handleEnvelope(_ envelope: MultiplayerWireEnvelope) {
        guard matchConfiguration != nil else { return }
        guard !seenMessageIDs.contains(envelope.messageID) else { return }

        switch sequenceBuffer.admit(envelope) {
        case .duplicate:
            return
        case .gapTooLarge:
            fail(.sequenceGap)
            return
        case .bufferOverflow:
            fail(.sequenceBufferOverflow)
            return
        case .buffered:
            startSequenceGapTimeout()
            return
        case .ready:
            break
        }

        var next: MultiplayerWireEnvelope? = envelope
        while let current = next, !sessionState.isTerminal {
            sequenceBuffer.commit(current)
            rememberMessageID(current.messageID)
            dispatch(current)
            next = sequenceBuffer.takeNextContiguous()
        }

        if sequenceBuffer.hasBufferedMessages, !sessionState.isTerminal {
            startSequenceGapTimeout()
        } else {
            sequenceGapTimeoutTask?.cancel()
            sequenceGapTimeoutTask = nil
        }
    }

    private func rememberMessageID(_ messageID: UUID) {
        seenMessageIDs.append(messageID)
        if seenMessageIDs.count > Self.maximumReplayCache { seenMessageIDs.removeFirst() }
    }

    private func dispatch(_ envelope: MultiplayerWireEnvelope) {
        guard let configuration = matchConfiguration else { return }
        switch envelope.payload {
        case .hello(let handshake):
            handleHello(handshake, envelope: envelope, configuration: configuration)
        case .acknowledged(let handshake):
            handleAcknowledged(handshake, envelope: envelope, configuration: configuration)
        default:
            guard envelope.matchID == matchID else { return }
            guard handshakeAccepted else { fail(.unexpectedMessage); return }
            handleSecurePayload(envelope.payload, configuration: configuration)
        }
    }

    private func handleHello(
        _ handshake: MultiplayerHandshakePayload,
        envelope: MultiplayerWireEnvelope,
        configuration: MultiplayerMatchConfiguration
    ) {
        // Only a host opens a match, so a host receiving one is a protocol violation.
        guard role == .guest else { fail(.unexpectedMessage); return }
        guard validate(handshake, configuration: configuration) else { return }

        guard matchID == nil else {
            // The host may repeat its opening message; re-acknowledge the established match only.
            guard envelope.matchID == matchID else { return }
            sendHandshake(MultiplayerWirePayload.acknowledged)
            return
        }

        matchID = envelope.matchID
        handshakeAccepted = true
        handshakeStatus = .accepted
        gameConfigTimeoutTask?.cancel()
        sendHandshake(MultiplayerWirePayload.acknowledged)
        startGameConfigTimeout()
    }

    private func handleAcknowledged(
        _ handshake: MultiplayerHandshakePayload,
        envelope: MultiplayerWireEnvelope,
        configuration: MultiplayerMatchConfiguration
    ) {
        // Only a guest acknowledges, so a guest receiving one is a protocol violation.
        guard role == .host else { fail(.unexpectedMessage); return }
        guard envelope.matchID == matchID else { return }
        guard validate(handshake, configuration: configuration) else { return }
        guard !handshakeAccepted else { return }
        handshakeAccepted = true
        handshakeStatus = .accepted
        gameConfigTimeoutTask?.cancel()
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
        catch { fail(.transportFailure) }
    }

    /// Handles a payload that arrived in order, from the expected sender, for the established match.
    ///
    /// Three outcomes are possible and each is deterministic:
    ///
    /// - the payload is applied;
    /// - the payload is a stale or duplicate restatement of a round already settled, and is
    ///   ignored;
    /// - the payload could not be produced by a peer following the protocol under this match's
    ///   content and scoring rules, and the session ends with a typed failure.
    private func handleSecurePayload(
        _ payload: MultiplayerWirePayload,
        configuration: MultiplayerMatchConfiguration
    ) {
        switch payload {
        case .gameConfig(let wireConfig):
            // Only a host configures a match.
            guard role == .guest else { fail(.unexpectedMessage); return }
            // The host retries delivery, so repeating an accepted configuration is harmless.
            guard receivedGameConfig == nil else { return }
            let config = wireConfig.makeGameConfig()
            guard acceptConfiguration(config, configuration: configuration) else { return }
            receivedGameConfig = config
            gameConfigTimeoutTask?.cancel()

        case .playerReady(let roundIndex):
            guard hasActiveContent() else { return }
            guard roundIndex == questionsCompleted else { return }
            receiveReady()

        case .answerSubmitted(let answer):
            guard hasActiveContent() else { return }
            guard answer.questionIndex == questionsCompleted else { return }
            guard let question = activeQuestion else { fail(.unexpectedPhase); return }
            guard MultiplayerPayloadValidator.isValidAnswer(
                answer,
                activeRoundIndex: questionsCompleted,
                question: question,
                rules: configuration.multiplayerRules
            ) else { fail(.invalidRoundPayload); return }
            guard opponentAnswer == nil else { return }
            opponentAnswer = answer

        case .questionResult(let result):
            // Only a host scores a round.
            guard role == .guest else { fail(.unexpectedMessage); return }
            guard hasActiveContent() else { return }
            guard result.questionIndex == questionsCompleted else { return }
            guard let question = activeQuestion else { fail(.unexpectedPhase); return }
            guard MultiplayerPayloadValidator.isValidQuestionResult(
                result,
                activeRoundIndex: questionsCompleted,
                question: question,
                previousHostScore: lastHostScore,
                previousGuestScore: lastGuestScore,
                rules: configuration.multiplayerRules
            ) else { fail(.invalidRoundPayload); return }
            guard questionResult == nil else { return }
            questionResult = result
            questionResultTimeoutTask?.cancel()

        case .gameEnd(let result):
            // Only a host ends a match.
            guard role == .guest else { fail(.unexpectedMessage); return }
            guard MultiplayerPayloadValidator.isValidGameEnd(
                result,
                questionsCompleted: questionsCompleted,
                hostScore: lastHostScore,
                guestScore: lastGuestScore
            ) else { return }
            finish(result)

        case .pause:
            receivePause()

        case .resume:
            receiveResume()

        case .hello, .acknowledged:
            // Handshake payloads are dispatched before this point; reaching here is a violation.
            fail(.unexpectedMessage)
        }
    }

    /// Whether a configuration has been adopted. A round payload before one is legal in a later
    /// phase but not in this one, so it ends the session rather than being silently dropped.
    private func hasActiveContent() -> Bool {
        guard activeQuestions.isEmpty else { return true }
        fail(.unexpectedPhase)
        return false
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

    /// Resumes only a session this peer actually paused.
    ///
    /// Ordering guarantees a resume cannot overtake its pause, so a resume without one is a
    /// redundant restatement — a peer foregrounding after a suppressed background, for example —
    /// and is ignored rather than moving the session into a phase it never left.
    private func receiveResume() {
        guard sessionState == .opponentPaused else { return }
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
                self.endWithTimeout(.ready)
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
            self.endWithTimeout(.gameConfiguration, hostScore: 0, guestScore: 0)
        }
    }

    /// Ends the session when a missing sequence never arrives.
    ///
    /// Without this, a peer that drops one message could hold the session open indefinitely with
    /// messages it can never deliver in order.
    private func startSequenceGapTimeout() {
        guard sequenceGapTimeoutTask == nil else { return }
        let generation = lifecycleGeneration
        sequenceGapTimeoutTask = scheduler.schedule(after: Self.sequenceGapTimeout) { [weak self] in
            guard let self, self.lifecycleGeneration == generation else { return }
            self.sequenceGapTimeoutTask = nil
            guard self.sequenceBuffer.hasBufferedMessages else { return }
            self.endWithTimeout(.sequenceGap)
        }
    }

    private func cancelAllTimeoutTasks() {
        reconnectionTask?.cancel(); reconnectionTask = nil
        pauseTimeoutTask?.cancel(); pauseTimeoutTask = nil
        readyTimeoutTask?.cancel(); readyTimeoutTask = nil
        questionResultTimeoutTask?.cancel(); questionResultTimeoutTask = nil
        gameConfigTimeoutTask?.cancel(); gameConfigTimeoutTask = nil
        gameEndTimeoutTask?.cancel(); gameEndTimeoutTask = nil
        sequenceGapTimeoutTask?.cancel(); sequenceGapTimeoutTask = nil
    }
}
