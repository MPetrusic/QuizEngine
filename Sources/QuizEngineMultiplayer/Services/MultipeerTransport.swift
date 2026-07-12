//
//  MultipeerTransport.swift
//  QuizEngineMultiplayer
//

import Foundation
@preconcurrency import MultipeerConnectivity
@preconcurrency import GameKit
import QuizEngineCore

#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class MultipeerTransport: NSObject, MultiplayerTransport {

    // MARK: - Constants

    private static let heartbeatInterval: TimeInterval = 5
    private static let reconnectingThreshold: TimeInterval = 15
    private static let disconnectThreshold: TimeInterval = 30
    private static let displayNameKey = "multiplayerDisplayName"

    // MARK: - MultiplayerTransport Properties

    public let localPlayer: MultiplayerPlayer
    public private(set) var connectionState: TransportConnectionState = .idle

    /// The event stream for transport events. Can be reset when ownership transfers.
    public private(set) var eventStream: AsyncStream<MultiplayerTransportEvent>

    // MARK: - Private Properties

    private let peerID: MCPeerID
    private var session: MCSession?
    private var browser: MCNearbyServiceBrowser?
    private var advertiser: MCNearbyServiceAdvertiser?

    /// The continuation for yielding events. Available immediately after init.
    private var continuation: AsyncStream<MultiplayerTransportEvent>.Continuation

    private var connectedPeer: MCPeerID?
    private var connectedPlayer: MultiplayerPlayer?
    private var assignedRole: MultiplayerRole?

    /// Maps MCPeerID display names to MultiplayerPlayer for discovered peers
    private var discoveredPeers: [MCPeerID: MultiplayerPlayer] = [:]
    /// Tracks pending invites from peers
    private var pendingInviteHandlers: [MCPeerID: (Bool, MCSession?) -> Void] = [:]

    private var heartbeatTask: Task<Void, Never>?
    private var lastMessageReceivedTime: Date = .now
    private var heartbeatMonitorTask: Task<Void, Never>?
    private var isReconnecting = false

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let serviceType: String

    // MARK: - Init

    public init(serviceType: String) {
        precondition(!serviceType.isEmpty && serviceType.count <= 15, "Bonjour service type must contain 1...15 characters")
        self.serviceType = serviceType
        let displayName = MultipeerTransport.resolveDisplayName()
        self.peerID = MCPeerID(displayName: displayName)
        self.localPlayer = MultiplayerPlayer(
            id: peerID.displayName,
            displayName: displayName
        )

        let (stream, continuation) = AsyncStream.makeStream(of: MultiplayerTransportEvent.self)
        self.eventStream = stream
        self.continuation = continuation

        super.init()
    }

    deinit {
        heartbeatTask?.cancel()
        heartbeatMonitorTask?.cancel()
    }

    /// Resets the event stream, creating a fresh stream and continuation.
    public func resetEventStream() {
        continuation.finish()
        let (stream, newContinuation) = AsyncStream.makeStream(of: MultiplayerTransportEvent.self)
        self.eventStream = stream
        self.continuation = newContinuation
        print("[MultipeerTransport] Event stream reset - new stream ready for iteration")
    }

    // MARK: - Display Name Resolution

    private static func resolveDisplayName() -> String {
        if GKLocalPlayer.local.isAuthenticated {
            return GKLocalPlayer.local.displayName
        }
        if let cached = UserDefaults.standard.string(forKey: displayNameKey), !cached.isEmpty {
            return cached
        }
        // Fallback — will be overwritten by lobby name entry
        #if canImport(UIKit)
        return UIDevice.current.name
        #else
        return "Player"
        #endif
    }

    /// Call from the lobby when the user enters their name (if not Game Center authenticated)
    public static func setDisplayName(_ name: String) {
        UserDefaults.standard.set(name, forKey: displayNameKey)
    }

    // MARK: - MultiplayerTransport Methods

    public func startSearching() {
        stopSearching()

        let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        self.session = session

        let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
        browser.delegate = self
        self.browser = browser

        let advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
        advertiser.delegate = self
        self.advertiser = advertiser

        browser.startBrowsingForPeers()
        advertiser.startAdvertisingPeer()
        connectionState = .searching
    }

    public func stopSearching() {
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        browser = nil
        advertiser = nil
        discoveredPeers.removeAll()
        pendingInviteHandlers.removeAll()
        if connectionState == .searching {
            connectionState = .idle
        }
    }

    public func invite(player: MultiplayerPlayer) {
        guard let session,
              let peerID = discoveredPeers.first(where: { $0.value.id == player.id })?.key else {
            return
        }
        browser?.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
        assignedRole = .host
        connectionState = .connecting
    }

    public func acceptInvite(from player: MultiplayerPlayer) {
        guard let peerID = discoveredPeers.first(where: { $0.value.id == player.id })?.key,
              let handler = pendingInviteHandlers.removeValue(forKey: peerID) else {
            return
        }
        handler(true, session)
        assignedRole = .guest
        connectionState = .connecting
    }

    public func declineInvite(from player: MultiplayerPlayer) {
        guard let peerID = discoveredPeers.first(where: { $0.value.id == player.id })?.key,
              let handler = pendingInviteHandlers.removeValue(forKey: peerID) else {
            return
        }
        handler(false, nil)
    }

    public func send(message: MultiplayerMessage) throws {
        guard let session,
              let connectedPeer,
              connectionState == .connected || connectionState == .reconnecting else {
            throw MultiplayerTransportError.notConnected
        }

        let data: Data
        do {
            data = try encoder.encode(message)
        } catch {
            throw MultiplayerTransportError.encodingFailed
        }

        do {
            try session.send(data, toPeers: [connectedPeer], with: .reliable)
        } catch {
            throw MultiplayerTransportError.sendFailed(error)
        }
    }

    public func disconnect() {
        stopHeartbeat()
        session?.disconnect()
        stopSearching()
        session = nil
        connectedPeer = nil
        connectedPlayer = nil
        assignedRole = nil
        connectionState = .disconnected
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

    private func handleReceivedData(_ data: Data, from peerID: MCPeerID) {
        lastMessageReceivedTime = .now

        if isReconnecting, connectionState == .reconnecting {
            isReconnecting = false
            connectionState = .connected
            if let player = connectedPlayer {
                continuation.yield(.reconnected(to: player))
            }
        }

        guard let message = try? decoder.decode(MultiplayerMessage.self, from: data) else {
            continuation.yield(.error(MultiplayerTransportError.decodingFailed))
            return
        }

        if case .heartbeat = message { return }

        let sender = connectedPlayer ?? MultiplayerPlayer(id: peerID.displayName, displayName: peerID.displayName)
        continuation.yield(.messageReceived(message, from: sender))
    }
}

// MARK: - MCSessionDelegate

extension MultipeerTransport: MCSessionDelegate {

    nonisolated public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let peerID = UncheckedSendable(peerID)
        Task { @MainActor [weak self] in
            self?.handlePeerStateChange(peerID: peerID.value, state: state)
        }
    }

    private func handlePeerStateChange(peerID: MCPeerID, state: MCSessionState) {
        switch state {
        case .connected:
            connectedPeer = peerID
            let player = discoveredPeers[peerID] ?? MultiplayerPlayer(
                id: peerID.displayName,
                displayName: peerID.displayName
            )
            connectedPlayer = player
            connectionState = .connected
            let role = assignedRole ?? .guest
            continuation.yield(.connected(to: player, role: role))
            stopSearching()
            startHeartbeat()

        case .connecting:
            connectionState = .connecting

        case .notConnected:
            guard connectionState != .idle && connectionState != .disconnected else { return }
            stopHeartbeat()
            connectionState = .disconnected
            if let player = connectedPlayer {
                continuation.yield(.disconnected(from: player))
            }
            connectedPeer = nil
            connectedPlayer = nil

        @unknown default:
            break
        }
    }

    nonisolated public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        let peerID = UncheckedSendable(peerID)
        Task { @MainActor [weak self] in
            self?.handleReceivedData(data, from: peerID.value)
        }
    }

    // Unused required delegate methods
    nonisolated public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        let peerID = UncheckedSendable(peerID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let player = MultiplayerPlayer(id: peerID.value.displayName, displayName: peerID.value.displayName)
            self.discoveredPeers[peerID.value] = player
            self.continuation.yield(.playerDiscovered(player))
        }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        let peerID = UncheckedSendable(peerID)
        Task { @MainActor [weak self] in
            guard let self,
                  let player = self.discoveredPeers.removeValue(forKey: peerID.value) else { return }
            self.continuation.yield(.playerLost(player))
        }
    }

    nonisolated public func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor [weak self] in
            self?.continuation.yield(.error(error))
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {

    nonisolated public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let peerID = UncheckedSendable(peerID)
        let invitationHandler = UncheckedSendable(invitationHandler)
        Task { @MainActor [weak self] in
            guard let self else {
                invitationHandler.value(false, nil)
                return
            }
            let player = MultiplayerPlayer(id: peerID.value.displayName, displayName: peerID.value.displayName)
            self.discoveredPeers[peerID.value] = player
            self.pendingInviteHandlers[peerID.value] = invitationHandler.value
            self.continuation.yield(.inviteReceived(from: player))
        }
    }

    nonisolated public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor [weak self] in
            self?.continuation.yield(.error(error))
        }
    }
}
