import XCTest
import QuizEngineCore
@testable import QuizEngineMultiplayer

final class QuizEngineMultiplayerTests: XCTestCase {
    func testGameConfigurationRoundTripsVariantQuestionsWithoutChangingIdentifiers() throws {
        let questions = [
            Question(
                id: 901,
                question: "Alternate variant question",
                answers: [Answer(text: "Correct", correct: true), Answer(text: "Wrong", correct: false)],
                categories: ["alternate-category"],
                difficulty: 3
            )
        ]
        let message = MultiplayerMessage.gameConfig(GameConfigPayload(questions: questions, seed: 42))

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(MultiplayerMessage.self, from: data)

        guard case .gameConfig(let configuration) = decoded else {
            return XCTFail("Expected game configuration")
        }
        XCTAssertEqual(configuration.seed, 42)
        XCTAssertEqual(configuration.questions, questions)
        XCTAssertEqual(configuration.questions.first?.categories, ["alternate-category"])
    }

    func testSeededAnswerShuffleIsDeterministicAcrossPeers() {
        let answers = ["A", "B", "C", "D"]
        var hostRNG = SeededRandomNumberGenerator(seed: 12345)
        var guestRNG = SeededRandomNumberGenerator(seed: 12345)

        XCTAssertEqual(answers.shuffled(using: &hostRNG), answers.shuffled(using: &guestRNG))
    }
}
