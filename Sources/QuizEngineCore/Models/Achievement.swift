import Foundation

public enum AchievementRule: Hashable, Sendable {
    case playStreak(minimum: Int)
    case bestScore(minimum: Int)
    case bestAnswerStreak(minimum: Int)
    case anyCategoryCorrect(minimum: Int)
    case categoryCorrect(categoryID: String, minimum: Int)
    case categoriesCorrect(categoryCount: Int, minimumPerCategory: Int)
    case lifetimeGames(minimum: Int)
    case lifetimeQuestions(minimum: Int)
    case totalCoinsEarned(minimum: Int)
    case powerUpTypesUsed(minimum: Int)
    case lifetimePowerUpsUsed(minimum: Int)
    case comeback(minimumDaysAway: Int)
    case localHour(startInclusive: Int, endExclusive: Int)
}

public struct AchievementDefinition: Identifiable, Hashable, Sendable {
    public let id: String
    public let nameKey: String
    public let descriptionKey: String
    public let iconName: String
    public let type: AchievementType
    public let coinReward: Int
    public let rule: AchievementRule
    public var isUnlocked: Bool
    public var unlockedDate: Date?

    public init(
        id: String,
        nameKey: String? = nil,
        descriptionKey: String? = nil,
        iconName: String = "",
        type: AchievementType,
        coinReward: Int,
        rule: AchievementRule,
        isUnlocked: Bool = false,
        unlockedDate: Date? = nil
    ) {
        self.id = id
        self.nameKey = nameKey ?? "achievement.\(id).name"
        self.descriptionKey = descriptionKey ?? "achievement.\(id).description"
        self.iconName = iconName.isEmpty ? type.iconName : iconName
        self.type = type
        self.coinReward = coinReward
        self.rule = rule
        self.isUnlocked = isUnlocked
        self.unlockedDate = unlockedDate
    }

    public func unlock(at date: Date = Date()) -> AchievementDefinition {
        var copy = self
        copy.isUnlocked = true
        copy.unlockedDate = date
        return copy
    }
}

public typealias Achievement = AchievementDefinition
