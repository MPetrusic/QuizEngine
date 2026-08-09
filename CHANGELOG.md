# Changelog

## v0.2.1

Remediation of the audited v0.2.0 release blockers. The published `v0.2.0` tag is unchanged; nothing in this section rewrites it.

### Correction to the published v0.2.0 notes

The v0.2.0 entry below states that `MultiplayerQuizViewModel` "can persist terminal rewards/statistics exactly once through the shared manager." **That statement was incomplete.** It described the successful path only. In v0.2.0 the view model set its terminal-effect flag *before* asking `PlayerProgressManager` to persist, so a terminal result whose save failed was neither applied nor retryable: the in-memory guard stayed set, every later delivery of the same result was rejected, and the coins, multiplayer statistics, and receipt were lost. v0.2.0 delivered at-most-once attempted processing, not exactly-once durable processing.

QEB-01 in this release supplies the remediation: an explicit `idle`/`pending`/`committing`/`committed` commit state, an immutable fingerprinted terminal record, a typed retryable-failure outcome, and `retryPendingTerminalCommit()`. See [terminal commit and retry](Docs/multiplayer.md#terminal-commit-and-retry).

The published v0.2.0 artifact itself is unchanged and still carries the original wording. Consumers that need durable terminal results must move to this release; pinning v0.2.0 keeps the loss path.

### Post-publication v0.2.0 identity — verified 2026-08-09

The [v0.2.0 release-validation handoff](Docs/v0.2.0-release-validation-and-migration-handoff.md) was written *before* the tag existed and says no tag or push had been created. That statement was true when committed and became stale the moment v0.2.0 was published. It is a historical record and is not rewritten. The current identity of the published release is:

| Property | Value |
| --- | --- |
| Annotated tag object | `8cb09d8e1c46bf48c6fc7a1ad75c9a0b903fc56d` |
| Peels to commit | `9c5b2282d001a6a7ad714c54ffa6d726eca9fd5e` |
| Tag type | annotated (`git cat-file -t v0.2.0` → `tag`) |
| Remote verification | `git ls-remote --tags origin refs/tags/v0.2.0*` returns the same tag object and peeled commit |
| Exact-tag consumer smoke test | A clean SwiftPM consumer depending on `exact: "0.2.0"` resolved to revision `9c5b2282d001a6a7ad714c54ffa6d726eca9fd5e`, linked all three library products, and built |

- QEB-05: record the complete v0.1.2-to-candidate public API comparison. `swift-api-digester` reports removed/renamed constructors and methods across all three products; every one is a defaulted-parameter or synthesized-conformance artifact, and a source fixture written against the v0.1.2 call shapes compiles unchanged. See [public API compatibility](Docs/api-compatibility-and-migration.md).
- QEB-06: correct the release documentation, add the post-publication tag evidence above, and record that the optional offline daily challenge is deferred from 0.2.x and remains unimplemented. Release validation is not evidence that it was delivered.
- QEB-02: add `QuizQuestionStructureRules` to `QuizEngineCore` as the single definition of answer count, answer-text normalization, correct-answer count, difficulty bounds, and category membership, and route both `QuizContentValidator` and the multiplayer wire validator through it.
- QEB-02: add the expected multiplayer question count, the canonical allowed category IDs, and the multiplayer rules to `MultiplayerMatchConfiguration`, with a variant-derived convenience initializer.
- QEB-02: validate outgoing host configurations before transmission and incoming guest configurations before publication, against the shared structural rules and all payload byte bounds.
- QEB-02: validate answers and question results against the active round and the actual question, and validate awarded points and score progression against the configured scoring rules instead of broad constants.
- QEB-02: replace ad-hoc replay suppression with a bounded contiguous-sequence buffer, and give ordering gaps, buffer overflow, unexpected phases, wrong-role messages, invalid configurations, impossible round payloads, phase deadlines, and transport send failures typed terminal outcomes.
- QEB-02: report a duplicate category from content validation as `QuizContentValidationIssue.duplicateCategory`.
- QEB-02: add the protocol, configuration, ordering, lifecycle, timeout, host/guest, and late-callback test matrix, with one invalid field per configuration payload.
- QEB-03: add exact historical persistence fixtures for `v0.1.0`, `v0.1.1`, `v0.1.2`, `v0.1.3`, and `v0.2.0` schema 1 under `Tests/QuizEngineCoreTests/Resources/PersistenceFixtures`, each emitted by building and running its own release tag in a detached worktree rather than synthesized with current models.
- QEB-03: add `Scripts/generate-persistence-fixtures.sh` and the per-tag generators, which reproduce every fixture deterministically inside an isolated home directory, and a generated `manifest.json` recording tag, commit, path, SHA-256, byte count, producing type and call, storage path, envelope and load-status expectation, provenance, measured byte-equivalence between releases, and the absence of real user data.
- QEB-03: add a table-driven migration suite covering bundle hash verification, public-path loading, load status, field-by-field values, mutation, promotion to the current envelope, reload, repeated import returning `.alreadyImported` without duplicate value, and corrupt-primary recovery from a valid historical schema-0 and schema-1 backup.
- QEB-03: dispatch envelope decoding on `QuizEnginePersistenceSchema.decodableEnvelopeVersions` instead of equality with `current`, so a document written by any released schema keeps loading and is promoted by the next save, and only an unknown future version is rejected. Behaviour is unchanged at schema 1 and the on-disk format of schema 1 is unchanged.
- QEB-03: move the Core test persistence fixtures to a `.copy` resource rule. `.process` flattens the resource tree, and the four `v0.1.x` releases deliberately keep separate fixtures under identical file names.
- QEB-04: add schema 2 with a bounded durable reward-receipt ledger and a separately persisted, non-prunable Premium claim identity; schema-0 and the committed `v0.2.0` schema-1 documents retain their balances and promote on their next save.
- QEB-04: add atomic, receipt-backed rewarded-ad and Premium bonus transactions with typed duplicate, conflict, eligibility, rejection, and persistence-failure outcomes, checked arithmetic, and full rollback on failed saves.
- QEB-04: deprecate the source-compatible reward bridges, make rewarded-ad bridges cooldown-gated and rollback-safe, and make the Premium marker a non-awarding legacy claim marker. Advertising SDK, StoreKit, entitlement resolution, Premium amount policy, and stable provider receipt acquisition remain app-owned.
- QEB-05: restore the deprecated v0.1.2 `PlayerProgress.dailyStatsDateFormatter` source-compatibility property as a fresh formatter on every access and restore the calendar-only `AchievementService.checkAchievements` call shape; deterministic engine date paths continue to use explicit clocks and calendars.

## v0.2.0

- Make StarterQuiz consume the public `QuizContentValidator` contract directly, so the reference consumer validates the same structural rules exposed to apps.
- Add the v0.2.0 release-validation and migration-handoff record. AmericanQuiz remains pinned to `v0.1.3` until its planned Phase 3 cutover.
- Add the opt-in `QuizContentValidator` aggregate API with immutable `Sendable` results/issues for positive unique IDs, canonical categories, four non-empty normalized-distinct answers, exactly one correct answer, and difficulty `1...3`. It preserves existing loading behavior and leaves app asset/editorial checks outside the package.
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
