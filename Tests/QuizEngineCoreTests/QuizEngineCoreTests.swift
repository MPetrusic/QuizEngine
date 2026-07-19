import XCTest
@testable import QuizEngineCore

@MainActor
final class QuizEngineCoreTests: XCTestCase {
    private var service: QuestionDataService {
        QuestionDataService(bundle: .module, fileName: "alternate_questions")
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

    private func makeAlternateVariant(
        categories: [QuizCategoryDefinition]? = nil,
        achievements: [AchievementDefinition]? = nil,
        fileName: String = "alternate_questions"
    ) throws -> QuizVariantDefinition {
        try QuizVariantDefinition(
            categories: categories ?? [
                .init(id: "space", displayNameKey: "category.space", iconName: "moon", displayOrder: 1, unlockRequirement: .coins(amount: 25)),
                .init(id: "nature", displayNameKey: "category.nature", iconName: "leaf", displayOrder: 0, unlockRequirement: .free),
                .init(id: "future", displayNameKey: "category.future", iconName: "sparkles", displayOrder: 2, unlockRequirement: .categoryCompletion(categoryID: "nature", percentage: 50))
            ],
            achievements: achievements ?? achievementRules,
            questionResource: QuestionResource(bundle: .module, fileName: fileName)
        )
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

    func testVariantSortsCategoriesAndSupportsDifferentIdentifiers() throws {
        let variant = try makeAlternateVariant()
        XCTAssertEqual(variant.categories.map(\.id), ["nature", "space", "future"])
        XCTAssertEqual(variant.category(id: "SPACE")?.coinCost, 25)
        XCTAssertNil(variant.category(id: "history"))
    }

    func testVariantValidationRejectsInvalidConfiguration() throws {
        let duplicate = try makeAlternateVariant().categories + [
            .init(id: "nature", displayNameKey: "category.duplicate", iconName: "leaf", displayOrder: 3, unlockRequirement: .free)
        ]
        XCTAssertThrowsError(try makeAlternateVariant(categories: duplicate)) { error in
            XCTAssertEqual(error as? QuizVariantValidationError, .duplicateCategoryID("nature"))
        }

        let duplicateOrder = [
            QuizCategoryDefinition(id: "nature", displayNameKey: "category.nature", iconName: "leaf", displayOrder: 0, unlockRequirement: .free),
            QuizCategoryDefinition(id: "space", displayNameKey: "category.space", iconName: "moon", displayOrder: 0, unlockRequirement: .free)
        ]
        XCTAssertThrowsError(try makeAlternateVariant(categories: duplicateOrder)) { error in
            XCTAssertEqual(error as? QuizVariantValidationError, .duplicateCategoryDisplayOrder(0))
        }

        let invalidUnlock = [
            QuizCategoryDefinition(id: "nature", displayNameKey: "category.nature", iconName: "leaf", displayOrder: 0, unlockRequirement: .categoryCompletion(categoryID: "missing", percentage: 50))
        ]
        XCTAssertThrowsError(try makeAlternateVariant(categories: invalidUnlock))

        let invalidAchievement = [
            AchievementDefinition(id: "missing_category", type: .category, coinReward: 1, rule: .categoryCorrect(categoryID: "missing", minimum: 1))
        ]
        XCTAssertThrowsError(try makeAlternateVariant(achievements: invalidAchievement))
        XCTAssertThrowsError(try makeAlternateVariant(fileName: " "))
    }

    func testEveryAchievementRuleUnlocksAtExactAndAboveThresholdAndReportsProgress() throws {
        let variant = try makeAlternateVariant()
        let achievementService = AchievementService(variant: variant)
        let calendar = utcCalendar
        let outsideNightWindow = date(hour: 12, calendar: calendar)

        for definition in variant.achievements {
            XCTAssertFalse(
                achievementService.checkAchievements(
                    progress: belowThresholdProgress,
                    date: outsideNightWindow,
                    calendar: calendar
                ).contains(where: { $0.id == definition.id }),
                "Expected \(definition.id) to remain locked below threshold"
            )

            let exact = progress(for: definition.rule, increase: 0, date: outsideNightWindow, calendar: calendar)
            let exactDate = evaluationDate(for: definition.rule, calendar: calendar, above: false)
            XCTAssertTrue(
                achievementService.checkAchievements(progress: exact, date: exactDate, calendar: calendar)
                    .contains(where: { $0.id == definition.id }),
                "Expected \(definition.id) to unlock at threshold"
            )

            let above = progress(for: definition.rule, increase: 1, date: outsideNightWindow, calendar: calendar)
            let aboveDate = evaluationDate(for: definition.rule, calendar: calendar, above: true)
            XCTAssertTrue(
                achievementService.checkAchievements(progress: above, date: aboveDate, calendar: calendar)
                    .contains(where: { $0.id == definition.id }),
                "Expected \(definition.id) to unlock above threshold"
            )

            if let progress = achievementService.getProgress(for: definition, progress: exact) {
                XCTAssertEqual(progress.current, progress.target, "Expected exact progress for \(definition.id)")
            } else {
                switch definition.rule {
                case .comeback, .localHour:
                    break
                default:
                    XCTFail("Expected numeric progress for \(definition.id)")
                }
            }
        }
    }

    func testAchievementRulesIgnoreStaleCategoryProgress() throws {
        let variant = try makeAlternateVariant()
        let service = AchievementService(variant: variant)
        var progress = PlayerProgress.default
        progress.categoryStats = [
            "stale": CategoryStat(correctlyAnsweredIDs: Set(1...100)),
            "nature": CategoryStat(correctlyAnsweredIDs: [1])
        ]

        let anyCategory = AchievementDefinition(id: "any", type: .category, coinReward: 1, rule: .anyCategoryCorrect(minimum: 2))
        let categories = AchievementDefinition(id: "categories", type: .category, coinReward: 1, rule: .categoriesCorrect(categoryCount: 2, minimumPerCategory: 1))
        XCTAssertEqual(service.getProgress(for: anyCategory, progress: progress)?.current, 1)
        XCTAssertEqual(service.getProgress(for: categories, progress: progress)?.current, 1)
    }

    func testCategoryUnlockRulesUseVariantDefinitionsAndRejectUnknownPremiumIDs() throws {
        let variant = try makeAlternateVariant()
        let manager = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            purchaseStatus: PremiumPurchaseStatus(),
            persistenceURL: try temporaryProgressURL()
        )

        XCTAssertTrue(manager.isCategoryUnlocked("nature"))
        XCTAssertTrue(manager.isCategoryUnlocked("space"))
        XCTAssertFalse(manager.isCategoryUnlocked("unknown"))
        XCTAssertEqual(manager.getUnlockProgress(for: "space").coinCost, 25)
        XCTAssertFalse(manager.getUnlockProgress(for: "unknown").isUnlocked)
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

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(hour: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 7, day: 12, hour: hour))!
    }

    private func evaluationDate(for rule: AchievementRule, calendar: Calendar, above: Bool) -> Date {
        if case .localHour(let start, let end) = rule {
            return date(hour: above && start + 1 < end ? start + 1 : start, calendar: calendar)
        }
        return date(hour: 12, calendar: calendar)
    }

    private func progress(
        for rule: AchievementRule,
        increase: Int,
        date: Date,
        calendar: Calendar
    ) -> PlayerProgress {
        var progress = PlayerProgress.default
        switch rule {
        case .playStreak(let minimum):
            progress.currentPlayStreak = minimum + increase
            progress.longestPlayStreak = minimum + increase
        case .bestScore(let minimum): progress.bestSingleSessionScore = minimum + increase
        case .bestAnswerStreak(let minimum): progress.bestSingleSessionStreak = minimum + increase
        case .anyCategoryCorrect(let minimum): progress.categoryStats["nature"] = CategoryStat(correctlyAnsweredIDs: Set(1...(minimum + increase)))
        case .categoryCorrect(let categoryID, let minimum): progress.categoryStats[categoryID] = CategoryStat(correctlyAnsweredIDs: Set(1...(minimum + increase)))
        case .categoriesCorrect(let count, let minimum):
            for categoryID in ["nature", "space", "future"].prefix(count) {
                progress.categoryStats[categoryID] = CategoryStat(correctlyAnsweredIDs: Set(1...(minimum + increase)))
            }
        case .lifetimeGames(let minimum): progress.lifetimeGamesPlayed = minimum + increase
        case .lifetimeQuestions(let minimum): progress.lifetimeQuestionsAnswered = minimum + increase
        case .totalCoinsEarned(let minimum): progress.totalCoinsEarned = minimum + increase
        case .powerUpTypesUsed(let minimum): progress.powerUpTypesUsed = Set((0..<(minimum + increase)).map(String.init))
        case .lifetimePowerUpsUsed(let minimum): progress.lifetimePowerUpsUsed = minimum + increase
        case .comeback(let minimumDaysAway): progress.previousAppOpenDate = calendar.date(byAdding: .day, value: -(minimumDaysAway + increase), to: date)
        case .localHour: break
        }
        return progress
    }

    private var belowThresholdProgress: PlayerProgress {
        var progress = PlayerProgress.default
        progress.currentPlayStreak = 0
        progress.longestPlayStreak = 0
        progress.bestSingleSessionScore = 0
        progress.bestSingleSessionStreak = 0
        progress.categoryStats = [:]
        progress.lifetimeGamesPlayed = 0
        progress.lifetimeQuestionsAnswered = 0
        progress.totalCoinsEarned = 0
        progress.powerUpTypesUsed = []
        progress.lifetimePowerUpsUsed = 0
        progress.previousAppOpenDate = nil
        return progress
    }

    private func temporaryProgressURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("player_progress.plist")
    }
}

private final class PremiumPurchaseStatus: PurchaseStatusProvider {
    let isPremium = true
    let adsRemoved = true
}
