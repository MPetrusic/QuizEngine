import Foundation

/// Immutable rule state for one single-player or practice session.
///
/// SwiftUI may project this state into animations, sheets, and overlays, but it
/// must not decide whether a rule transition is valid. `generation` changes on
/// every accepted transition and is used to reject delayed work from a prior
/// session state.
public struct SoloQuizSessionState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case answering
        case feedback(SoloQuizAnswerOutcome)
        case awaitingDescription
        case awaitingExtraLife
        case lifeGranted
        case terminal(TerminalReason)
    }

    public enum TerminalReason: Equatable, Sendable {
        case completed
        case exhaustedLives
        case exited
        case emptySession
    }

    public let generation: UInt
    public let questionIndex: Int?
    public let phase: Phase

    public var acceptsAnswerInput: Bool {
        if case .answering = phase { return true }
        return false
    }

    public var isTerminal: Bool {
        if case .terminal = phase { return true }
        return false
    }

    public init(generation: UInt, questionIndex: Int?, phase: Phase) {
        self.generation = generation
        self.questionIndex = questionIndex
        self.phase = phase
    }
}

/// The outcome that locked a question. It is independent of any SwiftUI
/// feedback treatment.
public enum SoloQuizAnswerOutcome: Equatable, Sendable {
    case correct
    case wrong
    case timedOut
    case skipped
}

/// A rule-originated signal for a presentation layer or session host.
///
/// Effects are values, not closures. A host can animate, announce, or ignore an
/// effect without changing game rules. Delayed effects carry the state
/// generation that produced them, so stale callbacks are harmless.
public enum SoloQuizSessionEffect: Equatable, Sendable {
    case questionBegan(index: Int, generation: UInt)
    case answerLocked(SoloQuizAnswerOutcome, generation: UInt)
    case showFeedback(SoloQuizAnswerOutcome, generation: UInt)
    case showDescription(generation: UInt)
    case offerExtraLife(generation: UInt)
    case showLifeGranted(generation: UInt)
    case showStreak(generation: UInt)
    case pendingWorkCancelled(generation: UInt)
    case terminal(SoloQuizSessionState.TerminalReason, generation: UInt)
}

/// Value reducer used by `QuizViewModel`. It intentionally owns no providers,
/// scheduler, SwiftUI state, or mutable shared state.
struct SoloQuizSessionReducer: Sendable {
    private(set) var state = SoloQuizSessionState(generation: 0, questionIndex: nil, phase: .idle)

    mutating func begin(questionIndex: Int?) -> [SoloQuizSessionEffect] {
        transition(questionIndex: questionIndex, phase: questionIndex == nil ? .terminal(.emptySession) : .answering)
    }

    mutating func lockAnswer(_ outcome: SoloQuizAnswerOutcome) -> [SoloQuizSessionEffect] {
        guard state.acceptsAnswerInput else { return [] }
        let effects = transition(questionIndex: state.questionIndex, phase: .feedback(outcome))
        return effects + [
            .answerLocked(outcome, generation: state.generation),
            .showFeedback(outcome, generation: state.generation)
        ]
    }

    mutating func showDescription() -> [SoloQuizSessionEffect] {
        guard case .feedback(.wrong) = state.phase else { return [] }
        return transition(questionIndex: state.questionIndex, phase: .awaitingDescription) + [
            .showDescription(generation: state.generation)
        ]
    }

    mutating func offerExtraLife() -> [SoloQuizSessionEffect] {
        guard !state.isTerminal else { return [] }
        return transition(questionIndex: state.questionIndex, phase: .awaitingExtraLife) + [
            .offerExtraLife(generation: state.generation)
        ]
    }

    mutating func grantExtraLife() -> [SoloQuizSessionEffect] {
        guard case .awaitingExtraLife = state.phase else { return [] }
        return transition(questionIndex: state.questionIndex, phase: .lifeGranted) + [
            .showLifeGranted(generation: state.generation)
        ]
    }

    mutating func markLifeGranted() -> [SoloQuizSessionEffect] {
        guard !state.isTerminal else { return [] }
        return transition(questionIndex: state.questionIndex, phase: .lifeGranted) + [
            .showLifeGranted(generation: state.generation)
        ]
    }

    mutating func advance(to questionIndex: Int?) -> [SoloQuizSessionEffect] {
        guard !state.isTerminal else { return [] }
        return transition(questionIndex: questionIndex, phase: questionIndex == nil ? .terminal(.completed) : .answering)
    }

    mutating func terminate(_ reason: SoloQuizSessionState.TerminalReason) -> [SoloQuizSessionEffect] {
        guard !state.isTerminal else { return [] }
        return transition(questionIndex: state.questionIndex, phase: .terminal(reason)) + [
            .terminal(reason, generation: state.generation)
        ]
    }

    mutating func restart(questionIndex: Int?) -> [SoloQuizSessionEffect] {
        let previousGeneration = state.generation
        let effects = begin(questionIndex: questionIndex)
        return [.pendingWorkCancelled(generation: previousGeneration)] + effects
    }

    private mutating func transition(
        questionIndex: Int?,
        phase: SoloQuizSessionState.Phase
    ) -> [SoloQuizSessionEffect] {
        state = SoloQuizSessionState(
            generation: state.generation &+ 1,
            questionIndex: questionIndex,
            phase: phase
        )
        if case .answering = phase, let questionIndex {
            return [.questionBegan(index: questionIndex, generation: state.generation)]
        }
        return []
    }
}
