import Foundation
import os
import QuizEngineCore
import QuizEngineGame
import QuizEngineMultiplayer

public final class TestClock: QuizEngineClock {
    private let state: OSAllocatedUnfairLock<Date>

    public var now: Date {
        state.withLock { $0 }
    }

    public init(now: Date) {
        self.state = OSAllocatedUnfairLock(initialState: now)
    }

    public func advance(by interval: TimeInterval) {
        state.withLock { date in
            date = date.addingTimeInterval(interval)
        }
    }

    public func setNow(_ date: Date) {
        state.withLock { $0 = date }
    }
}

@MainActor
public final class TestScheduler: QuizEngineScheduler {
    private struct ScheduledEntry {
        let dueTime: TimeInterval
        let order: Int
        let task: TestScheduledTask
        let operation: @MainActor () -> Void
    }

    public final class TestScheduledTask: QuizEngineScheduledTask {
        fileprivate private(set) var isCancelled = false

        public func cancel() {
            isCancelled = true
        }
    }

    private var currentTime: TimeInterval = 0
    private var nextOrder = 0
    private var entries: [ScheduledEntry] = []

    public init() {}

    @discardableResult
    public func schedule(
        after delay: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
    ) -> any QuizEngineScheduledTask {
        let task = TestScheduledTask()
        entries.append(
            ScheduledEntry(
                dueTime: currentTime + max(0, delay),
                order: nextOrder,
                task: task,
                operation: operation
            )
        )
        nextOrder += 1
        return task
    }

    public var pendingTaskCount: Int {
        entries.filter { !$0.task.isCancelled }.count
    }

    public func advance(by interval: TimeInterval) {
        let targetTime = currentTime + max(0, interval)

        while let nextIndex = entries.indices
            .filter({ entries[$0].dueTime <= targetTime })
            .min(by: {
                if entries[$0].dueTime == entries[$1].dueTime {
                    return entries[$0].order < entries[$1].order
                }
                return entries[$0].dueTime < entries[$1].dueTime
            }) {
            let entry = entries.remove(at: nextIndex)
            currentTime = entry.dueTime
            guard !entry.task.isCancelled else { continue }
            entry.operation()
        }

        currentTime = targetTime
    }

    public func runNext() {
        guard let nextDueTime = entries
            .filter({ !$0.task.isCancelled })
            .map(\.dueTime)
            .min() else { return }
        advance(by: nextDueTime - currentTime)
    }

    public func runAll(maximumTasks: Int = 1_000) {
        for _ in 0..<maximumTasks {
            guard pendingTaskCount > 0 else { return }
            runNext()
        }
    }
}

/// Delivers a snapshot of queued operations even after cancellation to verify stale-callback guards.
@MainActor
public final class CancellationIgnoringTestScheduler: QuizEngineScheduler {
    private final class ScheduledTask: QuizEngineScheduledTask {
        func cancel() {}
    }

    private var operations: [@MainActor () -> Void] = []

    public init() {}

    @discardableResult
    public func schedule(
        after delay: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
    ) -> any QuizEngineScheduledTask {
        operations.append(operation)
        return ScheduledTask()
    }

    public var pendingTaskCount: Int { operations.count }

    public func runPendingBatch() {
        let pending = operations
        operations.removeAll()
        pending.forEach { $0() }
    }
}

public final class TemporaryPersistence {
    public let directoryURL: URL
    public let progressURL: URL
    public let preferencesURL: URL

    public init() throws {
        let fileManager = FileManager.default
        let baseDirectory = fileManager.temporaryDirectory
        let processID = ProcessInfo.processInfo.processIdentifier
        var index = 0
        let directory: URL

        while true {
            let candidate = baseDirectory
                .appendingPathComponent("QuizEngineTest-\(processID)-\(index)", isDirectory: true)
            do {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                directory = candidate
                break
            } catch {
                guard fileManager.fileExists(atPath: candidate.path) else {
                    throw error
                }
                index += 1
            }
        }

        directoryURL = directory
        progressURL = directory.appendingPathComponent("player_progress.plist")
        preferencesURL = directory.appendingPathComponent("user_preferences.plist")
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

public enum FakePersistenceFailurePoint: Equatable, Sendable {
    case readPrimary
    case readBackup
    case replacePrimary
    case partialReplacePrimary
    case insufficientStorage
    case restoreBackup
    case removePrimary
    case readMarker
    case replaceMarker
    case removeMarker
}

/// An in-memory store with deterministic failure injection for persistence tests.
public final class FakePersistenceStore: QuizEnginePersistenceStore, @unchecked Sendable {
    public let primaryURL: URL
    public let backupURL: URL
    public let transactionMarkerURL: URL

    public var primaryData: Data?
    public var backupData: Data?
    public var transactionMarkerData: Data?
    public var readBackOverride: Data?
    public var failurePoint: FakePersistenceFailurePoint?
    public var onReplacePrimaryAttempt: (() -> Void)?
    public private(set) var operations: [String] = []
    public private(set) var replacePrimaryAttemptCount = 0

    public init(
        primaryData: Data? = nil,
        backupData: Data? = nil,
        transactionMarkerData: Data? = nil
    ) {
        let base = URL(fileURLWithPath: "/fake/quiz-engine-progress.plist")
        primaryURL = base
        backupURL = URL(fileURLWithPath: base.path + ".backup")
        transactionMarkerURL = URL(fileURLWithPath: base.path + ".import-marker")
        self.primaryData = primaryData
        self.backupData = backupData
        self.transactionMarkerData = transactionMarkerData
    }

    public func readPrimary() throws -> Data? {
        try failIfNeeded(.readPrimary)
        operations.append("readPrimary")
        let replacementHasStarted = operations.contains("replacePrimary") ||
            operations.contains("partialReplacePrimary")
        return replacementHasStarted ? (readBackOverride ?? primaryData) : primaryData
    }

    public func readBackup() throws -> Data? {
        try failIfNeeded(.readBackup)
        operations.append("readBackup")
        return backupData
    }

    public func replacePrimary(with data: Data) throws {
        replacePrimaryAttemptCount += 1
        onReplacePrimaryAttempt?()
        if failurePoint == .partialReplacePrimary {
            failurePoint = nil
            operations.append("partialReplacePrimary")
            backupData = primaryData
            primaryData = data
            throw PersistenceError.writeFailed(path: primaryURL.path, reason: "Injected partial replacement failure")
        }
        try failIfNeeded(.replacePrimary)
        try failIfNeeded(.insufficientStorage)
        operations.append("replacePrimary")
        backupData = primaryData
        primaryData = data
    }

    public func restoreBackup() throws {
        try failIfNeeded(.restoreBackup)
        operations.append("restoreBackup")
        guard let backupData else {
            throw PersistenceError.backupUnavailable(path: backupURL.path)
        }
        primaryData = backupData
        readBackOverride = nil
    }

    public func removePrimary() throws {
        try failIfNeeded(.removePrimary)
        operations.append("removePrimary")
        primaryData = nil
    }

    public func readTransactionMarker() throws -> Data? {
        try failIfNeeded(.readMarker)
        operations.append("readMarker")
        return transactionMarkerData
    }

    public func replaceTransactionMarker(with data: Data) throws {
        try failIfNeeded(.replaceMarker)
        operations.append("replaceMarker")
        transactionMarkerData = data
    }

    public func removeTransactionMarker() throws {
        try failIfNeeded(.removeMarker)
        operations.append("removeMarker")
        transactionMarkerData = nil
    }

    private func failIfNeeded(_ point: FakePersistenceFailurePoint) throws {
        guard failurePoint == point else { return }
        failurePoint = nil
        switch point {
        case .readPrimary, .readBackup, .readMarker:
            throw PersistenceError.readFailed(path: primaryURL.path, reason: "Injected failure")
        case .replacePrimary:
            throw PersistenceError.writeFailed(path: primaryURL.path, reason: "Injected failure")
        case .partialReplacePrimary:
            fatalError("Handled before failIfNeeded")
        case .insufficientStorage:
            throw PersistenceError.insufficientStorage(path: primaryURL.path)
        case .restoreBackup:
            throw PersistenceError.backupRecoveryFailed(path: backupURL.path, reason: "Injected failure")
        case .removePrimary, .removeMarker:
            throw PersistenceError.writeFailed(path: primaryURL.path, reason: "Injected failure")
        case .replaceMarker:
            throw PersistenceError.importMarkerWriteFailed(path: transactionMarkerURL.path, reason: "Injected failure")
        }
    }
}

public final class RecordingAnalytics: AnalyticsProvider {
    public struct MultiplayerCompletion: Equatable, Sendable {
        public let result: String
        public let myScore: Int
        public let opponentScore: Int
        public let questionsCompleted: Int
        public let durationSeconds: Int
        public let transportType: String

        public init(
            result: String,
            myScore: Int,
            opponentScore: Int,
            questionsCompleted: Int,
            durationSeconds: Int,
            transportType: String
        ) {
            self.result = result
            self.myScore = myScore
            self.opponentScore = opponentScore
            self.questionsCompleted = questionsCompleted
            self.durationSeconds = durationSeconds
            self.transportType = transportType
        }
    }

    private struct State: Sendable {
        var gameStarts: [(String?, GameMode)] = []
        var gameEnds: [(Int, Int, Int, Int)] = []
        var powerUps: [(PowerUp, Int)] = []
        var powerUpFunding: [(PowerUp, PowerUpFundingSource, Int)] = []
        var extraLives: [ExtraLifeMethod] = []
        var achievements: [(String, Int)] = []
        var disconnects: [(Int, String, String)] = []
        var multiplayerCompletions: [MultiplayerCompletion] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public var gameStarts: [(String?, GameMode)] { state.withLock { $0.gameStarts } }
    public var gameEnds: [(Int, Int, Int, Int)] { state.withLock { $0.gameEnds } }
    public var powerUps: [(PowerUp, Int)] { state.withLock { $0.powerUps } }
    public var powerUpFunding: [(PowerUp, PowerUpFundingSource, Int)] { state.withLock { $0.powerUpFunding } }
    public var extraLives: [ExtraLifeMethod] { state.withLock { $0.extraLives } }
    public var achievements: [(String, Int)] { state.withLock { $0.achievements } }
    public var disconnects: [(Int, String, String)] { state.withLock { $0.disconnects } }
    public var multiplayerCompletions: [MultiplayerCompletion] { state.withLock { $0.multiplayerCompletions } }

    public init() {}

    public func logGameStarted(category: String?, mode: GameMode) {
        state.withLock { $0.gameStarts.append((category, mode)) }
    }

    public func logGameEnded(score: Int, livesRemaining: Int, questionsAnswered: Int, coinsEarned: Int, category: String?, mode: GameMode) {
        state.withLock { $0.gameEnds.append((score, livesRemaining, questionsAnswered, coinsEarned)) }
    }

    public func logPowerUpUsed(type: PowerUp, coinsSpent: Int) {
        state.withLock { $0.powerUps.append((type, coinsSpent)) }
    }

    public func logPowerUpUsed(type: PowerUp, fundingSource: PowerUpFundingSource, coinsSpent: Int) {
        state.withLock { $0.powerUpFunding.append((type, fundingSource, coinsSpent)) }
        logPowerUpUsed(type: type, coinsSpent: coinsSpent)
    }

    public func logExtraLifeUsed(method: ExtraLifeMethod) {
        state.withLock { $0.extraLives.append(method) }
    }

    public func logAchievementUnlocked(achievementId: String, coinReward: Int) {
        state.withLock { $0.achievements.append((achievementId, coinReward)) }
    }

    public func logMultiplayerDisconnect(questionsCompleted: Int, reason: String, transportType: String) {
        state.withLock { $0.disconnects.append((questionsCompleted, reason, transportType)) }
    }

    public func logMultiplayerMatchCompleted(
        result: String,
        myScore: Int,
        opponentScore: Int,
        questionsCompleted: Int,
        durationSeconds: Int,
        transportType: String
    ) {
        state.withLock {
            $0.multiplayerCompletions.append(
                MultiplayerCompletion(
                    result: result,
                    myScore: myScore,
                    opponentScore: opponentScore,
                    questionsCompleted: questionsCompleted,
                    durationSeconds: durationSeconds,
                    transportType: transportType
                )
            )
        }
    }
}

@MainActor
public final class FakeInterstitialAdProvider: InterstitialAdProvider {
    public private(set) var loadCount = 0
    public private(set) var showCount = 0
    public var ready = false

    public init(ready: Bool = false) {
        self.ready = ready
    }

    public func load() {
        loadCount += 1
    }

    public func isReady() -> Bool {
        ready
    }

    public func show() {
        showCount += 1
    }
}

@MainActor
public final class FakeRewardAdProvider: RewardAdProvider {
    public private(set) var loadCount = 0
    public private(set) var showCount = 0
    public var isLoaded: Bool
    private var completion: (@MainActor (Bool) -> Void)?
    private var lastCompletion: (@MainActor (Bool) -> Void)?

    public init(isLoaded: Bool = false) {
        self.isLoaded = isLoaded
    }

    public func load() {
        loadCount += 1
    }

    public func show(completion: @escaping @MainActor (Bool) -> Void) {
        showCount += 1
        self.completion = completion
        lastCompletion = completion
    }

    public func completeReward(earned: Bool) {
        completion?(earned)
        completion = nil
    }

    /// Simulates a broken SDK adapter invoking an already-delivered callback.
    public func repeatLastCompletion(earned: Bool) {
        lastCompletion?(earned)
    }
}

public final class FakePurchaseStatus: PurchaseStatusProvider {
    public var isPremium: Bool
    public var adsRemoved: Bool

    public init(isPremium: Bool = false, adsRemoved: Bool = false) {
        self.isPremium = isPremium
        self.adsRemoved = adsRemoved
    }
}

public final class RecordingHaptics: HapticProvider {
    public private(set) var notifications: [HapticNotificationType] = []
    public private(set) var impacts: [HapticImpactStyle] = []

    public init() {}

    public func notification(_ type: HapticNotificationType) {
        notifications.append(type)
    }

    public func impact(_ style: HapticImpactStyle) {
        impacts.append(style)
    }
}

@MainActor
public final class RecordingLeaderboard: LeaderboardProvider {
    public private(set) var submittedScores: [Int] = []

    public init() {}

    public func submitScore(_ score: Int) async {
        submittedScores.append(score)
    }
}

@MainActor
public final class FakeTransport: MultiplayerTransport {
    public let localPlayer: MultiplayerPlayer
    public private(set) var connectionState: TransportConnectionState = .idle
    public private(set) var eventStream: AsyncStream<MultiplayerTransportEvent>
    public private(set) var sentMessages: [MultiplayerMessage] = []
    public private(set) var rawPayloadEventStream: AsyncStream<MultiplayerRawPayloadEvent>
    public private(set) var sentRawPayloads: [Data] = []
    public var supportsRawPayloads: Bool { true }

    private var continuation: AsyncStream<MultiplayerTransportEvent>.Continuation
    private var rawContinuation: AsyncStream<MultiplayerRawPayloadEvent>.Continuation

    public init(
        localPlayer: MultiplayerPlayer = MultiplayerPlayer(id: "test", displayName: "Test")
    ) {
        self.localPlayer = localPlayer
        let (stream, continuation) = AsyncStream.makeStream(of: MultiplayerTransportEvent.self)
        eventStream = stream
        self.continuation = continuation
        let (rawStream, rawContinuation) = AsyncStream.makeStream(of: MultiplayerRawPayloadEvent.self)
        rawPayloadEventStream = rawStream
        self.rawContinuation = rawContinuation
    }

    public func startSearching() {
        connectionState = .searching
    }

    public func stopSearching() {
        connectionState = .idle
    }

    public func invite(player: MultiplayerPlayer) {}
    public func acceptInvite(from player: MultiplayerPlayer) {}
    public func declineInvite(from player: MultiplayerPlayer) {}

    public func send(message: MultiplayerMessage) throws {
        sentMessages.append(message)
    }

    /// Set to make the app-owned transport refuse the next and every later raw send.
    public var rawSendFailure: (any Error)?

    public func sendRawPayload(_ data: Data) throws {
        if let rawSendFailure { throw rawSendFailure }
        sentRawPayloads.append(data)
    }

    public func disconnect() {
        connectionState = .disconnected
    }

    public func emit(_ event: MultiplayerTransportEvent) {
        continuation.yield(event)
    }

    public func emitRaw(_ data: Data, from sender: MultiplayerPlayer) {
        rawContinuation.yield(.init(data: data, sender: sender))
    }

    public func resetEventStream() {
        continuation.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: MultiplayerTransportEvent.self)
        eventStream = stream
        self.continuation = continuation
        rawContinuation.finish()
        let (rawStream, rawContinuation) = AsyncStream.makeStream(of: MultiplayerRawPayloadEvent.self)
        rawPayloadEventStream = rawStream
        self.rawContinuation = rawContinuation
    }
}

public enum QuizEngineTestFixtures {
    public static func questions(count: Int = 4, category: String = "nature") -> [Question] {
        guard count > 0 else { return [] }
        return (1...count).map { index in
            Question(
                id: index,
                question: "Question \(index)",
                answers: [
                    Answer(text: "Correct \(index)", correct: true),
                    Answer(text: "Wrong \(index)", correct: false),
                    Answer(text: "Other \(index)", correct: false),
                    Answer(text: "Another \(index)", correct: false)
                ],
                categories: [category],
                difficulty: (index % 3) + 1
            )
        }
    }

    public static func variant(
        questionResource: QuestionResource,
        categoryID: String = "nature"
    ) throws -> QuizVariantDefinition {
        try QuizVariantDefinition(
            categories: [
                QuizCategoryDefinition(
                    id: categoryID,
                    displayNameKey: "category.\(categoryID)",
                    iconName: "leaf",
                    displayOrder: 0,
                    unlockRequirement: .free
                )
            ],
            achievements: [],
            questionResource: questionResource
        )
    }
}
