import Foundation

public struct CategoryItem: Identifiable {
    public let id: String
    public let displayName: String
    public let iconName: String
    public let questionCount: Int
    public let isPremium: Bool
    public let unlockCost: Int?
    public var seenCount: Int
    public var isLocked: Bool
    public var unlockProgress: UnlockProgress?

    public init(
        id: String,
        displayName: String,
        iconName: String,
        questionCount: Int,
        isPremium: Bool,
        unlockCost: Int?,
        seenCount: Int = 0,
        isLocked: Bool = false,
        unlockProgress: UnlockProgress? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.iconName = iconName
        self.questionCount = questionCount
        self.isPremium = isPremium
        self.unlockCost = unlockCost
        self.seenCount = seenCount
        self.isLocked = isLocked
        self.unlockProgress = unlockProgress
    }

    public var isAllCategories: Bool { id == "all" }

    public static func allCategories(
        displayName: String,
        totalCount: Int,
        seenCount: Int = 0
    ) -> CategoryItem {
        CategoryItem(
            id: "all",
            displayName: displayName,
            iconName: "square.grid.3x3.fill",
            questionCount: totalCount,
            isPremium: false,
            unlockCost: nil,
            seenCount: seenCount
        )
    }

    public static func category(
        definition: QuizCategoryDefinition,
        displayName: String,
        questionCount: Int,
        seenCount: Int = 0,
        isLocked: Bool = false,
        unlockProgress: UnlockProgress? = nil
    ) -> CategoryItem {
        CategoryItem(
            id: definition.id,
            displayName: displayName,
            iconName: definition.iconName,
            questionCount: questionCount,
            isPremium: isLocked,
            unlockCost: unlockProgress?.coinCost,
            seenCount: seenCount,
            isLocked: isLocked,
            unlockProgress: unlockProgress
        )
    }
}
