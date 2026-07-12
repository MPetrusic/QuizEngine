import Foundation

public indirect enum UnlockRequirement: Hashable, Sendable {
    case free
    case questionsCorrect(count: Int)
    case categoryCompletion(categoryID: String, percentage: Double)
    case coins(amount: Int)
    case anyOf([UnlockRequirement])

    public var coinCost: Int? {
        switch self {
        case .coins(let amount):
            return amount
        case .anyOf(let options):
            return options.lazy.compactMap(\.coinCost).first
        default:
            return nil
        }
    }
}

public struct UnlockProgress: Sendable {
    public let isUnlocked: Bool
    public let requirementDescription: String
    public let requirementValue: Int?
    public let currentValue: Int
    public let targetValue: Int
    public let coinCost: Int?

    public init(
        isUnlocked: Bool,
        requirementDescription: String,
        requirementValue: Int? = nil,
        currentValue: Int,
        targetValue: Int,
        coinCost: Int?
    ) {
        self.isUnlocked = isUnlocked
        self.requirementDescription = requirementDescription
        self.requirementValue = requirementValue
        self.currentValue = currentValue
        self.targetValue = targetValue
        self.coinCost = coinCost
    }

    public var progressPercentage: Double {
        guard targetValue > 0 else { return isUnlocked ? 1 : 0 }
        return min(1, Double(currentValue) / Double(targetValue))
    }

    public var progressText: String { "\(currentValue)/\(targetValue)" }

    public static func unlocked() -> UnlockProgress {
        UnlockProgress(
            isUnlocked: true,
            requirementDescription: "",
            currentValue: 0,
            targetValue: 0,
            coinCost: nil
        )
    }

    public static func free() -> UnlockProgress {
        UnlockProgress(
            isUnlocked: true,
            requirementDescription: "category_unlock_requirement.description.free",
            currentValue: 0,
            targetValue: 0,
            coinCost: nil
        )
    }
}
