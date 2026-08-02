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

    public static func load(from url: URL? = nil) -> UserPreferences {
        let decoder = PropertyListDecoder()
        let sourceURL = url ?? plistURL

        guard let data = try? Data(contentsOf: sourceURL),
              let preferences = try? decoder.decode(UserPreferences.self, from: data)
        else {
            return UserPreferences(hapticsEnabled: true)
        }

        return preferences
    }

    public static func write(preferences: UserPreferences, to url: URL? = nil) {
        let encoder = PropertyListEncoder()
        let destinationURL = url ?? plistURL

        if let data = try? encoder.encode(preferences) {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? data.write(to: destinationURL)
            } else {
                FileManager.default.createFile(atPath: destinationURL.path, contents: data, attributes: nil)
            }
        }
    }
}
