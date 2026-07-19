//
//  MultiplayerConnectionManager.swift
//  QuizEngineMultiplayer
//

import Foundation

public enum LobbyConnectionState: Sendable {
    case idle
    case searching
    case inviteSent
    case inviteReceived
    case connecting
    case connected
}

@MainActor
public final class MultiplayerConnectionManager: ObservableObject {

    // MARK: - Published Properties

    @Published public private(set) var connectionState: LobbyConnectionState = .idle
    @Published public private(set) var discoveredPlayers: [MultiplayerPlayer] = []
    @Published public private(set) var opponent: MultiplayerPlayer?
    @Published public private(set) var role: MultiplayerRole?
    @Published public private(set) var pendingInviteFrom: MultiplayerPlayer?
    @Published public var error: String?

    // MARK: - Private Properties

    private var transport: (any MultiplayerTransport)?
    private var eventListenerTask: Task<Void, Never>?
    /// Messages received during lobby phase before handoff — forwarded to game coordinator.
    private var bufferedMessages: [MultiplayerMessage] = []

    // MARK: - Init

    public init() {}

    // MARK: - Public Methods

    public func startSearching(using transport: any MultiplayerTransport) {
        stopSearching()
        self.transport = transport
        transport.startSearching()
        connectionState = .searching
        startListening()
    }

    public func stopSearching() {
        eventListenerTask?.cancel()
        eventListenerTask = nil
        transport?.stopSearching()
        discoveredPlayers.removeAll()
        pendingInviteFrom = nil
        bufferedMessages = []
        if connectionState != .connected {
            connectionState = .idle
        }
    }

    public func invitePlayer(_ player: MultiplayerPlayer) {
        transport?.invite(player: player)
        connectionState = .inviteSent
    }

    public func acceptInvite(from player: MultiplayerPlayer) {
        transport?.acceptInvite(from: player)
        pendingInviteFrom = nil
        connectionState = .connecting
    }

    public func declineInvite(from player: MultiplayerPlayer) {
        transport?.declineInvite(from: player)
        pendingInviteFrom = nil
        if connectionState == .inviteReceived {
            connectionState = .searching
        }
    }

    /// Transfers transport ownership to the game coordinator. Call once on match start.
    /// Resets the event stream so the new owner gets a fresh stream to iterate.
    /// Returns the transport and any messages buffered during the lobby phase.
    public func handoffTransport() -> (transport: any MultiplayerTransport, bufferedMessages: [MultiplayerMessage])? {
        eventListenerTask?.cancel()
        eventListenerTask = nil
        let t = transport
        let messages = bufferedMessages
        transport = nil
        bufferedMessages = []
        // Reset the event stream so the game coordinator gets a fresh stream.
        // AsyncStream is single-consumer, so we need a new stream after the lobby consumed it.
        t?.resetEventStream()
        guard let t else { return nil }
        return (t, messages)
    }

    public func reset() {
        eventListenerTask?.cancel()
        eventListenerTask = nil
        transport?.disconnect()
        transport = nil
        discoveredPlayers.removeAll()
        opponent = nil
        role = nil
        pendingInviteFrom = nil
        error = nil
        bufferedMessages = []
        connectionState = .idle
    }

    /// Attaches a transport for an app-owned inbound connection flow.
    /// The package intentionally does not know which SDK supplied the invitation.
    public func startConnecting(
        using transport: any MultiplayerTransport,
        prepareTransport: () -> Void
    ) {
        stopSearching()
        self.transport = transport
        connectionState = .connecting
        startListening()
        prepareTransport()
    }

    // MARK: - Private

    private func startListening() {
        guard let transport else { return }
        eventListenerTask = Task { [weak self] in
            for await event in transport.eventStream {
                guard !Task.isCancelled else { return }
                self?.handleEvent(event)
            }
        }
    }

    private func handleEvent(_ event: MultiplayerTransportEvent) {
        print("[MultiplayerConnectionManager] handleEvent: \(event)")
        switch event {
        case .playerDiscovered(let player):
            if !discoveredPlayers.contains(where: { $0.id == player.id }) {
                discoveredPlayers.append(player)
            }

        case .playerLost(let player):
            discoveredPlayers.removeAll { $0.id == player.id }
            if pendingInviteFrom?.id == player.id {
                pendingInviteFrom = nil
                if connectionState == .inviteReceived {
                    connectionState = .searching
                }
            }

        case .inviteReceived(let player):
            pendingInviteFrom = player
            connectionState = .inviteReceived

        case .connected(let player, let assignedRole):
            opponent = player
            role = assignedRole
            connectionState = .connected

        case .disconnected:
            opponent = nil
            role = nil
            error = String(localized: "multiplayer_connection.error.disconnected")
            connectionState = .searching

        case .error(let err):
            error = err.localizedDescription

        case .reconnecting, .reconnected:
            // Not relevant for lobby — handled by game coordinator
            break

        case .messageReceived(let message, _):
            // Buffer messages received during lobby phase so they can be forwarded
            // to the game coordinator after handoff (prevents gameConfig loss).
            print("[MultiplayerConnectionManager] Buffering message received during lobby phase: \(message)")
            bufferedMessages.append(message)
        }
    }
}
