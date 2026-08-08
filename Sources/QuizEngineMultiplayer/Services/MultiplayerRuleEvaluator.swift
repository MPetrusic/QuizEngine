import Foundation
import QuizEngineCore

enum MultiplayerRuleEvaluator {
    static func points(
        hostCorrect: Bool,
        guestCorrect: Bool,
        hostMilliseconds: Int,
        guestMilliseconds: Int,
        hostSkipped: Bool,
        guestSkipped: Bool,
        rules: QuizMultiplayerRules
    ) -> (host: Int, guest: Int) {
        if hostCorrect, guestCorrect {
            let difference = abs(hostMilliseconds - guestMilliseconds)
            if difference < rules.tieThresholdMilliseconds {
                return (rules.scoring.tiedCorrectPoints, rules.scoring.tiedCorrectPoints)
            }
            if hostMilliseconds < guestMilliseconds {
                return (rules.scoring.fasterCorrectPoints, rules.scoring.slowerCorrectPoints)
            }
            return (rules.scoring.slowerCorrectPoints, rules.scoring.fasterCorrectPoints)
        }

        return (
            pointsForSingleAnswer(correct: hostCorrect, skipped: hostSkipped, rules: rules.scoring),
            pointsForSingleAnswer(correct: guestCorrect, skipped: guestSkipped, rules: rules.scoring)
        )
    }

    static func correctAnswerCoins(
        correctAnswers: Int,
        questionsCompleted: Int,
        rules: QuizMultiplayerRewardRules
    ) -> Int {
        guard questionsCompleted >= rules.minimumQuestionsForAnyReward else { return 0 }
        return saturatingMultiply(correctAnswers, rules.correctAnswerCoins)
    }

    static func totalCoins(
        correctAnswers: Int,
        questionsCompleted: Int,
        result: MultiplayerGameResult?,
        isPremium: Bool,
        rules: QuizMultiplayerRewardRules
    ) -> Int {
        guard questionsCompleted >= rules.minimumQuestionsForAnyReward else { return 0 }
        let answerCoins = correctAnswerCoins(
            correctAnswers: correctAnswers,
            questionsCompleted: questionsCompleted,
            rules: rules
        )
        guard questionsCompleted >= rules.minimumQuestionsForOutcomeBonus else { return answerCoins }

        let rewards = isPremium ? rules.premiumOutcomeRewards : rules.standardOutcomeRewards
        let fullBonus: Int
        switch result {
        case .won: fullBonus = rewards.win
        case .lost: fullBonus = rewards.loss
        case .draw: fullBonus = rewards.draw
        case .opponentDisconnected: fullBonus = rewards.opponentDisconnected
        case .none: fullBonus = 0
        }
        let bonus = questionsCompleted >= rules.questionsForFullOutcomeBonus
            ? fullBonus
            : fullBonus / rules.partialRewardDivisor
        return saturatingAdd(answerCoins, bonus)
    }

    private static func pointsForSingleAnswer(
        correct: Bool,
        skipped: Bool,
        rules: QuizMultiplayerScoringRules
    ) -> Int {
        if correct { return rules.fasterCorrectPoints }
        if skipped { return 0 }
        return rules.wrongAnswerPoints
    }

    private static func saturatingAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return result }
        return rhs >= 0 ? Int.max : Int.min
    }

    private static func saturatingMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard overflow else { return result }
        return (lhs >= 0) == (rhs >= 0) ? Int.max : Int.min
    }
}
