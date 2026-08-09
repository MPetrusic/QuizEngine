import CryptoKit
import XCTest
@testable import QuizEngineCore
import QuizEngineTestSupport

// MARK: - Manifest model
//
// The shape is declared explicitly rather than as a loose dictionary so a manifest
// that stops describing a required field fails to compile-check at decode time.

struct FixtureManifest: Decodable {
    let manifestVersion: Int
    let regenerateCommand: String
    let fixtures: [FixtureEntry]
}

struct FixtureEntry: Decodable {
    let path: String
    let tag: String
    let commit: String
    let sha256: String
    let byteCount: Int
    let kind: String
    let producingType: String
    let producingCall: String
    let storagePath: String
    let envelope: String
    let expectedSchemaVersion: Int
    let expectedLoadStatus: String
    let howObtained: String
    let containsNoRealUserDataOrSecret: Bool
    let identicalBytesWith: [String]
    let expectedProgress: ExpectedProgress?
    let expectedPreferences: ExpectedPreferences?
}

struct ExpectedPreferences: Decodable {
    let hapticsEnabled: Bool
}

struct ExpectedCategoryStat: Decodable {
    let questionsAnswered: Int
    let questionsCorrect: Int
    let correctlyAnsweredIDs: [Int]
    let bestScore: Int
    let questionsCountAtHundredPercent: Int?
}

struct ExpectedDailyStat: Decodable {
    let questionsAnswered: Int
    let questionsCorrect: Int
    let gamesPlayed: Int
    let totalResponseTimeMs: Int
    let questionsByDifficulty: [String: Int]
    let correctByDifficulty: [String: Int]
}

struct ExpectedHourlyPerformance: Decodable {
    let questionsAnswered: Int
    let questionsCorrect: Int
    let sessionCount: Int
}

struct ExpectedReceipt: Decodable {
    let matchID: String
    let fingerprint: String
}

struct ExpectedRewardReceipt: Decodable {
    let receiptID: String
    let kind: RewardReceiptKind
    let fingerprint: String
    let recordedAt: String?
}

struct ExpectedProgress: Decodable {
    let coins: Int
    let currentStreak: Int
    let longestStreak: Int
    let totalCoinsEarned: Int
    let totalCoinsSpent: Int
    let categoryStats: [String: ExpectedCategoryStat]
    let unlockedPacks: [String]
    let seenQuestionIDs: [Int]
    let unlockedAchievements: [String]
    let manuallyUnlockedCategories: [String]
    let lifetimeGamesPlayed: Int
    let lifetimeQuestionsAnswered: Int
    let lifetimeQuestionsCorrect: Int
    let bestSingleSessionScore: Int
    let bestSingleSessionStreak: Int
    let powerUpTypesUsed: [String]
    let lifetimePowerUpsUsed: Int?
    let dailyStats: [String: ExpectedDailyStat]
    let hourlyPerformance: [String: ExpectedHourlyPerformance]
    let lifetimeAverageResponseTimeMs: Int
    let lifetimeResponseTimeSamples: Int
    let hasReceivedPremiumBonusCoins: Bool
    let currentPlayStreak: Int
    let longestPlayStreak: Int
    let multiplayerGamesPlayed: Int
    let multiplayerGamesWon: Int
    let multiplayerGamesLost: Int
    let multiplayerGamesDraw: Int
    let bestMultiplayerScore: Int
    let multiplayerWinStreak: Int
    let longestMultiplayerWinStreak: Int
    let multiplayerTotalResponseTimeMs: Int
    let multiplayerTotalQuestionsAnswered: Int
    let multiplayerTotalQuestionsCorrect: Int
    let powerUpCredits: [String: Int]
    let multiplayerMatchReceipts: [ExpectedReceipt]
    let rewardReceipts: [ExpectedRewardReceipt]
    let lastAppOpenDate: String?
    let lastDailyRewardClaimedDate: String?
    let lastRewardAdWatchedDate: String?
    let previousAppOpenDate: String?
    let lastPlayedDate: String?
}

// MARK: - Tests

@MainActor
final class PersistenceFixtureMigrationTests: XCTestCase {

    // MARK: Deterministic environment
    //
    // Nothing in this suite may depend on the machine's locale, time zone, or clock.

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    /// A fixed instant well after every date stored in any fixture, so no rule in the
    /// manager can interpret a fixture date as being in the future.
    private var fixedNow: Date {
        date(fromISO8601: "2026-01-15T12:00:00Z")!
    }

    private func date(fromISO8601 text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private func makeVariant() throws -> QuizVariantDefinition {
        try QuizVariantDefinition(
            categories: [
                .init(
                    id: "history",
                    displayNameKey: "category.history",
                    iconName: "book",
                    displayOrder: 0,
                    unlockRequirement: .free
                ),
                .init(
                    id: "geography",
                    displayNameKey: "category.geography",
                    iconName: "globe",
                    displayOrder: 1,
                    unlockRequirement: .free
                )
            ],
            achievements: [],
            questionResource: QuestionResource(bundle: .module, fileName: "alternate_questions")
        )
    }

    private func makeManager(
        store: any QuizEnginePersistenceStore
    ) throws -> PlayerProgressManager {
        try PlayerProgressManager(
            variant: try makeVariant(),
            questionDataService: QuestionDataService(bundle: .module, fileName: "alternate_questions"),
            persistenceStore: store,
            clock: TestClock(now: fixedNow),
            calendar: utcCalendar
        )
    }

    /// A throwaway directory for one test. Nothing here ever touches a real Documents
    /// directory.
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quizengine-fixture-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    // MARK: Bundle access

    private func manifest() throws -> FixtureManifest {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "manifest",
                withExtension: "json",
                subdirectory: "PersistenceFixtures"
            ),
            "PersistenceFixtures/manifest.json is missing from the test bundle"
        )
        return try JSONDecoder().decode(FixtureManifest.self, from: Data(contentsOf: url))
    }

    /// Reads the fixture through `Bundle.module`, which is what the requirement to hash
    /// "the resource as loaded from the bundle" means: if the build ever transformed
    /// these bytes, this is where it would show.
    private func bundledFixtureData(_ entry: FixtureEntry) throws -> Data {
        let components = entry.path.split(separator: "/")
        XCTAssertEqual(components.count, 2, "fixture paths are <tag>/<file>: \(entry.path)")
        let fileName = String(components[1])
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: (fileName as NSString).deletingPathExtension,
                withExtension: (fileName as NSString).pathExtension,
                subdirectory: "PersistenceFixtures/\(components[0])"
            ),
            "\(entry.path) is missing from the test bundle"
        )
        return try Data(contentsOf: url)
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Fixture inventory and integrity

    func testFixtureManifestCoversEveryReleasedArtifact() throws {
        let manifest = try manifest()
        XCTAssertEqual(manifest.manifestVersion, 1)
        XCTAssertEqual(manifest.regenerateCommand, "sh Scripts/generate-persistence-fixtures.sh")

        let paths = Set(manifest.fixtures.map(\.path))
        let expectedPaths: Set<String> = [
            "v0.1.0/player_progress_default.plist",
            "v0.1.0/player_progress_populated.plist",
            "v0.1.0/user_preferences.plist",
            "v0.1.1/player_progress_default.plist",
            "v0.1.1/player_progress_populated.plist",
            "v0.1.1/user_preferences.plist",
            "v0.1.2/player_progress_default.plist",
            "v0.1.2/player_progress_populated.plist",
            "v0.1.2/user_preferences.plist",
            "v0.1.3/player_progress_default.plist",
            "v0.1.3/player_progress_populated.plist",
            "v0.1.3/user_preferences.plist",
            "v0.2.0/player_progress_schema_1.plist",
            "v0.2.0/user_preferences_schema_1.plist"
        ]
        XCTAssertEqual(paths, expectedPaths)

        for entry in manifest.fixtures {
            XCTAssertTrue(
                entry.containsNoRealUserDataOrSecret,
                "\(entry.path) is not confirmed free of real user data"
            )
            XCTAssertEqual(
                entry.commit.count,
                40,
                "\(entry.path) must record a full originating commit"
            )
            XCTAssertTrue(entry.path.hasPrefix(entry.tag + "/"))
            XCTAssertFalse(entry.producingType.isEmpty)
            XCTAssertFalse(entry.producingCall.isEmpty)
            XCTAssertFalse(entry.storagePath.isEmpty)
            XCTAssertFalse(entry.envelope.isEmpty)
            XCTAssertFalse(entry.howObtained.isEmpty)
            switch entry.kind {
            case "playerProgress":
                XCTAssertNotNil(entry.expectedProgress, "\(entry.path) records no expected values")
            case "userPreferences":
                XCTAssertNotNil(entry.expectedPreferences, "\(entry.path) records no expected values")
            default:
                XCTFail("unknown fixture kind \(entry.kind) for \(entry.path)")
            }
        }

        // Coverage is kept per release even where the bytes are identical, which is
        // exactly the case for the four v0.1.x releases.
        XCTAssertEqual(
            manifest.fixtures.first { $0.path == "v0.1.0/player_progress_populated.plist" }?
                .identicalBytesWith,
            [
                "v0.1.1/player_progress_populated.plist",
                "v0.1.2/player_progress_populated.plist",
                "v0.1.3/player_progress_populated.plist"
            ]
        )
        XCTAssertEqual(
            manifest.fixtures.first { $0.path == "v0.2.0/player_progress_schema_1.plist" }?
                .identicalBytesWith,
            []
        )
    }

    func testBundledFixtureBytesMatchTheirRecordedHashes() throws {
        for entry in try manifest().fixtures {
            let data = try bundledFixtureData(entry)
            XCTAssertEqual(
                sha256Hex(data),
                entry.sha256,
                "\(entry.path) does not match its recorded SHA-256 as loaded from the bundle"
            )
            XCTAssertEqual(data.count, entry.byteCount, "\(entry.path) byte count changed")
        }
    }

    func testRecordedByteEquivalenceBetweenReleasesIsAccurate() throws {
        let manifest = try manifest()
        var hashByPath: [String: String] = [:]
        for entry in manifest.fixtures {
            hashByPath[entry.path] = sha256Hex(try bundledFixtureData(entry))
        }
        for entry in manifest.fixtures {
            for other in entry.identicalBytesWith {
                XCTAssertEqual(
                    hashByPath[entry.path],
                    hashByPath[other],
                    "\(entry.path) claims byte equivalence with \(other) but the bytes differ"
                )
            }
            let unlistedMatches = hashByPath
                .filter { $0.key != entry.path && $0.value == hashByPath[entry.path] }
                .keys
                .sorted()
            XCTAssertEqual(
                unlistedMatches,
                entry.identicalBytesWith.sorted(),
                "\(entry.path) has byte-identical siblings the manifest does not record"
            )
        }
    }

    // MARK: Load through the public path

    func testHistoricalProgressFixturesLoadWithTheExpectedStatusAndValues() throws {
        for entry in try manifest().fixtures where entry.kind == "playerProgress" {
            let expected = try XCTUnwrap(entry.expectedProgress)
            let directory = try makeTemporaryDirectory()
            let primaryURL = directory.appendingPathComponent("player_progress.plist")
            try bundledFixtureData(entry).write(to: primaryURL)

            let manager = try makeManager(
                store: FileQuizEnginePersistenceStore(primaryURL: primaryURL)
            )

            XCTAssertEqual(
                manager.persistenceStatus,
                expectedStatus(for: entry),
                "\(entry.path) loaded with the wrong status"
            )
            XCTAssertNil(manager.lastPersistenceError, "\(entry.path) reported a load error")
            assertProgress(manager.progress, matches: expected, label: entry.path)
        }
    }

    func testHistoricalPreferenceFixturesLoadWithTheExpectedValues() throws {
        for entry in try manifest().fixtures where entry.kind == "userPreferences" {
            let expected = try XCTUnwrap(entry.expectedPreferences)
            let directory = try makeTemporaryDirectory()
            let primaryURL = directory.appendingPathComponent("user_preferences.plist")
            try bundledFixtureData(entry).write(to: primaryURL)

            let preferences = try UserPreferencesLoader.load(
                from: FileQuizEnginePersistenceStore(primaryURL: primaryURL)
            )
            XCTAssertEqual(
                preferences.hapticsEnabled,
                expected.hapticsEnabled,
                "\(entry.path) decoded the wrong hapticsEnabled value"
            )
        }
    }

    // MARK: Mutate, promote, reload

    func testMutatingAHistoricalProgressFixturePromotesItAndSurvivesReload() throws {
        for entry in try manifest().fixtures where entry.kind == "playerProgress" {
            let expected = try XCTUnwrap(entry.expectedProgress)
            let directory = try makeTemporaryDirectory()
            let primaryURL = directory.appendingPathComponent("player_progress.plist")
            try bundledFixtureData(entry).write(to: primaryURL)

            let manager = try makeManager(
                store: FileQuizEnginePersistenceStore(primaryURL: primaryURL)
            )
            manager.addCoins(7)
            XCTAssertEqual(manager.persistenceStatus, .saved, "\(entry.path) did not save")
            XCTAssertEqual(manager.progress.coins, expected.coins + 7)
            XCTAssertEqual(manager.progress.totalCoinsEarned, expected.totalCoinsEarned + 7)

            // The document on disk is now a current-schema envelope regardless of the
            // schema it arrived as.
            let promoted = try PropertyListSerialization.propertyList(
                from: try Data(contentsOf: primaryURL),
                options: [],
                format: nil
            ) as? [String: Any]
            XCTAssertEqual(
                promoted?["schemaVersion"] as? Int,
                QuizEnginePersistenceSchema.current,
                "\(entry.path) was not promoted to the current schema envelope"
            )
            XCTAssertNotNil(promoted?["payload"], "\(entry.path) has no envelope payload")

            // A recreated manager reads back the same values plus the mutation.
            let reloaded = try makeManager(
                store: FileQuizEnginePersistenceStore(primaryURL: primaryURL)
            )
            XCTAssertEqual(
                reloaded.persistenceStatus,
                .loaded(schemaVersion: QuizEnginePersistenceSchema.current),
                "\(entry.path) did not reload as the current schema"
            )
            assertProgress(
                reloaded.progress,
                matches: expected,
                label: "\(entry.path) after reload",
                coinDelta: 7
            )
        }
    }

    func testMutatingAHistoricalPreferenceFixturePromotesItAndSurvivesReload() throws {
        for entry in try manifest().fixtures where entry.kind == "userPreferences" {
            let expected = try XCTUnwrap(entry.expectedPreferences)
            let directory = try makeTemporaryDirectory()
            let primaryURL = directory.appendingPathComponent("user_preferences.plist")
            try bundledFixtureData(entry).write(to: primaryURL)
            let store = FileQuizEnginePersistenceStore(primaryURL: primaryURL)

            let mutated = UserPreferences(hapticsEnabled: !expected.hapticsEnabled)
            try UserPreferencesLoader.write(preferences: mutated, to: store)

            let promoted = try PropertyListSerialization.propertyList(
                from: try Data(contentsOf: primaryURL),
                options: [],
                format: nil
            ) as? [String: Any]
            XCTAssertEqual(
                promoted?["schemaVersion"] as? Int,
                QuizEnginePersistenceSchema.current,
                "\(entry.path) was not promoted to the current schema envelope"
            )

            let reloaded = try UserPreferencesLoader.load(
                from: FileQuizEnginePersistenceStore(primaryURL: primaryURL)
            )
            XCTAssertEqual(reloaded.hapticsEnabled, mutated.hapticsEnabled, entry.path)
        }
    }

    // MARK: Repeated import

    func testRepeatingTheImportOnAHistoricalFixtureIsAlreadyImportedWithoutDuplicateValue() throws {
        for entry in try manifest().fixtures where entry.kind == "playerProgress" {
            let directory = try makeTemporaryDirectory()
            let primaryURL = directory.appendingPathComponent("player_progress.plist")
            try bundledFixtureData(entry).write(to: primaryURL)

            let manager = try makeManager(
                store: FileQuizEnginePersistenceStore(primaryURL: primaryURL)
            )

            // A legacy import that adds coins, a power-up credit, a statistic, and an
            // identifier on top of whatever the historical document already held.
            var target = manager.progress
            target.coins += 250
            target.totalCoinsEarned += 250
            target.powerUpCredits[.fiftyFifty, default: 0] += 3
            target.lifetimeQuestionsAnswered += 11
            target.seenQuestionIDs.insert(9_001)
            target.unlockedAchievements.insert("imported_award")

            let request = try PlayerProgressImportRequest(
                identifier: "legacy-import-\(entry.tag)",
                sourceFingerprint: "fingerprint-\(entry.path)",
                progress: target
            )

            XCTAssertEqual(try manager.importProgress(request), .imported, entry.path)
            XCTAssertEqual(manager.persistenceStatus, .imported, entry.path)
            assertImportedValuesAreExactlyOnce(manager.progress, target: target, label: entry.path)

            // Repeating the identical request must not credit anything a second time.
            XCTAssertEqual(try manager.importProgress(request), .alreadyImported, entry.path)
            XCTAssertEqual(manager.persistenceStatus, .alreadyImported, entry.path)
            assertImportedValuesAreExactlyOnce(manager.progress, target: target, label: entry.path)

            // And neither must repeating it after the process is recreated.
            let relaunched = try makeManager(
                store: FileQuizEnginePersistenceStore(primaryURL: primaryURL)
            )
            assertImportedValuesAreExactlyOnce(
                relaunched.progress,
                target: target,
                label: "\(entry.path) after relaunch"
            )
            XCTAssertEqual(try relaunched.importProgress(request), .alreadyImported, entry.path)
            assertImportedValuesAreExactlyOnce(
                relaunched.progress,
                target: target,
                label: "\(entry.path) after repeated import"
            )
        }
    }

    // MARK: Corrupt primary, valid historical backup

    func testCorruptPrimaryRecoversFromAValidHistoricalBackup() throws {
        let cases = [
            "v0.1.0/player_progress_populated.plist", // schema 0
            "v0.2.0/player_progress_schema_1.plist"   // schema 1
        ]
        let manifest = try manifest()

        for path in cases {
            let entry = try XCTUnwrap(manifest.fixtures.first { $0.path == path })
            let expected = try XCTUnwrap(entry.expectedProgress)
            let directory = try makeTemporaryDirectory()
            let primaryURL = directory.appendingPathComponent("player_progress.plist")
            let backupURL = directory.appendingPathComponent("player_progress.plist.backup")

            try bundledFixtureData(entry).write(to: backupURL)
            try Data("this is not a property list".utf8).write(to: primaryURL)

            let manager = try makeManager(
                store: FileQuizEnginePersistenceStore(primaryURL: primaryURL)
            )
            XCTAssertEqual(
                manager.persistenceStatus,
                .recoveredFromBackup(schemaVersion: entry.expectedSchemaVersion),
                "\(path) did not recover from its historical backup"
            )
            XCTAssertNil(manager.lastPersistenceError, path)
            assertProgress(manager.progress, matches: expected, label: "\(path) recovered")

            // Recovery restored the primary verbatim, so the next launch needs no
            // recovery and still reports the schema the historical document was
            // written at — recovery does not silently promote it.
            let relaunched = try makeManager(
                store: FileQuizEnginePersistenceStore(primaryURL: primaryURL)
            )
            XCTAssertEqual(
                relaunched.persistenceStatus,
                expectedStatus(for: entry),
                "\(path) did not settle after recovery"
            )
            assertProgress(relaunched.progress, matches: expected, label: "\(path) after relaunch")
        }
    }

    func testCommittedSchema1FixtureDefaultsRewardReceiptsAndPromotesToSchema2() throws {
        let entry = try XCTUnwrap(
            try manifest().fixtures.first { $0.path == "v0.2.0/player_progress_schema_1.plist" }
        )
        let expected = try XCTUnwrap(entry.expectedProgress)
        let directory = try makeTemporaryDirectory()
        let primaryURL = directory.appendingPathComponent("player_progress.plist")
        try bundledFixtureData(entry).write(to: primaryURL)

        let manager = try makeManager(
            store: FileQuizEnginePersistenceStore(primaryURL: primaryURL)
        )
        XCTAssertEqual(manager.persistenceStatus, .loaded(schemaVersion: 1))
        XCTAssertTrue(manager.progress.rewardReceipts.isEmpty)
        XCTAssertEqual(manager.progress.coins, expected.coins)
        XCTAssertEqual(manager.progress.totalCoinsEarned, expected.totalCoinsEarned)

        manager.addCoins(0)
        XCTAssertEqual(manager.persistenceStatus, .saved)
        XCTAssertEqual(manager.progress.coins, expected.coins)
        XCTAssertEqual(manager.progress.totalCoinsEarned, expected.totalCoinsEarned)

        let promoted = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: primaryURL),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(promoted["schemaVersion"] as? Int, 2)

        let reloaded = try makeManager(
            store: FileQuizEnginePersistenceStore(primaryURL: primaryURL)
        )
        XCTAssertEqual(reloaded.persistenceStatus, .loaded(schemaVersion: 2))
        XCTAssertTrue(reloaded.progress.rewardReceipts.isEmpty)
        XCTAssertEqual(reloaded.progress.coins, expected.coins)
        XCTAssertEqual(reloaded.progress.totalCoinsEarned, expected.totalCoinsEarned)
    }

    func testCurrentSchemaRoundTripsRewardReceiptLedger() throws {
        let directory = try makeTemporaryDirectory()
        let primaryURL = directory.appendingPathComponent("player_progress.plist")
        let store = FileQuizEnginePersistenceStore(primaryURL: primaryURL)
        let manager = try makeManager(store: store)
        var target = manager.progress
        target.rewardReceipts = [
            RewardReceipt(
                receiptID: "reward-request-0001",
                kind: .rewardedAdCoins,
                fingerprint: "rewarded-ad-coins|v1|25",
                recordedAt: fixedNow
            )
        ]
        let request = try PlayerProgressImportRequest(
            identifier: "schema-2-ledger-probe",
            sourceFingerprint: "schema-2-ledger-probe-v1",
            progress: target
        )

        XCTAssertEqual(try manager.importProgress(request), .imported)
        let document = try XCTUnwrap(
            try PropertyListSerialization.propertyList(
                from: Data(contentsOf: primaryURL),
                options: [],
                format: nil
            ) as? [String: Any]
        )
        XCTAssertEqual(document["schemaVersion"] as? Int, 2)

        let reloaded = try makeManager(
            store: FileQuizEnginePersistenceStore(primaryURL: primaryURL)
        )
        XCTAssertEqual(reloaded.persistenceStatus, .loaded(schemaVersion: 2))
        XCTAssertEqual(reloaded.progress, target)
        XCTAssertEqual(reloaded.progress.rewardReceipts, target.rewardReceipts)
    }

    // MARK: Versioned schema dispatch

    func testSchemaDispatchDescribesEveryReleasedEnvelopeVersion() {
        XCTAssertEqual(QuizEnginePersistenceSchema.legacy, 0)
        XCTAssertEqual(QuizEnginePersistenceSchema.firstVersioned, 1)
        XCTAssertEqual(QuizEnginePersistenceSchema.current, 2)
        XCTAssertGreaterThanOrEqual(
            QuizEnginePersistenceSchema.current,
            QuizEnginePersistenceSchema.firstVersioned
        )
        XCTAssertEqual(
            QuizEnginePersistenceSchema.decodableEnvelopeVersions,
            QuizEnginePersistenceSchema.firstVersioned...QuizEnginePersistenceSchema.current
        )

        // Envelope-less documents are schema 0 and are not an envelope version.
        XCTAssertFalse(QuizEnginePersistenceSchema.canDecodeEnvelope(version: QuizEnginePersistenceSchema.legacy))
        XCTAssertFalse(QuizEnginePersistenceSchema.canDecodeEnvelope(version: -1))
        for version in QuizEnginePersistenceSchema.decodableEnvelopeVersions {
            XCTAssertTrue(
                QuizEnginePersistenceSchema.canDecodeEnvelope(version: version),
                "released envelope version \(version) must stay decodable"
            )
            XCTAssertEqual(
                QuizEnginePersistenceSchema.requiresPromotion(from: version),
                version != QuizEnginePersistenceSchema.current
            )
        }
        // An unknown, i.e. future, version is rejected rather than guessed at.
        XCTAssertFalse(
            QuizEnginePersistenceSchema.canDecodeEnvelope(
                version: QuizEnginePersistenceSchema.current + 1
            )
        )
    }

    /// Decoding dispatches on the released range, so every released envelope version
    /// keeps loading and reports the version it was written at. Today that range is a
    /// single version; when a new schema ships, this case covers the older one for free.
    func testEveryReleasedEnvelopeVersionDecodesAndReportsItsOwnVersion() throws {
        let entry = try XCTUnwrap(
            try manifest().fixtures.first { $0.path == "v0.2.0/player_progress_schema_1.plist" }
        )
        let shipped = try bundledFixtureData(entry)
        let payload = try XCTUnwrap(
            (
                try PropertyListSerialization.propertyList(from: shipped, options: [], format: nil)
                    as? [String: Any]
            )?["payload"]
        )

        for version in QuizEnginePersistenceSchema.decodableEnvelopeVersions {
            // A probe derived from the shipped schema-1 payload, relabelled to the
            // version under test. This is a dispatch probe, never a committed fixture.
            let probe = try PropertyListSerialization.data(
                fromPropertyList: ["schemaVersion": version, "payload": payload],
                format: .binary,
                options: 0
            )
            let decoded = try PersistenceDocumentCodec.decode(
                PlayerProgress.self,
                from: probe,
                path: "probe"
            )
            XCTAssertEqual(decoded.schemaVersion, version)
            XCTAssertFalse(decoded.isLegacy)
            XCTAssertEqual(decoded.payload.coins, entry.expectedProgress?.coins)
        }

        let future = QuizEnginePersistenceSchema.current + 1
        let futureProbe = try PropertyListSerialization.data(
            fromPropertyList: ["schemaVersion": future, "payload": payload],
            format: .binary,
            options: 0
        )
        XCTAssertThrowsError(
            try PersistenceDocumentCodec.decode(PlayerProgress.self, from: futureProbe, path: "probe")
        ) { error in
            XCTAssertEqual(
                error as? PersistenceError,
                .unsupportedSchema(path: "probe", version: future)
            )
        }
    }

    func testImportMarkerAcceptsEveryReleasedSchemaVersionAndRejectsUnknownOnes() throws {
        let progress = PlayerProgress.default
        for version in QuizEnginePersistenceSchema.decodableEnvelopeVersions {
            let marker = ImportMarker(
                schemaVersion: version,
                identifier: "marker",
                sourceFingerprint: "fingerprint",
                state: .completed,
                hadPrimary: true,
                timestamp: fixedNow,
                targetProgress: progress,
                previousProgress: progress
            )
            let data = try PersistenceMarkerCodec.encode(marker, path: "probe")
            let decoded = try PersistenceMarkerCodec.decode(from: data, path: "probe")
            XCTAssertEqual(decoded.schemaVersion, version)
        }

        let futureMarker = ImportMarker(
            schemaVersion: QuizEnginePersistenceSchema.current + 1,
            identifier: "marker",
            sourceFingerprint: "fingerprint",
            state: .completed,
            hadPrimary: true,
            timestamp: fixedNow,
            targetProgress: progress,
            previousProgress: progress
        )
        let futureData = try PersistenceMarkerCodec.encode(futureMarker, path: "probe")
        XCTAssertThrowsError(try PersistenceMarkerCodec.decode(from: futureData, path: "probe")) { error in
            XCTAssertEqual(error as? PersistenceError, .malformedImportMarker(path: "probe"))
        }
    }

    // MARK: - Assertions

    private func expectedStatus(for entry: FixtureEntry) -> PersistenceStatus {
        entry.expectedSchemaVersion == QuizEnginePersistenceSchema.legacy
            ? .loadedLegacy
            : .loaded(schemaVersion: entry.expectedSchemaVersion)
    }

    private func assertImportedValuesAreExactlyOnce(
        _ progress: PlayerProgress,
        target: PlayerProgress,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(progress.coins, target.coins, "\(label) coins", file: file, line: line)
        XCTAssertEqual(
            progress.totalCoinsEarned,
            target.totalCoinsEarned,
            "\(label) totalCoinsEarned",
            file: file,
            line: line
        )
        XCTAssertEqual(
            progress.powerUpCredits,
            target.powerUpCredits,
            "\(label) powerUpCredits",
            file: file,
            line: line
        )
        XCTAssertEqual(
            progress.lifetimeQuestionsAnswered,
            target.lifetimeQuestionsAnswered,
            "\(label) lifetimeQuestionsAnswered",
            file: file,
            line: line
        )
        XCTAssertEqual(
            progress.seenQuestionIDs,
            target.seenQuestionIDs,
            "\(label) seenQuestionIDs",
            file: file,
            line: line
        )
        XCTAssertEqual(
            progress.unlockedAchievements,
            target.unlockedAchievements,
            "\(label) unlockedAchievements",
            file: file,
            line: line
        )
        XCTAssertEqual(
            progress.multiplayerMatchReceipts,
            target.multiplayerMatchReceipts,
            "\(label) multiplayerMatchReceipts",
            file: file,
            line: line
        )
        XCTAssertEqual(
            progress.rewardReceipts,
            target.rewardReceipts,
            "\(label) rewardReceipts",
            file: file,
            line: line
        )
        XCTAssertEqual(
            progress.multiplayerGamesPlayed,
            target.multiplayerGamesPlayed,
            "\(label) multiplayerGamesPlayed",
            file: file,
            line: line
        )
        XCTAssertEqual(progress, target, "\(label) whole document", file: file, line: line)
    }

    private func assertDate(
        _ actual: Date?,
        matchesISO8601 expected: String?,
        field: String,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let expected else {
            XCTAssertNil(actual, "\(label) \(field) should be absent", file: file, line: line)
            return
        }
        guard let actual else {
            XCTFail("\(label) \(field) is missing; expected \(expected)", file: file, line: line)
            return
        }
        guard let expectedDate = date(fromISO8601: expected) else {
            XCTFail("\(label) \(field) manifest value is not ISO-8601: \(expected)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expectedDate, "\(label) \(field)", file: file, line: line)

        // Also pin the wall-clock reading against an explicit calendar and time zone, so
        // the assertion cannot pass because the machine happens to be in UTC.
        let calendar = utcCalendar
        let actualComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: actual
        )
        let expectedComponents = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: expectedDate
        )
        XCTAssertEqual(
            actualComponents,
            expectedComponents,
            "\(label) \(field) UTC components",
            file: file,
            line: line
        )
    }

    private func assertProgress(
        _ progress: PlayerProgress,
        matches expected: ExpectedProgress,
        label: String,
        coinDelta: Int = 0,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        func check<Value: Equatable>(
            _ actual: Value,
            _ want: Value,
            _ field: String
        ) {
            XCTAssertEqual(actual, want, "\(label) \(field)", file: file, line: line)
        }

        check(progress.coins, expected.coins + coinDelta, "coins")
        check(progress.totalCoinsEarned, expected.totalCoinsEarned + coinDelta, "totalCoinsEarned")
        check(progress.totalCoinsSpent, expected.totalCoinsSpent, "totalCoinsSpent")
        check(progress.currentStreak, expected.currentStreak, "currentStreak")
        check(progress.longestStreak, expected.longestStreak, "longestStreak")
        check(progress.unlockedPacks, Set(expected.unlockedPacks), "unlockedPacks")
        check(progress.seenQuestionIDs, Set(expected.seenQuestionIDs), "seenQuestionIDs")
        check(progress.unlockedAchievements, Set(expected.unlockedAchievements), "unlockedAchievements")
        check(
            progress.manuallyUnlockedCategories,
            Set(expected.manuallyUnlockedCategories),
            "manuallyUnlockedCategories"
        )
        check(progress.lifetimeGamesPlayed, expected.lifetimeGamesPlayed, "lifetimeGamesPlayed")
        check(
            progress.lifetimeQuestionsAnswered,
            expected.lifetimeQuestionsAnswered,
            "lifetimeQuestionsAnswered"
        )
        check(
            progress.lifetimeQuestionsCorrect,
            expected.lifetimeQuestionsCorrect,
            "lifetimeQuestionsCorrect"
        )
        check(progress.bestSingleSessionScore, expected.bestSingleSessionScore, "bestSingleSessionScore")
        check(
            progress.bestSingleSessionStreak,
            expected.bestSingleSessionStreak,
            "bestSingleSessionStreak"
        )
        check(progress.powerUpTypesUsed, Set(expected.powerUpTypesUsed), "powerUpTypesUsed")
        check(progress.lifetimePowerUpsUsed, expected.lifetimePowerUpsUsed, "lifetimePowerUpsUsed")
        check(
            progress.lifetimeAverageResponseTimeMs,
            expected.lifetimeAverageResponseTimeMs,
            "lifetimeAverageResponseTimeMs"
        )
        check(
            progress.lifetimeResponseTimeSamples,
            expected.lifetimeResponseTimeSamples,
            "lifetimeResponseTimeSamples"
        )
        check(
            progress.hasReceivedPremiumBonusCoins,
            expected.hasReceivedPremiumBonusCoins,
            "hasReceivedPremiumBonusCoins"
        )
        check(progress.currentPlayStreak, expected.currentPlayStreak, "currentPlayStreak")
        check(progress.longestPlayStreak, expected.longestPlayStreak, "longestPlayStreak")
        check(progress.multiplayerGamesPlayed, expected.multiplayerGamesPlayed, "multiplayerGamesPlayed")
        check(progress.multiplayerGamesWon, expected.multiplayerGamesWon, "multiplayerGamesWon")
        check(progress.multiplayerGamesLost, expected.multiplayerGamesLost, "multiplayerGamesLost")
        check(progress.multiplayerGamesDraw, expected.multiplayerGamesDraw, "multiplayerGamesDraw")
        check(progress.bestMultiplayerScore, expected.bestMultiplayerScore, "bestMultiplayerScore")
        check(progress.multiplayerWinStreak, expected.multiplayerWinStreak, "multiplayerWinStreak")
        check(
            progress.longestMultiplayerWinStreak,
            expected.longestMultiplayerWinStreak,
            "longestMultiplayerWinStreak"
        )
        check(
            progress.multiplayerTotalResponseTimeMs,
            expected.multiplayerTotalResponseTimeMs,
            "multiplayerTotalResponseTimeMs"
        )
        check(
            progress.multiplayerTotalQuestionsAnswered,
            expected.multiplayerTotalQuestionsAnswered,
            "multiplayerTotalQuestionsAnswered"
        )
        check(
            progress.multiplayerTotalQuestionsCorrect,
            expected.multiplayerTotalQuestionsCorrect,
            "multiplayerTotalQuestionsCorrect"
        )

        // Fields introduced after v0.1.x: present in the v0.2.0 fixture, defaulted for
        // the schema-0 fixtures. Both cases are recorded in the manifest.
        check(
            Dictionary(uniqueKeysWithValues: progress.powerUpCredits.map { ($0.key.rawValue, $0.value) }),
            expected.powerUpCredits,
            "powerUpCredits"
        )
        check(
            progress.multiplayerMatchReceipts.map(\.matchID),
            expected.multiplayerMatchReceipts.map(\.matchID),
            "multiplayerMatchReceipts matchIDs"
        )
        check(
            progress.multiplayerMatchReceipts.map(\.fingerprint),
            expected.multiplayerMatchReceipts.map(\.fingerprint),
            "multiplayerMatchReceipts fingerprints"
        )
        check(
            progress.rewardReceipts.map(\.receiptID),
            expected.rewardReceipts.map(\.receiptID),
            "rewardReceipts receiptIDs"
        )
        check(
            progress.rewardReceipts.map(\.kind),
            expected.rewardReceipts.map(\.kind),
            "rewardReceipts kinds"
        )
        check(
            progress.rewardReceipts.map(\.fingerprint),
            expected.rewardReceipts.map(\.fingerprint),
            "rewardReceipts fingerprints"
        )
        for (actual, want) in zip(progress.rewardReceipts, expected.rewardReceipts) {
            assertDate(
                actual.recordedAt,
                matchesISO8601: want.recordedAt,
                field: "rewardReceipts[\(actual.receiptID)].recordedAt",
                label: label,
                file: file,
                line: line
            )
        }

        check(progress.categoryStats.keys.sorted(), expected.categoryStats.keys.sorted(), "categoryStats keys")
        for (category, want) in expected.categoryStats {
            guard let actual = progress.categoryStats[category] else {
                XCTFail("\(label) categoryStats is missing \(category)", file: file, line: line)
                continue
            }
            check(actual.questionsAnswered, want.questionsAnswered, "categoryStats[\(category)].questionsAnswered")
            check(actual.questionsCorrect, want.questionsCorrect, "categoryStats[\(category)].questionsCorrect")
            check(
                actual.correctlyAnsweredIDs,
                Set(want.correctlyAnsweredIDs),
                "categoryStats[\(category)].correctlyAnsweredIDs"
            )
            check(actual.bestScore, want.bestScore, "categoryStats[\(category)].bestScore")
            check(
                actual.questionsCountAtHundredPercent,
                want.questionsCountAtHundredPercent,
                "categoryStats[\(category)].questionsCountAtHundredPercent"
            )
        }

        check(progress.dailyStats.keys.sorted(), expected.dailyStats.keys.sorted(), "dailyStats keys")
        for (day, want) in expected.dailyStats {
            guard let actual = progress.dailyStats[day] else {
                XCTFail("\(label) dailyStats is missing \(day)", file: file, line: line)
                continue
            }
            check(actual.questionsAnswered, want.questionsAnswered, "dailyStats[\(day)].questionsAnswered")
            check(actual.questionsCorrect, want.questionsCorrect, "dailyStats[\(day)].questionsCorrect")
            check(actual.gamesPlayed, want.gamesPlayed, "dailyStats[\(day)].gamesPlayed")
            check(
                actual.totalResponseTimeMs,
                want.totalResponseTimeMs,
                "dailyStats[\(day)].totalResponseTimeMs"
            )
            check(
                actual.questionsByDifficulty,
                want.questionsByDifficulty,
                "dailyStats[\(day)].questionsByDifficulty"
            )
            check(
                actual.correctByDifficulty,
                want.correctByDifficulty,
                "dailyStats[\(day)].correctByDifficulty"
            )
        }

        check(
            progress.hourlyPerformance.keys.map(String.init).sorted(),
            expected.hourlyPerformance.keys.sorted(),
            "hourlyPerformance keys"
        )
        for (hourText, want) in expected.hourlyPerformance {
            guard let hour = Int(hourText), let actual = progress.hourlyPerformance[hour] else {
                XCTFail("\(label) hourlyPerformance is missing hour \(hourText)", file: file, line: line)
                continue
            }
            check(actual.questionsAnswered, want.questionsAnswered, "hourlyPerformance[\(hour)].questionsAnswered")
            check(actual.questionsCorrect, want.questionsCorrect, "hourlyPerformance[\(hour)].questionsCorrect")
            check(actual.sessionCount, want.sessionCount, "hourlyPerformance[\(hour)].sessionCount")
        }

        assertDate(
            progress.lastAppOpenDate,
            matchesISO8601: expected.lastAppOpenDate,
            field: "lastAppOpenDate",
            label: label,
            file: file,
            line: line
        )
        assertDate(
            progress.lastDailyRewardClaimedDate,
            matchesISO8601: expected.lastDailyRewardClaimedDate,
            field: "lastDailyRewardClaimedDate",
            label: label,
            file: file,
            line: line
        )
        assertDate(
            progress.lastRewardAdWatchedDate,
            matchesISO8601: expected.lastRewardAdWatchedDate,
            field: "lastRewardAdWatchedDate",
            label: label,
            file: file,
            line: line
        )
        assertDate(
            progress.previousAppOpenDate,
            matchesISO8601: expected.previousAppOpenDate,
            field: "previousAppOpenDate",
            label: label,
            file: file,
            line: line
        )
        assertDate(
            progress.lastPlayedDate,
            matchesISO8601: expected.lastPlayedDate,
            field: "lastPlayedDate",
            label: label,
            file: file,
            line: line
        )
    }
}
