//
//  MultiplayerTransportFactory.swift
//  QuizEngineMultiplayer
//

import Foundation

public enum TransportType: Sendable {
    case nearby
    case gameCenterFriends
    case gameCenterRandom
}

@MainActor
public struct MultiplayerTransportFactory {
    public static func create(
        _ type: TransportType,
        nearbyServiceType: String? = nil
    ) -> any MultiplayerTransport {
        switch type {
        case .nearby:
            guard let nearbyServiceType else {
                preconditionFailure("nearbyServiceType is required for nearby multiplayer")
            }
            return MultipeerTransport(serviceType: nearbyServiceType)
        case .gameCenterFriends:
            return GameKitTransport(matchType: .friends)
        case .gameCenterRandom:
            return GameKitTransport(matchType: .random)
        }
    }

    public init() {}
}
