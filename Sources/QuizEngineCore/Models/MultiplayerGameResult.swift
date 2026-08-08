import Foundation

public enum MultiplayerGameResult: Equatable, Sendable {
    case won
    case lost
    case draw
    case opponentDisconnected
}
