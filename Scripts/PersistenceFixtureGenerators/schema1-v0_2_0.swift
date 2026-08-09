//
//  schema1-v0_2_0.swift
//  Historical persistence fixture generator for tag v0.2.0 (schema 1).
//
//  This file is never compiled by the package. `Scripts/generate-persistence-fixtures.sh`
//  copies it into a detached worktree of v0.2.0 as
//  `Sources/PersistenceFixtureGenerator/main.swift`, appends an executable target to
//  that worktree's `Package.swift`, and runs it. Every byte of both emitted fixtures
//  is produced by v0.2.0's own models, envelope codec, and write path.
//
//  Unlike v0.1.x, v0.2.0 exposes a public transactional write path, so this generator
//  seeds prior state through `PlayerProgressManager.importProgress(_:)` rather than by
//  pre-encoding a document. The committed fixture is the primary document left behind
//  after real public engine operations ran on top of that import; the import marker and
//  backup siblings are intentionally not committed.
//
//  Filesystem isolation: the harness sets `CFFIXED_USER_HOME` to a throwaway directory.
//  Determinism: the harness sets `SWIFT_DETERMINISTIC_HASHING=1`, and this generator
//  injects a fixed clock and an explicit UTC Gregorian calendar.
//

import Foundation
import QuizEngineCore

// MARK: - Harness

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: PersistenceFixtureGenerator <output-directory>\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

let documentsDirectory = FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)
    .first!

let isolatedHome = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"]
    .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
guard let isolatedHome,
      documentsDirectory.resolvingSymlinksInPath().path.hasPrefix(isolatedHome) else {
    FileHandle.standardError.write(
        Data(
            """
            refusing to run: the resolved Documents directory is outside CFFIXED_USER_HOME
              CFFIXED_USER_HOME: \(isolatedHome ?? "<unset>")
              Documents:         \(documentsDirectory.resolvingSymlinksInPath().path)

            """.utf8
        )
    )
    exit(3)
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)

func isoDate(_ text: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.formatOptions = [.withInternetDateTime]
    guard let date = formatter.date(from: text) else {
        fatalError("unparsable fixture date: \(text)")
    }
    return date
}

func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

/// A fixed clock so nothing in the emitted documents depends on when they were made.
struct FixtureClock: QuizEngineClock {
    let now: Date
}

var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

func makeVariant() throws -> QuizVariantDefinition {
    try QuizVariantDefinition(
        categories: [],
        achievements: [],
        questionResource: QuestionResource(bundle: .main, fileName: "fixture_questions")
    )
}

@MainActor
func makeManager(persistenceURL: URL) throws -> PlayerProgressManager {
    PlayerProgressManager(
        variant: try makeVariant(),
        questionDataService: QuestionDataService(bundle: .main, fileName: "fixture_questions"),
        persistenceURL: persistenceURL,
        clock: FixtureClock(now: isoDate("2025-11-04T12:00:00Z")),
        calendar: utcCalendar
    )
}

// MARK: - Value serialization for the manifest

func json(_ stat: CategoryStat) -> [String: Any] {
    var value: [String: Any] = [
        "questionsAnswered": stat.questionsAnswered,
        "questionsCorrect": stat.questionsCorrect,
        "correctlyAnsweredIDs": stat.correctlyAnsweredIDs.sorted(),
        "bestScore": stat.bestScore
    ]
    if let hundred = stat.questionsCountAtHundredPercent {
        value["questionsCountAtHundredPercent"] = hundred
    }
    return value
}

func json(_ stat: DailyStat) -> [String: Any] {
    [
        "questionsAnswered": stat.questionsAnswered,
        "questionsCorrect": stat.questionsCorrect,
        "gamesPlayed": stat.gamesPlayed,
        "totalResponseTimeMs": stat.totalResponseTimeMs,
        "questionsByDifficulty": stat.questionsByDifficulty,
        "correctByDifficulty": stat.correctByDifficulty
    ]
}

func json(_ performance: HourlyPerformance) -> [String: Any] {
    [
        "questionsAnswered": performance.questionsAnswered,
        "questionsCorrect": performance.questionsCorrect,
        "sessionCount": performance.sessionCount
    ]
}

func json(_ progress: PlayerProgress) -> [String: Any] {
    var value: [String: Any] = [
        "coins": progress.coins,
        "currentStreak": progress.currentStreak,
        "longestStreak": progress.longestStreak,
        "totalCoinsEarned": progress.totalCoinsEarned,
        "totalCoinsSpent": progress.totalCoinsSpent,
        "categoryStats": progress.categoryStats.mapValues(json),
        "unlockedPacks": progress.unlockedPacks.sorted(),
        "seenQuestionIDs": progress.seenQuestionIDs.sorted(),
        "unlockedAchievements": progress.unlockedAchievements.sorted(),
        "manuallyUnlockedCategories": progress.manuallyUnlockedCategories.sorted(),
        "lifetimeGamesPlayed": progress.lifetimeGamesPlayed,
        "lifetimeQuestionsAnswered": progress.lifetimeQuestionsAnswered,
        "lifetimeQuestionsCorrect": progress.lifetimeQuestionsCorrect,
        "bestSingleSessionScore": progress.bestSingleSessionScore,
        "bestSingleSessionStreak": progress.bestSingleSessionStreak,
        "powerUpTypesUsed": progress.powerUpTypesUsed.sorted(),
        "dailyStats": progress.dailyStats.mapValues(json),
        "hourlyPerformance": Dictionary(
            uniqueKeysWithValues: progress.hourlyPerformance.map { (String($0.key), json($0.value)) }
        ),
        "lifetimeAverageResponseTimeMs": progress.lifetimeAverageResponseTimeMs,
        "lifetimeResponseTimeSamples": progress.lifetimeResponseTimeSamples,
        "hasReceivedPremiumBonusCoins": progress.hasReceivedPremiumBonusCoins,
        "currentPlayStreak": progress.currentPlayStreak,
        "longestPlayStreak": progress.longestPlayStreak,
        "multiplayerGamesPlayed": progress.multiplayerGamesPlayed,
        "multiplayerGamesWon": progress.multiplayerGamesWon,
        "multiplayerGamesLost": progress.multiplayerGamesLost,
        "multiplayerGamesDraw": progress.multiplayerGamesDraw,
        "bestMultiplayerScore": progress.bestMultiplayerScore,
        "multiplayerWinStreak": progress.multiplayerWinStreak,
        "longestMultiplayerWinStreak": progress.longestMultiplayerWinStreak,
        "multiplayerTotalResponseTimeMs": progress.multiplayerTotalResponseTimeMs,
        "multiplayerTotalQuestionsAnswered": progress.multiplayerTotalQuestionsAnswered,
        "multiplayerTotalQuestionsCorrect": progress.multiplayerTotalQuestionsCorrect,
        "powerUpCredits": Dictionary(
            uniqueKeysWithValues: progress.powerUpCredits.map { ($0.key.rawValue, $0.value) }
        ),
        "multiplayerMatchReceipts": progress.multiplayerMatchReceipts.map {
            ["matchID": $0.matchID, "fingerprint": $0.fingerprint]
        },
        // Reward receipts do not exist in v0.2.0. This is the value the current
        // package must observe after decoding the released schema-1 document.
        "rewardReceipts": [[String: Any]]()
    ]
    if let date = progress.lastAppOpenDate { value["lastAppOpenDate"] = isoString(date) }
    if let date = progress.lastDailyRewardClaimedDate { value["lastDailyRewardClaimedDate"] = isoString(date) }
    if let date = progress.lastRewardAdWatchedDate { value["lastRewardAdWatchedDate"] = isoString(date) }
    if let date = progress.previousAppOpenDate { value["previousAppOpenDate"] = isoString(date) }
    if let date = progress.lastPlayedDate { value["lastPlayedDate"] = isoString(date) }
    if let used = progress.lifetimePowerUpsUsed { value["lifetimePowerUpsUsed"] = used }
    if progress.hasReceivedPremiumBonusCoins {
        // Schema 1 only has the Boolean. Current decoding maps it to a permanent
        // unversioned identity because the original amount/version are unknowable.
        value["premiumBonusClaimedVersion"] = "legacy-unversioned"
        value["premiumBonusClaimedFingerprint"] = "legacy-unversioned"
    }
    return value
}

func writeJSON(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try data.write(to: url)
}

// MARK: - The imported prior state
//
// Every value below is invented test data. It contains no real player, device,
// account, credential, or other secret.

let importedProgress = PlayerProgress(
    coins: 2_075,
    currentStreak: 12,
    longestStreak: 31,
    lastAppOpenDate: isoDate("2025-11-04T08:40:00Z"),
    lastDailyRewardClaimedDate: isoDate("2025-11-04T08:41:10Z"),
    totalCoinsEarned: 9_640,
    totalCoinsSpent: 7_565,
    categoryStats: [
        "history": CategoryStat(
            questionsAnswered: 268,
            questionsCorrect: 221,
            correctlyAnsweredIDs: [3, 17, 42, 88, 101, 133],
            bestScore: 1_460,
            questionsCountAtHundredPercent: nil
        ),
        "geography": CategoryStat(
            questionsAnswered: 190,
            questionsCorrect: 176,
            correctlyAnsweredIDs: [5, 9, 23, 61],
            bestScore: 1_720,
            questionsCountAtHundredPercent: 120
        )
    ],
    unlockedPacks: ["history-expansion", "starter-pack"],
    seenQuestionIDs: [3, 5, 9, 17, 23, 42, 61, 88, 101, 133, 150],
    unlockedAchievements: ["first_win", "history_50", "streak_30"],
    manuallyUnlockedCategories: ["culture", "science"],
    lifetimeGamesPlayed: 147,
    lifetimeQuestionsAnswered: 1_903,
    lifetimeQuestionsCorrect: 1_566,
    bestSingleSessionScore: 1_720,
    bestSingleSessionStreak: 26,
    powerUpTypesUsed: ["fiftyFifty", "skipQuestion", "timeFreeze"],
    lifetimePowerUpsUsed: 82,
    lastRewardAdWatchedDate: isoDate("2025-11-03T19:20:00Z"),
    dailyStats: [
        "2025-11-02": DailyStat(
            questionsAnswered: 33,
            questionsCorrect: 28,
            gamesPlayed: 3,
            totalResponseTimeMs: 182_600,
            questionsByDifficulty: ["1": 13, "2": 14, "3": 6],
            correctByDifficulty: ["1": 13, "2": 11, "3": 4]
        ),
        "2025-11-03": DailyStat(
            questionsAnswered: 27,
            questionsCorrect: 21,
            gamesPlayed: 2,
            totalResponseTimeMs: 149_850,
            questionsByDifficulty: ["1": 11, "2": 10, "3": 6],
            correctByDifficulty: ["1": 10, "2": 8, "3": 3]
        ),
        "2025-11-04": DailyStat(
            questionsAnswered: 14,
            questionsCorrect: 12,
            gamesPlayed: 1,
            totalResponseTimeMs: 70_450,
            questionsByDifficulty: ["1": 6, "2": 5, "3": 3],
            correctByDifficulty: ["1": 6, "2": 4, "3": 2]
        )
    ],
    hourlyPerformance: [
        8: HourlyPerformance(questionsAnswered: 96, questionsCorrect: 81, sessionCount: 11),
        19: HourlyPerformance(questionsAnswered: 214, questionsCorrect: 172, sessionCount: 21),
        22: HourlyPerformance(questionsAnswered: 118, questionsCorrect: 97, sessionCount: 14)
    ],
    lifetimeAverageResponseTimeMs: 5_318,
    lifetimeResponseTimeSamples: 1_903,
    hasReceivedPremiumBonusCoins: false,
    previousAppOpenDate: isoDate("2025-11-03T18:55:00Z"),
    currentPlayStreak: 9,
    longestPlayStreak: 17,
    lastPlayedDate: isoDate("2025-11-03T22:05:00Z"),
    multiplayerGamesPlayed: 41,
    multiplayerGamesWon: 24,
    multiplayerGamesLost: 13,
    multiplayerGamesDraw: 4,
    bestMultiplayerScore: 910,
    multiplayerWinStreak: 2,
    longestMultiplayerWinStreak: 9,
    multiplayerTotalResponseTimeMs: 231_700,
    multiplayerTotalQuestionsAnswered: 410,
    multiplayerTotalQuestionsCorrect: 322,
    multiplayerMatchReceipts: [
        MultiplayerMatchReceipt(matchID: "fixture-match-0001", fingerprint: "fp-0001-host-win-780")
    ],
    powerUpCredits: [.fiftyFifty: 3, .skipQuestion: 2]
)

// MARK: - Generation

@MainActor
func generateFixtures() throws {
    let progressURL = documentsDirectory.appendingPathComponent("player_progress.plist")
    let manager = try makeManager(persistenceURL: progressURL)

    // Seed through the public import transaction, which writes the schema-1 envelope
    // with v0.2.0's own codec.
    let request = try PlayerProgressImportRequest(
        identifier: "fixture-import-v0.2.0",
        sourceFingerprint: "fixture-source-fingerprint",
        progress: importedProgress
    )
    let importResult = try manager.importProgress(request)
    precondition(importResult == .imported, "the seed import must succeed")

    // Deterministic public engine operations on top of the imported state.
    manager.addCoins(60)
    precondition(manager.spendCoins(140), "spendCoins must succeed with this balance")
    precondition(manager.grantPowerUpCredits(4, for: .timeFreeze), "granting credits must succeed")
    precondition(
        manager.consumePowerUp(.fiftyFifty)?.fundingSource == .freeCredit,
        "the first 50/50 activation must be funded by a credit"
    )
    manager.recordCorrectAnswer(questionID: 402, category: "science")
    manager.recordWrongAnswer(questionID: 403, category: "science")
    manager.updateBestScore(category: "science", sessionScore: 880)
    manager.recordQuestionSeen(questionID: 511)
    manager.recordSessionStats(
        questionsAnswered: 15,
        questionsCorrect: 13,
        sessionScore: 1_840,
        longestStreak: 28,
        usedPowerUps: [.streakShield]
    )
    let recordingOutcome = manager.recordMultiplayerResult(
        matchID: "fixture-match-0002",
        fingerprint: "fp-0002-guest-draw-640",
        won: false,
        draw: true,
        score: 640,
        questionsCompleted: 10,
        questionsCorrect: 7,
        coinsEarned: 30,
        responseTimes: [4_100, 3_650, 2_900]
    )
    precondition(recordingOutcome == .recorded, "the second receipt must be newly recorded")
    precondition(
        manager.unlockAchievement(id: "science_starter", coinReward: 25),
        "science_starter must be newly unlocked"
    )
    manager.markPremiumBonusCoinsReceived()

    // Preferences, written through the public injected-store path so a failure is not
    // swallowed. This is the same schema-1 envelope the non-throwing URL overload writes.
    let preferencesURL = documentsDirectory.appendingPathComponent("user_preferences.plist")
    try UserPreferencesLoader.write(
        preferences: UserPreferences(hapticsEnabled: false),
        to: FileQuizEnginePersistenceStore(primaryURL: preferencesURL)
    )

    // Collect. Only the primary documents are committed; the import marker and the
    // backup siblings are deliberately left behind in the throwaway directory.
    try FileManager.default.copyItem(
        at: progressURL,
        to: outputDirectory.appendingPathComponent("player_progress_schema_1.plist")
    )
    try FileManager.default.copyItem(
        at: preferencesURL,
        to: outputDirectory.appendingPathComponent("user_preferences_schema_1.plist")
    )

    // Re-read the emitted documents through v0.2.0's own decoder and publish what they
    // actually contain, so the manifest describes the artifact rather than an intent.
    let reloaded = try makeManager(persistenceURL: progressURL)
    let reloadedPreferences = try UserPreferencesLoader.load(
        from: FileQuizEnginePersistenceStore(primaryURL: preferencesURL)
    )

    try writeJSON(
        [
            "player_progress_schema_1.plist": json(reloaded.progress),
            "user_preferences_schema_1.plist": ["hapticsEnabled": reloadedPreferences.hapticsEnabled]
        ],
        to: outputDirectory.appendingPathComponent("observed-values.json")
    )

    print("wrote 2 fixtures to \(outputDirectory.path)")
}

try MainActor.assumeIsolated { try generateFixtures() }
