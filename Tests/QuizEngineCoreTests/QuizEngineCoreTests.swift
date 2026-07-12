import XCTest
@testable import QuizEngineCore

@MainActor
final class QuizEngineCoreTests: XCTestCase {
    private var service: QuestionDataService {
        QuestionDataService(bundle: .module, fileName: "alternate_questions")
    }

    private var alternateVariant: QuizVariantDefinition {
        QuizVariantDefinition(
            categories: [
                .init(id: "space", displayNameKey: "category.space", iconName: "moon", displayOrder: 1, unlockRequirement: .coins(amount: 25)),
                .init(id: "nature", displayNameKey: "category.nature", iconName: "leaf", displayOrder: 0, unlockRequirement: .free),
                .init(id: "future", displayNameKey: "category.future", iconName: "sparkles", displayOrder: 2, unlockRequirement: .categoryCompletion(categoryID: "nature", percentage: 50))
            ],
            achievements: achievementRules,
            questionResource: QuestionResource(bundle: .module, fileName: "alternate_questions")
        )
    }

    private var achievementRules: [AchievementDefinition] {
        [
            .init(id: "streak", type: .streak, coinReward: 1, rule: .playStreak(minimum: 3)),
            .init(id: "score", type: .score, coinReward: 1, rule: .bestScore(minimum: 100)),
            .init(id: "answers", type: .accuracy, coinReward: 1, rule: .bestAnswerStreak(minimum: 5)),
            .init(id: "any_category", type: .category, coinReward: 1, rule: .anyCategoryCorrect(minimum: 2)),
            .init(id: "nature", type: .category, coinReward: 1, rule: .categoryCorrect(categoryID: "nature", minimum: 2)),
            .init(id: "two_categories", type: .category, coinReward: 1, rule: .categoriesCorrect(categoryCount: 2, minimumPerCategory: 2)),
            .init(id: "games", type: .lifetime, coinReward: 1, rule: .lifetimeGames(minimum: 10)),
            .init(id: "questions", type: .lifetime, coinReward: 1, rule: .lifetimeQuestions(minimum: 20)),
            .init(id: "coins", type: .lifetime, coinReward: 1, rule: .totalCoinsEarned(minimum: 30)),
            .init(id: "power_types", type: .powerUp, coinReward: 1, rule: .powerUpTypesUsed(minimum: 2)),
            .init(id: "power_count", type: .powerUp, coinReward: 1, rule: .lifetimePowerUpsUsed(minimum: 4)),
            .init(id: "comeback", type: .special, coinReward: 1, rule: .comeback(minimumDaysAway: 30)),
            .init(id: "night", type: .special, coinReward: 1, rule: .localHour(startInclusive: 0, endExclusive: 5))
        ]
    }

    func testExplicitQuestionResourceLoadsAlternateFile() throws {
        let data = try service.getQuestionData()
        XCTAssertEqual(data.questions.count, 3)
        XCTAssertEqual(try service.getAllCategories(), ["nature", "space"])
    }

    func testMissingQuestionResourceReportsConfiguredFilename() {
        let missing = QuestionDataService(bundle: .module, fileName: "not_the_default_name")
        XCTAssertThrowsError(try missing.getQuestionData()) { error in
            guard case QuestionDataError.fileNotFound(let name) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(name, "not_the_default_name")
        }
    }

    func testVariantSortsCategoriesAndSupportsDifferentIdentifiers() {
        XCTAssertEqual(alternateVariant.categories.map(\.id), ["nature", "space", "future"])
        XCTAssertEqual(alternateVariant.category(id: "SPACE")?.coinCost, 25)
        XCTAssertNil(alternateVariant.category(id: "history"))
    }

    func testGenericAchievementEvaluatorCoversEveryRule() {
        var progress = PlayerProgress.default
        progress.longestPlayStreak = 3
        progress.currentPlayStreak = 3
        progress.bestSingleSessionScore = 100
        progress.bestSingleSessionStreak = 5
        progress.categoryStats = [
            "nature": CategoryStat(correctlyAnsweredIDs: [1, 2]),
            "space": CategoryStat(correctlyAnsweredIDs: [3, 4])
        ]
        progress.lifetimeGamesPlayed = 10
        progress.lifetimeQuestionsAnswered = 20
        progress.totalCoinsEarned = 30
        progress.powerUpTypesUsed = ["a", "b"]
        progress.lifetimePowerUpsUsed = 4

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: 2))!
        progress.previousAppOpenDate = calendar.date(byAdding: .day, value: -31, to: now)

        let service = AchievementService(definitions: achievementRules)
        let unlocked = service.checkAchievements(progress: progress, date: now, calendar: calendar)
        XCTAssertEqual(Set(unlocked.map(\.id)), Set(achievementRules.map(\.id)))
        XCTAssertEqual(service.getProgress(for: achievementRules[5], progress: progress)?.current, 2)
    }

    func testCategoryUnlockRulesUseVariantDefinitions() throws {
        let manager = PlayerProgressManager(
            variant: alternateVariant,
            questionDataService: service,
            persistenceURL: try temporaryProgressURL()
        )

        XCTAssertTrue(manager.isCategoryUnlocked("nature"))
        XCTAssertFalse(manager.isCategoryUnlocked("space"))
        XCTAssertFalse(manager.isCategoryUnlocked("unknown"))
        XCTAssertEqual(manager.getUnlockProgress(for: "space", totalQuestionsInCategory: 1).coinCost, 25)
    }

    func testLegacyProgressPlistPreservesStoredIdentifiersAndDefaultsNewFields() throws {
        let legacy: [String: Any] = [
            "coins": 321,
            "unlockedAchievements": ["legacy_achievement"],
            "manuallyUnlockedCategories": ["legacy_category"],
            "lifetimeGamesPlayed": 9
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: legacy, format: .xml, options: 0)
        let decoded = try PropertyListDecoder().decode(PlayerProgress.self, from: data)

        XCTAssertEqual(decoded.coins, 321)
        XCTAssertEqual(decoded.unlockedAchievements, ["legacy_achievement"])
        XCTAssertEqual(decoded.manuallyUnlockedCategories, ["legacy_category"])
        XCTAssertEqual(decoded.lifetimeGamesPlayed, 9)
        XCTAssertEqual(decoded.multiplayerGamesPlayed, 0)
    }

    private func temporaryProgressURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("player_progress.plist")
    }
}
