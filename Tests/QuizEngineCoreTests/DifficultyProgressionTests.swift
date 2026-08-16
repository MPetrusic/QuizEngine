import XCTest
@testable import QuizEngineCore
import QuizEngineTestSupport

/// QE-A1. Difficulty-progressive session construction as a supported,
/// non-deprecated path across the competitive, category, and practice builders.
@MainActor
final class DifficultyProgressionTests: XCTestCase {

    // MARK: - The default is unchanged

    /// Every consumer built against `0.2.2` gets exactly what it got before.
    func testProgressionDefaultsToNoneSoExistingConsumersAreUnaffected() throws {
        XCTAssertEqual(QuizRulesConfiguration.serbianCompatible.sessions.difficultyProgression, .none)

        let rules = try makeRules(progression: .none)
        let ordered = try service(rules: rules, seed: 99).getQuestionsForCompetitiveMode()
        let shuffledOnly = try service(rules: rules, seed: 99).getQuestionsForCompetitiveMode()

        // Same seed, same order: nothing reorders after the shuffle.
        XCTAssertEqual(ordered.map(\.id), shuffledOnly.map(\.id))
        XCTAssertFalse(isRamped(ordered), "an unconfigured session must not be ramped")
    }

    /// Omitting the parameter must still compile and mean `.none`, which is the
    /// property that keeps this release source-compatible.
    func testSessionRulesInitialiserKeepsItsPreExistingSignature() {
        let rules = QuizSessionRules(
            competitiveQuestionLimit: 20,
            categoryQuestionLimit: nil,
            practiceQuestionCount: 20,
            practiceUnansweredRatio: 0.8,
            multiplayerQuestionCount: 15
        )
        XCTAssertEqual(rules.difficultyProgression, .none)
    }

    // MARK: - The ramp

    func testCompetitiveModeRampsEasyToHardWhenConfigured() throws {
        let questions = try service(rules: try makeRules(progression: .easyToHard), seed: 7)
            .getQuestionsForCompetitiveMode()

        XCTAssertEqual(questions.count, 80)
        assertRamped(questions)
    }

    func testCategoryModeRampsEasyToHardWhenConfigured() throws {
        let questions = try service(rules: try makeRules(progression: .easyToHard), seed: 11)
            .getQuestionsForCategoryMode(category: "space")

        XCTAssertEqual(questions.count, 30)
        assertRamped(questions)
    }

    func testPracticeModeRampsEasyToHardWhenConfigured() throws {
        let rules = try makeRules(progression: .easyToHard, practiceCount: 30)
        let result = try service(rules: rules, seed: 3).getQuestionsForPracticeMode(
            category: nil,
            correctlyAnsweredIDs: []
        )

        XCTAssertEqual(result.questions.count, 30)
        assertRamped(result.questions)
    }

    /// **The reason the fixed positions 5 and 15 had to go.**
    ///
    /// AmericanQuiz's competitive mode sets no `competitiveQuestionLimit`, so a
    /// run is the whole bank. Under the old absolute thresholds everything from
    /// position 15 onward was hard — a 60-question run would have opened with 5
    /// easy and then served 45 hard questions in a row. The bands must scale.
    func testTheRampScalesWithSessionLengthRatherThanUsingFixedPositions() throws {
        let questions = try service(rules: try makeRules(progression: .easyToHard), seed: 5)
            .getQuestionsForCompetitiveMode()

        // The bank holds 25 easy and 25 hard, so the opening and closing
        // twenty are each drawn from one difficulty.
        let easyBand = questions.prefix(20)
        let hardBand = questions.suffix(20)

        XCTAssertTrue(easyBand.allSatisfy { $0.difficulty == 1 }, "the easy band must scale to a quarter of the run")
        XCTAssertTrue(hardBand.allSatisfy { $0.difficulty == 3 }, "the hard band must scale to the last quarter")

        // The old behaviour, stated so the regression is unmistakable: under the
        // fixed positions every question from 15 onward was hard.
        XCTAssertFalse(
            questions.dropFirst(15).allSatisfy { $0.difficulty == 3 },
            "positions 15+ are all hard, which is the fixed-position behaviour this replaced"
        )
    }

    /// At the size and supply the old algorithm was written for, the ordering
    /// reproduces it exactly — 5 easy, then 10 medium, then 5 hard.
    func testAtTwentyQuestionsTheBandsReproduceTheLegacyFiveAndFifteenSplit() throws {
        // The `legacysize` category holds exactly 20 questions shaped 5 easy /
        // 10 medium / 5 hard — the supply the old fixed split assumed. Drawing
        // 20 from the mixed bank instead would assert against whatever the
        // shuffle happened to deal.
        let rules = try makeRules(progression: .easyToHard)
        let questions = try service(rules: rules, seed: 21)
            .getQuestionsForCategoryMode(category: "legacysize")

        XCTAssertEqual(questions.count, 20)
        XCTAssertTrue(questions.prefix(5).allSatisfy { $0.difficulty == 1 })
        XCTAssertTrue(questions.dropFirst(5).prefix(10).allSatisfy { $0.difficulty == 2 })
        XCTAssertTrue(questions.dropFirst(15).allSatisfy { $0.difficulty == 3 })
    }

    /// The limit is applied before the ramp. Ordering the whole bank and then
    /// taking a prefix would hand the player an all-easy session.
    func testTheLimitIsAppliedBeforeTheRampSoAShortSessionStillSpansTheRange() throws {
        let rules = try makeRules(progression: .easyToHard, competitiveLimit: 12)
        let questions = try service(rules: rules, seed: 33).getQuestionsForCompetitiveMode()

        XCTAssertEqual(questions.count, 12)
        XCTAssertGreaterThan(
            Set(questions.map(\.difficulty)).count, 1,
            "a limited session ramped after truncation would be one difficulty throughout"
        )
        assertRamped(questions)
    }

    // MARK: - Determinism (QE-4)

    func testTheRampIsDeterministicUnderAnInjectedGenerator() throws {
        let rules = try makeRules(progression: .easyToHard)
        let first = try service(rules: rules, seed: 4_242).getQuestionsForCompetitiveMode()
        let second = try service(rules: rules, seed: 4_242).getQuestionsForCompetitiveMode()
        let different = try service(rules: rules, seed: 4_243).getQuestionsForCompetitiveMode()

        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertNotEqual(first.map(\.id), different.map(\.id), "a different seed must produce a different draw")
        // Both are still ramped: determinism is about which questions, not
        // whether the ordering rule applied.
        assertRamped(different)
    }

    /// The ramp must not drop, duplicate, or invent a question.
    func testTheRampPreservesTheSessionContentsExactly() throws {
        let plain = try service(rules: try makeRules(progression: .none), seed: 8)
            .getQuestionsForCompetitiveMode()
        let ramped = try service(rules: try makeRules(progression: .easyToHard), seed: 8)
            .getQuestionsForCompetitiveMode()

        XCTAssertEqual(Set(plain.map(\.id)), Set(ramped.map(\.id)))
        XCTAssertEqual(ramped.count, Set(ramped.map(\.id)).count, "the ramp duplicated a question")
    }

    /// A bank that does not span the three difficulties must not lose questions
    /// to the fallback chain.
    ///
    /// This is not hypothetical: **every question AmericanQuiz ships today
    /// carries `difficulty: 1`**, pending the Phase 7 editorial pass. Turning the
    /// ramp on against that bank must be a no-op, not a session that quietly
    /// drops questions the fallback could not place.
    func testABankThatDoesNotSpanTheDifficultiesKeepsEveryQuestion() throws {
        let variant = try QuizVariantDefinition(
            categories: [
                .init(id: "space", displayNameKey: "category.space", iconName: "moon", displayOrder: 0, unlockRequirement: .free),
                .init(id: "nature", displayNameKey: "category.nature", iconName: "leaf", displayOrder: 1, unlockRequirement: .free)
            ],
            achievements: [],
            questionResource: QuestionResource(bundle: .module, fileName: "alternate_questions"),
            rules: try makeRules(progression: .easyToHard)
        )
        let service = QuestionDataService(
            variant: variant,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 1)
        )

        let bank = try service.getQuestionData().questions
        let session = try service.getQuestionsForCompetitiveMode()

        XCTAssertEqual(Set(session.map(\.id)), Set(bank.map(\.id)))
        XCTAssertEqual(session.count, bank.count)
    }

    // MARK: - Multiplayer stays out

    /// A fixed match shared by two players has no meaningful ramp, and both
    /// sides must see one identical order.
    func testMultiplayerIgnoresTheProgressionSetting() throws {
        let rules = try makeRules(progression: .easyToHard)
        let match = try service(rules: rules, seed: 77).getQuestionsForMultiplayerMatch()
        let plain = try service(rules: try makeRules(progression: .none), seed: 77)
            .getQuestionsForMultiplayerMatch()

        XCTAssertEqual(match.map(\.id), plain.map(\.id))
    }

    // MARK: - Helpers

    private func service(rules: QuizRulesConfiguration, seed: UInt64) throws -> QuestionDataService {
        QuestionDataService(
            variant: try QuizVariantDefinition(
                categories: [
                    .init(id: "space", displayNameKey: "category.space", iconName: "moon", displayOrder: 0, unlockRequirement: .free),
                    .init(id: "nature", displayNameKey: "category.nature", iconName: "leaf", displayOrder: 1, unlockRequirement: .free)
                ],
                achievements: [],
                questionResource: QuestionResource(bundle: .module, fileName: "difficulty_ramp_questions"),
                rules: rules
            ),
            randomNumberGenerator: SeededRandomNumberGenerator(seed: seed)
        )
    }

    private func makeRules(
        progression: QuizDifficultyProgression,
        competitiveLimit: Int? = nil,
        practiceCount: Int = 20
    ) throws -> QuizRulesConfiguration {
        let base = QuizRulesConfiguration.serbianCompatible
        return try QuizRulesConfiguration(
            economy: base.economy,
            solo: base.solo,
            powerUps: base.powerUps,
            extraLife: base.extraLife,
            sessions: QuizSessionRules(
                competitiveQuestionLimit: competitiveLimit,
                categoryQuestionLimit: nil,
                practiceQuestionCount: practiceCount,
                practiceUnansweredRatio: 0.8,
                multiplayerQuestionCount: 15,
                difficultyProgression: progression
            ),
            soloInterstitialEligibility: base.soloInterstitialEligibility,
            multiplayer: base.multiplayer
        )
    }

    /// The session opens on the easiest band and closes on the hardest.
    ///
    /// Deliberately **not** a mean comparison: a random shuffle clears that
    /// roughly half the time, so it cannot tell a ramp from luck and the first
    /// version of this file had a `.none` test passing for the wrong reason.
    /// Band purity is the discriminator — a shuffle putting fifteen easy
    /// questions first by chance is vanishingly unlikely, and the ramp
    /// guarantees it whenever the supply exists.
    ///
    /// Deliberately not "sorted by difficulty" either: the algorithm falls back
    /// to an adjacent band when one runs dry, so a strict sort would fail on an
    /// uneven bank while the ramp is still doing its job.
    private func isRamped(_ questions: [Question]) -> Bool {
        let count = questions.count
        guard count >= 4 else { return true }
        let band = count / 4
        return questions.prefix(band).allSatisfy { $0.difficulty == 1 }
            && questions.suffix(band).allSatisfy { $0.difficulty == 3 }
    }

    private func assertRamped(
        _ questions: [Question],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            isRamped(questions),
            "the session is not ramped: \(questions.map(\.difficulty))",
            file: file,
            line: line
        )
    }
}
