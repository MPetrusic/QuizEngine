//
//  UserPreferencesLoader.swift
//  QuizEngineCore
//
//  Created by Milos Petrusic on 15.7.23..
//

import Foundation

public class UserPreferencesLoader {
    static private var plistURL: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documents.appendingPathComponent("user_preferences.plist")
    }

    public static func load() -> UserPreferences {
        let decoder = PropertyListDecoder()

        guard let data = try? Data.init(contentsOf: plistURL),
              let preferences = try? decoder.decode(UserPreferences.self, from: data)
        else {
            return UserPreferences(hapticsEnabled: true)
        }

        return preferences
    }

    public static func write(preferences: UserPreferences) {
        let encoder = PropertyListEncoder()

        if let data = try? encoder.encode(preferences) {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try? data.write(to: plistURL)
            } else {
                FileManager.default.createFile(atPath: plistURL.path, contents: data, attributes: nil)
            }
        }
    }
}
