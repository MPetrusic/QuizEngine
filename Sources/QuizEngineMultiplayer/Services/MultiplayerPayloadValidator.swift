import Foundation
import QuizEngineCore

/// A structural or policy defect in a peer-supplied game configuration.
///
/// Reasons are reported individually so a test can prove one invalid field at a time.
enum MultiplayerConfigurationRejection: Equatable, Sendable {
    case questionCountMismatch(expected: Int, actual: Int)
    case nonPositiveQuestionID(questionIndex: Int, id: Int)
    case duplicateQuestionID(questionIndex: Int, id: Int)
    case blankQuestionText(questionIndex: Int)
    case oversizedQuestionText(questionIndex: Int, bytes: Int)
    case invalidAnswerCount(questionIndex: Int, count: Int)
    case blankAnswerText(questionIndex: Int, answerIndex: Int)
    case duplicateAnswerText(questionIndex: Int, answerIndex: Int)
    case oversizedAnswerText(questionIndex: Int, answerIndex: Int, bytes: Int)
    case invalidCorrectAnswerCount(questionIndex: Int, count: Int)
    case invalidDifficulty(questionIndex: Int, difficulty: Int)
    case missingCategories(questionIndex: Int)
    case tooManyCategories(questionIndex: Int, count: Int)
    case blankCategory(questionIndex: Int, categoryIndex: Int)
    case unknownCategory(questionIndex: Int, categoryID: String)
    case duplicateCategory(questionIndex: Int, categoryID: String)
    case oversizedCategory(questionIndex: Int, categoryIndex: Int, bytes: Int)
    case oversizedImageName(questionIndex: Int, bytes: Int)
    case oversizedDescription(questionIndex: Int, bytes: Int)
}

/// Validates hardened wire payloads against the match content policy, the active round, and the
/// configured scoring rules.
///
/// Structural question rules come from `QuizQuestionStructureRules` so the engine never keeps a
/// second definition of answer count, answer-text normalization, correct-answer count, difficulty
/// bounds, or category membership. Everything this type adds on top is transport-specific: byte
/// bounds, the configured question count, and round/score legality.
enum MultiplayerPayloadValidator {
    static let maximumQuestionTextBytes = 4_096
    static let maximumAnswerTextBytes = 4_096
    static let maximumCategoriesPerQuestion = 8
    static let maximumCategoryBytes = 128
    static let maximumImageNameBytes = 256
    static let maximumDescriptionBytes = 8_192
    /// An absolute ceiling applied on top of the configured round timer so a variant with an
    /// implausible timer cannot admit an implausible response time.
    static let maximumResponseTimeMs = 3_600_000

    /// Sentinel answer indexes that are not positions in the answer list.
    static let timeoutAnswerIndex = -1
    static let skipAnswerIndex = -2
    static let lowestValidAnswerIndex = -2

    // MARK: - Game configuration

    /// Returns every reason `config` cannot be played under `configuration`, in question order.
    static func rejections(
        for config: GameConfigPayload,
        configuration: MultiplayerMatchConfiguration
    ) -> [MultiplayerConfigurationRejection] {
        var rejections: [MultiplayerConfigurationRejection] = []

        if config.questions.count != configuration.expectedQuestionCount {
            rejections.append(
                .questionCountMismatch(
                    expected: configuration.expectedQuestionCount,
                    actual: config.questions.count
                )
            )
        }

        var seenQuestionIDs = Set<Int>()
        for (questionIndex, question) in config.questions.enumerated() {
            if !seenQuestionIDs.insert(question.id).inserted {
                rejections.append(.duplicateQuestionID(questionIndex: questionIndex, id: question.id))
            }

            for issue in QuizQuestionStructureRules.issues(
                in: question,
                allowedCategoryIDs: configuration.allowedCategoryIDs
            ) {
                rejections.append(mapped(issue, questionIndex: questionIndex))
            }

            rejections.append(contentsOf: sizeRejections(for: question, questionIndex: questionIndex))
        }

        return rejections
    }

    private static func mapped(
        _ issue: QuizQuestionStructureIssue,
        questionIndex: Int
    ) -> MultiplayerConfigurationRejection {
        switch issue {
        case .nonPositiveID(let id):
            return .nonPositiveQuestionID(questionIndex: questionIndex, id: id)
        case .missingCategories:
            return .missingCategories(questionIndex: questionIndex)
        case .blankCategory(let categoryIndex, _):
            return .blankCategory(questionIndex: questionIndex, categoryIndex: categoryIndex)
        case .unknownCategory(_, let categoryID):
            return .unknownCategory(questionIndex: questionIndex, categoryID: categoryID)
        case .duplicateCategory(_, let categoryID):
            return .duplicateCategory(questionIndex: questionIndex, categoryID: categoryID)
        case .invalidAnswerCount(let count):
            return .invalidAnswerCount(questionIndex: questionIndex, count: count)
        case .blankAnswerText(let answerIndex, _):
            return .blankAnswerText(questionIndex: questionIndex, answerIndex: answerIndex)
        case .duplicateAnswerText(let answerIndex, _):
            return .duplicateAnswerText(questionIndex: questionIndex, answerIndex: answerIndex)
        case .invalidCorrectAnswerCount(let count):
            return .invalidCorrectAnswerCount(questionIndex: questionIndex, count: count)
        case .invalidDifficulty(let difficulty):
            return .invalidDifficulty(questionIndex: questionIndex, difficulty: difficulty)
        }
    }

    private static func sizeRejections(
        for question: Question,
        questionIndex: Int
    ) -> [MultiplayerConfigurationRejection] {
        var rejections: [MultiplayerConfigurationRejection] = []

        if QuizQuestionStructureRules.isBlank(question.question) {
            rejections.append(.blankQuestionText(questionIndex: questionIndex))
        } else if question.question.utf8.count > maximumQuestionTextBytes {
            rejections.append(
                .oversizedQuestionText(questionIndex: questionIndex, bytes: question.question.utf8.count)
            )
        }

        for (answerIndex, answer) in question.answers.enumerated()
        where answer.text.utf8.count > maximumAnswerTextBytes {
            rejections.append(
                .oversizedAnswerText(
                    questionIndex: questionIndex,
                    answerIndex: answerIndex,
                    bytes: answer.text.utf8.count
                )
            )
        }

        if question.categories.count > maximumCategoriesPerQuestion {
            rejections.append(
                .tooManyCategories(questionIndex: questionIndex, count: question.categories.count)
            )
        }

        for (categoryIndex, categoryID) in question.categories.enumerated()
        where categoryID.utf8.count > maximumCategoryBytes {
            rejections.append(
                .oversizedCategory(
                    questionIndex: questionIndex,
                    categoryIndex: categoryIndex,
                    bytes: categoryID.utf8.count
                )
            )
        }

        if let imageName = question.imageName, imageName.utf8.count > maximumImageNameBytes {
            rejections.append(
                .oversizedImageName(questionIndex: questionIndex, bytes: imageName.utf8.count)
            )
        }

        if let description = question.description, description.utf8.count > maximumDescriptionBytes {
            rejections.append(
                .oversizedDescription(questionIndex: questionIndex, bytes: description.utf8.count)
            )
        }

        return rejections
    }

    // MARK: - Round payloads

    /// The inclusive upper bound on a response time for the configured round timer.
    static func maximumResponseTime(for rules: QuizMultiplayerRules) -> Int {
        min(max(0, rules.timerDurationMilliseconds), maximumResponseTimeMs)
    }

    /// Whether `answer` can be an answer to `question` in the round the session is playing.
    ///
    /// The index is checked against the question's actual answer count rather than a fixed
    /// maximum, so a payload can never reference an answer the question does not offer.
    static func isValidAnswer(
        _ answer: AnswerPayload,
        activeRoundIndex: Int,
        question: Question,
        rules: QuizMultiplayerRules
    ) -> Bool {
        guard answer.questionIndex == activeRoundIndex else { return false }
        guard answer.answerIndex >= lowestValidAnswerIndex,
              answer.answerIndex < question.answers.count else { return false }
        return (0...maximumResponseTime(for: rules)).contains(answer.responseTimeMs)
    }

    /// Whether `result` can be the host's result for the active round.
    ///
    /// Awarded points must be a value the configured scoring rules can produce for the reported
    /// correctness and response times, and each running total must be the previous total plus the
    /// points awarded this round. A payload that skips, rewinds, or inflates a score is rejected.
    static func isValidQuestionResult(
        _ result: QuestionResultPayload,
        activeRoundIndex: Int,
        question: Question,
        previousHostScore: Int,
        previousGuestScore: Int,
        rules: QuizMultiplayerRules
    ) -> Bool {
        guard result.questionIndex == activeRoundIndex else { return false }
        guard result.correctAnswerIndex >= 0,
              result.correctAnswerIndex < question.answers.count else { return false }

        let responseTimeRange = 0...maximumResponseTime(for: rules)
        guard responseTimeRange.contains(result.hostResponseTimeMs),
              responseTimeRange.contains(result.guestResponseTimeMs) else { return false }

        let allowed = allowedPoints(for: result, rules: rules)
        guard allowed.host.contains(result.hostPointsAwarded),
              allowed.guest.contains(result.guestPointsAwarded) else { return false }

        guard let hostTotal = exactTotal(previousHostScore, result.hostPointsAwarded),
              let guestTotal = exactTotal(previousGuestScore, result.guestPointsAwarded),
              hostTotal == result.hostTotalScore,
              guestTotal == result.guestTotalScore else { return false }

        return true
    }

    /// Whether `payload` can end the match given the scores the session has committed.
    static func isValidGameEnd(
        _ payload: GameEndPayload,
        questionsCompleted: Int,
        hostScore: Int,
        guestScore: Int
    ) -> Bool {
        // A completed match must have played at least one round.
        guard payload.reason != .completed || questionsCompleted > 0 else { return false }
        // Once rounds have been committed, a terminal payload may not restate their outcome.
        guard questionsCompleted == 0 ||
                (payload.hostFinalScore == hostScore && payload.guestFinalScore == guestScore) else {
            return false
        }
        return true
    }

    /// The point values the configured rules can award for the correctness and timing reported in
    /// `result`.
    ///
    /// The wire does not carry whether a wrong answer was a deliberate skip or a timeout, so the
    /// allowed set is the union over both possibilities. When both players answered correctly the
    /// rules are fully determined and the set holds exactly one value per player.
    private static func allowedPoints(
        for result: QuestionResultPayload,
        rules: QuizMultiplayerRules
    ) -> (host: Set<Int>, guest: Set<Int>) {
        let answered = MultiplayerRuleEvaluator.points(
            hostCorrect: result.hostCorrect,
            guestCorrect: result.guestCorrect,
            hostMilliseconds: result.hostResponseTimeMs,
            guestMilliseconds: result.guestResponseTimeMs,
            hostSkipped: false,
            guestSkipped: false,
            rules: rules
        )
        let skipped = MultiplayerRuleEvaluator.points(
            hostCorrect: result.hostCorrect,
            guestCorrect: result.guestCorrect,
            hostMilliseconds: result.hostResponseTimeMs,
            guestMilliseconds: result.guestResponseTimeMs,
            hostSkipped: true,
            guestSkipped: true,
            rules: rules
        )
        return ([answered.host, skipped.host], [answered.guest, skipped.guest])
    }

    /// Score progression must be exact, so an overflowing total is never accepted.
    private static func exactTotal(_ previous: Int, _ awarded: Int) -> Int? {
        let (total, overflow) = previous.addingReportingOverflow(awarded)
        return overflow ? nil : total
    }
}
