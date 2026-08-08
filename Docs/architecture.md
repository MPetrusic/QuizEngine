# Architecture and product selection

QuizEngine contains game logic. An app supplies the content and platform integrations.

```text
App resources + localizations ──> QuizVariantDefinition ──> QuestionDataService
                                                               │
App providers ─────────────────────────────────────────> PlayerProgressManager
                                                               │
App SwiftUI views <──────────────────────── QuizViewModel / multiplayer view model
```

## Choose products deliberately

- Every app links `QuizEngineCore`.
- Link `QuizEngineGame` for the supplied single-player/practice state machine.
- Link `QuizEngineMultiplayer` only when the app implements and ships multiplayer. It does not provide Game Center or nearby-device networking itself.

An app can build custom views around the public Core models. It must not duplicate engine scoring, progression, or achievement logic.

## App composition

Create the variant once at startup, then create one question service and inject it everywhere. `PlayerProgressManager` persists to `Documents/player_progress.plist` by default through a versioned, atomic `FileQuizEnginePersistenceStore`. The store keeps a sibling backup and import marker, and verifies every replacement by reading it back.

```swift
let variant = try QuizVariantDefinition(
    categories: MyQuizVariant.categories,
    achievements: MyQuizVariant.achievements,
    questionResource: .init(bundle: .main, fileName: "my_questions"),
    rules: MyQuizVariant.rules
)
let questions = QuestionDataService(variant: variant)
let progress = PlayerProgressManager(
    variant: variant,
    questionDataService: questions,
    analytics: MyAnalyticsAdapter(),
    purchaseStatus: MyPurchaseStatusAdapter()
)
```

Use `QuizContentValidator.validate(_:categories:)` in consumer CI on the decoded question data and `variant.categories`. It is a pure, immutable Core contract for structural content only; app-owned image/asset-catalog and editorial validation stay outside the package. Validate before a migration or content cutover, but keep the existing loader behavior unchanged for source compatibility.

Existing URL-based initializers remain compatible. Apps that need typed load and write failures should inject a `QuizEnginePersistenceStore` through the throwing initializer and handle `PersistenceError` explicitly. A public `PlayerProgressImportRequest` provides an exactly-once, marker-backed import transaction for app-owned legacy migration planners.

Power-up credits live in `PlayerProgress`, keyed by `PowerUp`; they are not app preferences or coin equivalents. Apps query balances and affordability through `PlayerProgressManager`, then call `consumePowerUp(_:)`. That operation spends one free credit before coins and atomically persists the funding deduction with power-up usage. `PowerUpSpendResult` exposes `.freeCredit` or `.coins` plus the actual coin amount to the game layer.

Legacy inventory mapping stays app-owned. Build the complete target `PlayerProgress` with legacy hint quantities mapped to `.fiftyFifty` credits and legacy skip quantities mapped to `.skipQuestion` credits, then submit it through `PlayerProgressImportRequest`. Do not convert those quantities to coins.

Do not create a second `QuestionDataService` with another file or bundle. Category totals, completion, unlocks, achievements, and sessions must refer to the same content set.

Pass `variant.rules` to each `QuizViewModel` and `MultiplayerQuizViewModel`. Compatibility initializers use `.serbianCompatible`, but mixing custom view-model rules with a default progress manager produces inconsistent pricing. Treat the validated variant as the composition root for all rule consumers.

## Deterministic dependencies

Inject one clock/calendar pair anywhere local dates or elapsed time affect rules, and inject seeded random generators when a session must be reproducible. Solo and multiplayer view models remain `@MainActor`; immutable questions, rules, progress snapshots, messages, and deterministic generator values are `Sendable`.

`QuizViewModel` owns timer decisions through its clock and scheduler. The legacy timer publisher remains source-compatible as a notification bridge, but calling `updateRemainingTimeAndHandleNavigationIfNeeded()` repeatedly for the same clock instant is idempotent. Forward scene background/foreground events to the view model so question and freeze timing pause and resume from their remaining duration.

Clock rollback is conservative: elapsed values never become negative or increase a remaining timer, and future streak/reward timestamps cannot grant another reward or rewrite streak state. An injected `Calendar` and its time zone define local-day and DST boundaries.

Single-player rule flow is an explicit state/effect reducer. `SoloQuizSessionState` and `SoloQuizSessionEffect` are immutable, `Sendable` values; the `@MainActor` view model publishes them while preserving the established flags and methods as compatibility projections. The reducer locks answers before feedback, rejects races and stale scheduled work by state/generation, and makes completed/exited terminal paths once-only. SwiftUI owns animations and sheets after observing an effect; it does not decide rule validity.

Hardened multiplayer similarly keeps UI-facing coordinators and view models on the main actor while transporting only immutable `Sendable` envelopes and payloads. A host-created match ID, exact protocol/content handshake, capability set, sender identity, replay ID, and phase/round checks guard every wire transition. Lifecycle timers capture the active match generation; terminal entry cancels them and cannot be reversed. The app provides its transport analytics label in `MultiplayerMatchConfiguration`.

## Serbian Quiz is a reference, not a template

`SerbianQuizVariantDefinition` shows the correct composition pattern. Its categories, achievement IDs, question resource, views, theme, Firebase/ads/StoreKit/Game Center adapters, and multiplayer transports are Serbian Quiz implementation details. New apps define all of those independently.

The Serbian GameKit and MultipeerConnectivity transports are examples of app-owned implementations of the optional multiplayer boundary; they are not package dependencies.
