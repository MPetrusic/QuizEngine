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
    case invalidAnswerCount(questionIndex: Int, count: Int)
    case emptyAnswerText(questionIndex: Int, answerIndex: Int, text: String)
    case duplicateAnswerText(questionIndex: Int, answerIndex: Int, text: String)
    case invalidCorrectAnswerCount(questionIndex: Int, count: Int)
    case invalidDifficulty(questionIndex: Int, difficulty: Int)
}

/// Validates reusable question structure without loading files, inspecting app assets, or mutating state.
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
            if question.id <= 0 {
                issues.append(.nonPositiveQuestionID(questionIndex: questionIndex, id: question.id))
            }
            if isDuplicateID {
                issues.append(.duplicateQuestionID(questionIndex: questionIndex, id: question.id))
            }

            if question.categories.isEmpty {
                issues.append(.missingCategories(questionIndex: questionIndex))
            } else {
                for categoryID in question.categories where !knownCategoryIDs.contains(categoryID) {
                    issues.append(.unknownCategory(questionIndex: questionIndex, categoryID: categoryID))
                }
            }

            if question.answers.count != 4 {
                issues.append(.invalidAnswerCount(questionIndex: questionIndex, count: question.answers.count))
            }

            var normalizedAnswers = Set<String>()
            for (answerIndex, answer) in question.answers.enumerated() {
                guard !answer.text.isEmpty, !answer.text.allSatisfy(\.isWhitespace) else {
                    issues.append(
                        .emptyAnswerText(
                            questionIndex: questionIndex,
                            answerIndex: answerIndex,
                            text: answer.text
                        )
                    )
                    continue
                }

                let normalizedText = normalizedAnswerText(answer.text)
                if !normalizedAnswers.insert(normalizedText).inserted {
                    issues.append(
                        .duplicateAnswerText(
                            questionIndex: questionIndex,
                            answerIndex: answerIndex,
                            text: answer.text
                        )
                    )
                }
            }

            let correctAnswerCount = question.answers.count(where: \.correct)
            if correctAnswerCount != 1 {
                issues.append(
                    .invalidCorrectAnswerCount(
                        questionIndex: questionIndex,
                        count: correctAnswerCount
                    )
                )
            }

            if !(1...3).contains(question.difficulty) {
                issues.append(
                    .invalidDifficulty(questionIndex: questionIndex, difficulty: question.difficulty)
                )
            }
        }

        return QuizContentValidationResult(issues: issues)
    }

    private static func normalizedAnswerText(_ text: String) -> String {
        let collapsedWhitespace = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsedWhitespace.folding(
            options: .caseInsensitive,
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
