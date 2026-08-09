//
//  PlayerProgressManager.swift
//  QuizEngineCore
//

import Foundation
import SwiftUI

@MainActor
public class PlayerProgressManager: ObservableObject {
    @Published public private(set) var progress: PlayerProgress
    @Published public var newlyUnlockedAchievements: [Achievement] = []
    @Published public private(set) var persistenceStatus: PersistenceStatus = .fresh
    @Published public private(set) var lastPersistenceError: PersistenceError?

    public let variant: QuizVariantDefinition
    public let questionDataService: QuestionDataService
    private let achievementService: AchievementService
    private let analytics: (any AnalyticsProvider)?
    private let purchaseStatus: (any PurchaseStatusProvider)?
    private let persistenceStore: any QuizEnginePersistenceStore
    private let clock: any QuizEngineClock
    private let calendar: Calendar
    private var lastPersistedProgress: PlayerProgress
    private let persistenceLoadFailed: Bool

    private static var plistURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("player_progress.plist")
    }

    private init(
        variant: QuizVariantDefinition,
        questionDataService: QuestionDataService,
        analytics: (any AnalyticsProvider)?,
        purchaseStatus: (any PurchaseStatusProvider)?,
        persistenceStore: any QuizEnginePersistenceStore,
        clock: any QuizEngineClock,
        calendar: Calendar,
        _implementation: Void
    ) {
        self.variant = variant
        self.questionDataService = questionDataService
        self.achievementService = AchievementService(
            variant: variant,
            clock: clock,
            calendar: calendar
        )
        self.analytics = analytics
        self.purchaseStatus = purchaseStatus
        self.persistenceStore = persistenceStore
        self.clock = clock
        self.calendar = calendar
        let freshProgress = PlayerProgress.fresh(initialCoins: variant.rules.economy.initialCoins)
        let loadResult = Self.load(from: persistenceStore, freshProgress: freshProgress)
        self.progress = loadResult.progress
        self.persistenceStatus = loadResult.status
        self.lastPersistenceError = loadResult.error
        self.lastPersistedProgress = loadResult.progress
        self.persistenceLoadFailed = loadResult.error != nil
    }

    public convenience init(
        variant: QuizVariantDefinition,
        questionDataService: QuestionDataService,
        analytics: (any AnalyticsProvider)? = nil,
        purchaseStatus: (any PurchaseStatusProvider)? = nil,
        persistenceURL: URL? = nil,
        clock: any QuizEngineClock = SystemQuizEngineClock(),
        calendar: Calendar = .current
    ) {
        self.init(
            variant: variant,
            questionDataService: questionDataService,
            analytics: analytics,
            purchaseStatus: purchaseStatus,
            persistenceStore: FileQuizEnginePersistenceStore(primaryURL: persistenceURL ?? Self.plistURL),
            clock: clock,
            calendar: calendar,
            _implementation: ()
        )
    }

    /// Creates a manager using an injected store and surfaces an existing
    /// persistence failure instead of falling back to the default progress.
    public convenience init(
        variant: QuizVariantDefinition,
        questionDataService: QuestionDataService,
        analytics: (any AnalyticsProvider)? = nil,
        purchaseStatus: (any PurchaseStatusProvider)? = nil,
        persistenceStore: any QuizEnginePersistenceStore,
        clock: any QuizEngineClock = SystemQuizEngineClock(),
        calendar: Calendar = .current
    ) throws {
        self.init(
            variant: variant,
            questionDataService: questionDataService,
            analytics: analytics,
            purchaseStatus: purchaseStatus,
            persistenceStore: persistenceStore,
            clock: clock,
            calendar: calendar,
            _implementation: ()
        )

        if let lastPersistenceError {
            throw lastPersistenceError
        }
    }

    // MARK: - Persistence

    public func persist() throws {
        if persistenceLoadFailed {
            throw failBecauseInitialLoadFailed()
        }
        do {
            try persistenceStore.withExclusiveAccess {
                try writeAndVerify(progress)
            }
            lastPersistedProgress = progress
            persistenceStatus = .saved
            lastPersistenceError = nil
        } catch let error as PersistenceError {
            progress = lastPersistedProgress
            persistenceStatus = .failed(error)
            lastPersistenceError = error
            throw error
        } catch {
            let persistenceError = PersistenceError.writeFailed(
                path: persistenceStore.primaryURL.path,
                reason: error.localizedDescription
            )
            progress = lastPersistedProgress
            persistenceStatus = .failed(persistenceError)
            lastPersistenceError = persistenceError
            throw persistenceError
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard !persistenceLoadFailed else {
            progress = lastPersistedProgress
            return false
        }
        do {
            try persistenceStore.withExclusiveAccess {
                try writeAndVerify(progress)
            }
            lastPersistedProgress = progress
            persistenceStatus = .saved
            lastPersistenceError = nil
            return true
        } catch let error as PersistenceError {
            progress = lastPersistedProgress
            persistenceStatus = .failed(error)
            lastPersistenceError = error
            return false
        } catch {
            let persistenceError = PersistenceError.writeFailed(
                path: persistenceStore.primaryURL.path,
                reason: error.localizedDescription
            )
            progress = lastPersistedProgress
            persistenceStatus = .failed(persistenceError)
            lastPersistenceError = persistenceError
            return false
        }
    }

    public func importProgress(
        _ request: PlayerProgressImportRequest
    ) throws -> PlayerProgressImportResult {
        do {
            if persistenceLoadFailed {
                throw failBecauseInitialLoadFailed()
            }
            return try persistenceStore.withExclusiveAccess {
                if let existingMarker = try persistenceStore.readDecodedImportMarker().marker {
                    guard existingMarker.identifier == request.identifier,
                          existingMarker.sourceFingerprint == request.sourceFingerprint else {
                        if existingMarker.state == .completed {
                            throw PersistenceError.conflictingImport(identifier: request.identifier)
                        }
                        throw PersistenceError.malformedImportMarker(
                            path: persistenceStore.transactionMarkerURL.path
                        )
                    }

                    if existingMarker.state == .completed {
                        guard existingMarker.targetProgress == request.progress else {
                            throw PersistenceError.conflictingImport(identifier: request.identifier)
                        }
                        try validateCompletedImport(existingMarker)
                        persistenceStatus = .alreadyImported
                        lastPersistenceError = nil
                        return .alreadyImported
                    }
                }

                let previousPrimaryData = try persistenceStore.readPrimary()
                let hadPrimary = previousPrimaryData != nil
                let previousProgress = previousPrimaryData.flatMap { data in
                    try? PersistenceDocumentCodec.decode(
                        PlayerProgress.self,
                        from: data,
                        path: persistenceStore.primaryURL.path
                    ).payload
                }
                let pendingMarker = ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: request.identifier,
                    sourceFingerprint: request.sourceFingerprint,
                    state: .pending,
                    hadPrimary: hadPrimary,
                    timestamp: clock.now,
                    targetProgress: request.progress,
                    previousProgress: previousProgress
                )
                try replaceImportMarker(pendingMarker)

                do {
                    try writeAndVerify(request.progress)

                    let completedMarker = ImportMarker(
                        schemaVersion: QuizEnginePersistenceSchema.current,
                        identifier: request.identifier,
                        sourceFingerprint: request.sourceFingerprint,
                        state: .completed,
                        hadPrimary: hadPrimary,
                        timestamp: clock.now,
                        targetProgress: request.progress,
                        previousProgress: previousProgress
                    )
                    try replaceImportMarker(completedMarker)

                    progress = request.progress
                    lastPersistedProgress = request.progress
                    persistenceStatus = .imported
                    lastPersistenceError = nil
                    return .imported
                } catch {
                    let operationError = error
                    do {
                        try recoverInterruptedImport(
                            hadPrimary: hadPrimary,
                            previousProgress: previousProgress
                        )
                    } catch {
                        throw error
                    }
                    throw operationError
                }
            }
        } catch let error as PersistenceError {
            persistenceStatus = .failed(error)
            lastPersistenceError = error
            throw error
        } catch {
            let persistenceError = PersistenceError.writeFailed(
                path: persistenceStore.primaryURL.path,
                reason: error.localizedDescription
            )
            persistenceStatus = .failed(persistenceError)
            lastPersistenceError = persistenceError
            throw persistenceError
        }
    }

    private func failBecauseInitialLoadFailed() -> PersistenceError {
        lastPersistenceError ?? .readFailed(
            path: persistenceStore.primaryURL.path,
            reason: "The initial persistence load failed."
        )
    }

    private func writeAndVerify(_ value: PlayerProgress) throws {
        let previousPrimaryData = try persistenceStore.readPrimary()
        let hadPrimary = previousPrimaryData != nil
        let previousProgress = previousPrimaryData.flatMap { data in
            try? PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: data,
                path: persistenceStore.primaryURL.path
            ).payload
        }
        let data: Data
        do {
            data = try PersistenceDocumentCodec.encode(
                value,
                path: persistenceStore.primaryURL.path
            )
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.writeFailed(
                path: persistenceStore.primaryURL.path,
                reason: error.localizedDescription
            )
        }

        do {
            try persistenceStore.replacePrimary(with: data)
        } catch {
            let operationError = error
            do {
                try repairFailedReplacement(
                    hadPrimary: hadPrimary,
                    attemptedData: data,
                    attemptedValue: value,
                    previousValue: previousProgress
                )
            } catch {
                throw error
            }
            throw operationError
        }

        do {
            guard let readBack = try persistenceStore.readPrimary() else {
                throw PersistenceError.readBackVerificationFailed(
                    path: persistenceStore.primaryURL.path
                )
            }
            let decoded = try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: readBack,
                path: persistenceStore.primaryURL.path
            )
            guard decoded.schemaVersion == QuizEnginePersistenceSchema.current,
                  decoded.payload == value else {
                throw PersistenceError.readBackVerificationFailed(
                    path: persistenceStore.primaryURL.path
                )
            }
        } catch {
            let verificationError = error
            do {
                try rollbackFailedReplacement(
                    hadPrimary: hadPrimary,
                    expectedValue: previousProgress
                )
            } catch {
                throw error
            }
            if let persistenceError = verificationError as? PersistenceError {
                throw persistenceError
            }
            throw PersistenceError.readBackVerificationFailed(
                path: persistenceStore.primaryURL.path
            )
        }
    }

    private func repairFailedReplacement<Value: Codable & Equatable & Sendable>(
        hadPrimary: Bool,
        attemptedData: Data,
        attemptedValue: Value,
        previousValue: Value?
    ) throws {
        let currentData: Data?
        do {
            currentData = try persistenceStore.readPrimary()
        } catch {
            try rollbackFailedReplacement(
                hadPrimary: hadPrimary,
                expectedValue: previousValue
            )
            return
        }

        guard let currentData else {
            if hadPrimary {
                try rollbackFailedReplacement(
                    hadPrimary: true,
                    expectedValue: previousValue
                )
            }
            return
        }

        let decodedSucceeded: Bool
        let decodedMatchesAttempt: Bool
        do {
            let decoded = try PersistenceDocumentCodec.decode(
                Value.self,
                from: currentData,
                path: persistenceStore.primaryURL.path
            )
            decodedSucceeded = true
            decodedMatchesAttempt = decoded.schemaVersion == QuizEnginePersistenceSchema.current &&
                decoded.payload == attemptedValue
        } catch {
            decodedSucceeded = false
            decodedMatchesAttempt = false
        }
        let needsRecovery = currentData == attemptedData || decodedMatchesAttempt || !decodedSucceeded

        if needsRecovery {
            try rollbackFailedReplacement(
                hadPrimary: hadPrimary,
                expectedValue: previousValue
            )
        }
    }

    private func rollbackFailedReplacement<Value: Codable & Equatable & Sendable>(
        hadPrimary: Bool,
        expectedValue: Value?
    ) throws {
        do {
            if hadPrimary {
                try persistenceStore.restoreBackup()
                guard let restoredData = try persistenceStore.readPrimary() else {
                    throw PersistenceError.readBackVerificationFailed(
                        path: persistenceStore.primaryURL.path
                    )
                }
                let restored = try PersistenceDocumentCodec.decode(
                    Value.self,
                    from: restoredData,
                    path: persistenceStore.primaryURL.path
                )
                if let expectedValue, restored.payload != expectedValue {
                    throw PersistenceError.readBackVerificationFailed(
                        path: persistenceStore.primaryURL.path
                    )
                }
            } else {
                try persistenceStore.removePrimary()
                if try persistenceStore.readPrimary() != nil {
                    throw PersistenceError.readBackVerificationFailed(
                        path: persistenceStore.primaryURL.path
                    )
                }
            }
        } catch let error as PersistenceError {
            let path = hadPrimary ? persistenceStore.backupURL.path : persistenceStore.primaryURL.path
            throw PersistenceError.backupRecoveryFailed(
                path: path,
                reason: error.localizedDescription
            )
        } catch {
            let path = hadPrimary ? persistenceStore.backupURL.path : persistenceStore.primaryURL.path
            throw PersistenceError.backupRecoveryFailed(
                path: path,
                reason: error.localizedDescription
            )
        }
    }

    private func validateCompletedImport(_ marker: ImportMarker) throws {
        guard let targetProgress = marker.targetProgress else {
            throw PersistenceError.malformedImportMarker(
                path: persistenceStore.transactionMarkerURL.path
            )
        }
        guard let currentData = try persistenceStore.readPrimary() else {
            throw PersistenceError.readBackVerificationFailed(
                path: persistenceStore.primaryURL.path
            )
        }
        let current = try PersistenceDocumentCodec.decode(
            PlayerProgress.self,
            from: currentData,
            path: persistenceStore.primaryURL.path
        )
        if let previousProgress = marker.previousProgress,
           previousProgress != targetProgress,
           current.payload == previousProgress {
            throw PersistenceError.readBackVerificationFailed(
                path: persistenceStore.primaryURL.path
            )
        }
    }

    private func replaceImportMarker(_ marker: ImportMarker) throws {
        let data = try PersistenceMarkerCodec.encode(
            marker,
            path: persistenceStore.transactionMarkerURL.path
        )
        try persistenceStore.replaceTransactionMarker(with: data)
        guard try persistenceStore.readDecodedImportMarker().marker == marker else {
            throw PersistenceError.readBackVerificationFailed(
                path: persistenceStore.transactionMarkerURL.path
            )
        }
    }

    private func recoverInterruptedImport(
        hadPrimary: Bool,
        previousProgress: PlayerProgress?
    ) throws {
        if hadPrimary {
            var currentMatchesPersistedProgress = false
            let expectedProgress = previousProgress ?? lastPersistedProgress
            do {
                guard let currentData = try persistenceStore.readPrimary() else {
                    throw PersistenceError.readBackVerificationFailed(
                        path: persistenceStore.primaryURL.path
                    )
                }
                let current = try PersistenceDocumentCodec.decode(
                    PlayerProgress.self,
                    from: currentData,
                    path: persistenceStore.primaryURL.path
                )
                currentMatchesPersistedProgress = current.payload == expectedProgress
            } catch {
                currentMatchesPersistedProgress = false
            }
            if !currentMatchesPersistedProgress {
                _ = try Self.restoreProgressBackupAndVerify(
                    from: persistenceStore,
                    expectedProgress: previousProgress
                )
            }
        } else {
            try persistenceStore.removePrimary()
        }
        try persistenceStore.removeTransactionMarker()
    }

    private static func restoreProgressBackupAndVerify(
        from store: any QuizEnginePersistenceStore,
        expectedProgress: PlayerProgress? = nil
    ) throws -> DecodedPersistence<PlayerProgress> {
        guard let backupData = try store.readBackup() else {
            throw PersistenceError.backupUnavailable(path: store.backupURL.path)
        }
        let backup = try PersistenceDocumentCodec.decode(
            PlayerProgress.self,
            from: backupData,
            path: store.backupURL.path
        )
        if let expectedProgress, backup.payload != expectedProgress {
            throw PersistenceError.backupRecoveryFailed(
                path: store.backupURL.path,
                reason: "The backup does not match the interrupted transaction's previous progress."
            )
        }
        try store.restoreBackup()
        guard let restoredData = try store.readPrimary() else {
            throw PersistenceError.readBackVerificationFailed(path: store.primaryURL.path)
        }
        let restored = try PersistenceDocumentCodec.decode(
            PlayerProgress.self,
            from: restoredData,
            path: store.primaryURL.path
        )
        if restored.payload != backup.payload {
            throw PersistenceError.backupRecoveryFailed(
                path: store.backupURL.path,
                reason: "The restored primary does not match the backup."
            )
        }
        return restored
    }

    private static func load(
        from store: any QuizEnginePersistenceStore,
        freshProgress: PlayerProgress
    ) -> PlayerProgressLoadResult {
        do {
            return try store.withExclusiveAccess {
                loadUnlocked(from: store, freshProgress: freshProgress)
            }
        } catch let error as PersistenceError {
            return PlayerProgressLoadResult(
                progress: freshProgress,
                status: .failed(error),
                error: error
            )
        } catch {
            let persistenceError = PersistenceError.readFailed(
                path: store.primaryURL.path,
                reason: error.localizedDescription
            )
            return PlayerProgressLoadResult(
                progress: freshProgress,
                status: .failed(persistenceError),
                error: persistenceError
            )
        }
    }

    private static func loadUnlocked(
        from store: any QuizEnginePersistenceStore,
        freshProgress: PlayerProgress
    ) -> PlayerProgressLoadResult {
        var recoveryStatus: PersistenceStatus?

        do {
            func validateCompletedMarker(_ marker: ImportMarker, against progress: PlayerProgress) throws {
                guard let targetProgress = marker.targetProgress else {
                    throw PersistenceError.malformedImportMarker(
                        path: store.transactionMarkerURL.path
                    )
                }
                if let previousProgress = marker.previousProgress,
                   previousProgress != targetProgress,
                   progress == previousProgress {
                    throw PersistenceError.readBackVerificationFailed(
                        path: store.primaryURL.path
                    )
                }
            }

            func recoverFromBackup(_ backupData: Data) throws -> PlayerProgressLoadResult {
                let backup = try PersistenceDocumentCodec.decode(
                    PlayerProgress.self,
                    from: backupData,
                    path: store.backupURL.path
                )
                try store.restoreBackup()
                guard let restoredData = try store.readPrimary(),
                      let restored = try? PersistenceDocumentCodec.decode(
                          PlayerProgress.self,
                          from: restoredData,
                          path: store.primaryURL.path
                      ),
                      restored.payload == backup.payload else {
                    throw PersistenceError.readBackVerificationFailed(
                        path: store.primaryURL.path
                    )
                }
                return PlayerProgressLoadResult(
                    progress: backup.payload,
                    status: .recoveredFromBackup(schemaVersion: backup.schemaVersion),
                    error: nil
                )
            }

            let importMarker = try store.readDecodedImportMarker().marker
            if let marker = importMarker, marker.state == .pending {
                if marker.hadPrimary {
                    let shouldRestoreBackup: Bool
                    if let previousProgress = marker.previousProgress {
                        var currentMatchesPrevious = false
                        do {
                            guard let currentData = try store.readPrimary() else {
                                throw PersistenceError.readBackVerificationFailed(
                                    path: store.primaryURL.path
                                )
                            }
                            let current = try PersistenceDocumentCodec.decode(
                                PlayerProgress.self,
                                from: currentData,
                                path: store.primaryURL.path
                            )
                            currentMatchesPrevious = current.payload == previousProgress
                        } catch {
                            currentMatchesPrevious = false
                        }
                        shouldRestoreBackup = !currentMatchesPrevious
                    } else if let targetProgress = marker.targetProgress {
                        var currentMatchesTarget = false
                        do {
                            guard let currentData = try store.readPrimary() else {
                                throw PersistenceError.readBackVerificationFailed(
                                    path: store.primaryURL.path
                                )
                            }
                            let current = try PersistenceDocumentCodec.decode(
                                PlayerProgress.self,
                                from: currentData,
                                path: store.primaryURL.path
                            )
                            currentMatchesTarget = current.payload == targetProgress
                        } catch {
                            currentMatchesTarget = true
                        }
                        shouldRestoreBackup = currentMatchesTarget
                    } else {
                        shouldRestoreBackup = true
                    }
                    if shouldRestoreBackup {
                        _ = try restoreProgressBackupAndVerify(
                            from: store,
                            expectedProgress: marker.previousProgress
                        )
                    }
                } else {
                    try store.removePrimary()
                }
                try store.removeTransactionMarker()
                recoveryStatus = .recoveredInterruptedImport
            }

            if let marker = importMarker, marker.state == .completed {
                guard marker.targetProgress != nil else {
                    throw PersistenceError.malformedImportMarker(
                        path: store.transactionMarkerURL.path
                    )
                }
            }

            guard let data = try store.readPrimary() else {
                if importMarker?.state == .completed {
                    throw PersistenceError.readBackVerificationFailed(
                        path: store.primaryURL.path
                    )
                }
                return PlayerProgressLoadResult(
                    progress: freshProgress,
                    status: recoveryStatus ?? .fresh,
                    error: nil
                )
            }

            do {
                let decoded = try PersistenceDocumentCodec.decode(
                    PlayerProgress.self,
                    from: data,
                    path: store.primaryURL.path
                )
                if let marker = importMarker, marker.state == .completed {
                    try validateCompletedMarker(marker, against: decoded.payload)
                }
                return PlayerProgressLoadResult(
                    progress: decoded.payload,
                    status: recoveryStatus ?? (decoded.isLegacy ? .loadedLegacy : .loaded(schemaVersion: decoded.schemaVersion)),
                    error: nil
                )
            } catch {
                guard let backupData = try store.readBackup() else {
                    throw error
                }

                do {
                    let recovered = try recoverFromBackup(backupData)
                    if let marker = importMarker, marker.state == .completed {
                        try validateCompletedMarker(marker, against: recovered.progress)
                    }
                    return recovered
                } catch let recoveryError as PersistenceError {
                    throw PersistenceError.backupRecoveryFailed(
                        path: store.backupURL.path,
                        reason: recoveryError.localizedDescription
                    )
                }
            }
        } catch let error as PersistenceError {
            return PlayerProgressLoadResult(
                progress: freshProgress,
                status: .failed(error),
                error: error
            )
        } catch {
            let persistenceError = PersistenceError.readFailed(
                path: store.primaryURL.path,
                reason: error.localizedDescription
            )
            return PlayerProgressLoadResult(
                progress: freshProgress,
                status: .failed(persistenceError),
                error: persistenceError
            )
        }
    }

    // MARK: - Coin Operations

    public func addCoins(_ amount: Int) {
        guard amount >= 0 else { return }
        let (coins, coinsOverflow) = progress.coins.addingReportingOverflow(amount)
        let (total, totalOverflow) = progress.totalCoinsEarned.addingReportingOverflow(amount)
        guard !coinsOverflow, !totalOverflow else { return }
        progress.coins = coins
        progress.totalCoinsEarned = total
        save()
    }

    public func spendCoins(_ amount: Int) -> Bool {
        guard amount >= 0, progress.coins >= amount else {
            return false
        }
        let (newTotalCoinsSpent, overflow) = progress.totalCoinsSpent.addingReportingOverflow(amount)
        guard !overflow else { return false }
        progress.coins -= amount
        progress.totalCoinsSpent = newTotalCoinsSpent
        return save()
    }

    public func canAfford(_ amount: Int) -> Bool {
        amount >= 0 && progress.coins >= amount
    }

    // MARK: - Power-Up Wallet

    /// Returns the number of free activations available for a power-up.
    public func powerUpCredits(for powerUp: PowerUp) -> Int {
        progress.powerUpCredits[powerUp] ?? 0
    }

    /// Adds free activations without changing the coin balance.
    @discardableResult
    public func grantPowerUpCredits(_ amount: Int, for powerUp: PowerUp) -> Bool {
        guard amount > 0 else { return false }
        let currentBalance = powerUpCredits(for: powerUp)
        guard currentBalance >= 0 else { return false }
        let (newBalance, overflow) = currentBalance.addingReportingOverflow(amount)
        guard !overflow else { return false }

        progress.powerUpCredits[powerUp] = newBalance
        return save()
    }

    /// Returns whether a free credit or the package-defined coin cost can fund the power-up.
    public func canFundPowerUp(_ powerUp: PowerUp) -> Bool {
        let creditBalance = powerUpCredits(for: powerUp)
        let usageCount = progress.lifetimePowerUpsUsed ?? 0
        guard creditBalance >= 0, usageCount >= 0, usageCount < Int.max else {
            return false
        }
        if creditBalance > 0 {
            return true
        }
        let cost = powerUpCost(for: powerUp)
        guard progress.coins >= cost else { return false }
        return !progress.totalCoinsSpent.addingReportingOverflow(cost).overflow
    }

    /// Consumes a free credit before coins and persists funding and usage as one transaction.
    @discardableResult
    public func consumePowerUp(_ powerUp: PowerUp) -> PowerUpSpendResult? {
        let result: PowerUpSpendResult
        let creditBalance = powerUpCredits(for: powerUp)
        let usageCount = progress.lifetimePowerUpsUsed ?? 0
        let (newUsageCount, usageOverflow) = usageCount.addingReportingOverflow(1)
        guard usageCount >= 0, !usageOverflow else { return nil }

        if creditBalance > 0 {
            progress.powerUpCredits[powerUp] = creditBalance - 1
            result = PowerUpSpendResult(
                powerUp: powerUp,
                fundingSource: .freeCredit,
                coinsSpent: 0
            )
        } else {
            let cost = powerUpCost(for: powerUp)
            guard creditBalance == 0, progress.coins >= cost else {
                return nil
            }
            let (newTotalCoinsSpent, spendingOverflow) = progress.totalCoinsSpent.addingReportingOverflow(cost)
            guard !spendingOverflow else { return nil }
            progress.coins -= cost
            progress.totalCoinsSpent = newTotalCoinsSpent
            result = PowerUpSpendResult(
                powerUp: powerUp,
                fundingSource: .coins,
                coinsSpent: cost
            )
        }

        recordPowerUpUsage(powerUp, newUsageCount: newUsageCount)
        guard save() else { return nil }
        return result
    }

    public func powerUpCost(for powerUp: PowerUp) -> Int {
        variant.rules.powerUps.rule(for: powerUp)?.coinCost ?? powerUp.cost
    }

    /// Compatibility marker for consumers that awarded Premium coins separately.
    ///
    /// This does not award coins. New code must use `claimPremiumBonus(_:)` so the
    /// entitlement, balance, total earned, claim identity, and receipt share one save.
    @available(*, deprecated, message: "Use claimPremiumBonus(_:) for an atomic Premium award.")
    public func markPremiumBonusCoinsReceived() {
        guard !progress.hasReceivedPremiumBonusCoins else { return }
        let snapshot = progress
        progress.hasReceivedPremiumBonusCoins = true
        progress.premiumBonusClaimedVersion = PlayerProgress.legacyPremiumBonusClaimIdentity
        progress.premiumBonusClaimedFingerprint = PlayerProgress.legacyPremiumBonusClaimIdentity
        guard save() else {
            progress = snapshot
            return
        }
    }

    /// Atomically applies the app-owned Premium bonus after entitlement resolution.
    @discardableResult
    public func claimPremiumBonus(
        _ request: PremiumBonusClaimRequest
    ) -> RewardTransactionOutcome {
        guard validRewardText(request.receiptID),
              validRewardText(request.rewardVersion),
              request.coinAmount > 0 else {
            return .rejected
        }

        let fingerprint = Self.rewardFingerprint(
            kind: .premiumBonusCoins,
            amount: request.coinAmount,
            version: request.rewardVersion
        )
        if let existing = rewardReceiptOutcome(
            receiptID: request.receiptID,
            fingerprint: fingerprint
        ) {
            return existing
        }

        if let claimedFingerprint = progress.premiumBonusClaimedFingerprint,
           let claimedVersion = progress.premiumBonusClaimedVersion {
            if claimedVersion == PlayerProgress.legacyPremiumBonusClaimIdentity,
               claimedFingerprint == PlayerProgress.legacyPremiumBonusClaimIdentity {
                return .ineligible
            }
            return claimedFingerprint == fingerprint && claimedVersion == request.rewardVersion
                ? .alreadyRecorded
                : .conflictingReceipt
        }
        guard !progress.hasReceivedPremiumBonusCoins else { return .ineligible }
        guard request.isEntitled else { return .ineligible }

        let snapshot = progress
        let (coins, coinsOverflow) = progress.coins.addingReportingOverflow(request.coinAmount)
        let (total, totalOverflow) = progress.totalCoinsEarned.addingReportingOverflow(request.coinAmount)
        guard !coinsOverflow, !totalOverflow else { return .rejected }

        progress.coins = coins
        progress.totalCoinsEarned = total
        progress.hasReceivedPremiumBonusCoins = true
        progress.premiumBonusClaimedVersion = request.rewardVersion
        progress.premiumBonusClaimedFingerprint = fingerprint
        appendRewardReceipt(
            RewardReceipt(
                receiptID: request.receiptID,
                kind: .premiumBonusCoins,
                fingerprint: fingerprint,
                recordedAt: clock.now
            )
        )

        guard save() else {
            progress = snapshot
            return rewardPersistenceFailure(
                reason: "The Premium bonus transaction was not persisted."
            )
        }
        return .recorded
    }

    // MARK: - Streak Operations

    public func handleAppOpen() {
        let now = clock.now
        progress.updateStreakOnAppOpen(now: now, calendar: calendar)
        save()
    }

    public func claimDailyReward() -> Int? {
        let now = clock.now
        guard progress.canClaimDailyReward(calendar: calendar, now: now) else {
            return nil
        }

        let rewardAmount = progress.dailyRewardAmount(using: variant.rules.economy.dailyRewardTiers)
        let streakDay = progress.currentStreak

        let (coins, coinsOverflow) = progress.coins.addingReportingOverflow(rewardAmount)
        let (total, totalOverflow) = progress.totalCoinsEarned.addingReportingOverflow(rewardAmount)
        guard !coinsOverflow, !totalOverflow else { return nil }
        progress.coins = coins
        progress.totalCoinsEarned = total
        progress.lastDailyRewardClaimedDate = now
        guard save() else {
            return nil
        }

        // Log analytics event
        analytics?.logDailyRewardClaimed(streakDay: streakDay, amount: rewardAmount)

        return rewardAmount
    }

    public func shouldShowDailyReward() -> Bool {
        let now = clock.now
        return progress.canClaimDailyReward(calendar: calendar, now: now)
    }

    #if DEBUG
    // MARK: - Debug Helpers

    /// Sets the current streak to a specific value for testing purposes.
    /// Only available in DEBUG builds.
    /// - Parameter streak: The streak value to set (will be clamped to >= 0)
    public func debugSetStreak(_ streak: Int) {
        progress.currentStreak = max(0, streak)
        // Also reset the claim date so we can test claiming
        progress.lastDailyRewardClaimedDate = nil
        save()
    }

    /// Resets the daily reward claim status so it can be claimed again.
    /// Only available in DEBUG builds.
    public func debugResetDailyRewardClaim() {
        progress.lastDailyRewardClaimedDate = nil
        save()
    }
    #endif

    // MARK: - Category Progress Tracking

    /// Records a correct answer for category progress
    public func recordCorrectAnswer(questionID: Int, category: String) {
        var stat = progress.categoryStats[category] ?? CategoryStat()

        stat.questionsAnswered += 1
        stat.questionsCorrect += 1
        stat.correctlyAnsweredIDs.insert(questionID)

        progress.categoryStats[category] = stat
        progress.seenQuestionIDs.insert(questionID)

        save()
    }

    /// Records a wrong answer for category progress
    public func recordWrongAnswer(questionID: Int, category: String) {
        var stat = progress.categoryStats[category] ?? CategoryStat()

        stat.questionsAnswered += 1
        // Don't increment questionsCorrect
        // Don't add to correctlyAnsweredIDs

        progress.categoryStats[category] = stat
        progress.seenQuestionIDs.insert(questionID)

        save()
    }

    /// Records the total question count when the user achieves 100% in a category.
    /// Looks up the real category total itself, so it works correctly in both
    /// category mode and practice mode with variant-configured session sizes.
    public func markCategoryHundredPercent(category: String) {
        guard var stat = progress.categoryStats[category],
              let totalQuestions = try? questionDataService.getQuestionCount(forCategory: category)
        else { return }
        guard stat.correctlyAnsweredIDs.count >= totalQuestions else { return }
        stat.questionsCountAtHundredPercent = totalQuestions
        progress.categoryStats[category] = stat
        save()
    }

    /// Updates best score for a category
    public func updateBestScore(category: String, sessionScore: Int) {
        var stat = progress.categoryStats[category] ?? CategoryStat()

        if sessionScore > stat.bestScore {
            stat.bestScore = sessionScore
            progress.categoryStats[category] = stat
            save()
        }
    }

    /// Get category statistics
    public func getCategoryStat(for category: String) -> CategoryStat? {
        return progress.categoryStats[category]
    }

    // MARK: - Session Statistics Tracking

    /// Updates the play streak (consecutive days with a completed game).
    /// Called at end of each competitive game session.
    /// Separate from the app-open streak which drives daily rewards.
    public func updatePlayStreak() {
        let today = clock.now

        guard let lastPlayed = progress.lastPlayedDate else {
            // First game ever
            progress.currentPlayStreak = 1
            progress.longestPlayStreak = 1
            progress.lastPlayedDate = today
            save()
            return
        }

        guard today >= lastPlayed else { return }

        if calendar.isDate(lastPlayed, inSameDayAs: today) {
            // Already played today, no change
            return
        }

        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)
        if let yesterday, calendar.isDate(lastPlayed, inSameDayAs: yesterday) {
            // Consecutive day — increment
            progress.currentPlayStreak += 1
        } else {
            // Missed a day — reset
            progress.currentPlayStreak = 1
        }

        if progress.currentPlayStreak > progress.longestPlayStreak {
            progress.longestPlayStreak = progress.currentPlayStreak
        }

        progress.lastPlayedDate = today
        save()
    }

    /// Records end-of-session statistics for achievement evaluation
    /// - Parameters:
    ///   - questionsAnswered: Number of questions answered in the session
    ///   - questionsCorrect: Number of questions answered correctly
    ///   - sessionScore: Final score for the session
    ///   - longestStreak: Longest consecutive correct answers during session
    ///   - usedPowerUps: Set of power-ups used during the session
    public func recordSessionStats(
        questionsAnswered: Int,
        questionsCorrect: Int,
        sessionScore: Int,
        longestStreak: Int,
        usedPowerUps: Set<PowerUp>
    ) {
        progress.lifetimeGamesPlayed += 1
        progress.lifetimeQuestionsAnswered += questionsAnswered
        progress.lifetimeQuestionsCorrect += questionsCorrect

        // Update global bests
        if sessionScore > progress.bestSingleSessionScore {
            progress.bestSingleSessionScore = sessionScore
        }

        if longestStreak > progress.bestSingleSessionStreak {
            progress.bestSingleSessionStreak = longestStreak
        }

        // Track power-up types used
        for powerUp in usedPowerUps {
            let key: String
            switch powerUp {
            case .fiftyFifty:
                key = "fiftyFifty"
            case .skipQuestion:
                key = "skipQuestion"
            case .timeFreeze:
                key = "timeFreeze"
            case .streakShield:
                key = "streakShield"
            }
            progress.powerUpTypesUsed.insert(key)
        }

        save()
    }

    /// Records that a power-up was used (called when power-up is activated)
    /// - Parameter powerUp: The power-up that was used
    public func recordPowerUpUsed(_ powerUp: PowerUp) {
        let usageCount = progress.lifetimePowerUpsUsed ?? 0
        let (newUsageCount, overflow) = usageCount.addingReportingOverflow(1)
        guard usageCount >= 0, !overflow else { return }
        recordPowerUpUsage(powerUp, newUsageCount: newUsageCount)
        save()
    }

    private func recordPowerUpUsage(_ powerUp: PowerUp, newUsageCount: Int) {
        progress.powerUpTypesUsed.insert(powerUp.rawValue)
        progress.lifetimePowerUpsUsed = newUsageCount
    }

    // MARK: - Multiplayer Result Recording

    /// Records the result of a multiplayer match and updates stats.
    /// - Parameters:
    ///   - won: True if player won, false if lost (ignored if draw)
    ///   - draw: True if the match ended in a draw
    ///   - score: Player's final score
    ///   - questionsCompleted: Number of questions completed in the match
    ///   - coinsEarned: Total coins earned (per-question + bonus)
    ///   - responseTimes: Array of response times in ms for each answered question
    public func recordMultiplayerResult(
        won: Bool,
        draw: Bool,
        score: Int,
        questionsCompleted: Int,
        questionsCorrect: Int,
        coinsEarned: Int,
        responseTimes: [Int]
    ) {
        guard coinsEarned >= 0 else { return }
        let (newCoins, coinsOverflow) = progress.coins.addingReportingOverflow(coinsEarned)
        let (newTotalCoinsEarned, totalCoinsOverflow) = progress.totalCoinsEarned.addingReportingOverflow(coinsEarned)
        guard !coinsOverflow, !totalCoinsOverflow else { return }

        progress.multiplayerGamesPlayed += 1

        if draw {
            progress.multiplayerGamesDraw += 1
            progress.multiplayerWinStreak = 0
        } else if won {
            progress.multiplayerGamesWon += 1
            progress.multiplayerWinStreak += 1
            if progress.multiplayerWinStreak > progress.longestMultiplayerWinStreak {
                progress.longestMultiplayerWinStreak = progress.multiplayerWinStreak
            }
        } else {
            progress.multiplayerGamesLost += 1
            progress.multiplayerWinStreak = 0
        }

        if score > progress.bestMultiplayerScore {
            progress.bestMultiplayerScore = score
        }

        let totalMs = responseTimes.reduce(0, +)
        progress.multiplayerTotalResponseTimeMs += totalMs
        progress.multiplayerTotalQuestionsAnswered += questionsCompleted
        progress.multiplayerTotalQuestionsCorrect += questionsCorrect

        progress.coins = newCoins
        progress.totalCoinsEarned = newTotalCoinsEarned
        save()
    }

    /// Records a multiplayer result once for a stable match identifier.
    ///
    /// The receipt and every statistic/reward mutation are persisted by the
    /// same transaction. A repeated identical terminal callback is therefore
    /// harmless even after the process is recreated.
    @discardableResult
    public func recordMultiplayerResult(
        matchID: String,
        fingerprint: String,
        won: Bool,
        draw: Bool,
        score: Int,
        questionsCompleted: Int,
        questionsCorrect: Int,
        coinsEarned: Int,
        responseTimes: [Int]
    ) -> MultiplayerResultRecordingOutcome {
        guard !matchID.isEmpty,
              !fingerprint.isEmpty,
              questionsCompleted >= 0,
              questionsCorrect >= 0,
              questionsCorrect <= questionsCompleted,
              coinsEarned >= 0,
              responseTimes.allSatisfy({ $0 >= 0 }) else {
            return .rejected
        }

        if let receipt = progress.multiplayerMatchReceipts.first(where: { $0.matchID == matchID }) {
            return receipt.fingerprint == fingerprint ? .alreadyRecorded : .conflictingReceipt
        }

        let snapshot = progress
        let totalResponseTime = responseTimes.reduce(into: 0) { partial, value in
            let (next, overflow) = partial.addingReportingOverflow(value)
            partial = overflow ? Int.max : next
        }
        guard totalResponseTime != Int.max else { return .rejected }

        let values = [
            progress.multiplayerGamesPlayed,
            progress.multiplayerGamesWon,
            progress.multiplayerGamesLost,
            progress.multiplayerGamesDraw,
            progress.multiplayerWinStreak,
            progress.multiplayerTotalResponseTimeMs,
            progress.multiplayerTotalQuestionsAnswered,
            progress.multiplayerTotalQuestionsCorrect
        ]
        guard values.allSatisfy({ $0 >= 0 }) else { return .rejected }

        let (newCoins, coinsOverflow) = progress.coins.addingReportingOverflow(coinsEarned)
        let (newTotalCoinsEarned, earnedOverflow) = progress.totalCoinsEarned.addingReportingOverflow(coinsEarned)
        let (newGamesPlayed, gamesOverflow) = progress.multiplayerGamesPlayed.addingReportingOverflow(1)
        let (newResponseTime, responseOverflow) = progress.multiplayerTotalResponseTimeMs.addingReportingOverflow(totalResponseTime)
        let (newQuestionsAnswered, answeredOverflow) = progress.multiplayerTotalQuestionsAnswered.addingReportingOverflow(questionsCompleted)
        let (newQuestionsCorrect, correctOverflow) = progress.multiplayerTotalQuestionsCorrect.addingReportingOverflow(questionsCorrect)
        guard !coinsOverflow, !earnedOverflow, !gamesOverflow, !responseOverflow, !answeredOverflow, !correctOverflow else {
            return .rejected
        }

        progress.multiplayerGamesPlayed = newGamesPlayed
        if draw {
            let (next, overflow) = progress.multiplayerGamesDraw.addingReportingOverflow(1)
            guard !overflow else { progress = snapshot; return .rejected }
            progress.multiplayerGamesDraw = next
            progress.multiplayerWinStreak = 0
        } else if won {
            let (wins, winsOverflow) = progress.multiplayerGamesWon.addingReportingOverflow(1)
            let (streak, streakOverflow) = progress.multiplayerWinStreak.addingReportingOverflow(1)
            guard !winsOverflow, !streakOverflow else { progress = snapshot; return .rejected }
            progress.multiplayerGamesWon = wins
            progress.multiplayerWinStreak = streak
            progress.longestMultiplayerWinStreak = max(progress.longestMultiplayerWinStreak, streak)
        } else {
            let (losses, overflow) = progress.multiplayerGamesLost.addingReportingOverflow(1)
            guard !overflow else { progress = snapshot; return .rejected }
            progress.multiplayerGamesLost = losses
            progress.multiplayerWinStreak = 0
        }

        progress.bestMultiplayerScore = max(progress.bestMultiplayerScore, score)
        progress.multiplayerTotalResponseTimeMs = newResponseTime
        progress.multiplayerTotalQuestionsAnswered = newQuestionsAnswered
        progress.multiplayerTotalQuestionsCorrect = newQuestionsCorrect
        progress.coins = newCoins
        progress.totalCoinsEarned = newTotalCoinsEarned
        progress.multiplayerMatchReceipts.append(.init(matchID: matchID, fingerprint: fingerprint))
        if progress.multiplayerMatchReceipts.count > 256 {
            progress.multiplayerMatchReceipts.removeFirst(progress.multiplayerMatchReceipts.count - 256)
        }

        guard save() else {
            progress = snapshot
            return .persistenceFailed(
                lastPersistenceError ?? .writeFailed(
                    path: persistenceStore.primaryURL.path,
                    reason: "The multiplayer result transaction was not persisted."
                )
            )
        }
        return .recorded
    }

    // MARK: - Question Seen Tracking

    /// Records that a question was shown to the user (for content freshness tracking)
    /// - Parameter questionID: The ID of the question that was shown
    public func recordQuestionSeen(questionID: Int) {
        guard !progress.seenQuestionIDs.contains(questionID) else { return }
        progress.seenQuestionIDs.insert(questionID)
        save()
    }

    /// Get count of seen questions for a category
    /// - Parameters:
    ///   - category: Category to filter by (nil = all categories)
    ///   - allQuestions: All questions to search within
    /// - Returns: Number of questions in the category that have been seen
    public func getSeenCount(forCategory category: String?, allQuestions: [Question]) -> Int {
        let categoryQuestions: [Question]
        if let category = category {
            categoryQuestions = allQuestions.filter { $0.categories.contains(category) }
        } else {
            categoryQuestions = allQuestions
        }
        return categoryQuestions.filter { progress.seenQuestionIDs.contains($0.id) }.count
    }

    /// Checks for newly unlocked achievements and updates progress
    /// Call this after recording session stats or other progress updates
    public func checkAndUnlockAchievements() {
        let now = clock.now
        let unlocked = achievementService.checkAchievements(
            progress: progress,
            date: now,
            calendar: calendar
        )

        guard !unlocked.isEmpty else {
            newlyUnlockedAchievements = []
            return
        }

        // Unlock each achievement and award coins
        for achievement in unlocked {
            progress.unlockedAchievements.insert(achievement.id)
            progress.coins += achievement.coinReward
            progress.totalCoinsEarned += achievement.coinReward
        }

        guard save() else {
            newlyUnlockedAchievements = []
            return
        }

        // Log analytics events only after the durable write succeeds.
        for achievement in unlocked {
            analytics?.logAchievementUnlocked(
                achievementId: achievement.id,
                coinReward: achievement.coinReward
            )
        }

        // Publish newly unlocked for UI to display
        newlyUnlockedAchievements = unlocked
    }

    /// Clears the list of newly unlocked achievements (call after UI has shown them)
    public func clearNewlyUnlockedAchievements() {
        newlyUnlockedAchievements = []
    }

    // MARK: - Achievement Management

    /// Unlocks an achievement and awards coins
    /// - Parameters:
    ///   - id: Achievement ID
    ///   - coinReward: Number of coins to award
    /// - Returns: true if achievement was newly unlocked, false if already unlocked
    @discardableResult
    public func unlockAchievement(id: String, coinReward: Int) -> Bool {
        guard !progress.unlockedAchievements.contains(id) else {
            return false
        }

        progress.unlockedAchievements.insert(id)
        progress.coins += coinReward
        progress.totalCoinsEarned += coinReward

        return save()
    }

    /// Checks if an achievement is unlocked
    /// - Parameter id: Achievement ID
    /// - Returns: true if the achievement is unlocked
    public func isAchievementUnlocked(_ id: String) -> Bool {
        return progress.unlockedAchievements.contains(id)
    }

    /// Returns count of unlocked achievements
    public var unlockedAchievementCount: Int {
        progress.unlockedAchievements.count
    }

    // MARK: - Convenience Accessors

    public var coins: Int {
        progress.coins
    }

    public var currentStreak: Int {
        progress.currentStreak
    }

    public var longestStreak: Int {
        progress.longestStreak
    }

    public var dailyRewardAmount: Int {
        progress.dailyRewardAmount(using: variant.rules.economy.dailyRewardTiers)
    }

    // NOTE: streakColor was removed — it uses Color.Theme.accentBright which is app-specific.
    // It will be added back as an app-side extension.

    public var lifetimeGamesPlayed: Int {
        progress.lifetimeGamesPlayed
    }

    public var lifetimeQuestionsAnswered: Int {
        progress.lifetimeQuestionsAnswered
    }

    public var lifetimeQuestionsCorrect: Int {
        progress.lifetimeQuestionsCorrect
    }

    public var bestSingleSessionScore: Int {
        progress.bestSingleSessionScore
    }

    public var bestSingleSessionStreak: Int {
        progress.bestSingleSessionStreak
    }

    public var hasUsedAllPowerUpTypes: Bool {
        progress.powerUpTypesUsed.count == 4
    }

    // MARK: - Multiplayer Convenience Accessors

    public var multiplayerGamesPlayed: Int {
        progress.multiplayerGamesPlayed
    }

    public var multiplayerGamesWon: Int {
        progress.multiplayerGamesWon
    }

    public var multiplayerGamesLost: Int {
        progress.multiplayerGamesLost
    }

    public var multiplayerGamesDraw: Int {
        progress.multiplayerGamesDraw
    }

    public var bestMultiplayerScore: Int {
        progress.bestMultiplayerScore
    }

    public var multiplayerWinStreak: Int {
        progress.multiplayerWinStreak
    }

    public var longestMultiplayerWinStreak: Int {
        progress.longestMultiplayerWinStreak
    }

    public var multiplayerTotalQuestionsAnswered: Int {
        progress.multiplayerTotalQuestionsAnswered
    }

    public var multiplayerTotalQuestionsCorrect: Int {
        progress.multiplayerTotalQuestionsCorrect
    }

    public var multiplayerWinRate: Double {
        guard progress.multiplayerGamesPlayed > 0 else { return 0 }
        return Double(progress.multiplayerGamesWon) / Double(progress.multiplayerGamesPlayed) * 100
    }

    public var multiplayerAccuracy: Double {
        guard progress.multiplayerTotalQuestionsAnswered > 0 else { return 0 }
        return Double(progress.multiplayerTotalQuestionsCorrect) / Double(progress.multiplayerTotalQuestionsAnswered) * 100
    }

    public var multiplayerAverageResponseTimeSeconds: Double {
        guard progress.multiplayerTotalQuestionsAnswered > 0 else { return 0 }
        return Double(progress.multiplayerTotalResponseTimeMs) / Double(progress.multiplayerTotalQuestionsAnswered) / 1000.0
    }

    public var multiplayerHasData: Bool {
        progress.multiplayerGamesPlayed > 0
    }

    // MARK: - Reward Ad Tracking

    /// Checks if the user can watch a rewarded ad for coins.
    public func canWatchRewardAd() -> Bool {
        guard let lastWatched = progress.lastRewardAdWatchedDate else {
            return true
        }
        let now = clock.now
        let secondsSince = max(0, now.timeIntervalSince(lastWatched))
        return secondsSince >= variant.rules.economy.rewardAd.cooldownSeconds
    }

    /// Atomically records a provider-earned rewarded-ad callback.
    @discardableResult
    public func recordRewardedAdReward(
        _ request: RewardedAdRewardRequest
    ) -> RewardTransactionOutcome {
        guard validRewardText(request.receiptID),
              validRewardText(request.rewardVersion),
              request.coinAmount > 0 else {
            return .rejected
        }

        let fingerprint = Self.rewardFingerprint(
            kind: .rewardedAdCoins,
            amount: request.coinAmount,
            version: request.rewardVersion
        )
        if let existing = rewardReceiptOutcome(
            receiptID: request.receiptID,
            fingerprint: fingerprint
        ) {
            return existing
        }

        let configuredAmount = variant.rules.economy.rewardAd.coinReward
        guard request.coinAmount == configuredAmount else { return .rejected }
        guard canWatchRewardAd() else { return .ineligible }

        let snapshot = progress
        let now = clock.now
        let (coins, coinsOverflow) = progress.coins.addingReportingOverflow(configuredAmount)
        let (total, totalOverflow) = progress.totalCoinsEarned.addingReportingOverflow(configuredAmount)
        guard !coinsOverflow, !totalOverflow else { return .rejected }

        progress.coins = coins
        progress.totalCoinsEarned = total
        progress.lastRewardAdWatchedDate = now
        appendRewardReceipt(
            RewardReceipt(
                receiptID: request.receiptID,
                kind: .rewardedAdCoins,
                fingerprint: fingerprint,
                recordedAt: now
            )
        )

        guard save() else {
            progress = snapshot
            return rewardPersistenceFailure(
                reason: "The rewarded-ad transaction was not persisted."
            )
        }
        return .recorded
    }

    @available(*, deprecated, message: "Use recordRewardedAdReward(_:) with a stable receipt ID.")
    public func recordRewardAdWatched() {
        recordCompatibilityRewardAd(
            coinsAwarded: variant.rules.economy.rewardAd.coinReward
        )
    }

    /// Compatibility transaction without durable callback identity.
    ///
    /// It remains cooldown-gated and rollback-safe, but cannot provide durable
    /// callback idempotency. Shipping consumers must use the receipt-backed API.
    @available(*, deprecated, message: "Use recordRewardedAdReward(_:) with a stable receipt ID.")
    public func recordRewardAdWatched(coinsAwarded: Int) {
        recordCompatibilityRewardAd(coinsAwarded: coinsAwarded)
    }

    private func recordCompatibilityRewardAd(coinsAwarded: Int) {
        guard coinsAwarded >= 0, canWatchRewardAd() else { return }
        let snapshot = progress
        let now = clock.now
        let (coins, coinsOverflow) = progress.coins.addingReportingOverflow(coinsAwarded)
        let (total, totalOverflow) = progress.totalCoinsEarned.addingReportingOverflow(coinsAwarded)
        guard !coinsOverflow, !totalOverflow else { return }
        progress.lastRewardAdWatchedDate = now
        progress.coins = coins
        progress.totalCoinsEarned = total
        guard save() else {
            progress = snapshot
            return
        }
    }

    private func validRewardText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func rewardFingerprint(
        kind: RewardReceiptKind,
        amount: Int,
        version: String
    ) -> String {
        let kindValue = kind.rawValue
        return "kind:\(kindValue.utf8.count):\(kindValue)|amount:\(amount)|version:\(version.utf8.count):\(version)"
    }

    private func rewardReceiptOutcome(
        receiptID: String,
        fingerprint: String
    ) -> RewardTransactionOutcome? {
        guard let receipt = progress.rewardReceipts.first(where: { $0.receiptID == receiptID }) else {
            return nil
        }
        return receipt.fingerprint == fingerprint ? .alreadyRecorded : .conflictingReceipt
    }

    private func appendRewardReceipt(_ receipt: RewardReceipt) {
        progress.rewardReceipts.append(receipt)
        let overflow = progress.rewardReceipts.count - PlayerProgress.maximumRewardReceiptCount
        if overflow > 0 {
            progress.rewardReceipts.removeFirst(overflow)
        }
    }

    private func rewardPersistenceFailure(reason: String) -> RewardTransactionOutcome {
        .persistenceFailed(
            lastPersistenceError ?? .writeFailed(
                path: persistenceStore.primaryURL.path,
                reason: reason
            )
        )
    }

    /// Returns the time remaining until the next reward ad is available
    /// - Returns: TimeInterval in seconds, or nil if ad is available now
    public func timeUntilNextRewardAd() -> TimeInterval? {
        guard let lastWatched = progress.lastRewardAdWatchedDate else {
            return nil
        }
        let now = clock.now
        let secondsSince = max(0, now.timeIntervalSince(lastWatched))
        let cooldownSeconds = variant.rules.economy.rewardAd.cooldownSeconds
        let remaining = cooldownSeconds - secondsSince
        return remaining > 0 ? remaining : nil
    }

    // MARK: - Category Unlock System

    /// Checks if a category is unlocked (either free, earned, purchased, or Premium)
    /// - Parameter categoryID: The category identifier (lowercase English)
    /// - Returns: true if the category is playable
    public func isCategoryUnlocked(_ categoryID: String) -> Bool {
        let normalizedID = categoryID.lowercased()
        guard let requirement = variant.category(id: normalizedID)?.unlockRequirement else {
            return false
        }

        // Premium users have all categories unlocked
        if purchaseStatus?.isPremium ?? false {
            return true
        }

        // Check if manually unlocked (purchased with coins)
        if progress.manuallyUnlockedCategories.contains(normalizedID) {
            return true
        }

        return evaluateRequirement(requirement)
    }

    /// Gets the unlock progress for a category
    /// - Parameters:
    ///   - categoryID: The category identifier
    /// - Returns: UnlockProgress with current state and progress info
    public func getUnlockProgress(for categoryID: String) -> UnlockProgress {
        let normalizedID = categoryID.lowercased()

        guard let requirement = variant.category(id: normalizedID)?.unlockRequirement else {
            return UnlockProgress(
                isUnlocked: false,
                requirementDescription: "category_unlock_requirement.description.unlock",
                currentValue: 0,
                targetValue: 0,
                coinCost: nil
            )
        }

        // Already manually unlocked
        if progress.manuallyUnlockedCategories.contains(normalizedID) {
            return .unlocked()
        }

        // Free categories
        if case .free = requirement {
            return .free()
        }

        // Evaluate and return progress
        return buildUnlockProgress(for: requirement, categoryID: normalizedID)
    }

    /// Attempts to unlock a category with coins
    /// - Parameter categoryID: The category to unlock
    /// - Returns: true if unlock was successful, false if insufficient coins or no coin option
    @discardableResult
    public func unlockCategoryWithCoins(_ categoryID: String) -> Bool {
        let normalizedID = categoryID.lowercased()

        // Already unlocked?
        if isCategoryUnlocked(normalizedID) {
            return true
        }

        // Get coin cost
        guard let cost = variant.category(id: normalizedID)?.coinCost else {
            return false
        }

        guard progress.coins >= cost else {
            return false
        }

        progress.coins -= cost
        progress.totalCoinsSpent += cost
        progress.manuallyUnlockedCategories.insert(normalizedID)
        guard save() else {
            return false
        }

        // Log analytics event
        analytics?.logCategoryUnlocked(categoryId: normalizedID, coinsSpent: cost)

        return true
    }

    // MARK: - Private Unlock Evaluation Helpers

    /// Evaluates if a requirement is satisfied
    private func evaluateRequirement(_ requirement: UnlockRequirement) -> Bool {
        switch requirement {
        case .free:
            return true

        case .questionsCorrect(let count):
            return progress.lifetimeQuestionsCorrect >= count

        case .categoryCompletion(let categoryID, let percentage):
            guard let stat = progress.categoryStats[categoryID] else {
                return false
            }
            // Get total questions in the required category
            if let totalQuestions = try? questionDataService.getQuestionCount(forCategory: categoryID) {
                let completion = stat.completionPercentage(totalQuestions: totalQuestions)
                return completion >= percentage
            }
            return false

        case .coins:
            // Coin requirements are handled separately via unlockCategoryWithCoins
            return false

        case .anyOf(let options):
            // Return true if ANY non-coin requirement is met
            for option in options {
                if case .coins = option {
                    continue // Skip coin options in auto-evaluation
                }
                if evaluateRequirement(option) {
                    return true
                }
            }
            return false
        }
    }

    /// Builds unlock progress info for UI display
    private func buildUnlockProgress(for requirement: UnlockRequirement, categoryID: String) -> UnlockProgress {
        let coinCost = variant.category(id: categoryID)?.coinCost

        switch requirement {
        case .free:
            return .free()

        case .questionsCorrect(let count):
            return UnlockProgress(
                isUnlocked: progress.lifetimeQuestionsCorrect >= count,
                requirementDescription: "category_unlock_requirement.description.questions_correct",
                requirementValue: count,
                currentValue: progress.lifetimeQuestionsCorrect,
                targetValue: count,
                coinCost: coinCost
            )

        case .categoryCompletion(let requiredCategoryID, let percentage):
            let stat = progress.categoryStats[requiredCategoryID]
            let totalQuestions = (try? questionDataService.getQuestionCount(forCategory: requiredCategoryID)) ?? 0
            let currentCompletion = stat?.completionPercentage(totalQuestions: totalQuestions) ?? 0
            let currentCorrect = stat?.correctlyAnsweredIDs.count ?? 0
            let targetCorrect = Int(ceil(Double(totalQuestions) * percentage / 100.0))

            return UnlockProgress(
                isUnlocked: currentCompletion >= percentage,
                requirementDescription: "category_unlock_requirement.description.category_completion",
                requirementValue: Int(percentage),
                currentValue: currentCorrect,
                targetValue: targetCorrect,
                coinCost: coinCost
            )

        case .coins(let amount):
            return UnlockProgress(
                isUnlocked: false,
                requirementDescription: "category_unlock_requirement.description.coins",
                requirementValue: amount,
                currentValue: 0,
                targetValue: 0,
                coinCost: amount
            )

        case .anyOf(let options):
            // Find the primary (non-coin) requirement to show progress
            for option in options {
                if case .coins = option {
                    continue
                }
                let progress = buildUnlockProgress(for: option, categoryID: categoryID)
                // Override coin cost from the anyOf options
                return UnlockProgress(
                    isUnlocked: progress.isUnlocked,
                    requirementDescription: progress.requirementDescription,
                    requirementValue: progress.requirementValue,
                    currentValue: progress.currentValue,
                    targetValue: progress.targetValue,
                    coinCost: coinCost
                )
            }

            // Fallback if only coin option exists
            return UnlockProgress(
                isUnlocked: false,
                requirementDescription: "category_unlock_requirement.description.unlock",
                currentValue: 0,
                targetValue: 0,
                coinCost: coinCost
            )
        }
    }

    // MARK: - Advanced Statistics

    /// Session statistics collected during gameplay for end-of-session recording
    public struct SessionStatistics: Sendable {
        public var questionsAnswered: Int
        public var questionsCorrect: Int
        public var totalResponseTimeMs: Int
        public var questionsByDifficulty: [QuestionDifficulty: Int]
        public var correctByDifficulty: [QuestionDifficulty: Int]
        public var sessionHour: Int

        public init(calendar: Calendar = .current, now: Date = Date()) {
            self.questionsAnswered = 0
            self.questionsCorrect = 0
            self.totalResponseTimeMs = 0
            self.questionsByDifficulty = [:]
            self.correctByDifficulty = [:]
            self.sessionHour = calendar.component(.hour, from: now)
        }

        public init(clock: any QuizEngineClock, calendar: Calendar) {
            self.init(calendar: calendar, now: clock.now)
        }
    }

    /// Records detailed session statistics at end of game
    /// - Parameter sessionStats: Aggregated statistics from the game session
    public func recordAdvancedSessionStats(_ sessionStats: SessionStatistics) {
        let now = clock.now
        let todayKey = PlayerProgress.dateKey(for: now, calendar: calendar)

        // Update or create daily stat
        var dailyStat = progress.dailyStats[todayKey] ?? DailyStat()
        dailyStat.questionsAnswered += sessionStats.questionsAnswered
        dailyStat.questionsCorrect += sessionStats.questionsCorrect
        dailyStat.gamesPlayed += 1
        dailyStat.totalResponseTimeMs += sessionStats.totalResponseTimeMs

        // Merge difficulty stats
        for (difficulty, count) in sessionStats.questionsByDifficulty {
            let key = String(difficulty.rawValue)
            dailyStat.questionsByDifficulty[key, default: 0] += count
        }
        for (difficulty, count) in sessionStats.correctByDifficulty {
            let key = String(difficulty.rawValue)
            dailyStat.correctByDifficulty[key, default: 0] += count
        }

        progress.dailyStats[todayKey] = dailyStat

        // Update hourly performance
        let hour = sessionStats.sessionHour
        var hourlyPerf = progress.hourlyPerformance[hour] ?? HourlyPerformance()
        hourlyPerf.questionsAnswered += sessionStats.questionsAnswered
        hourlyPerf.questionsCorrect += sessionStats.questionsCorrect
        hourlyPerf.sessionCount += 1
        progress.hourlyPerformance[hour] = hourlyPerf

        // Update lifetime average response time (incremental average)
        if sessionStats.questionsAnswered > 0 {
            let totalSamples = progress.lifetimeResponseTimeSamples + sessionStats.questionsAnswered
            let currentTotal = progress.lifetimeAverageResponseTimeMs * progress.lifetimeResponseTimeSamples
            let newTotal = currentTotal + sessionStats.totalResponseTimeMs
            progress.lifetimeAverageResponseTimeMs = totalSamples > 0 ? newTotal / totalSamples : 0
            progress.lifetimeResponseTimeSamples = totalSamples
        }

        // Cleanup old daily stats (keep 30 days)
        cleanupOldDailyStats(now: now)

        save()
    }

    /// Removes daily stats older than 30 days
    private func cleanupOldDailyStats(now: Date) {
        let cutoffDate = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let cutoffKey = PlayerProgress.dateKey(for: cutoffDate, calendar: calendar)

        progress.dailyStats = progress.dailyStats.filter { key, _ in
            key >= cutoffKey
        }
    }

    // MARK: - Advanced Statistics Computed Properties

    /// Returns daily stats for the last N days, sorted by date
    /// - Parameter days: Number of days to retrieve (default 7)
    /// - Returns: Array of (dateKey, DailyStat) tuples, oldest first
    public func getDailyStats(forLastDays days: Int = 7) -> [(date: String, stat: DailyStat)] {
        var result: [(String, DailyStat)] = []
        let now = clock.now

        for dayOffset in (0..<days).reversed() {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let key = PlayerProgress.dateKey(for: date, calendar: calendar)
            let stat = progress.dailyStats[key] ?? DailyStat()
            result.append((key, stat))
        }

        return result
    }

    /// Returns accuracy trend for the last N days
    /// - Parameter days: Number of days (default 7)
    /// - Returns: Array of accuracy percentages (0-100), oldest first
    public func getAccuracyTrend(forLastDays days: Int = 7) -> [Double] {
        getDailyStats(forLastDays: days).map { $0.stat.accuracy }
    }

    /// Returns the best performing hour(s) of day based on accuracy
    /// - Returns: Tuple with best hour (0-23) and accuracy, or nil if no data
    public func getBestPerformingHour() -> (hour: Int, accuracy: Double)? {
        let validHours = progress.hourlyPerformance.filter { $0.value.questionsAnswered >= 5 }
        guard !validHours.isEmpty else { return nil }

        let best = validHours.max { $0.value.accuracy < $1.value.accuracy }
        guard let bestEntry = best else { return nil }

        return (bestEntry.key, bestEntry.value.accuracy)
    }

    /// Returns the most active hour(s) of day based on session count
    /// - Returns: Tuple with most active hour (0-23) and session count, or nil if no data
    public func getMostActiveHour() -> (hour: Int, sessions: Int)? {
        guard !progress.hourlyPerformance.isEmpty else { return nil }

        let most = progress.hourlyPerformance.max { $0.value.sessionCount < $1.value.sessionCount }
        guard let mostEntry = most else { return nil }

        return (mostEntry.key, mostEntry.value.sessionCount)
    }

    /// Returns accuracy breakdown by difficulty level
    /// - Returns: Dictionary mapping difficulty to accuracy percentage
    public func getAccuracyByDifficulty() -> [QuestionDifficulty: Double] {
        var totalByDifficulty: [QuestionDifficulty: Int] = [:]
        var correctByDifficulty: [QuestionDifficulty: Int] = [:]

        for (_, dailyStat) in progress.dailyStats {
            for difficulty in QuestionDifficulty.allCases {
                let key = String(difficulty.rawValue)
                totalByDifficulty[difficulty, default: 0] += dailyStat.questionsByDifficulty[key] ?? 0
                correctByDifficulty[difficulty, default: 0] += dailyStat.correctByDifficulty[key] ?? 0
            }
        }

        var result: [QuestionDifficulty: Double] = [:]
        for difficulty in QuestionDifficulty.allCases {
            let total = totalByDifficulty[difficulty] ?? 0
            let correct = correctByDifficulty[difficulty] ?? 0
            result[difficulty] = total > 0 ? Double(correct) / Double(total) * 100 : 0
        }

        return result
    }

    /// Returns category performance with accuracy for each played category
    /// - Returns: Array of (category, accuracy, questionsAnswered) sorted by accuracy descending
    public func getCategoryPerformance() -> [(category: String, accuracy: Double, questionsAnswered: Int, bestScore: Int)] {
        progress.categoryStats.compactMap { categoryID, stat in
            guard stat.questionsAnswered > 0 else { return nil }
            return (categoryID, stat.accuracy, stat.questionsAnswered, stat.bestScore)
        }
        .sorted { $0.accuracy > $1.accuracy }
    }

    /// Returns lifetime average response time in seconds
    public var lifetimeAverageResponseTimeSeconds: Double {
        guard progress.lifetimeResponseTimeSamples > 0 else { return 0 }
        return Double(progress.lifetimeAverageResponseTimeMs) / 1000.0
    }

    /// Returns overall lifetime accuracy
    public var lifetimeAccuracy: Double {
        guard progress.lifetimeQuestionsAnswered > 0 else { return 0 }
        return Double(progress.lifetimeQuestionsCorrect) / Double(progress.lifetimeQuestionsAnswered) * 100
    }

    /// Formats hour for display (e.g., 14 -> "14:00")
    public static func formatHour(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    /// Formats hour range for display (e.g., 14 -> "14:00 - 15:00")
    public static func formatHourRange(_ hour: Int) -> String {
        let nextHour = (hour + 1) % 24
        return String(format: "%02d:00 - %02d:00", hour, nextHour)
    }

    // MARK: - Reset (for testing)

    public func resetProgress() {
        progress = PlayerProgress.default
        save()
    }
}
