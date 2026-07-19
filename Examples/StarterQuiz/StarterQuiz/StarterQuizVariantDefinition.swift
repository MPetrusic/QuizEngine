import Foundation
import QuizEngineCore

enum StarterQuizVariantDefinition {
    static let categories: [QuizCategoryDefinition] = [
        .init(
            id: "space",
            displayNameKey: "quiz.category.space",
            iconName: "sparkles",
            displayOrder: 0,
            unlockRequirement: .free
        ),
        .init(
            id: "nature",
            displayNameKey: "quiz.category.nature",
            iconName: "leaf.fill",
            displayOrder: 1,
            unlockRequirement: .questionsCorrect(count: 2)
        )
    ]

    static let achievements: [AchievementDefinition] = [
        .init(
            id: "first_game",
            type: .special,
            coinReward: 5,
            rule: .lifetimeGames(minimum: 1)
        ),
        .init(
            id: "space_expert",
            type: .category,
            coinReward: 10,
            rule: .categoryCorrect(categoryID: "space", minimum: 3)
        )
    ]

    static let variant: QuizVariantDefinition = {
        do {
            return try QuizVariantDefinition(
                categories: categories,
                achievements: achievements,
                questionResource: .init(bundle: .main, fileName: StarterQuizContent.questionsFileName)
            )
        } catch {
            fatalError("Invalid StarterQuiz variant: \(error.localizedDescription)")
        }
    }()
}
