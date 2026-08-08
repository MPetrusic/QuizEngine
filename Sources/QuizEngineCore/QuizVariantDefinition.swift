import Foundation

public enum QuizVariantValidationError: Error, Equatable, Sendable, LocalizedError {
    case invalidCategoryID(String)
    case duplicateCategoryID(String)
    case duplicateCategoryDisplayOrder(Int)
    case invalidAchievementID(String)
    case duplicateAchievementID(String)
    case missingLocalizationKey(String)
    case missingIconName(String)
    case invalidQuestionFileName
    case invalidUnlockRequirement(String)
    case invalidAchievementRule(String)

    public var errorDescription: String? {
        switch self {
        case .invalidCategoryID(let id): return "Category ID must be a non-empty lowercase identifier: \(id)"
        case .duplicateCategoryID(let id): return "Duplicate category ID: \(id)"
        case .duplicateCategoryDisplayOrder(let order): return "Duplicate category display order: \(order)"
        case .invalidAchievementID(let id): return "Achievement ID must be a non-empty lowercase identifier: \(id)"
        case .duplicateAchievementID(let id): return "Duplicate achievement ID: \(id)"
        case .missingLocalizationKey(let key): return "Missing localization key for \(key)"
        case .missingIconName(let id): return "Missing icon name for \(id)"
        case .invalidQuestionFileName: return "Question resource filename must not be empty"
        case .invalidUnlockRequirement(let message): return "Invalid unlock requirement: \(message)"
        case .invalidAchievementRule(let message): return "Invalid achievement rule: \(message)"
        }
    }
}

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
    public let rules: QuizRulesConfiguration

    public init(
        categories: [QuizCategoryDefinition],
        achievements: [AchievementDefinition],
        questionResource: QuestionResource
    ) throws {
        try self.init(
            categories: categories,
            achievements: achievements,
            questionResource: questionResource,
            rules: .serbianCompatible
        )
    }

    public init(
        categories: [QuizCategoryDefinition],
        achievements: [AchievementDefinition],
        questionResource: QuestionResource,
        rules: QuizRulesConfiguration
    ) throws {
        try Self.validate(
            categories: categories,
            achievements: achievements,
            questionResource: questionResource
        )
        self.categories = categories.sorted { $0.displayOrder < $1.displayOrder }
        self.achievements = achievements
        self.questionResource = questionResource
        self.rules = rules
    }

    public func category(id: String) -> QuizCategoryDefinition? {
        categories.first { $0.id == id.lowercased() }
    }

    private static func validate(
        categories: [QuizCategoryDefinition],
        achievements: [AchievementDefinition],
        questionResource: QuestionResource
    ) throws {
        guard !questionResource.fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuizVariantValidationError.invalidQuestionFileName
        }

        var categoryIDs = Set<String>()
        var displayOrders = Set<Int>()
        for category in categories {
            guard isCanonicalIdentifier(category.id) else {
                throw QuizVariantValidationError.invalidCategoryID(category.id)
            }
            guard categoryIDs.insert(category.id).inserted else {
                throw QuizVariantValidationError.duplicateCategoryID(category.id)
            }
            guard displayOrders.insert(category.displayOrder).inserted else {
                throw QuizVariantValidationError.duplicateCategoryDisplayOrder(category.displayOrder)
            }
            try validateLocalizationAndIcon(
                nameKey: category.displayNameKey,
                iconName: category.iconName,
                identifier: category.id
            )
        }

        for category in categories {
            try validate(category.unlockRequirement, categoryIDs: categoryIDs)
        }

        var achievementIDs = Set<String>()
        for achievement in achievements {
            guard isCanonicalIdentifier(achievement.id) else {
                throw QuizVariantValidationError.invalidAchievementID(achievement.id)
            }
            guard achievementIDs.insert(achievement.id).inserted else {
                throw QuizVariantValidationError.duplicateAchievementID(achievement.id)
            }
            guard achievement.coinReward >= 0 else {
                throw QuizVariantValidationError.invalidAchievementRule("negative reward for \(achievement.id)")
            }
            try validateLocalizationAndIcon(
                nameKey: achievement.nameKey,
                descriptionKey: achievement.descriptionKey,
                iconName: achievement.iconName,
                identifier: achievement.id
            )
            try validate(achievement.rule, categoryIDs: categoryIDs)
        }
    }

    private static func validateLocalizationAndIcon(
        nameKey: String,
        descriptionKey: String? = nil,
        iconName: String,
        identifier: String
    ) throws {
        guard !nameKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuizVariantValidationError.missingLocalizationKey(identifier)
        }
        if let descriptionKey,
           descriptionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw QuizVariantValidationError.missingLocalizationKey(identifier)
        }
        guard !iconName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuizVariantValidationError.missingIconName(identifier)
        }
    }

    private static func validate(
        _ requirement: UnlockRequirement,
        categoryIDs: Set<String>
    ) throws {
        switch requirement {
        case .free:
            return
        case .questionsCorrect(let count):
            guard count > 0 else { throw QuizVariantValidationError.invalidUnlockRequirement("questionsCorrect must be positive") }
        case .categoryCompletion(let categoryID, let percentage):
            guard categoryIDs.contains(categoryID), (1...100).contains(percentage) else {
                throw QuizVariantValidationError.invalidUnlockRequirement("unknown category or percentage outside 1...100")
            }
        case .coins(let amount):
            guard amount > 0 else { throw QuizVariantValidationError.invalidUnlockRequirement("coin amount must be positive") }
        case .anyOf(let options):
            guard !options.isEmpty else { throw QuizVariantValidationError.invalidUnlockRequirement("anyOf must not be empty") }
            for option in options {
                try validate(option, categoryIDs: categoryIDs)
            }
        }
    }

    private static func validate(
        _ rule: AchievementRule,
        categoryIDs: Set<String>
    ) throws {
        switch rule {
        case .playStreak(let minimum), .bestScore(let minimum), .bestAnswerStreak(let minimum),
                .anyCategoryCorrect(let minimum), .lifetimeGames(let minimum),
                .lifetimeQuestions(let minimum), .totalCoinsEarned(let minimum),
                .powerUpTypesUsed(let minimum), .lifetimePowerUpsUsed(let minimum):
            guard minimum > 0 else { throw QuizVariantValidationError.invalidAchievementRule("minimum must be positive") }
        case .categoryCorrect(let categoryID, let minimum):
            guard categoryIDs.contains(categoryID), minimum > 0 else {
                throw QuizVariantValidationError.invalidAchievementRule("unknown category or non-positive minimum")
            }
        case .categoriesCorrect(let categoryCount, let minimumPerCategory):
            guard (1...categoryIDs.count).contains(categoryCount), minimumPerCategory > 0 else {
                throw QuizVariantValidationError.invalidAchievementRule("invalid category count or non-positive minimum")
            }
        case .comeback(let minimumDaysAway):
            guard minimumDaysAway > 0 else { throw QuizVariantValidationError.invalidAchievementRule("comeback days must be positive") }
        case .localHour(let start, let end):
            guard (0..<24).contains(start), (1...24).contains(end), start < end else {
                throw QuizVariantValidationError.invalidAchievementRule("hour range must be within 0..<24 and increasing")
            }
        }
    }

    private static func isCanonicalIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value == value.lowercased() && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
