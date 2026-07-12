//
//  AchievementType.swift
//  QuizEngineCore
//
//  Created by Claude on 13.2.26..
//

import Foundation

/// Categories of achievements that can be unlocked
public enum AchievementType: String, Codable, CaseIterable, Hashable, Sendable {
    case score         // Single session score achievements
    case accuracy      // Consecutive correct answers
    case category      // Category completion
    case lifetime      // Cumulative lifetime stats
    case streak        // Daily streak milestones
    case powerUp       // Power-up usage achievements
    case special       // Unique/special achievements

    public var displayNameKey: String {
        switch self {
        case .score: return "achievement_type.score"
        case .accuracy: return "achievement_type.accuracy"
        case .category: return "achievement_type.category"
        case .lifetime: return "achievement_type.lifetime"
        case .streak: return "achievement_type.streak"
        case .powerUp: return "achievement_type.power_up"
        case .special: return "achievement_type.special"
        }
    }

    /// Default SF Symbol icon name for the achievement type
    public var iconName: String {
        switch self {
        case .score:
            return "star.fill"
        case .accuracy:
            return "target"
        case .category:
            return "checkmark.circle.fill"
        case .lifetime:
            return "infinity"
        case .streak:
            return "flame.fill"
        case .powerUp:
            return "bolt.fill"
        case .special:
            return "sparkles"
        }
    }
}
