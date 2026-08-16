import XCTest
import QuizEngineCore
import QuizEngineTestSupport
@testable import QuizEngineGame

/// QE-A5 (neutral pause/resume) and QE-A6 (answer submission).
@MainActor
final class SessionControlTests: XCTestCase {
    private var questions: [Question] {
        [
            Question(
                id: 1,
                question: "First",
                answers: [
                    Answer(text: "Wrong", correct: false),
                    Answer(text: "Right", correct: true),
                    Answer(text: "Also wrong", correct: false)
                ],
                categories: ["alpha"]
            ),
            Question(
                id: 2,
                question: "Second",
                answers: [
                    Answer(text: "Right", correct: true),
                    Answer(text: "Wrong", correct: false)
                ],
                categories: ["beta"]
            )
        ]
    }

    private func makeViewModel(
        mode: GameMode = .singlePlayer,
        scheduler: TestScheduler = TestScheduler()
    ) -> QuizViewModel {
        QuizViewModel(
            questions: questions,
            gameMode: mode,
            selectedCategory: nil,
            scheduler: scheduler
        )
    }

    // MARK: - QE-A5: pause and resume

    /// Timer state is observed through `timeRemaining` under an injected clock,
    /// the way every other lifecycle test here does it — the underlying flags
    /// are private, and asserting behaviour rather than internals is the point.
    private func makeTimedViewModel(
        fundPowerUps: Bool = false
    ) throws -> (QuizViewModel, TestClock, TestScheduler) {
        let clock = TestClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let scheduler = TestScheduler()
        let viewModel = QuizViewModel(
            questions: questions,
            gameMode: .singlePlayer,
            selectedCategory: nil,
            clock: clock,
            scheduler: scheduler,
            randomNumberGenerator: SeededRandomNumberGenerator(seed: 12)
        )
        // A power-up with no funding source never activates, so a freeze test
        // without a progress manager would assert against a freeze that never
        // started.
        if fundPowerUps {
            viewModel.progressManager = try makeProgressManager()
        }
        return (viewModel, clock, scheduler)
    }

    private func makeProgressManager() throws -> PlayerProgressManager {
        let resource = QuestionResource(bundle: .main, fileName: "unused")
        let variant = try QuizVariantDefinition(
            categories: [
                QuizCategoryDefinition(id: "alpha", displayNameKey: "category.alpha", iconName: "a.circle", displayOrder: 0, unlockRequirement: .free),
                QuizCategoryDefinition(id: "beta", displayNameKey: "category.beta", iconName: "b.circle", displayOrder: 1, unlockRequirement: .free)
            ],
            achievements: [],
            questionResource: resource,
            rules: .serbianCompatible
        )
        return try PlayerProgressManager(
            variant: variant,
            questionDataService: QuestionDataService(resource: resource, rules: .serbianCompatible),
            persistenceStore: FakePersistenceStore(),
            clock: TestClock(now: Date(timeIntervalSinceReferenceDate: 0))
        )
    }

    /// **The view model shuffles each question's answers**, so a test that
    /// hardcoded an index would be asserting against the shuffle rather than
    /// against adjudication. The index is read back from the session, which is
    /// also what a real caller does.
    private func indexOfCorrectAnswer(in viewModel: QuizViewModel) throws -> Int {
        let answers = try XCTUnwrap(viewModel.questionData.first).answers
        return try XCTUnwrap(answers.firstIndex(where: \.correct))
    }

    private func indexOfWrongAnswer(in viewModel: QuizViewModel) throws -> Int {
        let answers = try XCTUnwrap(viewModel.questionData.first).answers
        return try XCTUnwrap(answers.firstIndex(where: { !$0.correct }))
    }

    private func advance(_ clock: TestClock, _ scheduler: TestScheduler, by interval: TimeInterval) {
        clock.advance(by: interval)
        scheduler.advance(by: interval)
    }

    /// The behaviour an app needs when it puts a sheet over a live run.
    ///
    /// Before this pair the only route was `handleAppBackgrounded()`, which
    /// asserts a backgrounding that did not happen.
    func testPauseSessionStopsTheClockAndResumeRestartsIt() throws {
        let (viewModel, clock, scheduler) = try makeTimedViewModel()
        advance(clock, scheduler, by: 2)
        let atPause = viewModel.timeRemaining

        viewModel.pauseSession()
        advance(clock, scheduler, by: 100)
        XCTAssertEqual(viewModel.timeRemaining, atPause, "a paused session must not lose time")
        XCTAssertEqual(viewModel.livesRemaining, 3, "a paused session must not time out")

        viewModel.resumeSession()
        advance(clock, scheduler, by: 2)
        XCTAssertLessThan(viewModel.timeRemaining, atPause, "resume must restart the clock")
        viewModel.stopTimer()
    }

    /// **The reason `stopTimer()` is not an adequate substitute.**
    ///
    /// Only the paused-session path pauses an active freeze. An app reaching for
    /// `stopTimer()` instead leaves a time freeze draining while the run is not
    /// being played — exactly the gap AmericanQuiz documented at its call site
    /// while waiting for this API.
    func testPauseSessionAlsoPausesAnActiveTimeFreeze() throws {
        let (viewModel, clock, scheduler) = try makeTimedViewModel(fundPowerUps: true)
        viewModel.useTimeFreeze()
        XCTAssertTrue(viewModel.isTimeFrozen)

        viewModel.pauseSession()
        advance(clock, scheduler, by: 100)
        XCTAssertTrue(viewModel.isTimeFrozen, "the freeze drained while the session was paused")

        viewModel.resumeSession()
        XCTAssertTrue(viewModel.isTimeFrozen)
        viewModel.stopTimer()
    }

    /// The contrast, asserted rather than described: `stopTimer()` does **not**
    /// hold a freeze, which is why the workaround was only ever a workaround.
    func testStopTimerAloneDoesNotHoldAFreeze() throws {
        let (viewModel, clock, scheduler) = try makeTimedViewModel(fundPowerUps: true)
        viewModel.useTimeFreeze()
        XCTAssertTrue(viewModel.isTimeFrozen)

        viewModel.stopTimer()
        advance(clock, scheduler, by: 100)
        XCTAssertFalse(viewModel.isTimeFrozen, "stopTimer is expected to let the freeze drain")
    }

    func testPauseIsIdempotentAndCannotLoseWhatWasRunning() throws {
        let (viewModel, clock, scheduler) = try makeTimedViewModel()
        advance(clock, scheduler, by: 1)
        let atPause = viewModel.timeRemaining

        viewModel.pauseSession()
        viewModel.pauseSession()
        advance(clock, scheduler, by: 50)
        XCTAssertEqual(viewModel.timeRemaining, atPause)

        viewModel.resumeSession()
        advance(clock, scheduler, by: 2)
        XCTAssertLessThan(
            viewModel.timeRemaining, atPause,
            "a double pause must still remember the clock was running"
        )
        viewModel.stopTimer()
    }

    func testResumingASessionThatWasNeverPausedDoesNotStartTheClock() throws {
        let (viewModel, clock, scheduler) = try makeTimedViewModel()
        viewModel.stopTimer()
        let stopped = viewModel.timeRemaining

        viewModel.resumeSession()
        advance(clock, scheduler, by: 10)
        XCTAssertEqual(
            viewModel.timeRemaining, stopped,
            "resume must not start a clock the app had deliberately stopped"
        )
    }

    /// A paused session must not resume itself through the timer's own entry.
    func testStartTimerIsRefusedWhileTheSessionIsPaused() throws {
        let (viewModel, clock, scheduler) = try makeTimedViewModel()
        viewModel.pauseSession()
        let atPause = viewModel.timeRemaining

        viewModel.startTimer()
        advance(clock, scheduler, by: 10)
        XCTAssertEqual(viewModel.timeRemaining, atPause)
    }

    /// The lifecycle methods keep working and are the same behaviour.
    func testLifecycleEntryPointsStillPauseAndResume() throws {
        let (viewModel, clock, scheduler) = try makeTimedViewModel()
        advance(clock, scheduler, by: 1)
        let atPause = viewModel.timeRemaining

        viewModel.handleAppBackgrounded()
        advance(clock, scheduler, by: 100)
        XCTAssertEqual(viewModel.timeRemaining, atPause)

        viewModel.handleAppForegrounded()
        advance(clock, scheduler, by: 2)
        XCTAssertLessThan(viewModel.timeRemaining, atPause)
        viewModel.stopTimer()
    }

    /// Mixed entry points must not deadlock the pause state: a sheet opened
    /// before backgrounding, then dismissed after foregrounding, must leave the
    /// run playable.
    func testPausingThroughOnePathAndResumingThroughTheOtherLeavesTheRunPlayable() throws {
        let (viewModel, clock, scheduler) = try makeTimedViewModel()
        advance(clock, scheduler, by: 1)
        let atPause = viewModel.timeRemaining

        viewModel.pauseSession()
        viewModel.handleAppForegrounded()
        advance(clock, scheduler, by: 2)

        XCTAssertLessThan(viewModel.timeRemaining, atPause)
        viewModel.stopTimer()
    }

    // MARK: - QE-A6: answer submission

    /// The rule that used to live in every consumer.
    func testAnsweringCorrectlyScoresWithoutTheCallerAdjudicating() throws {
        let viewModel = makeViewModel()
        viewModel.stopTimer()
        let correct = try indexOfCorrectAnswer(in: viewModel)

        XCTAssertEqual(viewModel.answer(at: correct), .correct)
        XCTAssertEqual(viewModel.score, 10)
        XCTAssertEqual(viewModel.livesRemaining, 3)
        XCTAssertEqual(viewModel.correctAnswersInRow, 1)
    }

    func testAnsweringWronglyCostsALifeWithoutTheCallerAdjudicating() throws {
        let viewModel = makeViewModel()
        viewModel.stopTimer()
        let wrong = try indexOfWrongAnswer(in: viewModel)

        XCTAssertEqual(viewModel.answer(at: wrong), .wrong)
        XCTAssertEqual(viewModel.score, 0)
        XCTAssertEqual(viewModel.livesRemaining, 2)
    }

    /// Correctness is read from the question, so a consumer cannot award a point
    /// for the wrong answer even by accident — which is the whole reason this
    /// moved out of the app.
    func testEveryWrongIndexIsAdjudicatedWrongAndTheCorrectOneRight() throws {
        for index in 0..<3 {
            let viewModel = makeViewModel()
            viewModel.stopTimer()
            let answers = try XCTUnwrap(viewModel.questionData.first).answers
            let expected: QuizViewModel.AnswerOutcome = answers[index].correct ? .correct : .wrong

            XCTAssertEqual(viewModel.answer(at: index), expected)
            XCTAssertEqual(viewModel.score, answers[index].correct ? 10 : 0)
        }
    }

    /// A refused submission must not cost a life. `rejected` exists precisely so
    /// it cannot be mistaken for `wrong`.
    func testOutOfRangeIndicesAreRejectedRatherThanCountedWrong() {
        let viewModel = makeViewModel()
        viewModel.stopTimer()

        XCTAssertEqual(viewModel.answer(at: -1), .rejected)
        XCTAssertEqual(viewModel.answer(at: 99), .rejected)
        XCTAssertEqual(viewModel.livesRemaining, 3)
        XCTAssertEqual(viewModel.score, 0)
    }

    /// Rapid repeated taps resolve once — the existing answer lock, reached
    /// through the new entry point.
    func testASecondSubmissionOnTheSameQuestionIsRejected() throws {
        let viewModel = makeViewModel()
        viewModel.stopTimer()
        let correct = try indexOfCorrectAnswer(in: viewModel)
        let wrong = try indexOfWrongAnswer(in: viewModel)

        XCTAssertEqual(viewModel.answer(at: correct), .correct)
        XCTAssertEqual(viewModel.answer(at: wrong), .rejected, "the answer lock must hold through answer(at:)")
        XCTAssertEqual(viewModel.score, 10, "a locked-out tap must not score again")
        XCTAssertEqual(viewModel.livesRemaining, 3, "a locked-out tap must not cost a life")
    }

    func testSubmissionsAfterTheSessionEndsAreRejected() throws {
        let viewModel = makeViewModel()
        viewModel.stopTimer()
        let correct = try indexOfCorrectAnswer(in: viewModel)
        viewModel.exitGame()

        XCTAssertEqual(viewModel.answer(at: correct), .rejected)
        XCTAssertEqual(viewModel.score, 0)
    }

    /// An empty session has no current question to adjudicate against.
    func testAnEmptySessionRejectsEverySubmission() {
        let viewModel = QuizViewModel(
            questions: [],
            gameMode: .singlePlayer,
            selectedCategory: nil,
            scheduler: TestScheduler()
        )
        XCTAssertEqual(viewModel.answer(at: 0), .rejected)
    }

    /// The two older entry points stay public and keep working, because a
    /// consumer that adjudicates elsewhere is still supported.
    func testTheOlderScoringEntryPointsRemainAvailable() {
        let viewModel = makeViewModel()
        viewModel.stopTimer()

        viewModel.increaseScoreForCorrectAnswer()
        XCTAssertEqual(viewModel.score, 10)
    }
}
