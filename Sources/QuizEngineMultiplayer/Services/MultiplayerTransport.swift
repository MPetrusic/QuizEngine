//
//  MultiplayerTransport.swift
//  QuizEngineMultiplayer
//

import Foundation
import QuizEngineCore

// MARK: - Technology Limitations
//
// 1. The host transport has no host migration. If the host disconnects, the game must end.
//    There is no way to promote a guest to host mid-session.
//
// 2. A transport may not guarantee message ordering even in reliable mode.
//    Messages sent sequentially may arrive out of order.
//
// 3. Neither transport supports true reconnection to the same session.
//    "Reconnecting" means hoping the existing connection recovers within the grace period.
//    If it doesn't, the game ends.
//
// 4. Transport payloads can be bounded. Question payloads should be monitored if
//    the question set grows.
//
// 5. A transport may not support background execution. When both players background,
//    the connection can be lost within the heartbeat timeout window.
//

// MARK: - Player & Role

public struct MultiplayerPlayer: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public enum MultiplayerRole: Codable, Sendable {
    case host
    case guest
}

// MARK: - Hardened wire protocol

/// Features a peer must understand before a QE-6 match can start.
public enum MultiplayerCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case sequencedEnvelopeV1
    case validatedPayloadV1
    case idempotentTerminalReceiptV1
}

public enum MultiplayerMatchConfigurationError: Error, Equatable, Sendable {
    case invalidProtocolVersion
    case invalidContentVersion
    case invalidAnalyticsTransportLabel
    case missingRequiredCapabilities
}

/// App-owned match identity and compatibility policy. Content versions must
/// match exactly; the package does not infer them from an app bundle.
public struct MultiplayerMatchConfiguration: Equatable, Sendable {
    public static let protocolVersion = 1
    public static let requiredQE6Capabilities: Set<MultiplayerCapability> = [
        .sequencedEnvelopeV1,
        .validatedPayloadV1,
        .idempotentTerminalReceiptV1
    ]

    public let protocolVersion: Int
    public let contentVersion: String
    public let requiredCapabilities: Set<MultiplayerCapability>
    public let analyticsTransportLabel: String

    public init(
        protocolVersion: Int = MultiplayerMatchConfiguration.protocolVersion,
        contentVersion: String,
        requiredCapabilities: Set<MultiplayerCapability> = MultiplayerMatchConfiguration.requiredQE6Capabilities,
        analyticsTransportLabel: String
    ) throws {
        guard protocolVersion > 0 else { throw MultiplayerMatchConfigurationError.invalidProtocolVersion }
        guard !contentVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              contentVersion.utf8.count <= 128 else {
            throw MultiplayerMatchConfigurationError.invalidContentVersion
        }
        guard !analyticsTransportLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              analyticsTransportLabel.utf8.count <= 64 else {
            throw MultiplayerMatchConfigurationError.invalidAnalyticsTransportLabel
        }
        guard requiredCapabilities.isSuperset(of: MultiplayerMatchConfiguration.requiredQE6Capabilities) else {
            throw MultiplayerMatchConfigurationError.missingRequiredCapabilities
        }
        self.protocolVersion = protocolVersion
        self.contentVersion = contentVersion
        self.requiredCapabilities = requiredCapabilities
        self.analyticsTransportLabel = analyticsTransportLabel
    }
}

public enum MultiplayerHandshakeStatus: Equatable, Sendable {
    case idle
    case negotiating
    case accepted
    case rejected(MultiplayerSessionFailure)
}

public enum MultiplayerSessionFailure: Equatable, Sendable {
    case unsupportedWireTransport
    case protocolMismatch
    case contentMismatch
    case capabilityMismatch
    case malformedPayload
    case unexpectedMessage
    case wrongSender
}

public struct MultiplayerHandshakePayload: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let contentVersion: String
    public let capabilities: Set<MultiplayerCapability>

    public init(protocolVersion: Int, contentVersion: String, capabilities: Set<MultiplayerCapability>) {
        self.protocolVersion = protocolVersion
        self.contentVersion = contentVersion
        self.capabilities = capabilities
    }
}

/// Immutable question representation used only across the hardened wire.
public struct MultiplayerWireAnswer: Codable, Equatable, Sendable {
    public let text: String
    public let correct: Bool

    public init(text: String, correct: Bool) {
        self.text = text
        self.correct = correct
    }
}

public struct MultiplayerWireQuestion: Codable, Equatable, Sendable {
    public let id: Int
    public let question: String
    public let answers: [MultiplayerWireAnswer]
    public let imageName: String?
    public let description: String?
    public let categories: [String]
    public let difficulty: Int

    public init(_ question: Question) {
        id = question.id
        self.question = question.question
        answers = question.answers.map { .init(text: $0.text, correct: $0.correct) }
        imageName = question.imageName
        description = question.description
        categories = question.categories
        difficulty = question.difficulty
    }

    public func makeQuestion() -> Question {
        Question(id: id, question: question, answers: answers.map { .init(text: $0.text, correct: $0.correct) }, imageName: imageName, description: description, categories: categories, difficulty: difficulty)
    }
}

public struct MultiplayerWireGameConfigPayload: Codable, Equatable, Sendable {
    public let questions: [MultiplayerWireQuestion]
    public let seed: UInt64

    public init(_ configuration: GameConfigPayload) {
        questions = configuration.questions.map(MultiplayerWireQuestion.init)
        seed = configuration.seed
    }

    public func makeGameConfig() -> GameConfigPayload {
        GameConfigPayload(questions: questions.map { $0.makeQuestion() }, seed: seed)
    }
}

public enum MultiplayerWirePayload: Codable, Equatable, Sendable {
    case hello(MultiplayerHandshakePayload)
    case acknowledged(MultiplayerHandshakePayload)
    case gameConfig(MultiplayerWireGameConfigPayload)
    case playerReady(roundIndex: Int)
    case answerSubmitted(AnswerPayload)
    case questionResult(QuestionResultPayload)
    case gameEnd(GameEndPayload)
    case pause
    case resume
}

public struct MultiplayerWireEnvelope: Codable, Equatable, Sendable {
    public let matchID: UUID
    public let sequence: UInt64
    public let messageID: UUID
    public let payload: MultiplayerWirePayload

    public init(matchID: UUID, sequence: UInt64, messageID: UUID = UUID(), payload: MultiplayerWirePayload) {
        self.matchID = matchID
        self.sequence = sequence
        self.messageID = messageID
        self.payload = payload
    }
}

public enum MultiplayerWireCodecError: Error, Equatable, Sendable {
    case payloadTooLarge
    case encodingFailed
    case decodingFailed
}

/// The only codec used by the hardened raw-payload path.
public enum MultiplayerWireCodec {
    public static let maximumPayloadBytes = 256 * 1024

    public static func encode(_ envelope: MultiplayerWireEnvelope) throws -> Data {
        do { return try JSONEncoder().encode(envelope) }
        catch { throw MultiplayerWireCodecError.encodingFailed }
    }

    public static func decode(_ data: Data) throws -> MultiplayerWireEnvelope {
        guard !data.isEmpty, data.count <= maximumPayloadBytes else { throw MultiplayerWireCodecError.payloadTooLarge }
        do { return try JSONDecoder().decode(MultiplayerWireEnvelope.self, from: data) }
        catch { throw MultiplayerWireCodecError.decodingFailed }
    }
}

public struct MultiplayerRawPayloadEvent: Sendable {
    public let data: Data
    public let sender: MultiplayerPlayer

    public init(data: Data, sender: MultiplayerPlayer) {
        self.data = data
        self.sender = sender
    }
}

// MARK: - Messages

public enum MultiplayerMessage: Codable, Sendable {
    case playerInfo(PlayerInfoPayload)
    case gameConfig(GameConfigPayload)
    case playerReady
    case answerSubmitted(AnswerPayload)
    case questionResult(QuestionResultPayload)
    case gameEnd(GameEndPayload)
    case heartbeat
    case pause
    case resume
}

public struct PlayerInfoPayload: Codable, Sendable {
    public let playerID: String
    public let displayName: String

    public init(playerID: String, displayName: String) {
        self.playerID = playerID
        self.displayName = displayName
    }
}

public struct GameConfigPayload: Codable, Sendable {
    public let questions: [Question]
    public let seed: UInt64

    public init(questions: [Question], seed: UInt64) {
        self.questions = questions
        self.seed = seed
    }
}

extension GameConfigPayload: Equatable {}

public struct AnswerPayload: Codable, Sendable {
    public let questionIndex: Int
    public let answerIndex: Int
    public let responseTimeMs: Int

    public init(questionIndex: Int, answerIndex: Int, responseTimeMs: Int) {
        self.questionIndex = questionIndex
        self.answerIndex = answerIndex
        self.responseTimeMs = responseTimeMs
    }
}

extension AnswerPayload: Equatable {}

public struct QuestionResultPayload: Codable, Sendable {
    public let questionIndex: Int
    public let correctAnswerIndex: Int
    public let hostCorrect: Bool
    public let guestCorrect: Bool
    public let hostResponseTimeMs: Int
    public let guestResponseTimeMs: Int
    public let hostPointsAwarded: Int
    public let guestPointsAwarded: Int
    public let hostTotalScore: Int
    public let guestTotalScore: Int

    public init(questionIndex: Int, correctAnswerIndex: Int, hostCorrect: Bool, guestCorrect: Bool, hostResponseTimeMs: Int, guestResponseTimeMs: Int, hostPointsAwarded: Int, guestPointsAwarded: Int, hostTotalScore: Int, guestTotalScore: Int) {
        self.questionIndex = questionIndex
        self.correctAnswerIndex = correctAnswerIndex
        self.hostCorrect = hostCorrect
        self.guestCorrect = guestCorrect
        self.hostResponseTimeMs = hostResponseTimeMs
        self.guestResponseTimeMs = guestResponseTimeMs
        self.hostPointsAwarded = hostPointsAwarded
        self.guestPointsAwarded = guestPointsAwarded
        self.hostTotalScore = hostTotalScore
        self.guestTotalScore = guestTotalScore
    }
}

extension QuestionResultPayload: Equatable {}

public struct GameEndPayload: Codable, Sendable, Equatable {
    public let hostFinalScore: Int
    public let guestFinalScore: Int
    public let reason: GameEndReason

    public init(hostFinalScore: Int, guestFinalScore: Int, reason: GameEndReason) {
        self.hostFinalScore = hostFinalScore
        self.guestFinalScore = guestFinalScore
        self.reason = reason
    }
}

public enum GameEndReason: String, Codable, Sendable {
    case completed
    case opponentLeft
    case disconnected
}

// MARK: - Session State Machine

/// Mutually exclusive states for an active multiplayer game session.
/// Terminal states (.disconnected, .gameOver) cannot be exited once entered.
public enum MultiplayerSessionState: Equatable, Sendable {
    /// Guest is waiting for the host to send the game configuration (questions + seed).
    case waitingForConfig
    /// Preparing the next question; waiting for both players to signal ready.
    case loadingRound
    /// Timer is running and the player can submit an answer.
    case playing
    /// Local player has answered; waiting for the opponent's answer.
    case waitingForOpponent
    /// Both players have answered (guest path); waiting for the host's QuestionResultPayload.
    case waitingForResult
    /// Round result is being displayed (auto-advances after a delay).
    case showingResult
    /// Opponent's app went to background. Timer is paused.
    case opponentPaused
    /// Transport connection has degraded; attempting to recover.
    case reconnecting
    /// Terminal: connection was definitively lost.
    case disconnected(GameEndPayload)
    /// Terminal: game completed (normally or opponent left).
    case gameOver(GameEndPayload)

    /// Whether this is a terminal state that cannot be exited.
    public var isTerminal: Bool {
        switch self {
        case .disconnected, .gameOver: return true
        default: return false
        }
    }

    /// The blocking overlay to display, if any. Only one overlay shows at a time.
    /// Priority: gameEnded > reconnecting > opponentPaused.
    public var blockingOverlay: MultiplayerOverlayType? {
        switch self {
        case .disconnected, .gameOver: return .gameEnded
        case .reconnecting: return .reconnecting
        case .opponentPaused: return .opponentPaused
        default: return nil
        }
    }
}

/// The type of full-screen blocking overlay to display during a multiplayer match.
public enum MultiplayerOverlayType: Equatable, Sendable {
    /// Game has ended (disconnected or completed). Navigation will follow.
    case gameEnded
    /// Connection degraded — attempting to recover.
    case reconnecting
    /// Opponent's app went to background.
    case opponentPaused
}

// MARK: - Transport Events

public enum MultiplayerTransportEvent: Sendable {
    case playerDiscovered(MultiplayerPlayer)
    case playerLost(MultiplayerPlayer)
    case inviteReceived(from: MultiplayerPlayer)
    case connected(to: MultiplayerPlayer, role: MultiplayerRole)
    case disconnected(from: MultiplayerPlayer)
    case reconnecting(to: MultiplayerPlayer)
    case reconnected(to: MultiplayerPlayer)
    case messageReceived(MultiplayerMessage, from: MultiplayerPlayer)
    case error(Error)
}

// MARK: - Connection State

public enum TransportConnectionState: Sendable {
    case idle
    case searching
    case connecting
    case connected
    case reconnecting
    case disconnected
}

// MARK: - Transport Protocol

@MainActor
public protocol MultiplayerTransport: AnyObject {
    var localPlayer: MultiplayerPlayer { get }
    var connectionState: TransportConnectionState { get }
    var eventStream: AsyncStream<MultiplayerTransportEvent> { get }

    /// Hardened transports expose raw bytes to QuizEngine so it owns decoding
    /// and validation. Legacy transports receive a default empty stream and
    /// remain source-compatible, but cannot start a QE-6 match.
    var rawPayloadEventStream: AsyncStream<MultiplayerRawPayloadEvent> { get }
    var supportsRawPayloads: Bool { get }

    func startSearching()
    func stopSearching()
    func invite(player: MultiplayerPlayer)
    func acceptInvite(from player: MultiplayerPlayer)
    func declineInvite(from player: MultiplayerPlayer)
    func send(message: MultiplayerMessage) throws
    func sendRawPayload(_ data: Data) throws
    func disconnect()

    /// Resets the event stream, creating a fresh stream for new consumers.
    /// Call this when transferring ownership (e.g., from lobby to game coordinator).
    func resetEventStream()
}

public extension MultiplayerTransport {
    var rawPayloadEventStream: AsyncStream<MultiplayerRawPayloadEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    var supportsRawPayloads: Bool { false }

    func sendRawPayload(_ data: Data) throws {
        throw MultiplayerTransportError.notConnected
    }
}

// MARK: - Game Coordinator Protocol

@MainActor
public protocol MultiplayerGameCoordinating: ObservableObject {
    var opponent: MultiplayerPlayer? { get }
    var role: MultiplayerRole? { get }
    var sessionState: MultiplayerSessionState { get }
    var opponentAnswer: AnswerPayload? { get }
    var questionResult: QuestionResultPayload? { get }
    var gameEndResult: GameEndPayload? { get }
    var opponentReady: Bool { get }

    func sendPlayerReady()
    func sendAnswer(_ answer: AnswerPayload)
    func sendQuestionResult(_ result: QuestionResultPayload)
    func sendGameEnd(_ result: GameEndPayload)
}

// MARK: - Transport Error

public enum MultiplayerTransportError: LocalizedError {
    case notConnected
    case encodingFailed
    case decodingFailed
    case sendFailed(Error)

    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "multiplayer_transport.error.not_connected")
        case .encodingFailed:
            return String(localized: "multiplayer_transport.error.encoding_failed")
        case .decodingFailed:
            return String(localized: "multiplayer_transport.error.decoding_failed")
        case .sendFailed(let error):
            return String(
                format: String(localized: "multiplayer_transport.error.send_failed"),
                error.localizedDescription
            )
        }
    }
}
