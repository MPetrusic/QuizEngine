# Deterministic testing

QuizEngine tests must not wait on wall time, depend on process-global randomness, call external services, or use the default Documents directory.

## Inject the dependencies

Use the additive dependency parameters on the Core, Game, and Multiplayer initializers:

- `QuizEngineClock` supplies `now`; pass a calendar with the desired time zone to progress APIs.
- `RandomNumberGenerator` supplies deterministic question, answer, seed, and ad-selection decisions.
- `QuizEngineScheduler` supplies delayed main-actor work. The test scheduler advances pending work explicitly.
- `PlayerProgressManager` receives a temporary `persistenceURL`.
- `UserPreferencesLoader.load(from:)` and `write(preferences:to:)` use an isolated preference URL.
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

QE-0 does not define schema versions, atomic persistence, backup/recovery, or migration transactions. Those belong to QE-1.
