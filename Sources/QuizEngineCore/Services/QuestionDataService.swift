//
//  QuestionDataService.swift
//  QuizEngineCore
//
//  Created by Milos Petrusic on 3.12.22..
//

import Foundation

// MARK: - Phase 4A: Session Build Result

/// Result of building a session, includes recycling status for UI feedback
public struct SessionBuildResult: Sendable {
    /// Questions selected for this session
    public let questions: [Question]
    /// True if ALL questions in category have been seen (recycling will occur)
    public let isRecycling: Bool
    /// Total number of questions available in the category
    public let totalInCategory: Int
    /// Number of questions already seen by the user
    public let seenCount: Int

    public init(questions: [Question], isRecycling: Bool, totalInCategory: Int, seenCount: Int) {
        self.questions = questions
        self.isRecycling = isRecycling
        self.totalInCategory = totalInCategory
        self.seenCount = seenCount
    }
}

// MARK: - Practice Session Result

/// Result of building a practice session with completion tracking
public struct PracticeSessionResult: Sendable {
    /// Questions selected for this session
    public let questions: [Question]
    /// Total questions in the category
    public let totalInCategory: Int
    /// Questions already correctly answered (for completion %)
    public let correctlyAnsweredCount: Int
    /// True if user has answered all questions correctly at least once
    public let isCategoryComplete: Bool

    public init(questions: [Question], totalInCategory: Int, correctlyAnsweredCount: Int, isCategoryComplete: Bool) {
        self.questions = questions
        self.totalInCategory = totalInCategory
        self.correctlyAnsweredCount = correctlyAnsweredCount
        self.isCategoryComplete = isCategoryComplete
    }
}

/// Error thrown when question data cannot be loaded
public enum QuestionDataError: Error {
    case fileNotFound(String)
    case decodingFailed(Error)
}

public protocol QuestionDataServiceProvider {
    func getQuestionData() throws -> QuestionData
    func getQuestionData(fromFile fileName: String) throws -> QuestionData
    func getQuestions(category: String?, difficulty: Int?) throws -> [Question]
}

public final class QuestionDataService: QuestionDataServiceProvider {
    private let resourceBundle: Bundle
    private let questionsFileName: String
    private var randomNumberGenerator: any RandomNumberGenerator
    public let rules: QuizRulesConfiguration

    public init(
        resource: QuestionResource,
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.resourceBundle = resource.bundle
        self.questionsFileName = resource.fileName
        self.randomNumberGenerator = randomNumberGenerator
        self.rules = .serbianCompatible
    }

    public init(
        variant: QuizVariantDefinition,
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.resourceBundle = variant.questionResource.bundle
        self.questionsFileName = variant.questionResource.fileName
        self.randomNumberGenerator = randomNumberGenerator
        self.rules = variant.rules
    }

    public init(
        resource: QuestionResource,
        rules: QuizRulesConfiguration,
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.resourceBundle = resource.bundle
        self.questionsFileName = resource.fileName
        self.randomNumberGenerator = randomNumberGenerator
        self.rules = rules
    }

    public init(
        bundle: Bundle,
        fileName: String,
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.resourceBundle = bundle
        self.questionsFileName = fileName
        self.randomNumberGenerator = randomNumberGenerator
        self.rules = .serbianCompatible
    }

    // MARK: - Load all questions from default file

    public func getQuestionData() throws -> QuestionData {
        return try getQuestionData(fromFile: questionsFileName)
    }

    // MARK: - Load questions from a specific file

    public func getQuestionData(fromFile fileName: String) throws -> QuestionData {
        let decoder = JSONDecoder()
        guard let resource = resourceBundle.url(forResource: fileName, withExtension: "json") else {
            throw QuestionDataError.fileNotFound(fileName)
        }

        do {
            let data = try Data(contentsOf: resource)
            return try decoder.decode(QuestionData.self, from: data)
        } catch {
            print("Error loading \(fileName).json: \(error.localizedDescription)")
            throw QuestionDataError.decodingFailed(error)
        }
    }

    // MARK: - Load filtered questions by category and/or difficulty

    public func getQuestions(category: String?, difficulty: Int?) throws -> [Question] {
        let allQuestions = try getQuestionData().questions

        var filtered = allQuestions

        if let category = category {
            filtered = filtered.filter { $0.categories.contains(category) }
        }

        if let difficulty = difficulty {
            filtered = filtered.filter { $0.difficulty == difficulty }
        }

        return filtered
    }

    // MARK: - Helper methods

    public func getAllCategories() throws -> [String] {
        let allQuestions = try getQuestionData().questions
        let categories = Set(allQuestions.flatMap { $0.categories })
        return Array(categories).sorted()
    }

    public func getQuestionCount(forCategory category: String) throws -> Int {
        let questions = try getQuestions(category: category, difficulty: nil)
        return questions.count
    }

    // MARK: - Competitive Mode (Pure Random - ALL Questions)

    public func getQuestionsForCompetitiveMode() throws -> [Question] {
        let allQuestions = try getQuestionData().questions
        let shuffled = allQuestions.shuffled(using: &randomNumberGenerator)
        // The limit is applied before the ramp, never after: ordering a bank of
        // 175 and then taking the first 20 would hand the player twenty easy
        // questions and call it a session.
        guard let limit = rules.sessions.competitiveQuestionLimit else {
            return orderedByConfiguredProgression(shuffled)
        }
        return orderedByConfiguredProgression(Array(shuffled.prefix(limit)))
    }

    // MARK: - Category Mode (All Questions from Category)

    public func getQuestionsForCategoryMode(category: String) throws -> [Question] {
        let categoryQuestions = try getQuestions(category: category, difficulty: nil)
        let shuffled = categoryQuestions.shuffled(using: &randomNumberGenerator)
        guard let limit = rules.sessions.categoryQuestionLimit else {
            return orderedByConfiguredProgression(shuffled)
        }
        return orderedByConfiguredProgression(Array(shuffled.prefix(limit)))
    }

    // MARK: - Multiplayer Mode (Random from All Categories)

    public func getQuestionsForMultiplayerMatch() throws -> [Question] {
        try getQuestionsForMultiplayerMatch(count: rules.sessions.multiplayerQuestionCount)
    }

    public func getQuestionsForMultiplayerMatch(count: Int = 15) throws -> [Question] {
        let allQuestions = try getQuestionData().questions.filter { $0.imageName == nil }
        return Array(allQuestions.shuffled(using: &randomNumberGenerator).prefix(count))
    }

    // MARK: - Practice Mode (Simple Random - Exactly 20 Questions)

    public func getQuestionsForPracticeMode(
        category: String?,
        correctlyAnsweredIDs: Set<Int>
    ) throws -> PracticeSessionResult {
        try getQuestionsForPracticeMode(
            category: category,
            correctlyAnsweredIDs: correctlyAnsweredIDs,
            sessionSize: rules.sessions.practiceQuestionCount,
            unansweredRatio: rules.sessions.practiceUnansweredRatio
        )
    }

    public func getQuestionsForPracticeMode(
        category: String?,
        correctlyAnsweredIDs: Set<Int>,
        sessionSize: Int = 20
    ) throws -> PracticeSessionResult {
        try getQuestionsForPracticeMode(
            category: category,
            correctlyAnsweredIDs: correctlyAnsweredIDs,
            sessionSize: sessionSize,
            unansweredRatio: 0.8
        )
    }

    private func getQuestionsForPracticeMode(
        category: String?,
        correctlyAnsweredIDs: Set<Int>,
        sessionSize: Int,
        unansweredRatio: Double
    ) throws -> PracticeSessionResult {
        let allCategoryQuestions = try getQuestions(category: category, difficulty: nil)
        let totalInCategory = allCategoryQuestions.count

        let masteredCount = allCategoryQuestions.filter { correctlyAnsweredIDs.contains($0.id) }.count
        let isCategoryComplete = masteredCount >= totalInCategory && totalInCategory > 0

        let unanswered = allCategoryQuestions
            .filter { !correctlyAnsweredIDs.contains($0.id) }
            .shuffled(using: &randomNumberGenerator)
        let answered = allCategoryQuestions
            .filter { correctlyAnsweredIDs.contains($0.id) }
            .shuffled(using: &randomNumberGenerator)

        let scaledUnansweredTarget = Double(sessionSize) * unansweredRatio
        let unansweredTarget = scaledUnansweredTarget >= Double(Int.max)
            ? Int.max
            : Int(scaledUnansweredTarget)
        let unansweredToTake = min(unansweredTarget, unanswered.count)
        let answeredToTake   = min(sessionSize - unansweredToTake, answered.count)

        var session = Array(unanswered.prefix(unansweredToTake))
                    + Array(answered.prefix(answeredToTake))

        if session.count < sessionSize {
            let used = Set(session.map(\.id))
            let extra = allCategoryQuestions
                .filter { !used.contains($0.id) }
                .shuffled(using: &randomNumberGenerator)
            session += extra.prefix(sessionSize - session.count)
        }

        let questionsToReturn = orderedByConfiguredProgression(
            session.shuffled(using: &randomNumberGenerator)
        )

        return PracticeSessionResult(
            questions: questionsToReturn,
            totalInCategory: totalInCategory,
            correctlyAnsweredCount: masteredCount,
            isCategoryComplete: isCategoryComplete
        )
    }

    @available(*, deprecated, message: "Use getQuestionsForPracticeMode or getQuestionsForCompetitiveMode instead")
    public func getQuestionsForSession(
        category: String?,
        correctlyAnsweredIDs: Set<Int>,
        sessionSize: Int = 20,
        unansweredRatio: Double = 0.7
    ) throws -> [Question] {
        let allCategoryQuestions = try getQuestions(category: category, difficulty: nil)

        let unanswered = allCategoryQuestions.filter { !correctlyAnsweredIDs.contains($0.id) }
        let answered = allCategoryQuestions.filter { correctlyAnsweredIDs.contains($0.id) }

        let unansweredCount = Int(Double(sessionSize) * unansweredRatio)
        let reviewCount = sessionSize - unansweredCount

        var session: [Question] = []

        if unanswered.count >= unansweredCount {
            session.append(contentsOf: unanswered.shuffled(using: &randomNumberGenerator).prefix(unansweredCount))
        } else {
            session.append(contentsOf: unanswered.shuffled(using: &randomNumberGenerator))
            let remaining = unansweredCount - unanswered.count
            session.append(contentsOf: answered.shuffled(using: &randomNumberGenerator).prefix(remaining))
        }

        session.append(contentsOf: answered.shuffled(using: &randomNumberGenerator).prefix(reviewCount))

        return session.shuffled(using: &randomNumberGenerator).prefix(sessionSize).map { $0 }
    }

    /// Still deprecated, but no longer for the reason the old message gave.
    ///
    /// Difficulty progression **is** used now — it is a variant rule, applied by
    /// the three live builders. This entry point stays deprecated because it is
    /// built on the deprecated `getQuestionsForSession`, not because the ramp is
    /// unused.
    @available(
        *, deprecated,
        message: "Set QuizSessionRules.difficultyProgression to .easyToHard and use the competitive, category, or practice builder"
    )
    public func getQuestionsForSessionWithDifficulty(
        category: String?,
        correctlyAnsweredIDs: Set<Int>,
        sessionSize: Int = 20
    ) throws -> [Question] {
        let mixedQuestions = try getQuestionsForSession(
            category: category,
            correctlyAnsweredIDs: correctlyAnsweredIDs,
            sessionSize: sessionSize,
            unansweredRatio: 0.7
        )

        return applyDifficultyProgression(to: mixedQuestions)
    }

    @available(*, deprecated, message: "Use getQuestionsForPracticeMode or getQuestionsForCompetitiveMode instead")
    public func getQuestionsForSessionWithStatus(
        category: String?,
        seenQuestionIDs: Set<Int>,
        correctlyAnsweredIDs: Set<Int>,
        sessionSize: Int = 20
    ) throws -> SessionBuildResult {
        let allCategoryQuestions = try getQuestions(category: category, difficulty: nil)
        let totalInCategory = allCategoryQuestions.count
        let seenCount = allCategoryQuestions.filter { seenQuestionIDs.contains($0.id) }.count
        let isRecycling = totalInCategory > 0 && seenCount >= totalInCategory

        let questions = try getQuestionsForSessionWithDifficulty(
            category: category,
            correctlyAnsweredIDs: correctlyAnsweredIDs,
            sessionSize: sessionSize
        )

        return SessionBuildResult(
            questions: questions,
            isRecycling: isRecycling,
            totalInCategory: totalInCategory,
            seenCount: seenCount
        )
    }

    /// Applies the variant's configured ordering, if it asked for one.
    ///
    /// The gate is here rather than in each builder so `none` — every consumer
    /// built against `0.2.2` — returns the caller's array untouched, including
    /// its identity, and cannot pay for a difficulty pass it did not request.
    private func orderedByConfiguredProgression(_ questions: [Question]) -> [Question] {
        switch rules.sessions.difficultyProgression {
        case .none:
            return questions
        case .easyToHard:
            return applyDifficultyProgression(to: questions)
        }
    }

    /// Orders a session easiest-first, shuffling within each difficulty so two
    /// runs over the same bank are not the same run.
    ///
    /// **This replaces a fixed-position band walk** that placed questions at
    /// absolute positions 5 and 15 with a preferred/fallback chain. Two things
    /// were wrong with it:
    ///
    /// - The positions were written for a 20-question session. AmericanQuiz's
    ///   competitive mode sets no `competitiveQuestionLimit`, so a run is the
    ///   whole bank — under fixed positions a 175-question run opened with five
    ///   easy questions, ten medium, and then a hundred and sixty hard ones.
    /// - When a band ran dry the chain fell back to an adjacent one, so a
    ///   surplus of easy questions could be stranded at the *end* of the
    ///   session. An easy question served last is exactly what an easy-to-hard
    ///   ramp promises not to do.
    ///
    /// Sorting removes both. The band widths now follow the session's own
    /// composition rather than a fraction that has to be reconciled with it, and
    /// there is nothing left over to misplace. Where supply matched the old
    /// bands — a 20-question session holding 5 easy, 10 medium and 5 hard — the
    /// output is identical to what the fixed positions produced.
    ///
    /// Difficulty is validated as `1...3` by `QuizQuestionStructureRules`, so
    /// the three groups are exhaustive; anything outside that range cannot reach
    /// a session. Deterministic under an injected generator, per QE-4.
    private func applyDifficultyProgression(to questions: [Question]) -> [Question] {
        let easy = questions.filter { $0.difficulty == 1 }.shuffled(using: &randomNumberGenerator)
        let medium = questions.filter { $0.difficulty == 2 }.shuffled(using: &randomNumberGenerator)
        let hard = questions.filter { $0.difficulty == 3 }.shuffled(using: &randomNumberGenerator)
        let ordered = easy + medium + hard

        // A question carrying a difficulty outside 1...3 would be dropped
        // silently by the three filters above, turning a content defect into a
        // shorter session nobody notices. Validation should have refused it
        // long before here; if it somehow did not, return the session untouched
        // rather than a lossy ordering of it.
        guard ordered.count == questions.count else { return questions }
        return ordered
    }
}
