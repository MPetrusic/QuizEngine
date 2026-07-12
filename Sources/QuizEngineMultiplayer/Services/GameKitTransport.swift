//
//  GameKitTransport.swift
//  QuizEngineMultiplayer
//

import Foundation
@preconcurrency import GameKit

public enum GameKitMatchType: Sendable {
    case friends
    case random
}

@MainActor
public final class GameKitTransport: NSObject, MultiplayerTransport {

    // MARK: - Constants

    private static let heartbeatInterval: TimeInterval = 5
    private static let reconnectingThreshold: TimeInterval = 15
    private static let disconnectThreshold: TimeInterval = 30

    // MARK: - MultiplayerTransport Properties

    public let localPlayer: MultiplayerPlayer
    public let matchType: GameKitMatchType
    public private(set) var connectionState: TransportConnectionState = .idle

    /// The event stream for transport events. Can be reset when ownership transfers.
    public private(set) var eventStream: AsyncStream<MultiplayerTransportEvent>

    // MARK: - Private Properties

    /// The continuation for yielding events. Available immediately after init.
    private var continuation: AsyncStream<MultiplayerTransportEvent>.Continuation

    private var match: GKMatch?
    private var connectedGKPlayer: GKPlayer?
    private var connectedPlayer: MultiplayerPlayer?
    private var assignedRole: MultiplayerRole?

    /// Maps MultiplayerPlayer.id to GKPlayer for friend invite lookup
    private var gkPlayerMap: [String: GKPlayer] = [:]

    private var matchmakingTask: Task<Void, Never>?
    private var friendsLoadTask: Task<Void, Never>?

    // Heartbeat
    private var heartbeatTask: Task<Void, Never>?
    private var heartbeatMonitorTask: Task<Void, Never>?
    private var lastMessageReceivedTime: Date = .now
    private var isReconnecting = false

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Init

    public init(matchType: GameKitMatchType) {
        self.matchType = matchType
        self.localPlayer = MultiplayerPlayer(
            id: GKLocalPlayer.local.teamPlayerID,
            displayName: GKLocalPlayer.local.displayName
        )

        let (stream, continuation) = AsyncStream.makeStream(of: MultiplayerTransportEvent.self)
        self.eventStream = stream
        self.continuation = continuation

        super.init()
    }

    deinit {
        heartbeatTask?.cancel()
        heartbeatMonitorTask?.cancel()
        matchmakingTask?.cancel()
        friendsLoadTask?.cancel()
    }

    /// Resets the event stream, creating a fresh stream and continuation.
    public func resetEventStream() {
        continuation.finish()

        let (stream, newContinuation) = AsyncStream.makeStream(of: MultiplayerTransportEvent.self)
        self.eventStream = stream
        self.continuation = newContinuation
        print("[GameKitTransport] Event stream reset - new stream ready for iteration")
    }

    // MARK: - MultiplayerTransport Methods

    public func startSearching() {
        guard GKLocalPlayer.local.isAuthenticated else {
            continuation.yield(.error(GameKitTransportError.notAuthenticated))
            return
        }

        connectionState = .searching

        switch matchType {
        case .friends:
            loadFriends()
        case .random:
            startRandomMatchmaking()
        }
    }

    public func stopSearching() {
        matchmakingTask?.cancel()
        matchmakingTask = nil
        friendsLoadTask?.cancel()
        friendsLoadTask = nil
        GKMatchmaker.shared().cancel()
        gkPlayerMap.removeAll()
        if connectionState == .searching || connectionState == .connecting {
            connectionState = .idle
        }
    }

    public func invite(player: MultiplayerPlayer) {
        guard let gkPlayer = gkPlayerMap[player.id] else { return }
        assignedRole = .host
        connectionState = .connecting
        startFriendMatchmaking(with: gkPlayer)
    }

    public func acceptInvite(from player: MultiplayerPlayer) {
        // GameKit invites are auto-accepted via GKLocalPlayerListener.
    }

    public func declineInvite(from player: MultiplayerPlayer) {
        // GameKit invites are declined by the user via the system UI.
    }

    /// Accepts a GKInvite directly (e.g., from the global invite handler).
    public func acceptInvite(_ invite: GKInvite) {
        assignedRole = .guest
        connectionState = .connecting
        acceptInviteMatch(invite)
    }

    public func send(message: MultiplayerMessage) throws {
        guard let match,
              connectionState == .connected || connectionState == .reconnecting else {
            print("[GameKitTransport] send() failed: not connected (state: \(connectionState))")
            throw MultiplayerTransportError.notConnected
        }

        let data: Data
        do {
            data = try encoder.encode(message)
        } catch {
            print("[GameKitTransport] send() failed: encoding error")
            throw MultiplayerTransportError.encodingFailed
        }

        do {
            print("[GameKitTransport] Sending message: \(message), size: \(data.count) bytes")
            try match.sendData(toAllPlayers: data, with: .reliable)
            print("[GameKitTransport] Message sent successfully")
        } catch {
            print("[GameKitTransport] send() failed: \(error)")
            throw MultiplayerTransportError.sendFailed(error)
        }
    }

    public func disconnect() {
        stopHeartbeat()
        match?.disconnect()
        match?.delegate = nil
        match = nil
        stopSearching()
        connectedGKPlayer = nil
        connectedPlayer = nil
        assignedRole = nil
        connectionState = .disconnected
    }

    // MARK: - Friends Loading

    private func loadFriends() {
        friendsLoadTask = Task { [weak self] in
            do {
                let friends = try await GKLocalPlayer.local.loadFriends()
                guard !Task.isCancelled else { return }
                for gkPlayer in friends {
                    let player = MultiplayerPlayer(
                        id: gkPlayer.teamPlayerID,
                        displayName: gkPlayer.displayName
                    )
                    self?.gkPlayerMap[player.id] = gkPlayer
                    self?.continuation.yield(.playerDiscovered(player))
                }
                if friends.isEmpty {
                    // No event needed — the lobby checks discoveredPlayers.isEmpty
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.continuation.yield(.error(error))
            }
        }
    }

    // MARK: - Matchmaking

    private func startFriendMatchmaking(with gkPlayer: GKPlayer) {
        matchmakingTask = Task { [weak self] in
            do {
                let request = GKMatchRequest()
                request.minPlayers = 2
                request.maxPlayers = 2
                request.recipients = [gkPlayer]

                let match = try await GKMatchmaker.shared().findMatch(for: request)
                guard !Task.isCancelled else { return }
                self?.handleMatchFound(match)
            } catch let error as GKError where error.code == .cancelled {
                guard !Task.isCancelled else { return }
                self?.connectionState = .idle
            } catch {
                guard !Task.isCancelled else { return }
                self?.connectionState = .idle
                self?.continuation.yield(.error(error))
            }
        }
    }

    private func startRandomMatchmaking() {
        matchmakingTask = Task { [weak self] in
            do {
                let request = GKMatchRequest()
                request.minPlayers = 2
                request.maxPlayers = 2

                let match = try await GKMatchmaker.shared().findMatch(for: request)
                guard !Task.isCancelled else { return }
                self?.handleMatchFound(match)
            } catch let error as GKError where error.code == .cancelled {
                guard !Task.isCancelled else { return }
                self?.connectionState = .idle
            } catch {
                guard !Task.isCancelled else { return }
                self?.connectionState = .idle
                self?.continuation.yield(.error(error))
            }
        }
    }

    private func acceptInviteMatch(_ invite: GKInvite) {
        matchmakingTask = Task { [weak self] in
            do {
                let match = try await GKMatchmaker.shared().match(for: invite)
                guard !Task.isCancelled else { return }
                self?.handleMatchFound(match)
            } catch {
                guard !Task.isCancelled else { return }
                self?.connectionState = .idle
                self?.continuation.yield(.error(error))
            }
        }
    }

    private func handleMatchFound(_ match: GKMatch) {
        self.match = match
        match.delegate = self

        if let opponentGKPlayer = match.players.first {
            connectedGKPlayer = opponentGKPlayer
            let opponent = MultiplayerPlayer(
                id: opponentGKPlayer.teamPlayerID,
                displayName: opponentGKPlayer.displayName
            )
            connectedPlayer = opponent
            connectionState = .connected

            let role: MultiplayerRole
            if matchType == .random {
                role = GKLocalPlayer.local.teamPlayerID < opponentGKPlayer.teamPlayerID ? .host : .guest
                assignedRole = role
            } else {
                role = assignedRole ?? .guest
            }

            continuation.yield(.connected(to: opponent, role: role))
            startHeartbeat()
        } else {
            connectionState = .connecting
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        stopHeartbeat()
        lastMessageReceivedTime = .now
        isReconnecting = false

        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.heartbeatInterval))
                guard !Task.isCancelled else { return }
                try? self?.send(message: .heartbeat)
            }
        }

        heartbeatMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.checkHeartbeat()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        heartbeatMonitorTask?.cancel()
        heartbeatMonitorTask = nil
    }

    private func checkHeartbeat() {
        let elapsed = Date.now.timeIntervalSince(lastMessageReceivedTime)

        if elapsed >= Self.disconnectThreshold {
            guard connectionState != .disconnected else { return }
            stopHeartbeat()
            connectionState = .disconnected
            if let player = connectedPlayer {
                continuation.yield(.disconnected(from: player))
            }
        } else if elapsed >= Self.reconnectingThreshold && !isReconnecting {
            isReconnecting = true
            connectionState = .reconnecting
            if let player = connectedPlayer {
                continuation.yield(.reconnecting(to: player))
            }
        }
    }

    // MARK: - Message Handling

    private func handleReceivedData(_ data: Data, from gkPlayer: GKPlayer) {
        lastMessageReceivedTime = .now
        print("[GameKitTransport] Received data: \(data.count) bytes from \(gkPlayer.displayName)")

        if isReconnecting, connectionState == .reconnecting {
            isReconnecting = false
            connectionState = .connected
            if let player = connectedPlayer {
                continuation.yield(.reconnected(to: player))
            }
        }

        guard let message = try? decoder.decode(MultiplayerMessage.self, from: data) else {
            print("[GameKitTransport] Failed to decode message from data")
            continuation.yield(.error(MultiplayerTransportError.decodingFailed))
            return
        }

        print("[GameKitTransport] Decoded message: \(message)")

        if case .heartbeat = message { return }

        let sender = connectedPlayer ?? MultiplayerPlayer(
            id: gkPlayer.teamPlayerID,
            displayName: gkPlayer.displayName
        )
        print("[GameKitTransport] Yielding messageReceived event to stream")
        continuation.yield(.messageReceived(message, from: sender))
    }
}

// MARK: - GKMatchDelegate

extension GameKitTransport: GKMatchDelegate {

    nonisolated public func match(_ match: GKMatch, didReceive data: Data, fromRemotePlayer player: GKPlayer) {
        let player = UncheckedSendable(player)
        Task { @MainActor [weak self] in
            self?.handleReceivedData(data, from: player.value)
        }
    }

    nonisolated public func match(_ match: GKMatch, player: GKPlayer, didChange state: GKPlayerConnectionState) {
        let player = UncheckedSendable(player)
        Task { @MainActor [weak self] in
            self?.handlePlayerStateChange(player: player.value, state: state)
        }
    }

    private func handlePlayerStateChange(player: GKPlayer, state: GKPlayerConnectionState) {
        switch state {
        case .connected:
            if connectionState == .connecting || connectionState == .searching {
                connectedGKPlayer = player
                let opponent = MultiplayerPlayer(
                    id: player.teamPlayerID,
                    displayName: player.displayName
                )
                connectedPlayer = opponent
                connectionState = .connected

                let role: MultiplayerRole
                if matchType == .random {
                    role = GKLocalPlayer.local.teamPlayerID < player.teamPlayerID ? .host : .guest
                    assignedRole = role
                } else {
                    role = assignedRole ?? .guest
                }

                continuation.yield(.connected(to: opponent, role: role))
                startHeartbeat()
            } else if let connectedPlayer, connectionState == .reconnecting {
                isReconnecting = false
                connectionState = .connected
                continuation.yield(.reconnected(to: connectedPlayer))
            }

        case .disconnected:
            guard connectionState != .idle && connectionState != .disconnected else { return }
            stopHeartbeat()
            connectionState = .disconnected
            if let connectedPlayer {
                continuation.yield(.disconnected(from: connectedPlayer))
            }

        case .unknown:
            break

        @unknown default:
            break
        }
    }
}

// MARK: - GKLocalPlayerListener (Invite Handling)

extension GameKitTransport: GKLocalPlayerListener {

    nonisolated public func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        let invite = UncheckedSendable(invite)
        Task { @MainActor [weak self] in
            self?.handleIncomingInvite(invite.value)
        }
    }

    private func handleIncomingInvite(_ invite: GKInvite) {
        assignedRole = .guest
        connectionState = .connecting
        acceptInviteMatch(invite)
    }
}

// MARK: - Error

public enum GameKitTransportError: LocalizedError {
    case notAuthenticated
    case noOpponentFound

    public var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return String(localized: "gamekit_transport.error.not_authenticated")
        case .noOpponentFound:
            return String(localized: "gamekit_transport.error.no_opponent_found")
        }
    }
}
