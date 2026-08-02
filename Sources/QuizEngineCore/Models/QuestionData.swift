//
//  QuestionData.swift
//  QuizEngineCore
//
//  Created by Milos Petrusic on 3.12.22..
//

import Foundation

public struct QuestionData: Codable, Sendable {
    public var questions: [Question]

    public init(questions: [Question]) {
        self.questions = questions
    }
}

public struct Question: Identifiable, Codable, Hashable, Sendable {
    public var id: Int
    public var question: String
    public var answers: [Answer]
    public var imageName: String?
    public var description: String?
    public var categories: [String]
    public var difficulty: Int

    // Coding keys to handle both old and new JSON formats
    public enum CodingKeys: String, CodingKey {
        case id
        case question
        case answers
        case imageName
        case description
        case categories
        case category  // Old format support
        case difficulty
    }

    // Custom decoder to handle backward compatibility with old questions.json
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        question = try container.decode(String.self, forKey: .question)
        answers = try container.decode([Answer].self, forKey: .answers)
        imageName = try container.decodeIfPresent(String.self, forKey: .imageName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        difficulty = try container.decodeIfPresent(Int.self, forKey: .difficulty) ?? 1

        // Handle both old single category and new multiple categories
        if let categoriesArray = try? container.decodeIfPresent([String].self, forKey: .categories) {
            categories = categoriesArray
        } else if let singleCategory = try? container.decodeIfPresent(String.self, forKey: .category) {
            categories = [singleCategory]
        } else {
            categories = []
        }
    }

    // Custom encoder to always save as categories array
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(question, forKey: .question)
        try container.encode(answers, forKey: .answers)
        try container.encodeIfPresent(imageName, forKey: .imageName)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(categories, forKey: .categories)
        try container.encode(difficulty, forKey: .difficulty)
    }

    // Standard initializer for creating questions in code
    public init(id: Int = 0, question: String, answers: [Answer], imageName: String? = nil, description: String? = nil, categories: [String] = [], difficulty: Int = 1) {
        self.id = id
        self.question = question
        self.answers = answers
        self.imageName = imageName
        self.description = description
        self.categories = categories
        self.difficulty = difficulty
    }

    // Convenience initializer for single category (backward compatibility)
    public init(id: Int = 0, question: String, answers: [Answer], imageName: String? = nil, description: String? = nil, category: String, difficulty: Int = 1) {
        self.init(id: id, question: question, answers: answers, imageName: imageName, description: description, categories: [category], difficulty: difficulty)
    }

    public var getAnswersShuffled: [Answer] {
        var randomNumberGenerator = SystemRandomNumberGenerator()
        return answers.shuffled(using: &randomNumberGenerator)
    }

    public func getAnswersShuffled<R: RandomNumberGenerator>(using randomNumberGenerator: inout R) -> [Answer] {
        answers.shuffled(using: &randomNumberGenerator)
    }

    public func getDecription() -> String {
        return description ?? ""
    }

}

public struct Answer: Hashable, Codable, Sendable {
    public var text: String
    public var correct: Bool

    public init(text: String, correct: Bool) {
        self.text = text
        self.correct = correct
    }
}

// MARK: - Question Pack Model

/// Represents a themed collection of questions
public struct QuestionPack: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var description: String
    public var iconName: String
    public var primaryCategory: String  // Main category for organization
    public var questionCount: Int
    public var isPremium: Bool
    public var unlockCost: Int?

    public init(id: String, name: String, description: String, iconName: String, primaryCategory: String, questionCount: Int, isPremium: Bool = false, unlockCost: Int? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.iconName = iconName
        self.primaryCategory = primaryCategory
        self.questionCount = questionCount
        self.isPremium = isPremium
        self.unlockCost = unlockCost
    }

}
