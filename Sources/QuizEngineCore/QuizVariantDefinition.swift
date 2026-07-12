import Foundation

public struct QuestionResource {
    public let bundle: Bundle
    public let fileName: String

    public init(bundle: Bundle, fileName: String) {
        self.bundle = bundle
        self.fileName = fileName
    }
}

public struct QuizVariantDefinition {
    public let categories: [QuizCategoryDefinition]
    public let achievements: [AchievementDefinition]
    public let questionResource: QuestionResource

    public init(
        categories: [QuizCategoryDefinition],
        achievements: [AchievementDefinition],
        questionResource: QuestionResource
    ) {
        precondition(Set(categories.map(\.id)).count == categories.count, "Category IDs must be unique")
        precondition(Set(achievements.map(\.id)).count == achievements.count, "Achievement IDs must be unique")
        self.categories = categories.sorted { $0.displayOrder < $1.displayOrder }
        self.achievements = achievements
        self.questionResource = questionResource
    }

    public func category(id: String) -> QuizCategoryDefinition? {
        categories.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }
}
