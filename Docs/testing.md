# Deterministic testing

QuizEngine tests must not wait on wall time, depend on process-global randomness, call external services, or use the default Documents directory.

## Inject the dependencies

Use the additive dependency parameters on the Core, Game, and Multiplayer initializers:

- `QuizEngineClock` supplies `now`; pass a calendar with the desired time zone to progress APIs.
- `RandomNumberGenerator` supplies deterministic question, answer, seed, and ad-selection decisions.
- `QuizEngineScheduler` supplies delayed main-actor work and rule-owned timer ticks. Advance the fake clock to the intended instant, then advance the test scheduler to execute due work.
- `PlayerProgressManager` and `UserPreferencesLoader` receive an injected `QuizEnginePersistenceStore` or temporary persistence URL.
- The store fake can deterministically fail primary reads, backup reads, atomic replacement, marker writes, recovery, and removal, and can return mismatched read-back data.
- Provider protocols receive test doubles rather than SDK-backed implementations.

The default initializer values preserve the production behavior used by existing consumers.

## Test-only support target

`QuizEngineTestSupport` is a non-product SwiftPM target used by the package's Core, Game, and Multiplayer tests. It contains:

- `TestClock` and `TestScheduler`;
- temporary progress/preferences storage;
- fake and recording providers;
- an in-memory `FakeTransport`;
- shared question and variant fixtures.

Use `TestScheduler.advance(by:)` or `runNext()` to drive delayed work. Do not add `sleep`, `Task.sleep`, polling, or arbitrary delays to tests.

Determinism coverage must compare independent instances with identical input, clock/calendar, seed, and call sequence. Cover competitive/category/practice/multiplayer selection, answer ordering, 50/50 removal, ad decisions, restart, scoring, and rewards. Time coverage must include backward clock movement, spring/fall DST, explicit time-zone calendars, exact timeout/freeze boundaries, rapid timeout/tap attempts, lifecycle pause/resume, and stale-task cancellation after restart.

For solo sessions, assert `SoloQuizSessionState` and `SoloQuizSessionEffect` directly rather than relying on SwiftUI animations or writable legacy flags. Cover rapid answer taps, a tap at the logical deadline, repeated terminal and rewarded-ad callbacks, restart/exit with cancellation-ignoring schedulers, stale effects, power-up conflicts, and exactly-once progress/analytics/leaderboard processing.

`TestClock` is lock-backed and can move forward or backward with `advance(by:)`, or jump to an exact instant with `setNow(_:)`. No test should depend on the host's current calendar, time zone, random generator, Documents directory, or wall-clock waiting.

Persistence tests must cover schema-0 compatibility, schema-1 writes, malformed primary and backup data, backup recovery, interrupted replacement, low storage, read-back mismatch, marker ordering, repeated imports, conflicting imports, and preference reloads. `PlayerProgressImportRequest` is package-generic; legacy source mapping remains app-owned.

Power-up wallet tests must cover independent per-power-up balances, credit-before-coin order, zero-credit fallback, insufficient funding, save/reload, failed-write rollback, and exactly-once imports. Assert both `PowerUpSpendResult.fundingSource` and `coinsSpent`. Legacy hint and skip fixtures must become 50/50 and skip credits without changing coins.

Rule tests should construct `QuizRulesConfiguration` directly and assert typed validation failures. Snapshot `.serbianCompatible`, then use custom configurations to prove fresh balance, session sizes, scoring, power-up effects, extra-life limits, daily/ad rewards, interstitial decisions, multiplayer rewards, and anti-farming boundaries. Continue using the existing fake clock, seeded RNG, scheduler, stores, and providers; configuration does not add a new timing or randomness seam.
