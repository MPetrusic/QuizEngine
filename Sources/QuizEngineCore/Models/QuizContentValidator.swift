import Foundation

/// A deterministic structural content-validation result for consumer CI and startup checks.
public struct QuizContentValidationResult: Equatable, Sendable {
    public let issues: [QuizContentValidationIssue]

    public init(issues: [QuizContentValidationIssue]) {
        self.issues = issues
    }

    public var isValid: Bool {
        issues.isEmpty
    }
}

/// A structural defect in decoded quiz content.
///
/// Question and answer indexes are zero-based and refer to their position in the supplied `QuestionData`.
public enum QuizContentValidationIssue: Equatable, Sendable {
    case nonPositiveQuestionID(questionIndex: Int, id: Int)
    case duplicateQuestionID(questionIndex: Int, id: Int)
    case missingCategories(questionIndex: Int)
    case unknownCategory(questionIndex: Int, categoryID: String)
    case duplicateCategory(questionIndex: Int, categoryID: String)
    case invalidAnswerCount(questionIndex: Int, count: Int)
    case emptyAnswerText(questionIndex: Int, answerIndex: Int, text: String)
    case duplicateAnswerText(questionIndex: Int, answerIndex: Int, text: String)
    case invalidCorrectAnswerCount(questionIndex: Int, count: Int)
    case invalidDifficulty(questionIndex: Int, difficulty: Int)
}

/// Validates reusable question structure without loading files, inspecting app assets, or mutating state.
///
/// Every structural rule comes from `QuizQuestionStructureRules`, which the multiplayer wire
/// validator also uses. This validator adds only the set-level rule that a question ID must be
/// unique across the supplied content.
public enum QuizContentValidator {
    /// Validates decoded questions against the canonical category IDs declared by the consumer variant.
    ///
    /// The returned issues are ordered by question, then by validation rule and answer index. This makes
    /// content-CI failures deterministic while allowing a consumer to report the full invalid content set.
    public static func validate(
        _ questionData: QuestionData,
        categories: [QuizCategoryDefinition]
    ) -> QuizContentValidationResult {
        let knownCategoryIDs = Set(categories.map(\.id))
        var seenQuestionIDs = Set<Int>()
        var issues: [QuizContentValidationIssue] = []

        for (questionIndex, question) in questionData.questions.enumerated() {
            let isDuplicateID = !seenQuestionIDs.insert(question.id).inserted
            let structureIssues = QuizQuestionStructureRules.issues(
                in: question,
                allowedCategoryIDs: knownCategoryIDs
            )

            var questionIssues = structureIssues.map { mapped($0, questionIndex: questionIndex) }
            if isDuplicateID {
                // The non-positive ID rule is always first when it applies, so a duplicate ID
                // reports directly after it and the aggregate order stays stable.
                let insertionIndex = question.id <= 0 ? 1 : 0
                questionIssues.insert(
                    .duplicateQuestionID(questionIndex: questionIndex, id: question.id),
                    at: insertionIndex
                )
            }
            issues.append(contentsOf: questionIssues)
        }

        return QuizContentValidationResult(issues: issues)
    }

    private static func mapped(
        _ issue: QuizQuestionStructureIssue,
        questionIndex: Int
    ) -> QuizContentValidationIssue {
        switch issue {
        case .nonPositiveID(let id):
            return .nonPositiveQuestionID(questionIndex: questionIndex, id: id)
        case .missingCategories:
            return .missingCategories(questionIndex: questionIndex)
        // A blank category can never be a canonical variant ID, so local content reports it
        // with the same issue an unrecognized ID produces.
        case .blankCategory(_, let categoryID), .unknownCategory(_, let categoryID):
            return .unknownCategory(questionIndex: questionIndex, categoryID: categoryID)
        case .duplicateCategory(_, let categoryID):
            return .duplicateCategory(questionIndex: questionIndex, categoryID: categoryID)
        case .invalidAnswerCount(let count):
            return .invalidAnswerCount(questionIndex: questionIndex, count: count)
        case .blankAnswerText(let answerIndex, let text):
            return .emptyAnswerText(questionIndex: questionIndex, answerIndex: answerIndex, text: text)
        case .duplicateAnswerText(let answerIndex, let text):
            return .duplicateAnswerText(questionIndex: questionIndex, answerIndex: answerIndex, text: text)
        case .invalidCorrectAnswerCount(let count):
            return .invalidCorrectAnswerCount(questionIndex: questionIndex, count: count)
        case .invalidDifficulty(let difficulty):
            return .invalidDifficulty(questionIndex: questionIndex, difficulty: difficulty)
        }
    }
}
