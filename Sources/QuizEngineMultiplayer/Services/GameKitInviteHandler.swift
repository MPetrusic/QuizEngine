//
//  GameKitInviteHandler.swift
//  QuizEngineMultiplayer
//
//  Global singleton that handles GameKit invites at app level.
//  Registered as GKLocalPlayerListener at app startup to receive
//  invites even when the multiplayer lobby is not open.
//

import Foundation
@preconcurrency import GameKit

@MainActor
public final class GameKitInviteHandler: NSObject, ObservableObject {

    // MARK: - Singleton

    public static let shared = GameKitInviteHandler()

    // MARK: - Published Properties

    /// The single source of truth for incoming invites.
    /// Non-nil means an invite is waiting to be handled.
    /// StartView observes this to navigate to the lobby.
    /// The lobby reads and clears it on appear (or in-place via onChange).
    @Published public private(set) var pendingInvite: GKInvite?

    // MARK: - Private Properties

    private var isRegistered = false
    /// Debounce: ignore duplicate didAccept callbacks within this window
    private var lastInviteTime: Date?

    // MARK: - Init

    private override init() {
        super.init()
    }

    // MARK: - Public Methods

    /// Call this after Game Center authentication succeeds.
    /// Should be called once from the app startup.
    public func registerListener() {
        guard GKLocalPlayer.local.isAuthenticated else { return }
        guard !isRegistered else { return }

        GKLocalPlayer.local.register(self)
        isRegistered = true
    }

    /// Call this to unregister (e.g., on logout, though rarely needed)
    public func unregisterListener() {
        guard isRegistered else { return }
        GKLocalPlayer.local.unregisterListener(self)
        isRegistered = false
    }

    /// Clears the pending invite. Call after the invite has been accepted/processed.
    public func clearPendingInvite() {
        pendingInvite = nil
    }
}

// MARK: - GKLocalPlayerListener

extension GameKitInviteHandler: GKLocalPlayerListener {

    /// Called when the local player accepts an invitation from another player.
    /// This is triggered when user taps the Game Center notification banner.
    /// GameKit can fire this callback more than once for the same invite,
    /// so we debounce within a 3-second window.
    nonisolated public func player(_ player: GKPlayer, didAccept invite: GKInvite) {
        let invite = UncheckedSendable(invite)
        Task { @MainActor in
            if let lastTime = self.lastInviteTime,
               Date().timeIntervalSince(lastTime) < 3 {
                return
            }
            self.lastInviteTime = Date()
            self.pendingInvite = invite.value
        }
    }

    /// Called when the local player sends other players an invitation.
    nonisolated public func player(_ player: GKPlayer, didRequestMatchWithRecipients recipientPlayers: [GKPlayer]) {
        // Currently not needed - the transport handles this flow
    }
}
