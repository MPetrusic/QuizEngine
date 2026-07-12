//
//  UserPreferences.swift
//  QuizEngineCore
//
//  Created by Milos Petrusic on 15.7.23..
//

import Foundation

public struct UserPreferences: Codable {
    public var hapticsEnabled: Bool

    public init(hapticsEnabled: Bool) {
        self.hapticsEnabled = hapticsEnabled
    }
}
