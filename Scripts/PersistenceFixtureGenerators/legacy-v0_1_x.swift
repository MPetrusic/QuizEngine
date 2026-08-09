//
//  legacy-v0_1_x.swift
//  Historical persistence fixture generator for tags v0.1.0 ... v0.1.3.
//
//  This file is never compiled by the package. `Scripts/generate-persistence-fixtures.sh`
//  copies it into a detached worktree of the target tag as
//  `Sources/PersistenceFixtureGenerator/main.swift`, appends an executable target to
//  that worktree's `Package.swift`, and runs it. Every byte of every emitted fixture
//  is therefore produced by the tag's own model, encoder, and `PlayerProgressManager.save()`.
//
//  The four v0.1.x tags share this generator because `PlayerProgress`, its `Codable`
//  conformance, `UserPreferences`, `PlayerProgressManager.save()` and
//  `UserPreferencesLoader.write(preferences:)` are byte-identical across them.
//  v0.1.3 additionally accepts an explicit URL in `UserPreferencesLoader.write(preferences:to:)`;
//  this generator deliberately uses the no-URL overload that every tag has, so all four
//  fixtures exercise the same shipped code path.
//
//  Filesystem isolation: the harness sets `CFFIXED_USER_HOME` to a throwaway directory,
//  so `FileManager.default.urls(for: .documentDirectory, ...)` — which v0.1.x resolves
//  internally and cannot be redirected for preferences — lands inside that directory.
//  No real Documents directory is read or written.
//
//  Determinism: the harness sets `SWIFT_DETERMINISTIC_HASHING=1` so `Set` and
//  `Dictionary` iteration order, and therefore the encoded bytes, are reproducible.
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

// A real Documents directory must never be touched. `CFFIXED_USER_HOME` is the only
// supported way to redirect the Darwin home directory, so refuse to run without it.
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

func makeVariant() throws -> QuizVariantDefinition {
    // The generator never reads question content; the resource only has to be
    // structurally valid so the variant initializer accepts it.
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
        persistenceURL: persistenceURL
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
        // Fields that do not exist in the v0.1.x model. The current package defaults
        // them on load, and the migration tests assert exactly these defaults.
        "powerUpCredits": [String: Int](),
        "multiplayerMatchReceipts": [[String: String]]()
    ]
    if let date = progress.lastAppOpenDate { value["lastAppOpenDate"] = isoString(date) }
    if let date = progress.lastDailyRewardClaimedDate { value["lastDailyRewardClaimedDate"] = isoString(date) }
    if let date = progress.lastRewardAdWatchedDate { value["lastRewardAdWatchedDate"] = isoString(date) }
    if let date = progress.previousAppOpenDate { value["previousAppOpenDate"] = isoString(date) }
    if let date = progress.lastPlayedDate { value["lastPlayedDate"] = isoString(date) }
    if let used = progress.lifetimePowerUpsUsed { value["lifetimePowerUpsUsed"] = used }
    return value
}

func writeJSON(_ value: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    try data.write(to: url)
}

// MARK: - The seed used for the populated fixture
//
// Every value below is invented test data. It contains no real player, device,
// account, credential, or other secret.

let seededProgress = PlayerProgress(
    coins: 1_240,
    currentStreak: 7,
    longestStreak: 23,
    lastAppOpenDate: isoDate("2025-03-14T09:15:00Z"),
    lastDailyRewardClaimedDate: isoDate("2025-03-14T09:16:30Z"),
    totalCoinsEarned: 4_820,
    totalCoinsSpent: 3_580,
    categoryStats: [
        "history": CategoryStat(
            questionsAnswered: 142,
            questionsCorrect: 118,
            correctlyAnsweredIDs: [3, 17, 42, 88, 101],
            bestScore: 940,
            questionsCountAtHundredPercent: nil
        ),
        "geography": CategoryStat(
            questionsAnswered: 96,
            questionsCorrect: 91,
            correctlyAnsweredIDs: [5, 9, 23],
            bestScore: 1_180,
            questionsCountAtHundredPercent: 120
        )
    ],
    unlockedPacks: ["history-expansion", "starter-pack"],
    seenQuestionIDs: [3, 5, 9, 17, 23, 42, 88, 101, 150],
    unlockedAchievements: ["first_win", "history_50", "streak_7"],
    manuallyUnlockedCategories: ["culture"],
    lifetimeGamesPlayed: 63,
    lifetimeQuestionsAnswered: 812,
    lifetimeQuestionsCorrect: 655,
    bestSingleSessionScore: 1_180,
    bestSingleSessionStreak: 19,
    powerUpTypesUsed: ["fiftyFifty", "skipQuestion"],
    lifetimePowerUpsUsed: 34,
    lastRewardAdWatchedDate: isoDate("2025-03-13T18:45:00Z"),
    dailyStats: [
        "2025-03-12": DailyStat(
            questionsAnswered: 24,
            questionsCorrect: 19,
            gamesPlayed: 2,
            totalResponseTimeMs: 138_400,
            questionsByDifficulty: ["1": 10, "2": 9, "3": 5],
            correctByDifficulty: ["1": 9, "2": 7, "3": 3]
        ),
        "2025-03-13": DailyStat(
            questionsAnswered: 31,
            questionsCorrect: 27,
            gamesPlayed: 3,
            totalResponseTimeMs: 171_950,
            questionsByDifficulty: ["1": 12, "2": 13, "3": 6],
            correctByDifficulty: ["1": 12, "2": 11, "3": 4]
        ),
        "2025-03-14": DailyStat(
            questionsAnswered: 8,
            questionsCorrect: 6,
            gamesPlayed: 1,
            totalResponseTimeMs: 41_300,
            questionsByDifficulty: ["1": 3, "2": 3, "3": 2],
            correctByDifficulty: ["1": 3, "2": 2, "3": 1]
        )
    ],
    hourlyPerformance: [
        9: HourlyPerformance(questionsAnswered: 48, questionsCorrect: 39, sessionCount: 5),
        18: HourlyPerformance(questionsAnswered: 133, questionsCorrect: 104, sessionCount: 12),
        21: HourlyPerformance(questionsAnswered: 77, questionsCorrect: 68, sessionCount: 9)
    ],
    lifetimeAverageResponseTimeMs: 5_742,
    lifetimeResponseTimeSamples: 812,
    hasReceivedPremiumBonusCoins: false,
    previousAppOpenDate: isoDate("2025-03-12T20:05:00Z"),
    currentPlayStreak: 4,
    longestPlayStreak: 11,
    lastPlayedDate: isoDate("2025-03-13T21:30:00Z"),
    multiplayerGamesPlayed: 18,
    multiplayerGamesWon: 11,
    multiplayerGamesLost: 5,
    multiplayerGamesDraw: 2,
    bestMultiplayerScore: 730,
    multiplayerWinStreak: 3,
    longestMultiplayerWinStreak: 6,
    multiplayerTotalResponseTimeMs: 96_400,
    multiplayerTotalQuestionsAnswered: 180,
    multiplayerTotalQuestionsCorrect: 141
)

// MARK: - Generation

@MainActor
func generateFixtures() throws {
    // Fixture 1: the document a brand-new v0.1.x install writes on its first save.

    let defaultWorkDirectory = documentsDirectory.appendingPathComponent("default", isDirectory: true)
    try FileManager.default.createDirectory(at: defaultWorkDirectory, withIntermediateDirectories: true)
    let defaultProgressURL = defaultWorkDirectory.appendingPathComponent("player_progress.plist")

    let defaultManager = try makeManager(persistenceURL: defaultProgressURL)
    // No prior document exists, so the manager holds `PlayerProgress.default`.
    // `addCoins(0)` is the smallest public call that triggers the tag's own `save()`
    // without altering any field, so the emitted bytes are the tag's encoding of
    // `PlayerProgress.default` exactly.
    defaultManager.addCoins(0)

    // Fixture 2: a populated document.

    let populatedWorkDirectory = documentsDirectory.appendingPathComponent("populated", isDirectory: true)
    try FileManager.default.createDirectory(at: populatedWorkDirectory, withIntermediateDirectories: true)
    let populatedProgressURL = populatedWorkDirectory.appendingPathComponent("player_progress.plist")

    // Seed the prior-session state using the tag's own model and encoder, exactly as
    // the tag's `save()` writes it. The seed is an intermediate artifact and is never
    // committed; the committed fixture below is rewritten by the tag's `save()` after
    // real public engine operations run against the decoded seed.
    try PropertyListEncoder().encode(seededProgress).write(to: populatedProgressURL)

    let populatedManager = try makeManager(persistenceURL: populatedProgressURL)
    precondition(populatedManager.coins == 1_240, "seed was not decoded by the tag's decoder")

    // Deterministic public engine operations. None of these reads the wall clock.
    populatedManager.addCoins(35)
    precondition(populatedManager.spendCoins(25), "spendCoins must succeed with this balance")
    populatedManager.recordCorrectAnswer(questionID: 207, category: "science")
    populatedManager.recordWrongAnswer(questionID: 208, category: "science")
    populatedManager.updateBestScore(category: "science", sessionScore: 640)
    populatedManager.recordQuestionSeen(questionID: 301)
    populatedManager.recordSessionStats(
        questionsAnswered: 12,
        questionsCorrect: 10,
        sessionScore: 1_300,
        longestStreak: 21,
        usedPowerUps: [.timeFreeze]
    )
    populatedManager.recordPowerUpUsed(.streakShield)
    populatedManager.recordMultiplayerResult(
        won: true,
        draw: false,
        score: 780,
        questionsCompleted: 10,
        questionsCorrect: 8,
        coinsEarned: 45,
        responseTimes: [3_100, 2_400, 5_200]
    )
    precondition(
        populatedManager.unlockAchievement(id: "science_starter", coinReward: 20),
        "science_starter must be newly unlocked"
    )
    populatedManager.markPremiumBonusCoinsReceived()

    // Fixture 3: preferences.

    // `hapticsEnabled: false` is the only nondefault value the v0.1.x model can
    // express; the loader returns `true` when the document is missing or undecodable.
    UserPreferencesLoader.write(preferences: UserPreferences(hapticsEnabled: false))
    let preferencesURL = documentsDirectory.appendingPathComponent("user_preferences.plist")

    // Collect.

    try FileManager.default.copyItem(
        at: defaultProgressURL,
        to: outputDirectory.appendingPathComponent("player_progress_default.plist")
    )
    try FileManager.default.copyItem(
        at: populatedProgressURL,
        to: outputDirectory.appendingPathComponent("player_progress_populated.plist")
    )
    try FileManager.default.copyItem(
        at: preferencesURL,
        to: outputDirectory.appendingPathComponent("user_preferences.plist")
    )

    // Re-read each emitted document through the tag's own decoder and publish what it
    // actually contains, so the manifest describes the artifact rather than an intent.
    let reloadedDefault = try makeManager(persistenceURL: defaultProgressURL)
    let reloadedPopulated = try makeManager(persistenceURL: populatedProgressURL)
    let reloadedPreferences = UserPreferencesLoader.load()

    try writeJSON(
        [
            "player_progress_default.plist": json(reloadedDefault.progress),
            "player_progress_populated.plist": json(reloadedPopulated.progress),
            "user_preferences.plist": ["hapticsEnabled": reloadedPreferences.hapticsEnabled]
        ],
        to: outputDirectory.appendingPathComponent("observed-values.json")
    )

    print("wrote 3 fixtures to \(outputDirectory.path)")
}

try MainActor.assumeIsolated { try generateFixtures() }
