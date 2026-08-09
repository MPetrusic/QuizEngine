import XCTest
@testable import QuizEngineCore
import QuizEngineTestSupport

@MainActor
final class RewardTransactionTests: XCTestCase {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private var fixedNow: Date {
        Date(timeIntervalSinceReferenceDate: 10_000)
    }

    private func makeRules(rewardAdAmount: Int = 25) throws -> QuizRulesConfiguration {
        let defaults = QuizRulesConfiguration.serbianCompatible
        return try QuizRulesConfiguration(
            economy: QuizEconomyRules(
                initialCoins: defaults.economy.initialCoins,
                correctAnswerCoinReward: defaults.economy.correctAnswerCoinReward,
                dailyRewardTiers: defaults.economy.dailyRewardTiers,
                rewardAd: QuizRewardAdRules(
                    coinReward: rewardAdAmount,
                    cooldownSeconds: defaults.economy.rewardAd.cooldownSeconds
                )
            ),
            solo: defaults.solo,
            powerUps: defaults.powerUps,
            extraLife: defaults.extraLife,
            sessions: defaults.sessions,
            soloInterstitialEligibility: defaults.soloInterstitialEligibility,
            multiplayer: defaults.multiplayer
        )
    }

    private func makeVariant(rules: QuizRulesConfiguration? = nil) throws -> QuizVariantDefinition {
        try QuizVariantDefinition(
            categories: [
                QuizCategoryDefinition(
                    id: "nature",
                    displayNameKey: "category.nature",
                    iconName: "leaf",
                    displayOrder: 0,
                    unlockRequirement: .free
                )
            ],
            achievements: [],
            questionResource: QuestionResource(bundle: .module, fileName: "alternate_questions"),
            rules: rules ?? makeRules()
        )
    }

    private func makeManager(
        store: FakePersistenceStore,
        clock: TestClock,
        rules: QuizRulesConfiguration? = nil
    ) throws -> PlayerProgressManager {
        let variant = try makeVariant(rules: rules)
        return try PlayerProgressManager(
            variant: variant,
            questionDataService: QuestionDataService(variant: variant),
            persistenceStore: store,
            clock: clock,
            calendar: utcCalendar
        )
    }

    private func fingerprint(
        kind: RewardReceiptKind,
        amount: Int,
        version: String
    ) -> String {
        let kindValue = kind.rawValue
        return "kind:\(kindValue.utf8.count):\(kindValue)|amount:\(amount)|version:\(version.utf8.count):\(version)"
    }

    private func assertRewardState(
        _ manager: PlayerProgressManager,
        store: FakePersistenceStore,
        coins: Int,
        totalCoinsEarned: Int,
        cooldownDate: Date?,
        premiumClaimed: Bool,
        premiumVersion: String?,
        premiumFingerprint: String?,
        receipts: [RewardReceipt],
        saveAttempts: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(manager.progress.coins, coins, "coins", file: file, line: line)
        XCTAssertEqual(
            manager.progress.totalCoinsEarned,
            totalCoinsEarned,
            "total coins earned",
            file: file,
            line: line
        )
        XCTAssertEqual(
            manager.progress.lastRewardAdWatchedDate,
            cooldownDate,
            "reward cooldown date",
            file: file,
            line: line
        )
        XCTAssertEqual(
            manager.progress.hasReceivedPremiumBonusCoins,
            premiumClaimed,
            "Premium claimed flag",
            file: file,
            line: line
        )
        XCTAssertEqual(
            manager.progress.premiumBonusClaimedVersion,
            premiumVersion,
            "Premium claimed version",
            file: file,
            line: line
        )
        XCTAssertEqual(
            manager.progress.premiumBonusClaimedFingerprint,
            premiumFingerprint,
            "Premium claimed fingerprint",
            file: file,
            line: line
        )
        XCTAssertEqual(
            manager.progress.rewardReceipts.count,
            receipts.count,
            "reward receipt count",
            file: file,
            line: line
        )
        XCTAssertEqual(
            manager.progress.rewardReceipts,
            receipts,
            "reward receipt contents",
            file: file,
            line: line
        )
        XCTAssertEqual(
            store.replacePrimaryAttemptCount,
            saveAttempts,
            "save-attempt count",
            file: file,
            line: line
        )
    }

    func testRewardedAdFirstEarnedCallbackRecordsOnceAndDuplicateSurvivesReload() throws {
        let store = FakePersistenceStore()
        let clock = TestClock(now: fixedNow)
        let manager = try makeManager(store: store, clock: clock)
        let request = RewardedAdRewardRequest(
            receiptID: "ad-provider-callback-1001",
            rewardVersion: "rewarded-ad-v1",
            coinAmount: 25
        )
        let receipt = RewardReceipt(
            receiptID: request.receiptID,
            kind: .rewardedAdCoins,
            fingerprint: fingerprint(
                kind: .rewardedAdCoins,
                amount: request.coinAmount,
                version: request.rewardVersion
            ),
            recordedAt: fixedNow
        )

        XCTAssertEqual(manager.recordRewardedAdReward(request), .recorded)
        assertRewardState(
            manager,
            store: store,
            coins: 125,
            totalCoinsEarned: 125,
            cooldownDate: fixedNow,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [receipt],
            saveAttempts: 1
        )

        XCTAssertEqual(manager.recordRewardedAdReward(request), .alreadyRecorded)
        assertRewardState(
            manager,
            store: store,
            coins: 125,
            totalCoinsEarned: 125,
            cooldownDate: fixedNow,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [receipt],
            saveAttempts: 1
        )

        let reloaded = try makeManager(store: store, clock: clock)
        XCTAssertEqual(reloaded.recordRewardedAdReward(request), .alreadyRecorded)
        assertRewardState(
            reloaded,
            store: store,
            coins: 125,
            totalCoinsEarned: 125,
            cooldownDate: fixedNow,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [receipt],
            saveAttempts: 1
        )
    }

    func testRewardedAdConflictingReceiptAndCooldownAreVisibleWithoutMutation() throws {
        let store = FakePersistenceStore()
        let clock = TestClock(now: fixedNow)
        let manager = try makeManager(store: store, clock: clock)
        let request = RewardedAdRewardRequest(
            receiptID: "ad-provider-callback-1002",
            rewardVersion: "rewarded-ad-v1",
            coinAmount: 25
        )
        XCTAssertEqual(manager.recordRewardedAdReward(request), .recorded)
        let expectedReceipts = manager.progress.rewardReceipts

        XCTAssertEqual(
            manager.recordRewardedAdReward(
                RewardedAdRewardRequest(
                    receiptID: request.receiptID,
                    rewardVersion: request.rewardVersion,
                    coinAmount: 30
                )
            ),
            .conflictingReceipt
        )
        XCTAssertEqual(
            manager.recordRewardedAdReward(
                RewardedAdRewardRequest(
                    receiptID: "ad-provider-callback-1003",
                    rewardVersion: request.rewardVersion,
                    coinAmount: 25
                )
            ),
            .ineligible
        )
        assertRewardState(
            manager,
            store: store,
            coins: 125,
            totalCoinsEarned: 125,
            cooldownDate: fixedNow,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: expectedReceipts,
            saveAttempts: 1
        )
    }

    func testRewardedAdSaveFailureRollsBackAndRetryRecordsExactlyOnce() throws {
        let store = FakePersistenceStore()
        let clock = TestClock(now: fixedNow)
        let manager = try makeManager(store: store, clock: clock)
        let request = RewardedAdRewardRequest(
            receiptID: "ad-provider-callback-1004",
            rewardVersion: "rewarded-ad-v1",
            coinAmount: 25
        )
        store.failurePoint = .replacePrimary

        XCTAssertEqual(
            manager.recordRewardedAdReward(request),
            .persistenceFailed(
                .writeFailed(path: store.primaryURL.path, reason: "Injected failure")
            )
        )
        assertRewardState(
            manager,
            store: store,
            coins: 100,
            totalCoinsEarned: 100,
            cooldownDate: nil,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [],
            saveAttempts: 1
        )

        XCTAssertEqual(manager.recordRewardedAdReward(request), .recorded)
        let recordedReceipts = manager.progress.rewardReceipts
        assertRewardState(
            manager,
            store: store,
            coins: 125,
            totalCoinsEarned: 125,
            cooldownDate: fixedNow,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: recordedReceipts,
            saveAttempts: 2
        )

        XCTAssertEqual(manager.recordRewardedAdReward(request), .alreadyRecorded)
        assertRewardState(
            manager,
            store: store,
            coins: 125,
            totalCoinsEarned: 125,
            cooldownDate: fixedNow,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: recordedReceipts,
            saveAttempts: 2
        )
    }

    func testRewardedAdNegativeAmountAndArithmeticOverflowProduceNoMutation() throws {
        let negativeStore = FakePersistenceStore()
        let negativeClock = TestClock(now: fixedNow)
        let negativeManager = try makeManager(store: negativeStore, clock: negativeClock)

        XCTAssertEqual(
            negativeManager.recordRewardedAdReward(
                RewardedAdRewardRequest(
                    receiptID: "negative-ad",
                    rewardVersion: "rewarded-ad-v1",
                    coinAmount: -1
                )
            ),
            .rejected
        )
        assertRewardState(
            negativeManager,
            store: negativeStore,
            coins: 100,
            totalCoinsEarned: 100,
            cooldownDate: nil,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [],
            saveAttempts: 0
        )

        var overflowProgress = PlayerProgress.default
        overflowProgress.coins = Int.max
        overflowProgress.totalCoinsEarned = Int.max
        let overflowStore = FakePersistenceStore(
            primaryData: try PersistenceDocumentCodec.encode(overflowProgress)
        )
        let overflowClock = TestClock(now: fixedNow)
        let overflowManager = try makeManager(store: overflowStore, clock: overflowClock)

        XCTAssertEqual(
            overflowManager.recordRewardedAdReward(
                RewardedAdRewardRequest(
                    receiptID: "overflow-ad",
                    rewardVersion: "rewarded-ad-v1",
                    coinAmount: 25
                )
            ),
            .rejected
        )
        assertRewardState(
            overflowManager,
            store: overflowStore,
            coins: Int.max,
            totalCoinsEarned: Int.max,
            cooldownDate: nil,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [],
            saveAttempts: 0
        )
    }

    func testRewardedAdConsumerAdapterSubmitsOnlyEarnedCallbacks() throws {
        let store = FakePersistenceStore()
        let clock = TestClock(now: fixedNow)
        let manager = try makeManager(store: store, clock: clock)
        let provider = FakeRewardAdProvider(isLoaded: true)
        let request = RewardedAdRewardRequest(
            receiptID: "ad-provider-callback-1005",
            rewardVersion: "rewarded-ad-v1",
            coinAmount: 25
        )
        var outcome: RewardTransactionOutcome?

        provider.show { earned in
            guard earned else { return }
            outcome = manager.recordRewardedAdReward(request)
        }
        provider.completeReward(earned: false)
        XCTAssertNil(outcome)
        assertRewardState(
            manager,
            store: store,
            coins: 100,
            totalCoinsEarned: 100,
            cooldownDate: nil,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [],
            saveAttempts: 0
        )

        provider.show { earned in
            guard earned else { return }
            outcome = manager.recordRewardedAdReward(request)
        }
        provider.completeReward(earned: true)
        XCTAssertEqual(outcome, .recorded)
        let recordedReceipts = manager.progress.rewardReceipts
        assertRewardState(
            manager,
            store: store,
            coins: 125,
            totalCoinsEarned: 125,
            cooldownDate: fixedNow,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: recordedReceipts,
            saveAttempts: 1
        )

        provider.repeatLastCompletion(earned: true)
        XCTAssertEqual(outcome, .alreadyRecorded)
        assertRewardState(
            manager,
            store: store,
            coins: 125,
            totalCoinsEarned: 125,
            cooldownDate: fixedNow,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: recordedReceipts,
            saveAttempts: 1
        )
    }

    func testPremiumFirstEligibleClaimRecordsAtomicallyAndDuplicateSurvivesReload() throws {
        let store = FakePersistenceStore()
        let clock = TestClock(now: fixedNow)
        let manager = try makeManager(store: store, clock: clock)
        let request = PremiumBonusClaimRequest(
            receiptID: "verified-store-transaction-2001",
            rewardVersion: "premium-welcome-v1",
            coinAmount: 500,
            isEntitled: true
        )
        let claimFingerprint = fingerprint(
            kind: .premiumBonusCoins,
            amount: request.coinAmount,
            version: request.rewardVersion
        )
        let receipt = RewardReceipt(
            receiptID: request.receiptID,
            kind: .premiumBonusCoins,
            fingerprint: claimFingerprint,
            recordedAt: fixedNow
        )

        XCTAssertEqual(manager.claimPremiumBonus(request), .recorded)
        assertRewardState(
            manager,
            store: store,
            coins: 600,
            totalCoinsEarned: 600,
            cooldownDate: nil,
            premiumClaimed: true,
            premiumVersion: request.rewardVersion,
            premiumFingerprint: claimFingerprint,
            receipts: [receipt],
            saveAttempts: 1
        )

        XCTAssertEqual(manager.claimPremiumBonus(request), .alreadyRecorded)
        let reloaded = try makeManager(store: store, clock: clock)
        XCTAssertEqual(reloaded.claimPremiumBonus(request), .alreadyRecorded)
        assertRewardState(
            reloaded,
            store: store,
            coins: 600,
            totalCoinsEarned: 600,
            cooldownDate: nil,
            premiumClaimed: true,
            premiumVersion: request.rewardVersion,
            premiumFingerprint: claimFingerprint,
            receipts: [receipt],
            saveAttempts: 1
        )
    }

    func testPremiumClaimRequiresEntitlementWithoutMutation() throws {
        let store = FakePersistenceStore()
        let clock = TestClock(now: fixedNow)
        let manager = try makeManager(store: store, clock: clock)

        XCTAssertEqual(
            manager.claimPremiumBonus(
                PremiumBonusClaimRequest(
                    receiptID: "unverified-store-transaction",
                    rewardVersion: "premium-welcome-v1",
                    coinAmount: 500,
                    isEntitled: false
                )
            ),
            .ineligible
        )
        assertRewardState(
            manager,
            store: store,
            coins: 100,
            totalCoinsEarned: 100,
            cooldownDate: nil,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [],
            saveAttempts: 0
        )
    }

    func testPremiumSaveFailureRollsBackEveryFieldAndRemainsRetryable() throws {
        let store = FakePersistenceStore()
        let clock = TestClock(now: fixedNow)
        let manager = try makeManager(store: store, clock: clock)
        let request = PremiumBonusClaimRequest(
            receiptID: "verified-store-transaction-2002",
            rewardVersion: "premium-welcome-v1",
            coinAmount: 500,
            isEntitled: true
        )
        store.failurePoint = .replacePrimary

        XCTAssertEqual(
            manager.claimPremiumBonus(request),
            .persistenceFailed(
                .writeFailed(path: store.primaryURL.path, reason: "Injected failure")
            )
        )
        assertRewardState(
            manager,
            store: store,
            coins: 100,
            totalCoinsEarned: 100,
            cooldownDate: nil,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [],
            saveAttempts: 1
        )

        XCTAssertEqual(manager.claimPremiumBonus(request), .recorded)
        let claimFingerprint = fingerprint(
            kind: .premiumBonusCoins,
            amount: request.coinAmount,
            version: request.rewardVersion
        )
        assertRewardState(
            manager,
            store: store,
            coins: 600,
            totalCoinsEarned: 600,
            cooldownDate: nil,
            premiumClaimed: true,
            premiumVersion: request.rewardVersion,
            premiumFingerprint: claimFingerprint,
            receipts: manager.progress.rewardReceipts,
            saveAttempts: 2
        )
    }

    func testPremiumConflictingAmountOrVersionIsRejectedVisibly() throws {
        let store = FakePersistenceStore()
        let clock = TestClock(now: fixedNow)
        let manager = try makeManager(store: store, clock: clock)
        let request = PremiumBonusClaimRequest(
            receiptID: "verified-store-transaction-2003",
            rewardVersion: "premium-welcome-v1",
            coinAmount: 500,
            isEntitled: true
        )
        XCTAssertEqual(manager.claimPremiumBonus(request), .recorded)
        let expectedReceipts = manager.progress.rewardReceipts
        let expectedFingerprint = try XCTUnwrap(manager.progress.premiumBonusClaimedFingerprint)

        XCTAssertEqual(
            manager.claimPremiumBonus(
                PremiumBonusClaimRequest(
                    receiptID: request.receiptID,
                    rewardVersion: request.rewardVersion,
                    coinAmount: 750,
                    isEntitled: true
                )
            ),
            .conflictingReceipt
        )
        XCTAssertEqual(
            manager.claimPremiumBonus(
                PremiumBonusClaimRequest(
                    receiptID: "verified-store-transaction-2004",
                    rewardVersion: "premium-welcome-v2",
                    coinAmount: 500,
                    isEntitled: true
                )
            ),
            .conflictingReceipt
        )
        assertRewardState(
            manager,
            store: store,
            coins: 600,
            totalCoinsEarned: 600,
            cooldownDate: nil,
            premiumClaimed: true,
            premiumVersion: request.rewardVersion,
            premiumFingerprint: expectedFingerprint,
            receipts: expectedReceipts,
            saveAttempts: 1
        )
    }

    func testRewardReceiptPruningCannotMakePremiumBonusClaimableAgain() throws {
        let store = FakePersistenceStore()
        let clock = TestClock(now: fixedNow)
        let manager = try makeManager(store: store, clock: clock)
        let premiumRequest = PremiumBonusClaimRequest(
            receiptID: "verified-store-transaction-2005",
            rewardVersion: "premium-welcome-v1",
            coinAmount: 500,
            isEntitled: true
        )
        XCTAssertEqual(manager.claimPremiumBonus(premiumRequest), .recorded)
        let claimFingerprint = try XCTUnwrap(manager.progress.premiumBonusClaimedFingerprint)
        let premiumReceipt = try XCTUnwrap(manager.progress.rewardReceipts.first)

        var seeded = manager.progress
        let fillerReceipts = (0..<(PlayerProgress.maximumRewardReceiptCount - 1)).map { index in
            RewardReceipt(
                receiptID: "retained-ad-\(index)",
                kind: .rewardedAdCoins,
                fingerprint: "retained-ad-fingerprint-\(index)",
                recordedAt: nil
            )
        }
        seeded.rewardReceipts = [premiumReceipt] + fillerReceipts
        store.primaryData = try PersistenceDocumentCodec.encode(seeded)

        let reloaded = try makeManager(store: store, clock: clock)
        let adRequest = RewardedAdRewardRequest(
            receiptID: "pruning-ad",
            rewardVersion: "rewarded-ad-v1",
            coinAmount: 25
        )
        XCTAssertEqual(reloaded.recordRewardedAdReward(adRequest), .recorded)
        XCTAssertFalse(
            reloaded.progress.rewardReceipts.contains { $0.receiptID == premiumRequest.receiptID }
        )
        XCTAssertEqual(reloaded.progress.rewardReceipts.count, PlayerProgress.maximumRewardReceiptCount)
        let receiptsAfterPruning = reloaded.progress.rewardReceipts

        XCTAssertEqual(reloaded.claimPremiumBonus(premiumRequest), .alreadyRecorded)
        assertRewardState(
            reloaded,
            store: store,
            coins: 625,
            totalCoinsEarned: 625,
            cooldownDate: fixedNow,
            premiumClaimed: true,
            premiumVersion: premiumRequest.rewardVersion,
            premiumFingerprint: claimFingerprint,
            receipts: receiptsAfterPruning,
            saveAttempts: 2
        )
    }

    func testRewardRequestsRejectEmptyIdentityAndVersionWithoutMutation() throws {
        let store = FakePersistenceStore()
        let clock = TestClock(now: fixedNow)
        let manager = try makeManager(store: store, clock: clock)

        for request in [
            RewardedAdRewardRequest(receiptID: "", rewardVersion: "rewarded-ad-v1", coinAmount: 25),
            RewardedAdRewardRequest(receiptID: "ad-identity", rewardVersion: " \n", coinAmount: 25)
        ] {
            XCTAssertEqual(manager.recordRewardedAdReward(request), .rejected)
        }
        for request in [
            PremiumBonusClaimRequest(
                receiptID: "",
                rewardVersion: "premium-welcome-v1",
                coinAmount: 500,
                isEntitled: true
            ),
            PremiumBonusClaimRequest(
                receiptID: "premium-identity",
                rewardVersion: " \n",
                coinAmount: 500,
                isEntitled: true
            )
        ] {
            XCTAssertEqual(manager.claimPremiumBonus(request), .rejected)
        }
        assertRewardState(
            manager,
            store: store,
            coins: 100,
            totalCoinsEarned: 100,
            cooldownDate: nil,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [],
            saveAttempts: 0
        )
    }

    func testRewardReceiptDecoderRejectsEachBoundUniquenessAndNonemptyDefect() throws {
        let validReceipt = RewardReceipt(
            receiptID: "valid-receipt",
            kind: .rewardedAdCoins,
            fingerprint: "valid-fingerprint"
        )
        let cases: [(String, [RewardReceipt])] = [
            (
                "over bound",
                (0...PlayerProgress.maximumRewardReceiptCount).map { index in
                    RewardReceipt(
                        receiptID: "bounded-\(index)",
                        kind: .rewardedAdCoins,
                        fingerprint: "fingerprint-\(index)"
                    )
                }
            ),
            (
                "duplicate receipt ID",
                [
                    validReceipt,
                    RewardReceipt(
                        receiptID: validReceipt.receiptID,
                        kind: .premiumBonusCoins,
                        fingerprint: "different-fingerprint"
                    )
                ]
            ),
            (
                "empty receipt ID",
                [RewardReceipt(receiptID: "", kind: .rewardedAdCoins, fingerprint: "fingerprint")]
            ),
            (
                "empty fingerprint",
                [RewardReceipt(receiptID: "receipt", kind: .rewardedAdCoins, fingerprint: "")]
            )
        ]

        for (label, receipts) in cases {
            var progress = PlayerProgress.default
            progress.rewardReceipts = receipts
            let store = FakePersistenceStore(
                primaryData: try PersistenceDocumentCodec.encode(progress)
            )
            XCTAssertThrowsError(
                try makeManager(store: store, clock: TestClock(now: fixedNow)),
                label
            ) { error in
                XCTAssertEqual(
                    error as? PersistenceError,
                    .malformedData(path: store.primaryURL.path),
                    label
                )
            }
            XCTAssertEqual(store.replacePrimaryAttemptCount, 0, label)
        }
    }

    @available(*, deprecated, message: "Deliberately exercises deprecated compatibility bridges.")
    func testDeprecatedRewardBridgesEnforceCooldownAndRollbackSafely() throws {
        let store = FakePersistenceStore()
        let clock = TestClock(now: fixedNow)
        let manager = try makeManager(store: store, clock: clock)

        manager.recordRewardAdWatched()
        assertRewardState(
            manager,
            store: store,
            coins: 125,
            totalCoinsEarned: 125,
            cooldownDate: fixedNow,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [],
            saveAttempts: 1
        )

        manager.recordRewardAdWatched(coinsAwarded: 999)
        assertRewardState(
            manager,
            store: store,
            coins: 125,
            totalCoinsEarned: 125,
            cooldownDate: fixedNow,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [],
            saveAttempts: 1
        )

        clock.advance(by: QuizRulesConfiguration.serbianCompatible.economy.rewardAd.cooldownSeconds)
        store.failurePoint = .replacePrimary
        manager.recordRewardAdWatched(coinsAwarded: 7)
        assertRewardState(
            manager,
            store: store,
            coins: 125,
            totalCoinsEarned: 125,
            cooldownDate: fixedNow,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [],
            saveAttempts: 2
        )

        manager.recordRewardAdWatched(coinsAwarded: 7)
        assertRewardState(
            manager,
            store: store,
            coins: 132,
            totalCoinsEarned: 132,
            cooldownDate: clock.now,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [],
            saveAttempts: 3
        )

        store.failurePoint = .replacePrimary
        manager.markPremiumBonusCoinsReceived()
        assertRewardState(
            manager,
            store: store,
            coins: 132,
            totalCoinsEarned: 132,
            cooldownDate: clock.now,
            premiumClaimed: false,
            premiumVersion: nil,
            premiumFingerprint: nil,
            receipts: [],
            saveAttempts: 4
        )

        manager.markPremiumBonusCoinsReceived()
        manager.markPremiumBonusCoinsReceived()
        assertRewardState(
            manager,
            store: store,
            coins: 132,
            totalCoinsEarned: 132,
            cooldownDate: clock.now,
            premiumClaimed: true,
            premiumVersion: PlayerProgress.legacyPremiumBonusClaimIdentity,
            premiumFingerprint: PlayerProgress.legacyPremiumBonusClaimIdentity,
            receipts: [],
            saveAttempts: 5
        )
    }
}
