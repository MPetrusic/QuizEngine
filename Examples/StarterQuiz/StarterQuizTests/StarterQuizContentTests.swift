import XCTest
@testable import StarterQuiz

final class StarterQuizContentTests: XCTestCase {
    func testQuestionContentIsValid() throws {
        try StarterQuizContent.validateQuestions(bundle: Bundle(for: StarterQuizContentTests.self))
    }

    func testQuestionResourceLoadsFromExplicitBundleAndFilename() throws {
        let service = StarterQuizContent.makeQuestionDataService(bundle: Bundle(for: StarterQuizContentTests.self))
        XCTAssertEqual(try service.getQuestionData().questions.count, 5)
    }
}
