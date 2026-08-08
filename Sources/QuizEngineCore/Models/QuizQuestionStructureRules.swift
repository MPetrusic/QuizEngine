import Foundation

/// A structural defect in a single question, independent of where the question came from.
///
/// Indexes are zero-based and refer to positions inside the inspected question.
public enum QuizQuestionStructureIssue: Equatable, Sendable {
    case nonPositiveID(id: Int)
    case missingCategories
    case blankCategory(categoryIndex: Int, categoryID: String)
    case unknownCategory(categoryIndex: Int, categoryID: String)
    case duplicateCategory(categoryIndex: Int, categoryID: String)
    case invalidAnswerCount(count: Int)
    case blankAnswerText(answerIndex: Int, text: String)
    case duplicateAnswerText(answerIndex: Int, text: String)
    case invalidCorrectAnswerCount(count: Int)
    case invalidDifficulty(difficulty: Int)
}

/// The single definition of question structure used by every validator in the engine.
///
/// `QuizContentValidator` applies these rules to locally decoded content and the multiplayer
/// wire validator applies them to a peer-supplied game configuration. Neither may define its
/// own answer count, answer-text normalization, correct-answer count, difficulty bound, or
/// category-membership rule, so content accepted from a peer is content the local pipeline
/// would also accept.
public enum QuizQuestionStructureRules {
    /// Every question must offer exactly this many answers.
    public static let requiredAnswerCount = 4

    /// The inclusive difficulty bounds a question must fall within.
    public static let difficultyRange = 1...3

    /// Exactly one answer must be marked correct.
    public static let requiredCorrectAnswerCount = 1

    /// Whether a string is empty or contains only whitespace.
    public static func isBlank(_ value: String) -> Bool {
        value.isEmpty || value.allSatisfy(\.isWhitespace)
    }

    /// Collapses whitespace runs and case-folds so two answers that read identically to a
    /// player cannot both appear in the same question.
    public static func normalizedAnswerText(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func isValidAnswerCount(_ count: Int) -> Bool {
        count == requiredAnswerCount
    }

    public static func isValidDifficulty(_ difficulty: Int) -> Bool {
        difficultyRange.contains(difficulty)
    }

    /// Returns every structural issue in `question`, ordered by rule and then by answer or
    /// category index. The order is part of the contract so validation output is deterministic.
    ///
    /// Duplicate question IDs are not reported here because uniqueness is a property of a
    /// question set, not of a single question. Callers own that check.
    public static func issues(
        in question: Question,
        allowedCategoryIDs: Set<String>
    ) -> [QuizQuestionStructureIssue] {
        var issues: [QuizQuestionStructureIssue] = []

        if question.id <= 0 {
            issues.append(.nonPositiveID(id: question.id))
        }

        if question.categories.isEmpty {
            issues.append(.missingCategories)
        } else {
            // At most one issue per entry, so a single defect is reported once.
            var seenCategoryIDs = Set<String>()
            for (categoryIndex, categoryID) in question.categories.enumerated() {
                let isDuplicate = !seenCategoryIDs.insert(categoryID).inserted
                if isBlank(categoryID) {
                    issues.append(.blankCategory(categoryIndex: categoryIndex, categoryID: categoryID))
                } else if !allowedCategoryIDs.contains(categoryID) {
                    issues.append(.unknownCategory(categoryIndex: categoryIndex, categoryID: categoryID))
                } else if isDuplicate {
                    issues.append(.duplicateCategory(categoryIndex: categoryIndex, categoryID: categoryID))
                }
            }
        }

        if !isValidAnswerCount(question.answers.count) {
            issues.append(.invalidAnswerCount(count: question.answers.count))
        }

        var normalizedAnswers = Set<String>()
        for (answerIndex, answer) in question.answers.enumerated() {
            guard !isBlank(answer.text) else {
                issues.append(.blankAnswerText(answerIndex: answerIndex, text: answer.text))
                continue
            }
            if !normalizedAnswers.insert(normalizedAnswerText(answer.text)).inserted {
                issues.append(.duplicateAnswerText(answerIndex: answerIndex, text: answer.text))
            }
        }

        let correctAnswerCount = question.answers.count(where: \.correct)
        if correctAnswerCount != requiredCorrectAnswerCount {
            issues.append(.invalidCorrectAnswerCount(count: correctAnswerCount))
        }

        if !isValidDifficulty(question.difficulty) {
            issues.append(.invalidDifficulty(difficulty: question.difficulty))
        }

        return issues
    }
}
