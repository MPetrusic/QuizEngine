# Public API compatibility and migration

This page records what the public surface guarantees across releases, what is deprecated, and the evidence behind the compatibility claim. It covers the three library products — `QuizEngineCore`, `QuizEngineGame`, and `QuizEngineMultiplayer`.

## Compatibility rule

Source compatibility is preserved unless a planning document explicitly replaces an API. Old entry points remain as deprecated bridges, and a bridge must be *safe*: keeping an unsafe legacy path does not close a blocker. New capability arrives as defaulted parameters and additional overloads rather than replaced signatures.

## Deprecated in this release

### `PlayerProgress.dailyStatsDateFormatter`

v0.1.2 exposed `public static let dailyStatsDateFormatter: DateFormatter`. v0.2.0 removed it when deterministic date helpers were introduced, which broke any source client that referenced it. It is restored here as a deprecated computed property with the same name and type.

```swift
@available(*, deprecated, message: "Use dateKey(for:calendar:) with an explicit calendar.")
public static var dailyStatsDateFormatter: DateFormatter
```

Two properties of the restored shim matter:

- **It returns a new formatter on every access.** The v0.1.2 symbol was a shared `let`. Restoring shared mutable formatter state would reintroduce a data race under strict concurrency, so the shim deliberately does not do it. Mutating the returned formatter affects only that instance; it cannot change what any engine call observes.
- **Its observable defaults match v0.1.2** — `yyyy-MM-dd` in the current time zone — so an existing caller that only formats a date keeps getting the same key.

`dateKey(for:calendar:)` is the authoritative replacement and the only thing new code should use:

```swift
// Deprecated: implicit current time zone, no injectable calendar.
let key = PlayerProgress.dailyStatsDateFormatter.string(from: date)

// Authoritative: explicit calendar, deterministic under test.
let key = PlayerProgress.dateKey(for: date, calendar: calendar)
```

Every engine-internal rule path — daily statistics, streaks, cooldowns, achievements — already routes through the explicit-calendar helper and an injected clock. The compatibility formatter is not used by engine logic and must not be reintroduced into it. `todayKey` and `currentHour` remain available for callers that genuinely want current-calendar behavior.

### `AchievementService.checkAchievements`

The calendar-only call shape is available again. All three forms resolve to the same evaluation:

```swift
service.checkAchievements(progress: progress)
service.checkAchievements(progress: progress, date: date, calendar: calendar)
```

The service holds an injected clock and calendar, so the short form is deterministic when the service is constructed with test dependencies rather than defaults.

### Reward bridges

`recordRewardAdWatched()` and `recordRewardAdWatched(coinsAwarded:)` remain callable and are deprecated. They are now cooldown-gated and roll back safely on a failed save, but they cannot provide durable callback idempotency because they carry no stable receipt identity. Shipping consumers must migrate to the receipt-backed API; see [rules and economy](rules-and-economy.md) and the reward transaction outcomes in [persistence](persistence-upgrades-troubleshooting.md). The legacy Premium marker is a claim marker only and is not a valid award workflow.

## v0.1.2 to candidate API comparison

Run on 2026-08-09.

| Property | Value |
| --- | --- |
| Tool | `swift-api-digester` (`-dump-sdk` then `-diagnose-sdk`) |
| Toolchain | Apple Swift 6.3.3 (swiftlang-6.3.3.1.3, clang-2100.1.1.101) |
| Xcode | 26.6 (17F113), macOS 26.5.2 (25F84) |
| Target | `arm64-apple-macosx14.0`, macOS SDK, identical on both sides |
| Baseline | exact tag `v0.1.2` (tag object `b76c9552397b8ab134cba823e703237d94718549`), peeled commit `847c0461bb18ab36f212a75b04d6c8b0daf9144f` |
| Candidate | `ea53485c5feaa018c07ac69f5c959a86ac1f4aff` |
| Products compared | all three shipped by v0.1.2 |

The package declares no `#if os(...)` or `canImport` conditionals in `Sources`, so the macOS-target module surface is the same surface an iOS consumer sees.

### Findings and disposition

Every reported item is a tool artifact. None is a source break. The digester reports a constructor as "removed" whenever its mangled signature changes, which adding a *defaulted* parameter always does, even though every existing call site still compiles.

| Product | Reported | Disposition |
| --- | --- | --- |
| Core | `AchievementService.init(variant:)` removed | Noise — now `init(variant:clock:calendar:)`, both new parameters defaulted |
| Core | `PlayerProgress.init(coins:…)` removed | Noise — same 36 parameters, plus 5 defaulted ones for receipts, Premium claim identity, and power-up credits |
| Core | `PlayerProgressManager.init(variant:questionDataService:analytics:purchaseStatus:persistenceURL:)` removed | Noise — additional injected dependencies, all defaulted |
| Core | `PlayerProgressManager.SessionStatistics.init()` removed | Noise — still a no-argument initializer |
| Core | `QuestionDataService.init(resource:)` removed | Noise — now `init(resource:randomNumberGenerator:)`, defaulted |
| Core | `QuestionDataService.init(bundle:fileName:)` removed | Noise — now `init(bundle:fileName:randomNumberGenerator:)`, defaulted. Removed from the *digester's* view in v0.2.0, not by this release; the call shape never stopped compiling |
| Core | `PowerUp.hash(into:)` and `PowerUp.hashValue` removed | Noise — `PowerUp` gained a `String` raw value, so `Hashable` is satisfied through `RawRepresentable` synthesis instead of members printed on the type. `PowerUp` is still `Hashable`; sets and dictionary keys are unaffected |
| Core | `canClaimDailyReward()` renamed to `canClaimDailyReward(calendar:now:)` | Noise — both parameters defaulted |
| Core | `updateStreakOnAppOpen()` renamed to `updateStreakOnAppOpen(now:calendar:)` | Noise — both parameters defaulted |
| Core | `UserPreferencesLoader.load()` renamed to `load(from:)` | Noise — `from` defaults to `nil`, resolving to the same plist URL |
| Core | `UserPreferencesLoader.write(preferences:)` renamed to `write(preferences:to:)` | Noise — `to` defaults to `nil` |
| Core | `recordRewardAdWatched(coinsAwarded:)` removed default argument | Accurate, and harmless — a separate no-argument `recordRewardAdWatched()` overload covers the v0.1.2 call shape. Both are deprecated |
| Game | `QuizViewModel.init(questions:gameMode:selectedCategory:…)` removed | Noise — additional defaulted injected dependencies |
| Multiplayer | `MultiplayerGameCoordinator.init(analytics:)` removed | Noise — additional defaulted dependencies |
| Multiplayer | `MultiplayerQuizViewModel.init(gameCoordinator:analytics:interstitialAd:purchaseStatus:)` removed | Noise — additional defaulted dependencies |

**Genuine remaining source breaks: none.**

### How "noise" was verified

Not by inspection. A source fixture was written containing every v0.1.2 call shape listed above — the original argument labels, in the original order, with no new arguments — in a separate SwiftPM package depending on the candidate. It compiles against the candidate with no errors. The only diagnostics are the intended deprecation warnings for `dailyStatsDateFormatter`, `recordRewardAdWatched()`, and `recordRewardAdWatched(coinsAwarded:)`.

A compiled fixture is the authoritative test here, because "source break" means old source stops compiling — which is exactly what the digester's signature-level report cannot decide on its own.

The in-package equivalents are `testDailyStatsDateFormatterCompatibilityUsesIndependentInstances` and `testAchievementServiceCalendarOnlyCompatibilityCallRemainsAvailable` in `Tests/QuizEngineCoreTests/QuizEngineCoreTests.swift`.

## Reproducing the comparison

```sh
swift build -Xswiftc -target -Xswiftc arm64-apple-macosx14.0
xcrun swift-api-digester -dump-sdk -module QuizEngineCore \
  -o core.json -I .build/debug/Modules \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target arm64-apple-macosx14.0 -abort-on-module-fail
```

Dump both sides that way, then compare and read the complete output:

```sh
xcrun swift-api-digester -diagnose-sdk \
  --input-paths baseline_core.json --input-paths candidate_core.json \
  -o diff_core.txt -v
```

Repeat per product. Treat every reported removal as unexplained until a compiled fixture proves the call shape survives.
