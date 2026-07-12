import Foundation

public struct QuizCategoryDefinition: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayNameKey: String
    public let iconName: String
    public let displayOrder: Int
    public let unlockRequirement: UnlockRequirement

    public init(
        id: String,
        displayNameKey: String,
        iconName: String,
        displayOrder: Int,
        unlockRequirement: UnlockRequirement
    ) {
        self.id = id.lowercased()
        self.displayNameKey = displayNameKey
        self.iconName = iconName
        self.displayOrder = displayOrder
        self.unlockRequirement = unlockRequirement
    }

    public var isFreeByDefault: Bool {
        if case .free = unlockRequirement { return true }
        return false
    }

    public var coinCost: Int? {
        unlockRequirement.coinCost
    }
}
