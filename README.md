# QuizEngine

Reusable iOS 17 quiz rules and state. It is not a complete app or a UI kit.

## Start here

Use the smallest product set your app needs:

| Product | Use it for |
| --- | --- |
| `QuizEngineCore` | questions, progress, categories, unlocks, achievements, persistence, provider protocols |
| `QuizEngineGame` | single-player and practice game state |
| `QuizEngineMultiplayer` | optional vendor-neutral multiplayer state and wire protocol |

Add the public package at the exact validated release:

```swift
.package(url: "https://github.com/MPetrusic/QuizEngine.git", exact: "0.2.1")
```

No repository credentials are required. Pin an exact release tag; do not use a moving branch as a production dependency.

**Do not pin `0.2.0`.** It carries a multiplayer defect that loses coins, statistics, and the match receipt when a terminal result fails to save. `0.2.1` is the remediation; see the [changelog](CHANGELOG.md).

Open [StarterQuiz](Examples/StarterQuiz/README.md) for a minimal runnable iOS app. Its [setup checklist](Docs/persistence-upgrades-troubleshooting.md#from-starterquiz-to-your-app) is the intended first integration path.

## Ownership boundary

| QuizEngine owns | Your app owns |
| --- | --- |
| quiz rules, scoring, game state, progress, unlock evaluation, achievement evaluation, persistence format, structural question validation | questions, localizations, views, theme, images, icons, asset-catalog checks, editorial checks, analytics, ads, purchases, leaderboards, entitlements, SDK setup, multiplayer transports |

Firebase, Google Mobile Ads, StoreKit, Game Center, MultipeerConnectivity, their IDs, and their capabilities do not belong in this package.

Persistence is owned by `QuizEngineCore`. New writes use a versioned schema-1 envelope, atomic sibling-file replacement, a backup, and read-back verification. Existing unversioned progress and preference plists remain readable as legacy schema 0. Use the throwing store-based APIs when the app must present typed corruption, storage, or recovery failures; the existing URL-based APIs remain source-compatible, with manager failures exposed through persistence status.

`PlayerProgress` also persists free credits independently for every `PowerUp`. `PlayerProgressManager.consumePowerUp(_:)` uses a free credit before the existing coin cost, records usage in the same durable transaction, and returns a `PowerUpSpendResult` for UI and analytics. A failed write rolls back the credit or coin deduction and the usage counters.

Reusable gameplay and economy policy is owned by the variant through a validated `QuizRulesConfiguration`. `.serbianCompatible` preserves released defaults; another app can select different timers, scoring, session sizes, costs, rewards, ad-eligibility inputs, and multiplayer thresholds without forking engine code.

## Required composition

1. Create one validated `QuizVariantDefinition` with your categories, achievements, explicit `QuestionResource`, and rules.
2. Create exactly one `QuestionDataService` from that variant.
3. Pass that same service and variant to `PlayerProgressManager`; build game sessions from the same service.
4. Keep category IDs, achievement IDs, and question IDs stable after release.
5. Add app-owned adapters only for integrations your app actually uses.

## Content validation

Validate decoded content in consumer CI before building a session or shipping a content update. The validator is pure and reports every structural issue in deterministic order; it does not inspect bundles, images, or editorial metadata.

```swift
let content = try QuestionDataService(variant: variant).getQuestionData()
let validation = QuizContentValidator.validate(content, categories: variant.categories)
precondition(validation.isValid, "Invalid quiz content: \(validation.issues)")
```

The package validates positive unique IDs, declared categories, four non-empty distinct answers, one correct answer, and difficulty `1...3`. Consumers must separately validate image names against their asset catalog, editorial approval, sources, content distribution, and any app-specific metadata. Once released, question IDs are persistent migration identifiers: never renumber or reuse them for different content.

## Guides

- [Architecture and product selection](Docs/architecture.md)
- [Variant definitions and content](Docs/variant-and-content.md)
- [Rules and economy configuration](Docs/rules-and-economy.md)
- [Question JSON](Docs/question-json.md)
- [Providers and vendor integrations](Docs/providers-and-integrations.md)
- [Optional multiplayer](Docs/multiplayer.md)
- [Persistence, upgrades, and troubleshooting](Docs/persistence-upgrades-troubleshooting.md)
- [Deterministic testing](Docs/testing.md)
- [Public API compatibility and migration](Docs/api-compatibility-and-migration.md)
- [Release checklist](Docs/release-checklist.md)
- [v0.2.0 release validation and migration handoff](Docs/v0.2.0-release-validation-and-migration-handoff.md) — historical pre-tag record; read its status note first

## Verification

```sh
Scripts/validate-package-boundaries.sh
swift test -Xswiftc -target -Xswiftc arm64-apple-macosx14.0 -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

The macOS target is only the Swift test host. Package products support iOS 17 and later.

## Deterministic testing

QuizEngine keeps production defaults for consumers, but its time, calendar, random selection, and delayed-work dependencies are injectable:

- `QuizEngineClock` and an explicit `Calendar` control date, time-zone, streak, cooldown, and statistics behavior.
- `RandomNumberGenerator` injection controls question, answer, seed, and ad-selection randomness.
- `QuizEngineScheduler` controls delayed game and multiplayer work, including rule-owned timer ticks. Tests advance a clock and scheduler instead of sleeping.
- Solo and multiplayer timers clamp clock rollback, and lifecycle pause/resume preserves remaining time without counting background duration.
- Calendar-day rewards and streaks use the injected calendar and reject timestamps that move backward.
- `PlayerProgressManager` and `UserPreferencesLoader` accept injected persistence stores and temporary persistence URLs for isolated tests.
- Existing provider protocols accept fake analytics, ads, purchases, haptics, leaderboards, and transports.
- Power-up tests can grant credits through the manager and assert the returned funding source without app services.

The package's `QuizEngineTestSupport` target is test-only and is not exposed as a library product. It supplies reusable clocks, schedulers, temporary persistence, provider fakes, transport fakes, and fixtures for the package test targets.

## Solo session state and effects

`QuizViewModel` remains `@MainActor` and keeps its established published flags and methods for existing SwiftUI consumers. New consumers can instead observe its immutable `sessionState` and drain `consumeSessionEffects()`. `SoloQuizSessionState` models answering, answer feedback, description, extra-life, transition, and terminal phases; `SoloQuizSessionEffect` expresses presentation work as `Sendable` values. These values cannot unlock an answer or re-run a terminal transition. `exitGame()` is terminal without awarding a completed-session result; repeated terminal, delayed, or rewarded-ad callbacks are ignored.

## Hardened multiplayer

QE-6 multiplayer uses the additive raw-payload transport path. Start hardened matches with a throwing `MultiplayerMatchConfiguration` containing an app-owned content version and analytics transport label. Peers negotiate protocol/capabilities and must have the exact same content version before the host sends questions. `MultiplayerWireCodec` owns bounded decoding; envelopes carry a host-created match ID, sequence, and replay ID. Existing message transports remain source-compatible but cannot start a hardened match.

Pass the shared `PlayerProgressManager` to `MultiplayerQuizViewModel` to persist the terminal result. The manager records a bounded match receipt with the reward/statistics transaction, so duplicate terminal callbacks and post-restart repeats are no-ops.
