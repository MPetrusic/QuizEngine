import Foundation

@MainActor
public final class AchievementService {
    public let definitions: [AchievementDefinition]

    public init(definitions: [AchievementDefinition]) {
        self.definitions = definitions
    }

    public func checkAchievements(
        progress: PlayerProgress,
        date: Date = Date(),
        calendar: Calendar = .current
    ) -> [AchievementDefinition] {
        definitions.filter {
            !progress.unlockedAchievements.contains($0.id)
                && isSatisfied($0.rule, progress: progress, date: date, calendar: calendar)
        }
    }

    public func getProgress(
        for achievement: AchievementDefinition,
        progress: PlayerProgress
    ) -> (current: Int, target: Int)? {
        switch achievement.rule {
        case .playStreak(let minimum):
            return (progress.currentPlayStreak, minimum)
        case .bestScore(let minimum):
            return (progress.bestSingleSessionScore, minimum)
        case .bestAnswerStreak(let minimum):
            return (progress.bestSingleSessionStreak, minimum)
        case .anyCategoryCorrect(let minimum):
            return (bestCategoryCorrectCount(progress), minimum)
        case .categoryCorrect(let categoryID, let minimum):
            return (correctCount(categoryID, progress), minimum)
        case .categoriesCorrect(let categoryCount, let minimumPerCategory):
            return (categoriesMeeting(minimumPerCategory, progress).count, categoryCount)
        case .lifetimeGames(let minimum):
            return (progress.lifetimeGamesPlayed, minimum)
        case .lifetimeQuestions(let minimum):
            return (progress.lifetimeQuestionsAnswered, minimum)
        case .totalCoinsEarned(let minimum):
            return (progress.totalCoinsEarned, minimum)
        case .powerUpTypesUsed(let minimum):
            return (progress.powerUpTypesUsed.count, minimum)
        case .lifetimePowerUpsUsed(let minimum):
            return (progress.lifetimePowerUpsUsed ?? 0, minimum)
        case .comeback, .localHour:
            return nil
        }
    }

    private func isSatisfied(
        _ rule: AchievementRule,
        progress: PlayerProgress,
        date: Date,
        calendar: Calendar
    ) -> Bool {
        switch rule {
        case .playStreak(let minimum):
            return progress.longestPlayStreak >= minimum
        case .bestScore(let minimum):
            return progress.bestSingleSessionScore >= minimum
        case .bestAnswerStreak(let minimum):
            return progress.bestSingleSessionStreak >= minimum
        case .anyCategoryCorrect(let minimum):
            return bestCategoryCorrectCount(progress) >= minimum
        case .categoryCorrect(let categoryID, let minimum):
            return correctCount(categoryID, progress) >= minimum
        case .categoriesCorrect(let categoryCount, let minimumPerCategory):
            return categoriesMeeting(minimumPerCategory, progress).count >= categoryCount
        case .lifetimeGames(let minimum):
            return progress.lifetimeGamesPlayed >= minimum
        case .lifetimeQuestions(let minimum):
            return progress.lifetimeQuestionsAnswered >= minimum
        case .totalCoinsEarned(let minimum):
            return progress.totalCoinsEarned >= minimum
        case .powerUpTypesUsed(let minimum):
            return progress.powerUpTypesUsed.count >= minimum
        case .lifetimePowerUpsUsed(let minimum):
            return (progress.lifetimePowerUpsUsed ?? 0) >= minimum
        case .comeback(let minimumDaysAway):
            guard let previousOpen = progress.previousAppOpenDate else { return false }
            let days = calendar.dateComponents([.day], from: previousOpen, to: date).day ?? 0
            return days >= minimumDaysAway
        case .localHour(let start, let end):
            let hour = calendar.component(.hour, from: date)
            return hour >= start && hour < end
        }
    }

    private func correctCount(_ categoryID: String, _ progress: PlayerProgress) -> Int {
        progress.categoryStats[categoryID]?.correctlyAnsweredIDs.count ?? 0
    }

    private func bestCategoryCorrectCount(_ progress: PlayerProgress) -> Int {
        progress.categoryStats.values.map { $0.correctlyAnsweredIDs.count }.max() ?? 0
    }

    private func categoriesMeeting(_ minimum: Int, _ progress: PlayerProgress) -> [String] {
        progress.categoryStats.compactMap { id, stat in
            stat.correctlyAnsweredIDs.count >= minimum ? id : nil
        }
    }
}
