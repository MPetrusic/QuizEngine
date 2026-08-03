# Changelog

## v0.2.0

- Add schema-versioned progress and preference persistence with legacy schema-0 decoding.
- Add injectable persistence stores, atomic replacement, backups, recovery, typed failures, serialized transactions, and read-back verification.
- Add marker-backed, exactly-once `PlayerProgressImportRequest` transactions.
- Preserve existing URL-based consumers and expose compatibility-path failures through persistence status.

## v0.1.3

- Add injectable clocks, calendars, random generators, schedulers, and temporary preference/progress URLs for deterministic tests.
- Add the package-internal `QuizEngineTestSupport` fixture target with fake providers and transports.
- Preserve existing consumer initializer compatibility and production defaults.

## v0.1.2

- Use the public HTTPS repository URL in consumer setup instructions.
- No public engine API or game-behavior changes.

## v0.1.1

- Add the runnable, vendor-neutral `StarterQuiz` reference app.
- Add integration, content, provider, multiplayer, persistence, troubleshooting, and release guides.
- No public engine API or game-behavior changes.

## v0.1.0

- First reusable QuizEngine release.
