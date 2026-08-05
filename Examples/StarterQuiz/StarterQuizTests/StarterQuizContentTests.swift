import XCTest
import QuizEngineCore
@testable import StarterQuiz

final class StarterQuizContentTests: XCTestCase {
    func testQuestionContentIsValid() throws {
        let bundle = Bundle(for: StarterQuizContentTests.self)
        let service = StarterQuizContent.makeQuestionDataService(bundle: bundle)
        let result = QuizContentValidator.validate(
            try service.getQuestionData(),
            categories: StarterQuizVariantDefinition.categories
        )

        XCTAssertTrue(result.isValid, "Unexpected QuizEngine validation issues: \(result.issues)")
        XCTAssertNoThrow(try StarterQuizContent.validateQuestions(bundle: bundle))
    }

    func testQuestionResourceLoadsFromExplicitBundleAndFilename() throws {
        let service = StarterQuizContent.makeQuestionDataService(bundle: Bundle(for: StarterQuizContentTests.self))
        XCTAssertEqual(try service.getQuestionData().questions.count, 5)
    }
}
