//
//  QuestionDataService.swift
//  QuizEngineCore
//
//  Created by Milos Petrusic on 3.12.22..
//

import Foundation

// MARK: - Phase 4A: Session Build Result

/// Result of building a session, includes recycling status for UI feedback
public struct SessionBuildResult {
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
public struct PracticeSessionResult {
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

    public init(
        resource: QuestionResource,
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.resourceBundle = resource.bundle
        self.questionsFileName = resource.fileName
        self.randomNumberGenerator = randomNumberGenerator
    }

    public init(
        bundle: Bundle,
        fileName: String,
        randomNumberGenerator: any RandomNumberGenerator = SystemRandomNumberGenerator()
    ) {
        self.resourceBundle = bundle
        self.questionsFileName = fileName
        self.randomNumberGenerator = randomNumberGenerator
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
        return allQuestions.shuffled(using: &randomNumberGenerator)
    }

    // MARK: - Category Mode (All Questions from Category)

    public func getQuestionsForCategoryMode(category: String) throws -> [Question] {
        let categoryQuestions = try getQuestions(category: category, difficulty: nil)
        return categoryQuestions.shuffled(using: &randomNumberGenerator)
    }

    // MARK: - Multiplayer Mode (Random from All Categories)

    public func getQuestionsForMultiplayerMatch(count: Int = 15) throws -> [Question] {
        let allQuestions = try getQuestionData().questions.filter { $0.imageName == nil }
        return Array(allQuestions.shuffled(using: &randomNumberGenerator).prefix(count))
    }

    // MARK: - Practice Mode (Simple Random - Exactly 20 Questions)

    public func getQuestionsForPracticeMode(
        category: String?,
        correctlyAnsweredIDs: Set<Int>,
        sessionSize: Int = 20
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

        let unansweredTarget = Int(Double(sessionSize) * 0.8)
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

        let questionsToReturn = session.shuffled(using: &randomNumberGenerator)

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

    @available(*, deprecated, message: "Difficulty progression not currently used")
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

    private func applyDifficultyProgression(to questions: [Question]) -> [Question] {
        let easy = questions.filter { $0.difficulty == 1 }.shuffled(using: &randomNumberGenerator)
        let medium = questions.filter { $0.difficulty == 2 }.shuffled(using: &randomNumberGenerator)
        let hard = questions.filter { $0.difficulty == 3 }.shuffled(using: &randomNumberGenerator)

        var result: [Question] = []
        var easyIndex = 0
        var mediumIndex = 0
        var hardIndex = 0

        for position in 0..<questions.count {
            let question: Question

            if position < 5 {
                question = getNextQuestion(
                    preferred: easy, preferredIndex: &easyIndex,
                    fallback1: medium, fallback1Index: &mediumIndex,
                    fallback2: hard, fallback2Index: &hardIndex
                )
            } else if position < 15 {
                question = getNextQuestion(
                    preferred: medium, preferredIndex: &mediumIndex,
                    fallback1: easy, fallback1Index: &easyIndex,
                    fallback2: hard, fallback2Index: &hardIndex
                )
            } else {
                question = getNextQuestion(
                    preferred: hard, preferredIndex: &hardIndex,
                    fallback1: medium, fallback1Index: &mediumIndex,
                    fallback2: easy, fallback2Index: &easyIndex
                )
            }

            result.append(question)
        }

        return result
    }

    private func getNextQuestion(
        preferred: [Question], preferredIndex: inout Int,
        fallback1: [Question], fallback1Index: inout Int,
        fallback2: [Question], fallback2Index: inout Int
    ) -> Question {
        if preferredIndex < preferred.count {
            defer { preferredIndex += 1 }
            return preferred[preferredIndex]
        } else if fallback1Index < fallback1.count {
            defer { fallback1Index += 1 }
            return fallback1[fallback1Index]
        } else {
            defer { fallback2Index += 1 }
            return fallback2[fallback2Index]
        }
    }
}
