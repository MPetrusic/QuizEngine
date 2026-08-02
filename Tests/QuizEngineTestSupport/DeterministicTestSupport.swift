import Foundation
import QuizEngineCore
import QuizEngineGame
import QuizEngineMultiplayer

public final class TestClock: QuizEngineClock, @unchecked Sendable {
    public private(set) var now: Date

    public init(now: Date) {
        self.now = now
    }

    public func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
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

public final class TemporaryPersistence: @unchecked Sendable {
    public let directoryURL: URL
    public let progressURL: URL
    public let preferencesURL: URL

    public init() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuizEngineTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoryURL = directory
        progressURL = directory.appendingPathComponent("player_progress.plist")
        preferencesURL = directory.appendingPathComponent("user_preferences.plist")
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

public final class RecordingAnalytics: AnalyticsProvider, @unchecked Sendable {
    public private(set) var gameStarts: [(String?, GameMode)] = []
    public private(set) var gameEnds: [(Int, Int, Int, Int)] = []
    public private(set) var powerUps: [(PowerUp, Int)] = []
    public private(set) var extraLives: [ExtraLifeMethod] = []
    public private(set) var achievements: [(String, Int)] = []
    public private(set) var disconnects: [(Int, String, String)] = []

    public init() {}

    public func logGameStarted(category: String?, mode: GameMode) {
        gameStarts.append((category, mode))
    }

    public func logGameEnded(score: Int, livesRemaining: Int, questionsAnswered: Int, coinsEarned: Int, category: String?, mode: GameMode) {
        gameEnds.append((score, livesRemaining, questionsAnswered, coinsEarned))
    }

    public func logPowerUpUsed(type: PowerUp, coinsSpent: Int) {
        powerUps.append((type, coinsSpent))
    }

    public func logExtraLifeUsed(method: ExtraLifeMethod) {
        extraLives.append(method)
    }

    public func logAchievementUnlocked(achievementId: String, coinReward: Int) {
        achievements.append((achievementId, coinReward))
    }

    public func logMultiplayerDisconnect(questionsCompleted: Int, reason: String, transportType: String) {
        disconnects.append((questionsCompleted, reason, transportType))
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

    public init(isLoaded: Bool = false) {
        self.isLoaded = isLoaded
    }

    public func load() {
        loadCount += 1
    }

    public func show(completion: @escaping @MainActor (Bool) -> Void) {
        showCount += 1
        self.completion = completion
    }

    public func completeReward(earned: Bool) {
        completion?(earned)
        completion = nil
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

public final class RecordingHaptics: HapticProvider, @unchecked Sendable {
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

    private var continuation: AsyncStream<MultiplayerTransportEvent>.Continuation

    public init(
        localPlayer: MultiplayerPlayer = MultiplayerPlayer(id: "test", displayName: "Test")
    ) {
        self.localPlayer = localPlayer
        let (stream, continuation) = AsyncStream.makeStream(of: MultiplayerTransportEvent.self)
        eventStream = stream
        self.continuation = continuation
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

    public func disconnect() {
        connectionState = .disconnected
    }

    public func emit(_ event: MultiplayerTransportEvent) {
        continuation.yield(event)
    }

    public func resetEventStream() {
        continuation.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: MultiplayerTransportEvent.self)
        eventStream = stream
        self.continuation = continuation
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
