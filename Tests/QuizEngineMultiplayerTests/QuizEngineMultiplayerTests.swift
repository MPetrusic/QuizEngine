import XCTest
import QuizEngineCore
@testable import QuizEngineMultiplayer

@MainActor
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

    func testConnectionManagerStartsGenericInboundTransportWithoutVendorTypes() {
        let manager = MultiplayerConnectionManager()
        let transport = FakeTransport()
        var prepared = false

        manager.startConnecting(using: transport) {
            prepared = true
        }

        XCTAssertTrue(prepared)
        guard case .connecting = manager.connectionState else {
            return XCTFail("Expected generic inbound connection state")
        }
    }
}

@MainActor
private final class FakeTransport: MultiplayerTransport {
    let localPlayer = MultiplayerPlayer(id: "test", displayName: "Test")
    private(set) var connectionState: TransportConnectionState = .idle
    private(set) var eventStream: AsyncStream<MultiplayerTransportEvent>
    private var continuation: AsyncStream<MultiplayerTransportEvent>.Continuation

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: MultiplayerTransportEvent.self)
        self.eventStream = stream
        self.continuation = continuation
    }

    func startSearching() { connectionState = .searching }
    func stopSearching() { connectionState = .idle }
    func invite(player: MultiplayerPlayer) {}
    func acceptInvite(from player: MultiplayerPlayer) {}
    func declineInvite(from player: MultiplayerPlayer) {}
    func send(message: MultiplayerMessage) throws {}
    func disconnect() { connectionState = .disconnected }

    func resetEventStream() {
        continuation.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: MultiplayerTransportEvent.self)
        eventStream = stream
        self.continuation = continuation
    }
}
