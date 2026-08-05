import Foundation
import QuizEngineCore

enum StarterQuizContentValidationError: LocalizedError {
    case structuralIssues([QuizContentValidationIssue])

    var errorDescription: String? {
        switch self {
        case .structuralIssues(let issues):
            return "StarterQuiz content failed QuizEngine validation: \(issues)"
        }
    }
}

enum StarterQuizContent {
    static let questionsFileName = "starter_questions"

    static func makeQuestionDataService(bundle: Bundle = .main) -> QuestionDataService {
        QuestionDataService(bundle: bundle, fileName: questionsFileName)
    }

    static func validateQuestions(bundle: Bundle) throws {
        let questionData = try makeQuestionDataService(bundle: bundle).getQuestionData()
        let result = QuizContentValidator.validate(
            questionData,
            categories: StarterQuizVariantDefinition.categories
        )

        guard result.isValid else {
            throw StarterQuizContentValidationError.structuralIssues(result.issues)
        }
    }
}
