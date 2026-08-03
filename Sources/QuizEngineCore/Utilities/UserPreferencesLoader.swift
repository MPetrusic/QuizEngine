//
//  UserPreferencesLoader.swift
//  QuizEngineCore
//
//  Created by Milos Petrusic on 15.7.23..
//

import Foundation

public class UserPreferencesLoader {
    static private var plistURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("user_preferences.plist")
    }

    public static func load(from url: URL? = nil) -> UserPreferences {
        let sourceURL = url ?? plistURL
        let store = FileQuizEnginePersistenceStore(primaryURL: sourceURL)
        return (try? load(from: store)) ?? UserPreferences(hapticsEnabled: true)
    }

    public static func write(preferences: UserPreferences, to url: URL? = nil) {
        let destinationURL = url ?? plistURL
        let store = FileQuizEnginePersistenceStore(primaryURL: destinationURL)
        try? write(preferences: preferences, to: store)
    }

    /// Loads preferences through an injected store and surfaces typed failures.
    public static func load(from store: any QuizEnginePersistenceStore) throws -> UserPreferences {
        try store.withExclusiveAccess {
            try loadUnlocked(from: store)
        }
    }

    private static func loadUnlocked(from store: any QuizEnginePersistenceStore) throws -> UserPreferences {
        func recoverFromBackup(_ backupData: Data) throws -> UserPreferences {
            let backup = try PersistenceDocumentCodec.decode(
                UserPreferences.self,
                from: backupData,
                path: store.backupURL.path
            )
            try store.restoreBackup()
            guard let restoredData = try store.readPrimary(),
                  let restored = try? PersistenceDocumentCodec.decode(
                      UserPreferences.self,
                      from: restoredData,
                      path: store.primaryURL.path
                  ),
                  restored.payload == backup.payload else {
                throw PersistenceError.readBackVerificationFailed(path: store.primaryURL.path)
            }
            return backup.payload
        }

        guard let data = try store.readPrimary() else {
            return UserPreferences(hapticsEnabled: true)
        }

        do {
            let decoded = try PersistenceDocumentCodec.decode(
                UserPreferences.self,
                from: data,
                path: store.primaryURL.path
            )
            return decoded.payload
        } catch {
            guard let backupData = try store.readBackup() else {
                throw error
            }
            do {
                return try recoverFromBackup(backupData)
            } catch let recoveryError as PersistenceError {
                throw PersistenceError.backupRecoveryFailed(
                    path: store.backupURL.path,
                    reason: recoveryError.localizedDescription
                )
            }
        }
    }

    /// Persists preferences through an injected store with read-back verification.
    public static func write(
        preferences: UserPreferences,
        to store: any QuizEnginePersistenceStore
    ) throws {
        try store.withExclusiveAccess {
            try writeUnlocked(preferences: preferences, to: store)
        }
    }

    private static func writeUnlocked(
        preferences: UserPreferences,
        to store: any QuizEnginePersistenceStore
    ) throws {
        let previousPrimaryData = try store.readPrimary()
        let hadPrimary = previousPrimaryData != nil
        let previousPreferences = previousPrimaryData.flatMap { data in
            try? PersistenceDocumentCodec.decode(
                UserPreferences.self,
                from: data,
                path: store.primaryURL.path
            ).payload
        }
        let data = try PersistenceDocumentCodec.encode(
            preferences,
            path: store.primaryURL.path
        )
        do {
            try store.replacePrimary(with: data)
        } catch {
            let operationError = error
            do {
                try repairFailedReplacement(
                    hadPrimary: hadPrimary,
                    attemptedData: data,
                    attemptedValue: preferences,
                    previousValue: previousPreferences,
                    store: store
                )
            } catch {
                throw error
            }
            throw operationError
        }

        do {
            guard let readBack = try store.readPrimary() else {
                throw PersistenceError.readBackVerificationFailed(path: store.primaryURL.path)
            }
            let decoded = try PersistenceDocumentCodec.decode(
                UserPreferences.self,
                from: readBack,
                path: store.primaryURL.path
            )
            guard decoded.schemaVersion == QuizEnginePersistenceSchema.current,
                  decoded.payload == preferences else {
                throw PersistenceError.readBackVerificationFailed(path: store.primaryURL.path)
            }
        } catch {
            let verificationError = error
            do {
                try rollbackFailedReplacement(
                    hadPrimary: hadPrimary,
                    expectedValue: previousPreferences,
                    store: store
                )
            } catch {
                throw error
            }
            throw verificationError
        }
    }

    private static func repairFailedReplacement<Value: Codable & Equatable & Sendable>(
        hadPrimary: Bool,
        attemptedData: Data,
        attemptedValue: Value,
        previousValue: Value?,
        store: any QuizEnginePersistenceStore
    ) throws {
        let currentData: Data?
        do {
            currentData = try store.readPrimary()
        } catch {
            try rollbackFailedReplacement(
                hadPrimary: hadPrimary,
                expectedValue: previousValue,
                store: store
            )
            return
        }

        guard let currentData else {
            if hadPrimary {
                try rollbackFailedReplacement(
                    hadPrimary: true,
                    expectedValue: previousValue,
                    store: store
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
                path: store.primaryURL.path
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
                expectedValue: previousValue,
                store: store
            )
        }
    }

    private static func rollbackFailedReplacement<Value: Codable & Equatable & Sendable>(
        hadPrimary: Bool,
        expectedValue: Value?,
        store: any QuizEnginePersistenceStore
    ) throws {
        do {
            if hadPrimary {
                try store.restoreBackup()
                guard let restoredData = try store.readPrimary() else {
                    throw PersistenceError.readBackVerificationFailed(path: store.primaryURL.path)
                }
                let restored = try PersistenceDocumentCodec.decode(
                    Value.self,
                    from: restoredData,
                    path: store.primaryURL.path
                )
                if let expectedValue, restored.payload != expectedValue {
                    throw PersistenceError.readBackVerificationFailed(path: store.primaryURL.path)
                }
            } else {
                try store.removePrimary()
                if try store.readPrimary() != nil {
                    throw PersistenceError.readBackVerificationFailed(path: store.primaryURL.path)
                }
            }
        } catch let error as PersistenceError {
            let path = hadPrimary ? store.backupURL.path : store.primaryURL.path
            throw PersistenceError.backupRecoveryFailed(
                path: path,
                reason: error.localizedDescription
            )
        } catch {
            let path = hadPrimary ? store.backupURL.path : store.primaryURL.path
            throw PersistenceError.backupRecoveryFailed(
                path: path,
                reason: error.localizedDescription
            )
        }
    }
}
