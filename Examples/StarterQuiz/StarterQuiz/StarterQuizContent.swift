import Foundation
import QuizEngineCore

enum StarterQuizContentValidationError: LocalizedError {
    case invalidQuestionID(Int)
    case duplicateQuestionID(Int)
    case unknownCategory(questionID: Int, categoryID: String)
    case missingCorrectAnswer(questionID: Int)

    var errorDescription: String? {
        switch self {
        case .invalidQuestionID(let id): return "Question ID must be positive: \(id)"
        case .duplicateQuestionID(let id): return "Question ID is duplicated: \(id)"
        case .unknownCategory(let questionID, let categoryID): return "Question \(questionID) references unknown category \(categoryID)"
        case .missingCorrectAnswer(let id): return "Question \(id) has no correct answer"
        }
    }
}

enum StarterQuizContent {
    static let questionsFileName = "starter_questions"

    static func makeQuestionDataService(bundle: Bundle = .main) -> QuestionDataService {
        QuestionDataService(bundle: bundle, fileName: questionsFileName)
    }

    static func validateQuestions(bundle: Bundle) throws {
        let questions = try makeQuestionDataService(bundle: bundle).getQuestionData().questions
        let categoryIDs = Set(StarterQuizVariantDefinition.categories.map(\.id))
        var questionIDs = Set<Int>()

        for question in questions {
            guard question.id > 0 else { throw StarterQuizContentValidationError.invalidQuestionID(question.id) }
            guard questionIDs.insert(question.id).inserted else {
                throw StarterQuizContentValidationError.duplicateQuestionID(question.id)
            }
            guard question.answers.contains(where: \.correct) else {
                throw StarterQuizContentValidationError.missingCorrectAnswer(questionID: question.id)
            }
            for categoryID in question.categories where !categoryIDs.contains(categoryID) {
                throw StarterQuizContentValidationError.unknownCategory(
                    questionID: question.id,
                    categoryID: categoryID
                )
            }
        }
    }
}
