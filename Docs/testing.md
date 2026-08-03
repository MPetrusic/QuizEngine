# Deterministic testing

QuizEngine tests must not wait on wall time, depend on process-global randomness, call external services, or use the default Documents directory.

## Inject the dependencies

Use the additive dependency parameters on the Core, Game, and Multiplayer initializers:

- `QuizEngineClock` supplies `now`; pass a calendar with the desired time zone to progress APIs.
- `RandomNumberGenerator` supplies deterministic question, answer, seed, and ad-selection decisions.
- `QuizEngineScheduler` supplies delayed main-actor work. The test scheduler advances pending work explicitly.
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

Persistence tests must cover schema-0 compatibility, schema-1 writes, malformed primary and backup data, backup recovery, interrupted replacement, low storage, read-back mismatch, marker ordering, repeated imports, conflicting imports, and preference reloads. `PlayerProgressImportRequest` is package-generic; legacy source mapping remains app-owned.

Power-up wallet tests must cover independent per-power-up balances, credit-before-coin order, zero-credit fallback, insufficient funding, save/reload, failed-write rollback, and exactly-once imports. Assert both `PowerUpSpendResult.fundingSource` and `coinsSpent`. Legacy hint and skip fixtures must become 50/50 and skip credits without changing coins.
