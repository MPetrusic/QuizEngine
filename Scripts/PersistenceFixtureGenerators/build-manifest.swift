//
//  build-manifest.swift
//  Builds Tests/QuizEngineCoreTests/Resources/PersistenceFixtures/manifest.json.
//
//  Run indirectly:  sh Scripts/generate-persistence-fixtures.sh
//  Run directly:    swift Scripts/PersistenceFixtureGenerators/build-manifest.swift \
//                       <fixture-root> <observed-root>
//
//  The manifest is generated, never hand-edited. Hashes and byte counts are measured
//  from the committed files; the recorded nondefault values are what the originating
//  tag's own decoder read back out of the file it had just written; byte-equivalence
//  between releases is measured rather than assumed.
//

import CryptoKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("usage: build-manifest.swift <fixture-root> <observed-root>\n".utf8)
    )
    exit(2)
}

let fixtureRoot = URL(fileURLWithPath: arguments[1], isDirectory: true)
let observedRoot = URL(fileURLWithPath: arguments[2], isDirectory: true)
let packageRoot = fixtureRoot
    .deletingLastPathComponent() // Resources
    .deletingLastPathComponent() // QuizEngineCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // package root

let tags = ["v0.1.0", "v0.1.1", "v0.1.2", "v0.1.3", "v0.2.0"]

// MARK: - Shell

func git(_ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["git", "-C", packageRoot.path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
    } catch {
        FileHandle.standardError.write(Data("could not run git: \(error)\n".utf8))
        exit(2)
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("git \(arguments.joined(separator: " ")) failed\n".utf8))
        exit(2)
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Per-file provenance

struct FixtureDescription {
    let kind: String
    let producingType: String
    let producingCall: String
    let storagePath: String
    let envelope: String
    let expectedSchemaVersion: Int
    let expectedLoadStatus: String
    let howObtained: String
}

let legacyProgressStorage = "Documents/player_progress.plist"
let legacyPreferencesStorage = "Documents/user_preferences.plist"

let legacyGeneratorNote = """
Produced by Scripts/generate-persistence-fixtures.sh, which checks the exact tag out \
into a detached git worktree, copies \
Scripts/PersistenceFixtureGenerators/legacy-v0_1_x.swift into it as an executable \
target, and runs it with CFFIXED_USER_HOME pointed at a throwaway home directory and \
SWIFT_DETERMINISTIC_HASHING=1. Reproduce with: \
sh Scripts/generate-persistence-fixtures.sh <tag>
"""

let schema1GeneratorNote = """
Produced by Scripts/generate-persistence-fixtures.sh, which checks v0.2.0 out into a \
detached git worktree, copies \
Scripts/PersistenceFixtureGenerators/schema1-v0_2_0.swift into it as an executable \
target, and runs it with CFFIXED_USER_HOME pointed at a throwaway home directory and \
SWIFT_DETERMINISTIC_HASHING=1. Reproduce with: \
sh Scripts/generate-persistence-fixtures.sh v0.2.0
"""

func description(for fileName: String, tag: String) -> FixtureDescription {
    switch fileName {
    case "player_progress_default.plist":
        return FixtureDescription(
            kind: "playerProgress",
            producingType: "QuizEngineCore.PlayerProgressManager",
            producingCall: "PlayerProgressManager.save(), reached through addCoins(0)",
            storagePath: legacyProgressStorage,
            envelope: "none — a bare PropertyListEncoder document with no schemaVersion key",
            expectedSchemaVersion: 0,
            expectedLoadStatus: "loadedLegacy",
            howObtained: """
                \(legacyGeneratorNote)

                A \(tag) PlayerProgressManager was created against an empty isolated \
                directory, so it held PlayerProgress.default, and addCoins(0) triggered \
                the tag's own first save without changing any field. These bytes are \
                therefore exactly what a brand-new \(tag) install writes.
                """
        )
    case "player_progress_populated.plist":
        return FixtureDescription(
            kind: "playerProgress",
            producingType: "QuizEngineCore.PlayerProgressManager",
            producingCall: "PlayerProgressManager.save(), reached through public engine mutations",
            storagePath: legacyProgressStorage,
            envelope: "none — a bare PropertyListEncoder document with no schemaVersion key",
            expectedSchemaVersion: 0,
            expectedLoadStatus: "loadedLegacy",
            howObtained: """
                \(legacyGeneratorNote)

                An invented prior-session PlayerProgress was encoded with \(tag)'s own \
                model and PropertyListEncoder as a throwaway seed, decoded by \(tag)'s \
                own PlayerProgressManager, and then mutated through the tag's public, \
                clock-free API (addCoins, spendCoins, recordCorrectAnswer, \
                recordWrongAnswer, updateBestScore, recordQuestionSeen, \
                recordSessionStats, recordPowerUpUsed, recordMultiplayerResult, \
                unlockAchievement, markPremiumBonusCoinsReceived). The committed bytes \
                are the output of the tag's own save() after those operations. The seed \
                is not committed.
                """
        )
    case "user_preferences.plist":
        return FixtureDescription(
            kind: "userPreferences",
            producingType: "QuizEngineCore.UserPreferencesLoader",
            producingCall: "UserPreferencesLoader.write(preferences:)",
            storagePath: legacyPreferencesStorage,
            envelope: "none — a bare PropertyListEncoder document with no schemaVersion key",
            expectedSchemaVersion: 0,
            expectedLoadStatus: "decoded as a legacy document",
            howObtained: """
                \(legacyGeneratorNote)

                \(tag)'s UserPreferencesLoader.write(preferences:) resolves the \
                Documents directory internally and cannot take a URL before v0.1.3, so \
                the generator redirects the whole home directory with CFFIXED_USER_HOME \
                and lets the shipped code path write the file itself. v0.1.3 also offers \
                write(preferences:to:), but all four tags deliberately use the shared \
                no-URL overload so the fixtures compare like for like. hapticsEnabled: \
                false is the only nondefault value this model can express — the loader \
                returns true for a missing or undecodable document.
                """
        )
    case "player_progress_schema_1.plist":
        return FixtureDescription(
            kind: "playerProgress",
            producingType: "QuizEngineCore.PlayerProgressManager",
            producingCall: "PlayerProgressManager.importProgress(_:) then save()",
            storagePath: legacyProgressStorage,
            envelope: "schema-1 PersistenceEnvelope with schemaVersion and payload keys",
            expectedSchemaVersion: 1,
            expectedLoadStatus: "loaded(schemaVersion: 1)",
            howObtained: """
                \(schema1GeneratorNote)

                An invented prior state was written through the public transactional \
                import (PlayerProgressImportRequest / importProgress), then mutated \
                through v0.2.0's public API (addCoins, spendCoins, grantPowerUpCredits, \
                consumePowerUp, recordCorrectAnswer, recordWrongAnswer, updateBestScore, \
                recordQuestionSeen, recordSessionStats, \
                recordMultiplayerResult(matchID:fingerprint:...), unlockAchievement, \
                markPremiumBonusCoinsReceived) with an injected fixed clock and an \
                explicit UTC Gregorian calendar. The committed bytes are the primary \
                document left by v0.2.0's own writeAndVerify; the import marker and the \
                backup sibling are not committed.
                """
        )
    case "user_preferences_schema_1.plist":
        return FixtureDescription(
            kind: "userPreferences",
            producingType: "QuizEngineCore.UserPreferencesLoader",
            producingCall: "UserPreferencesLoader.write(preferences:to:) with an injected FileQuizEnginePersistenceStore",
            storagePath: legacyPreferencesStorage,
            envelope: "schema-1 PersistenceEnvelope with schemaVersion and payload keys",
            expectedSchemaVersion: 1,
            expectedLoadStatus: "decoded as schema 1",
            howObtained: """
                \(schema1GeneratorNote)

                Written through v0.2.0's public throwing injected-store overload so a \
                write failure could not be swallowed. This is the same envelope the \
                non-throwing URL overload produces.
                """
        )
    default:
        FileHandle.standardError.write(Data("unknown fixture file: \(fileName)\n".utf8))
        exit(2)
    }
}

// MARK: - Collect

struct Fixture {
    let tag: String
    let fileName: String
    let sha256: String
    let byteCount: Int
    let description: FixtureDescription
    let observed: Any
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

var fixtures: [Fixture] = []

for tag in tags {
    let observedURL = observedRoot.appendingPathComponent("\(tag).json")
    guard let observedData = try? Data(contentsOf: observedURL),
          let observed = try? JSONSerialization.jsonObject(with: observedData) as? [String: Any] else {
        FileHandle.standardError.write(
            Data(
                """
                missing observed values for \(tag) at \(observedURL.path).
                Run `sh Scripts/generate-persistence-fixtures.sh` with no arguments so \
                every tag is regenerated before the manifest is rebuilt.

                """.utf8
            )
        )
        exit(2)
    }

    for fileName in observed.keys.sorted() {
        let fileURL = fixtureRoot.appendingPathComponent(tag).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else {
            FileHandle.standardError.write(Data("missing fixture file \(fileURL.path)\n".utf8))
            exit(2)
        }
        fixtures.append(
            Fixture(
                tag: tag,
                fileName: fileName,
                sha256: sha256Hex(data),
                byteCount: data.count,
                description: description(for: fileName, tag: tag),
                observed: observed[fileName]!
            )
        )
    }
}

// Byte-equivalence between releases is measured, not assumed. Coverage is kept per
// release even when the bytes match, as QEB-03 requires.
var pathsByHash: [String: [String]] = [:]
for fixture in fixtures {
    pathsByHash[fixture.sha256, default: []].append("\(fixture.tag)/\(fixture.fileName)")
}

// MARK: - Emit

var entries: [[String: Any]] = []
for fixture in fixtures {
    let path = "\(fixture.tag)/\(fixture.fileName)"
    let identical = (pathsByHash[fixture.sha256] ?? []).filter { $0 != path }
    var entry: [String: Any] = [
        "path": path,
        "tag": fixture.tag,
        "commit": git(["rev-parse", "\(fixture.tag)^{commit}"]),
        "sha256": fixture.sha256,
        "byteCount": fixture.byteCount,
        "kind": fixture.description.kind,
        "producingType": fixture.description.producingType,
        "producingCall": fixture.description.producingCall,
        "storagePath": fixture.description.storagePath,
        "envelope": fixture.description.envelope,
        "expectedSchemaVersion": fixture.description.expectedSchemaVersion,
        "expectedLoadStatus": fixture.description.expectedLoadStatus,
        "howObtained": fixture.description.howObtained,
        "containsNoRealUserDataOrSecret": true,
        "identicalBytesWith": identical.sorted()
    ]
    switch fixture.description.kind {
    case "playerProgress":
        entry["expectedProgress"] = fixture.observed
    default:
        entry["expectedPreferences"] = fixture.observed
    }
    entries.append(entry)
}

let manifest: [String: Any] = [
    "manifestVersion": 1,
    "generator": "Scripts/generate-persistence-fixtures.sh",
    "manifestBuilder": "Scripts/PersistenceFixtureGenerators/build-manifest.swift",
    "regenerateCommand": "sh Scripts/generate-persistence-fixtures.sh",
    "notes": [
        "Every fixture was emitted by building and running its own release tag's source in a detached git worktree. Nothing here was synthesized with current models, PropertyListSerialization dictionaries, or hand-written property lists.",
        "Do not edit a fixture or this manifest by hand. Change the generator, rerun the regenerate command, and commit the new bytes and hashes together.",
        "expectedProgress and expectedPreferences record what the originating tag's own decoder read back out of the file it had just written. The migration tests assert those values through the current public load path.",
        "powerUpCredits and multiplayerMatchReceipts do not exist in the v0.1.x model. The values recorded for v0.1.x fixtures are the defaults the current package must apply on load.",
        "rewardReceipts and the Premium claimed version/fingerprint do not exist in any released fixture model. Reward receipts default to empty; a released true hasReceivedPremiumBonusCoins flag maps to the permanent legacy-unversioned claim identity so migration cannot re-award it.",
        "identicalBytesWith is measured from the committed bytes. Releases with identical documents keep separate fixtures anyway, so a future divergence is caught per release.",
        "Fixture content is invented test data. No fixture contains a real player, device, account, credential, or other secret."
    ],
    "fixtures": entries
]

let data = try JSONSerialization.data(
    withJSONObject: manifest,
    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
)
let manifestURL = fixtureRoot.appendingPathComponent("manifest.json")
try (data + Data("\n".utf8)).write(to: manifestURL)
print("    \(entries.count) fixtures described in \(manifestURL.path)")
