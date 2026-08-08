import Foundation
import QuizEngineCore

/// Immutable domain data used to durably commit one terminal multiplayer result.
public struct MultiplayerTerminalRecord: Equatable, Sendable {
    public let matchID: String
    public let localRole: MultiplayerRole
    public let terminalReason: GameEndReason
    public let hostFinalScore: Int
    public let guestFinalScore: Int
    public let questionsCompleted: Int
    public let questionsCorrect: Int
    public let awardedCoins: Int
    public let responseTimes: [Int]
    public let fingerprint: String

    public init(
        matchID: String,
        localRole: MultiplayerRole,
        terminalReason: GameEndReason,
        hostFinalScore: Int,
        guestFinalScore: Int,
        questionsCompleted: Int,
        questionsCorrect: Int,
        awardedCoins: Int,
        responseTimes: [Int]
    ) {
        self.matchID = matchID
        self.localRole = localRole
        self.terminalReason = terminalReason
        self.hostFinalScore = hostFinalScore
        self.guestFinalScore = guestFinalScore
        self.questionsCompleted = questionsCompleted
        self.questionsCorrect = questionsCorrect
        self.awardedCoins = awardedCoins
        self.responseTimes = responseTimes
        self.fingerprint = Self.makeFingerprint(
            matchID: matchID,
            localRole: localRole,
            terminalReason: terminalReason,
            hostFinalScore: hostFinalScore,
            guestFinalScore: guestFinalScore,
            questionsCompleted: questionsCompleted,
            questionsCorrect: questionsCorrect,
            awardedCoins: awardedCoins,
            responseTimes: responseTimes
        )
    }

    public var localScore: Int {
        localRole == .host ? hostFinalScore : guestFinalScore
    }

    public var opponentScore: Int {
        localRole == .host ? guestFinalScore : hostFinalScore
    }

    public var result: MultiplayerGameResult {
        guard terminalReason == .completed else { return .opponentDisconnected }
        if localScore > opponentScore { return .won }
        if localScore < opponentScore { return .lost }
        return .draw
    }

    private static func makeFingerprint(
        matchID: String,
        localRole: MultiplayerRole,
        terminalReason: GameEndReason,
        hostFinalScore: Int,
        guestFinalScore: Int,
        questionsCompleted: Int,
        questionsCorrect: Int,
        awardedCoins: Int,
        responseTimes: [Int]
    ) -> String {
        let role = localRole == .host ? "host" : "guest"
        let reason: String
        switch terminalReason {
        case .completed: reason = "completed"
        case .opponentLeft: reason = "opponent_left"
        case .disconnected: reason = "disconnected"
        }
        let fields = [
            "match_id", matchID,
            "local_role", role,
            "terminal_reason", reason,
            "host_final_score", String(hostFinalScore),
            "guest_final_score", String(guestFinalScore),
            "questions_completed", String(questionsCompleted),
            "questions_correct", String(questionsCorrect),
            "awarded_coins", String(awardedCoins),
            "response_times_ms", responseTimes.map(String.init).joined(separator: ",")
        ]
        return "qeb01-v1|" + fields
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }
}

public enum MultiplayerTerminalCommitState: Equatable, Sendable {
    case idle
    case pending(MultiplayerTerminalRecord)
    case committing(MultiplayerTerminalRecord)
    case committed(receiptID: String)
}

public enum MultiplayerTerminalCommitFailure: Equatable, Sendable {
    case missingStableMatchData
    case persistenceUnavailable
    case conflictingReceipt
    case rejected
    case persistenceFailed(PersistenceError)

    var isRetryable: Bool {
        if case .persistenceFailed = self { return true }
        return false
    }
}
