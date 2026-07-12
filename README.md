# QuizEngine

Reusable iOS 17 quiz logic. Apps own their SwiftUI views, design, questions, localization, Firebase, ads, StoreKit, Game Center configuration, and SDK adapters.

## Products

- `QuizEngineCore`: models, progress, persistence, question loading, categories, achievements, and provider protocols.
- `QuizEngineGame`: single-player and practice game state.
- `QuizEngineMultiplayer`: optional nearby and Game Center multiplayer.

## App setup

1. Define a `QuizVariantDefinition` containing category definitions, achievement definitions, and a `QuestionResource` with an explicit bundle and JSON filename.
2. Create one `QuestionDataService` from that resource and inject it with the variant into `PlayerProgressManager`.
3. Inject app-owned analytics, ads, purchases, leaderboard, and haptic providers where required.
4. Link `QuizEngineMultiplayer` only when needed. Pass the app's Bonjour service type when creating nearby transport.
5. Provide localized values for the keys carried by category/achievement definitions and the engine keys used by power-ups and multiplayer errors.

Question JSON uses a top-level `questions` array. Each question requires stable integer `id`, `question`, `answers`, and `categories` identifiers. Category and achievement IDs are persistence contracts: never rename them after release without a migration.

## App capability checklist

Vendor integrations stay in the app. Configure its Firebase plist, AdMob application/unit IDs, StoreKit products, Game Center leaderboards, entitlements, Local Network usage description, Bonjour service declarations, privacy strings, and app-specific tests independently.

## Verification

Run:

```sh
Scripts/validate-package-boundaries.sh
swift test -Xswiftc -target -Xswiftc arm64-apple-macosx14.0
```

The explicit macOS target is only a host for the test process; the package's supported product platform is iOS 17.
