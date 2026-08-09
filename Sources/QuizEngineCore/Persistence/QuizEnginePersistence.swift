//
//  QuizEnginePersistence.swift
//  QuizEngineCore
//

import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The persistence schema versions this package understands.
///
/// Decoding dispatches on the range of released envelope versions rather than on
/// equality with `current`. A document written by an earlier released schema must
/// keep loading and be promoted by the next save; only an unknown — that is, a
/// future — version is rejected. Bumping `current` when a new schema ships is
/// therefore enough to keep every previously released document readable, and it
/// cannot silently strand documents written by a shipped release.
public enum QuizEnginePersistenceSchema {
    /// Documents written before the versioned envelope existed. These have no
    /// `schemaVersion` key at all and are recognized by the absence of the envelope.
    public static let legacy = 0

    /// The first released envelope version.
    public static let firstVersioned = 1

    /// The envelope version written by the current package.
    public static let current = 2

    /// Every envelope version this package can decode.
    public static var decodableEnvelopeVersions: ClosedRange<Int> {
        firstVersioned...current
    }

    /// Whether an envelope carrying `version` can be decoded by this package.
    public static func canDecodeEnvelope(version: Int) -> Bool {
        decodableEnvelopeVersions.contains(version)
    }

    /// Whether a document decoded at `version` still has to be promoted on the next save.
    public static func requiresPromotion(from version: Int) -> Bool {
        version != current
    }
}

/// Typed failures produced by QuizEngine persistence.
public enum PersistenceError: Error, Equatable, Sendable, LocalizedError {
    case invalidImportRequest
    case readFailed(path: String, reason: String)
    case malformedData(path: String)
    case unsupportedSchema(path: String, version: Int)
    case writeFailed(path: String, reason: String)
    case insufficientStorage(path: String)
    case readBackVerificationFailed(path: String)
    case backupUnavailable(path: String)
    case backupRecoveryFailed(path: String, reason: String)
    case malformedImportMarker(path: String)
    case conflictingImport(identifier: String)
    case importMarkerWriteFailed(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidImportRequest:
            return "The persistence import request is invalid."
        case let .readFailed(path, reason):
            return "Could not read persistence at \(path): \(reason)"
        case let .malformedData(path):
            return "Persistence at \(path) is malformed."
        case let .unsupportedSchema(path, version):
            return "Persistence at \(path) uses unsupported schema version \(version)."
        case let .writeFailed(path, reason):
            return "Could not write persistence at \(path): \(reason)"
        case let .insufficientStorage(path):
            return "There is not enough storage to write persistence at \(path)."
        case let .readBackVerificationFailed(path):
            return "Persistence read-back verification failed at \(path)."
        case let .backupUnavailable(path):
            return "No usable persistence backup is available at \(path)."
        case let .backupRecoveryFailed(path, reason):
            return "Could not recover persistence from \(path): \(reason)"
        case let .malformedImportMarker(path):
            return "The persistence import marker at \(path) is malformed."
        case let .conflictingImport(identifier):
            return "Persistence import \(identifier) was already completed with different source data."
        case let .importMarkerWriteFailed(path, reason):
            return "Could not write the persistence import marker at \(path): \(reason)"
        }
    }
}

/// Describes what happened while loading or persisting a document.
public enum PersistenceStatus: Equatable, Sendable {
    case fresh
    case loadedLegacy
    case loaded(schemaVersion: Int)
    case recoveredFromBackup(schemaVersion: Int)
    case recoveredInterruptedImport
    case saved
    case imported
    case alreadyImported
    case failed(PersistenceError)
}

/// A persistence store used by the Core models and by deterministic tests.
///
/// The store owns file-system mechanics. The caller owns encoding, schema
/// validation, and read-back verification.
public protocol QuizEnginePersistenceStore: Sendable {
    var primaryURL: URL { get }
    var backupURL: URL { get }
    var transactionMarkerURL: URL { get }

    func readPrimary() throws -> Data?
    func readBackup() throws -> Data?
    func replacePrimary(with data: Data) throws
    func restoreBackup() throws
    func removePrimary() throws

    func readTransactionMarker() throws -> Data?
    func replaceTransactionMarker(with data: Data) throws
    func removeTransactionMarker() throws

    /// Serializes a complete read/backup/replace/verify transaction.
    ///
    /// Stores that do not need cross-process coordination may use the default
    /// implementation. The production file store coordinates both threads
    /// and processes sharing the same primary URL.
    func withExclusiveAccess<Result>(_ operation: () throws -> Result) throws -> Result
}

public extension QuizEnginePersistenceStore {
    func withExclusiveAccess<Result>(_ operation: () throws -> Result) throws -> Result {
        try operation()
    }
}

private final class PersistenceProcessLockRegistry: @unchecked Sendable {
    private let registryLock = NSLock()
    private var locks: [String: NSRecursiveLock] = [:]

    func lock(for path: String) -> NSRecursiveLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let lock = locks[path] {
            return lock
        }
        let lock = NSRecursiveLock()
        locks[path] = lock
        return lock
    }
}

/// The production file-backed persistence store.
public final class FileQuizEnginePersistenceStore: QuizEnginePersistenceStore, @unchecked Sendable {
    private static let processLockRegistry = PersistenceProcessLockRegistry()

    public let primaryURL: URL
    public let backupURL: URL
    public let transactionMarkerURL: URL

    private let temporaryURL: URL
    private let backupTemporaryURL: URL
    private let markerTemporaryURL: URL
    private let lockURL: URL
    private let fileManager: FileManager
    private let processLock: NSRecursiveLock
    private var exclusiveAccessDepth = 0

    public init(primaryURL: URL, fileManager: FileManager = .default) {
        self.primaryURL = primaryURL
        self.backupURL = Self.siblingURL(for: primaryURL, suffix: ".backup")
        self.transactionMarkerURL = Self.siblingURL(for: primaryURL, suffix: ".import-marker")
        self.temporaryURL = Self.siblingURL(for: primaryURL, suffix: ".tmp")
        self.backupTemporaryURL = Self.siblingURL(for: primaryURL, suffix: ".backup.tmp")
        self.markerTemporaryURL = Self.siblingURL(for: primaryURL, suffix: ".import-marker.tmp")
        self.lockURL = Self.siblingURL(for: primaryURL, suffix: ".lock")
        self.fileManager = fileManager
        self.processLock = Self.processLockRegistry.lock(for: lockURL.path)
    }

    public func withExclusiveAccess<Result>(_ operation: () throws -> Result) throws -> Result {
        processLock.lock()
        defer { processLock.unlock() }

        if exclusiveAccessDepth > 0 {
            exclusiveAccessDepth += 1
            defer { exclusiveAccessDepth -= 1 }
            return try operation()
        }

        try ensureParentDirectory()
#if canImport(Darwin)
        let descriptor = lockURL.path.withCString { path in
            Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw PersistenceError.writeFailed(
                path: lockURL.path,
                reason: String(cString: strerror(errno))
            )
        }
        defer { _ = Darwin.close(descriptor) }

        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw PersistenceError.writeFailed(
                path: lockURL.path,
                reason: String(cString: strerror(errno))
            )
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
#endif

        try removeStaleTemporaryFiles()
        exclusiveAccessDepth = 1
        defer { exclusiveAccessDepth = 0 }
        return try operation()
    }

    public func readPrimary() throws -> Data? {
        try withExclusiveAccess { try readData(at: primaryURL) }
    }

    public func readBackup() throws -> Data? {
        try withExclusiveAccess { try readData(at: backupURL) }
    }

    public func replacePrimary(with data: Data) throws {
        try withExclusiveAccess {
            try ensureParentDirectory()

            if fileManager.fileExists(atPath: primaryURL.path) {
                try atomicallyCopy(from: primaryURL, to: backupURL, temporaryURL: backupTemporaryURL)
            }

            try atomicallyReplace(data: data, at: primaryURL, temporaryURL: temporaryURL)
        }
    }

    public func restoreBackup() throws {
        try withExclusiveAccess {
            guard fileManager.fileExists(atPath: backupURL.path) else {
                throw PersistenceError.backupUnavailable(path: backupURL.path)
            }

            do {
                let backupData = try Data(contentsOf: backupURL)
                try atomicallyReplace(data: backupData, at: primaryURL, temporaryURL: temporaryURL)
            } catch let error as PersistenceError {
                throw PersistenceError.backupRecoveryFailed(
                    path: backupURL.path,
                    reason: error.localizedDescription
                )
            } catch {
                throw PersistenceError.backupRecoveryFailed(
                    path: backupURL.path,
                    reason: error.localizedDescription
                )
            }
        }
    }

    public func removePrimary() throws {
        try withExclusiveAccess { try removeIfPresent(primaryURL, operation: "remove") }
    }

    public func readTransactionMarker() throws -> Data? {
        try withExclusiveAccess { try readData(at: transactionMarkerURL) }
    }

    public func replaceTransactionMarker(with data: Data) throws {
        do {
            try withExclusiveAccess {
                try ensureParentDirectory()
                try atomicallyReplace(data: data, at: transactionMarkerURL, temporaryURL: markerTemporaryURL)
            }
        } catch let error as PersistenceError {
            throw PersistenceError.importMarkerWriteFailed(
                path: transactionMarkerURL.path,
                reason: error.localizedDescription
            )
        } catch {
            throw PersistenceError.importMarkerWriteFailed(
                path: transactionMarkerURL.path,
                reason: error.localizedDescription
            )
        }
    }

    public func removeTransactionMarker() throws {
        try withExclusiveAccess { try removeIfPresent(transactionMarkerURL, operation: "remove import marker") }
    }

    private func readData(at url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        do {
            return try Data(contentsOf: url)
        } catch {
            throw map(error: error, path: url.path, operation: "read")
        }
    }

    private func ensureParentDirectory() throws {
        let directory = primaryURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw map(error: error, path: directory.path, operation: "create directory")
        }
    }

    private func atomicallyCopy(from source: URL, to destination: URL, temporaryURL: URL) throws {
        do {
            try removeIfPresent(temporaryURL, operation: "remove temporary backup")
            try fileManager.copyItem(at: source, to: temporaryURL)
            try replaceFile(at: temporaryURL, destination: destination)
        } catch let error as PersistenceError {
            try? removeIfPresent(temporaryURL, operation: "remove temporary backup")
            throw error
        } catch {
            try? removeIfPresent(temporaryURL, operation: "remove temporary backup")
            throw map(error: error, path: destination.path, operation: "write backup")
        }
    }

    private func atomicallyReplace(data: Data, at destination: URL, temporaryURL: URL) throws {
        do {
            try removeIfPresent(temporaryURL, operation: "remove temporary file")
            try data.write(to: temporaryURL, options: [])
            try replaceFile(at: temporaryURL, destination: destination)
        } catch let error as PersistenceError {
            try? removeIfPresent(temporaryURL, operation: "remove temporary file")
            throw error
        } catch {
            try? removeIfPresent(temporaryURL, operation: "remove temporary file")
            throw map(error: error, path: destination.path, operation: "write")
        }
    }

    private func replaceFile(at temporaryURL: URL, destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
    }

    private func removeIfPresent(_ url: URL, operation: String) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw map(error: error, path: url.path, operation: operation)
        }
    }

    private func removeStaleTemporaryFiles() throws {
        try removeIfPresent(temporaryURL, operation: "remove temporary file")
        try removeIfPresent(backupTemporaryURL, operation: "remove temporary backup")
        try removeIfPresent(markerTemporaryURL, operation: "remove temporary import marker")
    }

    private func map(error: Error, path: String, operation: String) -> PersistenceError {
        let nsError = error as NSError
        if nsError.code == NSFileWriteOutOfSpaceError ||
            (nsError.domain == NSPOSIXErrorDomain && nsError.code == 28) {
            return .insufficientStorage(path: path)
        }

        if operation == "read" {
            return .readFailed(path: path, reason: error.localizedDescription)
        }
        return .writeFailed(path: path, reason: error.localizedDescription)
    }

    private static func siblingURL(for url: URL, suffix: String) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + suffix)
    }
}

/// The package-neutral destination of a legacy import.
public struct PlayerProgressImportRequest: Equatable, Sendable {
    public let identifier: String
    public let sourceFingerprint: String
    public let progress: PlayerProgress

    public init(
        identifier: String,
        sourceFingerprint: String,
        progress: PlayerProgress
    ) throws {
        guard !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !sourceFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              progress.powerUpCredits.values.allSatisfy({ $0 >= 0 }) else {
            throw PersistenceError.invalidImportRequest
        }
        self.identifier = identifier
        self.sourceFingerprint = sourceFingerprint
        self.progress = progress
    }
}

public enum PlayerProgressImportResult: Equatable, Sendable {
    case imported
    case alreadyImported
}

struct PersistenceEnvelope<Value: Codable>: Codable {
    let schemaVersion: Int
    let payload: Value
}

struct DecodedPersistence<Value> {
    let payload: Value
    let schemaVersion: Int
    let isLegacy: Bool
}

enum PersistenceDocumentCodec {
    static func encode<Value: Codable>(_ value: Value, path: String = "") throws -> Data {
        let encoder = PropertyListEncoder()
        do {
            return try encoder.encode(
                PersistenceEnvelope(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    payload: value
                )
            )
        } catch {
            throw PersistenceError.writeFailed(path: path, reason: error.localizedDescription)
        }
    }

    static func decode<Value: Codable>(
        _ type: Value.Type,
        from data: Data,
        path: String
    ) throws -> DecodedPersistence<Value> {
        let decoder = PropertyListDecoder()
        let hasEnvelopeKey: Bool
        do {
            let propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            )
            hasEnvelopeKey = (propertyList as? [String: Any])?["schemaVersion"] != nil
        } catch {
            throw PersistenceError.malformedData(path: path)
        }

        if hasEnvelopeKey {
            do {
                let envelope = try decoder.decode(PersistenceEnvelope<Value>.self, from: data)
                guard QuizEnginePersistenceSchema.canDecodeEnvelope(version: envelope.schemaVersion) else {
                    throw PersistenceError.unsupportedSchema(
                        path: path,
                        version: envelope.schemaVersion
                    )
                }
                return DecodedPersistence(
                    payload: envelope.payload,
                    schemaVersion: envelope.schemaVersion,
                    isLegacy: false
                )
            } catch let error as PersistenceError {
                throw error
            } catch {
                throw PersistenceError.malformedData(path: path)
            }
        }

        do {
            return DecodedPersistence(
                payload: try decoder.decode(Value.self, from: data),
                schemaVersion: QuizEnginePersistenceSchema.legacy,
                isLegacy: true
            )
        } catch {
            throw PersistenceError.malformedData(path: path)
        }
    }
}

enum ImportMarkerState: String, Codable, Equatable {
    case pending
    case completed
}

struct ImportMarker: Codable, Equatable {
    let schemaVersion: Int
    let identifier: String
    let sourceFingerprint: String
    let state: ImportMarkerState
    let hadPrimary: Bool
    let timestamp: Date
    let targetProgress: PlayerProgress?
    let previousProgress: PlayerProgress?

    init(
        schemaVersion: Int,
        identifier: String,
        sourceFingerprint: String,
        state: ImportMarkerState,
        hadPrimary: Bool,
        timestamp: Date,
        targetProgress: PlayerProgress? = nil,
        previousProgress: PlayerProgress? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.identifier = identifier
        self.sourceFingerprint = sourceFingerprint
        self.state = state
        self.hadPrimary = hadPrimary
        self.timestamp = timestamp
        self.targetProgress = targetProgress
        self.previousProgress = previousProgress
    }
}

enum PersistenceMarkerCodec {
    static func encode(_ marker: ImportMarker, path: String = "") throws -> Data {
        do {
            return try PropertyListEncoder().encode(marker)
        } catch {
            throw PersistenceError.importMarkerWriteFailed(path: path, reason: error.localizedDescription)
        }
    }

    static func decode(from data: Data, path: String) throws -> ImportMarker {
        do {
            let marker = try PropertyListDecoder().decode(ImportMarker.self, from: data)
            // A marker written by an earlier released schema must still be recognized,
            // or an interrupted import would become unrecoverable across an upgrade.
            guard QuizEnginePersistenceSchema.canDecodeEnvelope(version: marker.schemaVersion),
                  !marker.identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !marker.sourceFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  marker.targetProgress != nil else {
                throw PersistenceError.malformedImportMarker(path: path)
            }
            return marker
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.malformedImportMarker(path: path)
        }
    }
}

struct DecodedImportMarker {
    let marker: ImportMarker?
}

struct PlayerProgressLoadResult {
    let progress: PlayerProgress
    let status: PersistenceStatus
    let error: PersistenceError?
}

extension QuizEnginePersistenceStore {
    func readDecodedImportMarker() throws -> DecodedImportMarker {
        guard let data = try readTransactionMarker() else {
            return DecodedImportMarker(marker: nil)
        }
        return DecodedImportMarker(
            marker: try PersistenceMarkerCodec.decode(from: data, path: transactionMarkerURL.path)
        )
    }
}
