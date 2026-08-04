# Changelog

## v0.2.0

- Harden multiplayer with an app-supplied protocol/content/capability handshake, host-created match IDs, bounded raw-payload decoding, sender/phase/round validation, replay/duplicate suppression, and deterministic terminal failures.
- Add additive raw-payload transport members while retaining legacy typed-message transport APIs as source-compatible bridges; hardened matches reject transports that do not implement the raw path.
- Remove hardcoded multiplayer analytics transport labels. Hardened callers supply the label in `MultiplayerMatchConfiguration`.
- Bind multiplayer lifecycle timeouts and callbacks to an active match generation; terminal entry is first-wins and cancels subsequent callbacks.
- Add durable bounded multiplayer match receipts and idempotent `PlayerProgressManager` result recording. `MultiplayerQuizViewModel` can persist terminal rewards/statistics exactly once through the shared manager.
- Add deterministic QE-6 tests for handshake mismatch, malformed/replayed/out-of-order payloads, wrong sender, unsupported transport, terminal idempotence, and durable reward receipts.

- Extract immutable, `Sendable` single-player session states and effects from SwiftUI presentation flags.
- Make answer locks, timeout/tap races, skip transitions, power-up conflicts, restart, exit, delayed callbacks, rewarded-ad requests, and completed terminal processing deterministic and idempotent.
- Keep `QuizViewModel` and existing SwiftUI-facing flags/methods `@MainActor` as additive compatibility bridges; add `sessionState`, `sessionEffects`, `consumeSessionEffects()`, and `exitGame()` for new hosts.
- Add deterministic QE-5 tests for rapid taps, deadline races, stale/exit callbacks, repeated terminal/reward requests, and conflicting power-ups.
- Complete deterministic clock, calendar/time-zone, RNG, selection, and scheduler injection across reusable rule boundaries.
- Make solo timer ticks scheduler-owned while preserving the public timer compatibility bridge and existing initializer defaults.
- Add solo lifecycle pause/resume for question and freeze timing; harden multiplayer pause/resume and timeout accounting.
- Clamp clock rollback for timers, response/match durations, daily rewards, streaks, cooldowns, achievements, and statistics.
- Remove shared mutable date formatting and replace unchecked QE-4 scheduler/test-clock state with actor-safe or lock-backed storage.
- Add deterministic selection, answer order, restart, reward, DST/time-zone, rollback, timeout, freeze, lifecycle, and stale-task tests without wall waiting.
- Add immutable, validated `QuizRulesConfiguration` owned by `QuizVariantDefinition`.
- Configure fresh coins, solo timer/lives/scoring/streaks, power-ups, extra life, daily and ad rewards, interstitial eligibility inputs, and session sizes.
- Configure multiplayer timer, scoring, standard/Premium rewards, and anti-farming thresholds while preserving Serbian-compatible defaults.
- Route Core, Game, and Multiplayer behavior through variant/session rules without changing existing initializer call sites or persistence decoding defaults.
- Add schema-versioned progress and preference persistence with legacy schema-0 decoding.
- Add injectable persistence stores, atomic replacement, backups, recovery, typed failures, serialized transactions, and read-back verification.
- Add marker-backed, exactly-once `PlayerProgressImportRequest` transactions.
- Add persistent per-power-up free credits with credit-before-coin consumption and atomic rollback.
- Expose power-up funding source and actual coin spend to game consumers and analytics while preserving the existing analytics callback.
- Support exactly-once legacy inventory targets without converting hint or skip value into coins.
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
