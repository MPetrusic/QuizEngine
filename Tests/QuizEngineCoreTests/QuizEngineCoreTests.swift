import XCTest
@testable import QuizEngineCore
import QuizEngineTestSupport

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
        let persistence = try TemporaryPersistence()
        let manager = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            purchaseStatus: PremiumPurchaseStatus(),
            persistenceURL: persistence.progressURL
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

    func testQuestionSelectionUsesInjectedRandomNumberGenerator() throws {
        let first = QuestionDataService(
            bundle: .module,
            fileName: "alternate_questions",
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 123)
        )
        let second = QuestionDataService(
            bundle: .module,
            fileName: "alternate_questions",
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 123)
        )

        XCTAssertEqual(
            try first.getQuestionsForCompetitiveMode().map(\.id),
            try second.getQuestionsForCompetitiveMode().map(\.id)
        )
    }

    func testProgressManagerUsesTemporaryPersistenceAndInjectedTime() throws {
        let persistence = try TemporaryPersistence()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let clock = TestClock(now: calendar.date(from: DateComponents(year: 2026, month: 8, day: 2, hour: 12))!)
        let variant = try makeAlternateVariant()

        let manager = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            persistenceURL: persistence.progressURL,
            clock: clock,
            calendar: calendar
        )
        manager.handleAppOpen()
        XCTAssertEqual(manager.currentStreak, 1)
        XCTAssertEqual(manager.claimDailyReward(), 10)

        clock.advance(by: 24 * 60 * 60)
        manager.handleAppOpen()
        XCTAssertEqual(manager.currentStreak, 2)
        XCTAssertEqual(manager.claimDailyReward(), 15)

        let reloaded = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            persistenceURL: persistence.progressURL,
            clock: clock,
            calendar: calendar
        )
        XCTAssertEqual(reloaded.currentStreak, 2)
        XCTAssertEqual(reloaded.coins, 125)
    }

    func testUserPreferencesCanUseTemporaryPersistence() throws {
        let persistence = try TemporaryPersistence()
        let preferences = UserPreferences(hapticsEnabled: false)

        UserPreferencesLoader.write(preferences: preferences, to: persistence.preferencesURL)

        XCTAssertFalse(UserPreferencesLoader.load(from: persistence.preferencesURL).hapticsEnabled)
    }

    func testVersionedProgressWriteReloadsThroughInjectedStore() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)

        manager.addCoins(25)

        XCTAssertEqual(manager.persistenceStatus, .saved)
        XCTAssertNil(manager.lastPersistenceError)
        XCTAssertNotNil(store.primaryData)

        let reloaded = try makeManager(store: store)
        XCTAssertEqual(reloaded.coins, 125)
        XCTAssertEqual(reloaded.persistenceStatus, .loaded(schemaVersion: 1))

        let propertyList = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: try XCTUnwrap(store.primaryData), options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(propertyList["schemaVersion"] as? Int, QuizEnginePersistenceSchema.current)
    }

    func testFileStoreLeavesBackupAndCleansTemporaryFilesAfterReplacement() throws {
        let persistence = try TemporaryPersistence()
        let variant = try makeAlternateVariant()
        let manager = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            persistenceURL: persistence.progressURL
        )

        manager.addCoins(1)
        manager.addCoins(1)

        XCTAssertTrue(FileManager.default.fileExists(atPath: persistence.progressURL.path + ".backup"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.progressURL.path + ".tmp"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.progressURL.path + ".backup.tmp"))

        try Data("stale primary temp".utf8).write(to: URL(fileURLWithPath: persistence.progressURL.path + ".tmp"))
        try Data("stale backup temp".utf8).write(to: URL(fileURLWithPath: persistence.progressURL.path + ".backup.tmp"))
        try Data("stale marker temp".utf8).write(to: URL(fileURLWithPath: persistence.progressURL.path + ".import-marker.tmp"))
        _ = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            persistenceURL: persistence.progressURL
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.progressURL.path + ".tmp"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.progressURL.path + ".backup.tmp"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: persistence.progressURL.path + ".import-marker.tmp"))
    }

    func testLegacyProgressLoadsAndNextSavePromotesToVersionedEnvelope() throws {
        var legacyProgress = PlayerProgress.default
        legacyProgress.coins = 321
        let legacyData = try PropertyListEncoder().encode(legacyProgress)
        let store = FakePersistenceStore(primaryData: legacyData)

        let manager = try makeManager(store: store)
        XCTAssertEqual(manager.coins, 321)
        XCTAssertEqual(manager.persistenceStatus, .loadedLegacy)

        manager.addCoins(1)

        let propertyList = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: try XCTUnwrap(store.primaryData), options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(propertyList["schemaVersion"] as? Int, QuizEnginePersistenceSchema.current)
        XCTAssertEqual(manager.coins, 322)
    }

    func testCompatibilityInitializerExposesMalformedPersistenceWithoutThrowing() throws {
        let persistence = try TemporaryPersistence()
        try Data("malformed".utf8).write(to: persistence.progressURL)
        let variant = try makeAlternateVariant()

        let manager = PlayerProgressManager(
            variant: variant,
            questionDataService: service,
            persistenceURL: persistence.progressURL
        )

        XCTAssertEqual(manager.progress, .default)
        guard case .failed(.malformedData) = manager.persistenceStatus else {
            return XCTFail("Expected a typed malformed-data status")
        }
        XCTAssertEqual(manager.lastPersistenceError, .malformedData(path: persistence.progressURL.path))
    }

    func testCompatibilityMutatorDoesNotOverwriteUnrecoverablePersistence() throws {
        let persistence = try TemporaryPersistence()
        let malformedData = Data("malformed".utf8)
        try malformedData.write(to: persistence.progressURL)
        let manager = PlayerProgressManager(
            variant: try makeAlternateVariant(),
            questionDataService: service,
            persistenceURL: persistence.progressURL
        )

        manager.addCoins(20)

        XCTAssertEqual(manager.progress, .default)
        XCTAssertEqual(try Data(contentsOf: persistence.progressURL), malformedData)
        XCTAssertEqual(manager.lastPersistenceError, .malformedData(path: persistence.progressURL.path))
    }

    func testThrowingInitializerReportsMalformedPersistence() throws {
        let store = FakePersistenceStore(primaryData: Data("malformed".utf8))

        XCTAssertThrowsError(try makeManager(store: store)) { error in
            guard case PersistenceError.malformedData = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCorruptPrimaryRecoversFromValidBackup() throws {
        var backupProgress = PlayerProgress.default
        backupProgress.coins = 777
        let store = FakePersistenceStore(
            primaryData: Data("corrupt".utf8),
            backupData: try PersistenceDocumentCodec.encode(backupProgress)
        )

        let manager = try makeManager(store: store)

        XCTAssertEqual(manager.coins, 777)
        XCTAssertEqual(manager.persistenceStatus, .recoveredFromBackup(schemaVersion: 1))
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            backupProgress
        )
    }

    func testCorruptPrimaryRecoversFromLegacyBackup() throws {
        var backupProgress = PlayerProgress.default
        backupProgress.coins = 778
        let legacyBackup = try PropertyListEncoder().encode(backupProgress)
        let store = FakePersistenceStore(
            primaryData: Data("corrupt".utf8),
            backupData: legacyBackup
        )

        let manager = try makeManager(store: store)

        XCTAssertEqual(manager.coins, 778)
        XCTAssertEqual(manager.persistenceStatus, .recoveredFromBackup(schemaVersion: QuizEnginePersistenceSchema.legacy))
    }

    func testMissingPrimaryUsesFreshStateAndPreservesStaleBackup() throws {
        var backupProgress = PlayerProgress.default
        backupProgress.coins = 456
        let backupData = try PersistenceDocumentCodec.encode(backupProgress)
        let store = FakePersistenceStore(backupData: backupData)

        let manager = try makeManager(store: store)

        XCTAssertEqual(manager.coins, PlayerProgress.default.coins)
        XCTAssertEqual(manager.persistenceStatus, .fresh)
        XCTAssertNil(store.primaryData)
        XCTAssertEqual(store.backupData, backupData)
    }

    func testCorruptPrimaryAndBackupReportsTypedRecoveryFailure() throws {
        let store = FakePersistenceStore(
            primaryData: Data("corrupt-primary".utf8),
            backupData: Data("corrupt-backup".utf8)
        )

        XCTAssertThrowsError(try makeManager(store: store)) { error in
            guard case PersistenceError.backupRecoveryFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInterruptedImportRestoresPreviousProgressAndClearsPendingMarker() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        var interruptedProgress = PlayerProgress.default
        interruptedProgress.coins = 999
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(interruptedProgress),
            backupData: try PersistenceDocumentCodec.encode(previousProgress),
            transactionMarkerData: try PropertyListEncoder().encode(
                ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: "legacy-import",
                    sourceFingerprint: "snapshot-1",
                    state: .pending,
                    hadPrimary: true,
                    timestamp: Date(timeIntervalSinceReferenceDate: 10),
                    targetProgress: interruptedProgress,
                    previousProgress: previousProgress
                )
            )
        )

        let manager = try makeManager(store: store)

        XCTAssertEqual(manager.coins, 111)
        XCTAssertEqual(manager.persistenceStatus, .recoveredInterruptedImport)
        XCTAssertNil(store.transactionMarkerData)

        let request = try PlayerProgressImportRequest(
            identifier: "legacy-import",
            sourceFingerprint: "snapshot-1",
            progress: interruptedProgress
        )
        XCTAssertEqual(try manager.importProgress(request), .imported)
        XCTAssertEqual(manager.coins, 999)
    }

    func testInterruptedFreshImportRemovesNewPrimaryAndDoesNotAdoptStaleBackup() throws {
        var staleProgress = PlayerProgress.default
        staleProgress.coins = 222
        var interruptedProgress = PlayerProgress.default
        interruptedProgress.coins = 999
        let staleBackup = try PersistenceDocumentCodec.encode(staleProgress)
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(interruptedProgress),
            backupData: staleBackup,
            transactionMarkerData: try PropertyListEncoder().encode(
                ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: "fresh-import",
                    sourceFingerprint: "snapshot-1",
                    state: .pending,
                    hadPrimary: false,
                    timestamp: Date(timeIntervalSinceReferenceDate: 10),
                    targetProgress: interruptedProgress
                )
            )
        )

        let manager = try makeManager(store: store)

        XCTAssertEqual(manager.progress, .default)
        XCTAssertEqual(manager.persistenceStatus, .recoveredInterruptedImport)
        XCTAssertNil(store.primaryData)
        XCTAssertEqual(store.backupData, staleBackup)
        XCTAssertNil(store.transactionMarkerData)
    }

    func testPendingImportKeepsIntactPrimaryWhenBackupWasNotUpdated() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        var staleBackupProgress = PlayerProgress.default
        staleBackupProgress.coins = 222
        var targetProgress = PlayerProgress.default
        targetProgress.coins = 999
        let staleBackup = try PersistenceDocumentCodec.encode(staleBackupProgress)
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(previousProgress),
            backupData: staleBackup,
            transactionMarkerData: try PropertyListEncoder().encode(
                ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: "pending-import",
                    sourceFingerprint: "snapshot-1",
                    state: .pending,
                    hadPrimary: true,
                    timestamp: Date(timeIntervalSinceReferenceDate: 10),
                    targetProgress: targetProgress,
                    previousProgress: previousProgress
                )
            )
        )

        let manager = try makeManager(store: store)

        XCTAssertEqual(manager.coins, 111)
        XCTAssertEqual(manager.persistenceStatus, .recoveredInterruptedImport)
        XCTAssertEqual(store.backupData, staleBackup)
        XCTAssertNil(store.transactionMarkerData)
    }

    func testInterruptedImportRejectsBackupThatDoesNotMatchPreviousProgress() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        var staleBackupProgress = PlayerProgress.default
        staleBackupProgress.coins = 222
        var targetProgress = PlayerProgress.default
        targetProgress.coins = 999
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(targetProgress),
            backupData: try PersistenceDocumentCodec.encode(staleBackupProgress),
            transactionMarkerData: try PropertyListEncoder().encode(
                ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: "stale-backup-import",
                    sourceFingerprint: "snapshot-1",
                    state: .pending,
                    hadPrimary: true,
                    timestamp: Date(timeIntervalSinceReferenceDate: 10),
                    targetProgress: targetProgress,
                    previousProgress: previousProgress
                )
            )
        )

        XCTAssertThrowsError(try makeManager(store: store)) { error in
            guard case PersistenceError.backupRecoveryFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            targetProgress
        )
    }

    func testWriteFailureDoesNotReportCompletionOrChangeInMemoryProgress() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        let store = FakePersistenceStore(primaryData: try PersistenceDocumentCodec.encode(previousProgress))
        let manager = try makeManager(store: store)
        store.failurePoint = .replacePrimary

        manager.addCoins(20)

        XCTAssertEqual(manager.coins, 111)
        XCTAssertEqual(manager.lastPersistenceError, .writeFailed(path: store.primaryURL.path, reason: "Injected failure"))
        XCTAssertNil(store.transactionMarkerData)
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            previousProgress
        )
    }

    func testPartialReplacementRestoresPreviousProgressAndReportsFailure() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        let store = FakePersistenceStore(primaryData: try PersistenceDocumentCodec.encode(previousProgress))
        let manager = try makeManager(store: store)
        store.failurePoint = .partialReplacePrimary

        manager.addCoins(20)

        XCTAssertEqual(manager.coins, 111)
        XCTAssertEqual(
            manager.lastPersistenceError,
            .writeFailed(path: store.primaryURL.path, reason: "Injected partial replacement failure")
        )
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            previousProgress
        )
        XCTAssertTrue(store.operations.contains("restoreBackup"))
    }

    func testInsufficientStorageIsReportedAsTypedFailure() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)
        store.failurePoint = .insufficientStorage

        manager.addCoins(20)

        XCTAssertEqual(
            manager.lastPersistenceError,
            .insufficientStorage(path: store.primaryURL.path)
        )
        XCTAssertEqual(manager.coins, PlayerProgress.default.coins)
    }

    func testReadBackMismatchRestoresBackupAndRollsBackMutation() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        var mismatchedProgress = previousProgress
        mismatchedProgress.coins = 999
        let store = FakePersistenceStore(primaryData: try PersistenceDocumentCodec.encode(previousProgress))
        let manager = try makeManager(store: store)
        store.readBackOverride = try PersistenceDocumentCodec.encode(mismatchedProgress)

        manager.addCoins(20)

        XCTAssertEqual(manager.coins, 111)
        XCTAssertEqual(manager.persistenceStatus, .failed(.readBackVerificationFailed(path: store.primaryURL.path)))
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            previousProgress
        )
    }

    func testFailedBooleanMutationsDoNotReportSuccess() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)

        store.failurePoint = .replacePrimary
        XCTAssertFalse(manager.spendCoins(10))
        XCTAssertEqual(manager.coins, PlayerProgress.default.coins)

        store.failurePoint = .replacePrimary
        XCTAssertNil(manager.claimDailyReward())
        XCTAssertEqual(manager.coins, PlayerProgress.default.coins)
    }

    func testImportTransactionCompletesExactlyOnceAndRejectsConflicts() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)
        var importedProgress = PlayerProgress.default
        importedProgress.coins = 888
        let request = try PlayerProgressImportRequest(
            identifier: "legacy-import",
            sourceFingerprint: "snapshot-1",
            progress: importedProgress
        )

        XCTAssertEqual(try manager.importProgress(request), .imported)
        XCTAssertEqual(manager.coins, 888)
        let pendingMarkerIndex = try XCTUnwrap(store.operations.firstIndex(of: "replaceMarker"))
        let primaryIndex = try XCTUnwrap(store.operations.firstIndex(of: "replacePrimary"))
        let completedMarkerIndex = try XCTUnwrap(store.operations.lastIndex(of: "replaceMarker"))
        XCTAssertLessThan(pendingMarkerIndex, primaryIndex)
        XCTAssertLessThan(primaryIndex, completedMarkerIndex)
        XCTAssertEqual(try manager.importProgress(request), .alreadyImported)

        let conflictingRequest = try PlayerProgressImportRequest(
            identifier: "legacy-import",
            sourceFingerprint: "snapshot-2",
            progress: PlayerProgress.default
        )
        XCTAssertThrowsError(try manager.importProgress(conflictingRequest)) { error in
            XCTAssertEqual(error as? PersistenceError, .conflictingImport(identifier: "legacy-import"))
        }
        XCTAssertEqual(manager.coins, 888)
    }

    func testCompletedImportCannotAcknowledgeARevertedDestination() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        var importedProgress = PlayerProgress.default
        importedProgress.coins = 888
        let request = try PlayerProgressImportRequest(
            identifier: "completed-import",
            sourceFingerprint: "snapshot-1",
            progress: importedProgress
        )
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(previousProgress),
            transactionMarkerData: try PropertyListEncoder().encode(
                ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: request.identifier,
                    sourceFingerprint: request.sourceFingerprint,
                    state: .completed,
                    hadPrimary: true,
                    timestamp: Date(timeIntervalSinceReferenceDate: 10),
                    targetProgress: importedProgress,
                    previousProgress: previousProgress
                )
            )
        )
        XCTAssertThrowsError(try makeManager(store: store)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .readBackVerificationFailed(path: store.primaryURL.path)
            )
        }
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            previousProgress
        )
    }

    func testFailedImportNeverWritesCompletionMarker() throws {
        let store = FakePersistenceStore()
        let manager = try makeManager(store: store)
        var importedProgress = PlayerProgress.default
        importedProgress.coins = 888
        let request = try PlayerProgressImportRequest(
            identifier: "failed-import",
            sourceFingerprint: "snapshot-1",
            progress: importedProgress
        )
        store.failurePoint = .replacePrimary

        XCTAssertThrowsError(try manager.importProgress(request))
        XCTAssertNil(store.transactionMarkerData)
        XCTAssertEqual(store.operations.filter { $0 == "replaceMarker" }.count, 1)
        XCTAssertEqual(manager.progress, .default)
    }

    func testFailedImportPreservesPrimaryWhenBackupWasNotUpdated() throws {
        var previousProgress = PlayerProgress.default
        previousProgress.coins = 111
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(previousProgress)
        )
        let manager = try makeManager(store: store)
        var importedProgress = PlayerProgress.default
        importedProgress.coins = 888
        let request = try PlayerProgressImportRequest(
            identifier: "failed-existing-import",
            sourceFingerprint: "snapshot-1",
            progress: importedProgress
        )
        store.failurePoint = .replacePrimary

        XCTAssertThrowsError(try manager.importProgress(request)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .writeFailed(path: store.primaryURL.path, reason: "Injected failure")
            )
        }
        XCTAssertNil(store.transactionMarkerData)
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            previousProgress
        )
    }

    func testPreferencesSupportLegacyDataAndVersionedStoreWrites() throws {
        let store = FakePersistenceStore(
            primaryData: try PropertyListEncoder().encode(UserPreferences(hapticsEnabled: false))
        )

        XCTAssertEqual(try UserPreferencesLoader.load(from: store), UserPreferences(hapticsEnabled: false))

        try UserPreferencesLoader.write(
            preferences: UserPreferences(hapticsEnabled: true),
            to: store
        )

        let propertyList = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: try XCTUnwrap(store.primaryData), options: [], format: nil) as? [String: Any]
        )
        XCTAssertEqual(propertyList["schemaVersion"] as? Int, QuizEnginePersistenceSchema.current)
        XCTAssertEqual(try UserPreferencesLoader.load(from: store), UserPreferences(hapticsEnabled: true))
    }

    func testPreferencesRecoverFromValidBackupWhenPrimaryIsMalformed() throws {
        let preferences = UserPreferences(hapticsEnabled: false)
        let store = FakePersistenceStore(
            primaryData: Data("corrupt".utf8),
            backupData: try PersistenceDocumentCodec.encode(preferences)
        )

        XCTAssertEqual(try UserPreferencesLoader.load(from: store), preferences)
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                UserPreferences.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            preferences
        )
    }

    func testPreferencesReadBackFailureRestoresPreviousValue() throws {
        let previous = UserPreferences(hapticsEnabled: false)
        let replacement = UserPreferences(hapticsEnabled: true)
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(previous)
        )
        store.readBackOverride = try PersistenceDocumentCodec.encode(previous)

        XCTAssertThrowsError(try UserPreferencesLoader.write(preferences: replacement, to: store)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .readBackVerificationFailed(path: store.primaryURL.path)
            )
        }
        XCTAssertEqual(
            try PersistenceDocumentCodec.decode(
                UserPreferences.self,
                from: try XCTUnwrap(store.primaryData),
                path: store.primaryURL.path
            ).payload,
            previous
        )
    }

    func testPreferencesUseFreshStateWhenPrimaryIsMissing() throws {
        let preferences = UserPreferences(hapticsEnabled: false)
        let backupData = try PersistenceDocumentCodec.encode(preferences)
        let store = FakePersistenceStore(backupData: backupData)

        XCTAssertEqual(try UserPreferencesLoader.load(from: store), UserPreferences(hapticsEnabled: true))
        XCTAssertNil(store.primaryData)
        XCTAssertEqual(store.backupData, backupData)
    }

    func testUnsupportedSchemaIsTypedAndDoesNotLoadAsDefault() throws {
        let data = try PropertyListEncoder().encode(
            PersistenceEnvelope(schemaVersion: 999, payload: PlayerProgress.default)
        )
        let store = FakePersistenceStore(primaryData: data)

        XCTAssertThrowsError(try makeManager(store: store)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .unsupportedSchema(path: store.primaryURL.path, version: 999)
            )
        }
    }

    func testImportRequestRejectsMissingIdentityFields() {
        XCTAssertThrowsError(
            try PlayerProgressImportRequest(
                identifier: "",
                sourceFingerprint: "fingerprint",
                progress: .default
            )
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .invalidImportRequest)
        }

        XCTAssertThrowsError(
            try PlayerProgressImportRequest(
                identifier: " \n",
                sourceFingerprint: "fingerprint",
                progress: .default
            )
        ) { error in
            XCTAssertEqual(error as? PersistenceError, .invalidImportRequest)
        }
    }

    func testMalformedImportMarkerDoesNotRecoverOrProceed() throws {
        let store = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(PlayerProgress.default),
            transactionMarkerData: try PropertyListEncoder().encode(
                ImportMarker(
                    schemaVersion: QuizEnginePersistenceSchema.current,
                    identifier: " ",
                    sourceFingerprint: "fingerprint",
                    state: .pending,
                    hadPrimary: true,
                    timestamp: Date(timeIntervalSinceReferenceDate: 10),
                    targetProgress: .default,
                    previousProgress: .default
                )
            )
        )

        XCTAssertThrowsError(try makeManager(store: store)) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .malformedImportMarker(path: store.transactionMarkerURL.path)
            )
        }
        XCTAssertNotNil(store.transactionMarkerData)
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

    private func makeManager(store: any QuizEnginePersistenceStore) throws -> PlayerProgressManager {
        try PlayerProgressManager(
            variant: try makeAlternateVariant(),
            questionDataService: service,
            persistenceStore: store,
            clock: TestClock(now: Date(timeIntervalSinceReferenceDate: 0))
        )
    }
}

private final class PremiumPurchaseStatus: PurchaseStatusProvider {
    let isPremium = true
    let adsRemoved = true
}
