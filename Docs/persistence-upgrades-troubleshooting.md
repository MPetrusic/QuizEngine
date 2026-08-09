# Persistence, upgrades, and troubleshooting

## Storage contracts

`PlayerProgressManager` stores progress in `Documents/player_progress.plist` unless the app injects a different URL or `QuizEnginePersistenceStore`. New files use a schema-1 property-list envelope with `schemaVersion` and `payload`; see [schema versions and dispatch](#schema-versions-and-dispatch) for what older documents do. The following are persistent contracts after first release:

- category IDs;
- achievement IDs;
- question integer IDs and their meaning;
- `PowerUp` raw identifiers used by persisted credit balances;
- purchase-status keys owned by the app.

Renaming an ID, deleting a category that appears in saved progress, or reusing a question ID for different content requires an explicit migration. Do not ship such a change as a normal content edit.

Before a cutover or content update, decode the proposed question data and run `QuizContentValidator.validate(_:categories:)` with the final variant categories. It catches package-owned structural defects without inspecting app resources. Asset-catalog existence, editorial approval, sources, and distribution gates remain consumer responsibilities.

For a genuinely fresh player with no primary progress document, `PlayerProgressManager` uses `variant.rules.economy.initialCoins`. Legacy/schema documents whose older payload omits `coins` or `totalCoinsEarned` continue to decode those fields as 100. Changing a variant's fresh balance never rewrites or reinterprets an existing player's stored balance.

Daily rewards, app/play streaks, reward-ad cooldowns, achievements, and daily/hourly statistics use the manager's injected clock and calendar. A clock earlier than a stored streak, claim, play, or cooldown timestamp cannot advance or reset that rule. Local-day and DST behavior is defined by the injected calendar and time zone.

## Schema versions and dispatch

`QuizEnginePersistenceSchema` describes what this package can read:

- `legacy` (0) — documents with no `schemaVersion` key at all, as written by `v0.1.x`;
- `firstVersioned` (1) — the first released envelope version;
- `current` — the envelope version this package writes;
- `decodableEnvelopeVersions` — `firstVersioned...current`, every released envelope version that still decodes.

Decoding dispatches on that range, not on equality with `current`. A document written at an earlier released schema loads, reports the version it was written at through `PersistenceStatus.loaded(schemaVersion:)`, and is promoted to `current` by the next save; recovery from a backup restores the historical document verbatim rather than promoting it. Only an unknown — that is, a future — version is rejected, as `PersistenceError.unsupportedSchema`. The import marker follows the same rule so an interrupted import stays recoverable across an upgrade.

Shipping a new schema therefore means bumping `current`, keeping the previous release's fixture, and adding its migration coverage. It never means widening an equality check.

## Historical fixtures

`Tests/QuizEngineCoreTests/Resources/PersistenceFixtures` holds exact saved documents from every released schema, with [`manifest.json`](../Tests/QuizEngineCoreTests/Resources/PersistenceFixtures/manifest.json) as the index. It records, per file, the originating tag and commit, SHA-256 and byte count, the type and call that produced it, its storage path, its envelope and expected load status, how it was obtained, measured byte-equivalence with other releases, the confirmation that it holds no real user data or secret, and the values the originating tag's own decoder read back.

| Release | Progress | Preferences | Envelope |
| --- | --- | --- | --- |
| `v0.1.0` | `player_progress_default.plist`, `player_progress_populated.plist` | `user_preferences.plist` | none — schema 0 |
| `v0.1.1` | same two files | `user_preferences.plist` | none — schema 0 |
| `v0.1.2` | same two files | `user_preferences.plist` | none — schema 0 |
| `v0.1.3` | same two files | `user_preferences.plist` | none — schema 0 |
| `v0.2.0` | `player_progress_schema_1.plist` | `user_preferences_schema_1.plist` | schema 1 |

The four `v0.1.x` releases encode identical documents, and the manifest records that measured equivalence. Separate fixtures are kept per release anyway, so a later divergence is caught for the release it belongs to.

`PersistenceFixtureMigrationTests` drives every entry through the public load, migration, save, reload, backup-recovery, and repeated-import paths. Regenerate the whole set with:

```sh
sh Scripts/generate-persistence-fixtures.sh
```

That script checks each exact tag out into a detached `git worktree`, builds the matching generator from `Scripts/PersistenceFixtureGenerators` against that tag's own sources, and runs it inside an isolated home directory, so no fixture is ever produced by current models or touches a real Documents directory. Never edit a generated document by hand; change the generator, rerun the script, and commit the new bytes and manifest together.

These package fixtures do not replace a consumer's own upgrade rehearsal. A consumer app must still install an archived build using its old persistence contract, upgrade over it, and verify that its own legacy files and values reconcile, before changing its persistence contract.

## Failure and recovery contract

The default file store uses these sibling paths:

- `player_progress.plist` — primary document;
- `player_progress.plist.backup` — last known primary document;
- `player_progress.plist.tmp` and `.backup.tmp` — short-lived atomic replacement files;
- `player_progress.plist.import-marker` — pending/completed import transaction marker.
- `player_progress.plist.lock` — process/thread coordination for complete persistence transactions.

Replacement writes the new document to a temporary sibling, preserves the previous primary as the backup, atomically replaces the primary, and then verifies the decoded document by reading it back. The production file store serializes the complete transaction across threads and processes sharing the same primary URL. Stale temporary siblings are removed before the next store operation. Low-storage, I/O, malformed-data, unsupported-schema, backup-recovery, and read-back failures are surfaced as `PersistenceError` values.

If the primary is missing, the manager starts with fresh state and leaves any stale backup untouched. If the primary is malformed but the backup decodes, the backup is restored and the manager reports `.recoveredFromBackup`. If both are unusable, the throwing APIs fail; the source-compatible initializer loads the default in-memory value but exposes the typed failure through `persistenceStatus` and `lastPersistenceError`. It never deletes the existing files.

## Import transaction

The app maps its legacy sources into a complete `PlayerProgress` value and submits a `PlayerProgressImportRequest` with a stable identifier and source fingerprint. QuizEngine writes a pending marker before replacing progress, verifies the replacement, and writes a completed marker last. A matching completed request returns `.alreadyImported` only when the submitted target also matches the completed transaction and the destination remains a valid persistence document; a different fingerprint or target fails as a conflict. A destination that matches the pre-import snapshot is treated as an incomplete transaction. A pending marker found on the next launch restores the prior backup only when it matches the marker's recorded previous progress (or removes a newly created primary), clears the marker, and leaves the import retryable. Legacy source files are never deleted by the package.

Power-up inventory is part of that complete target. Map each legacy hint to one `.fiftyFifty` credit and each legacy skip to one `.skipQuestion` credit. Preserve any other existing engine credit balances according to the app's conflict plan. Credit counts must be nonnegative, and inventory value must never be converted into coins.

## From StarterQuiz to your app

1. Add the remote package at exact `0.2.0` and select only the products you need.
2. Copy the composition pattern: one variant, one explicit question resource, one shared question service, one progress manager.
3. Replace the starter categories, achievement IDs, strings, icons, question JSON, assets, bundle ID, and UI.
4. Add content validation tests before release.
5. Add app-owned provider adapters, SDK configuration, purchase restoration, and entitlement/privacy configuration only if your app needs them.
6. Add multiplayer last; link its product and implement a transport only then.
7. Before each dependency upgrade, pin the new tag, build, run app tests, and manually test changed engine flows.

## Common failures

| Symptom | Cause and fix |
| --- | --- |
| `fileNotFound` | JSON is not in the configured target bundle, or `fileName` incorrectly includes `.json`. |
| Unlock/completion totals are wrong | More than one question service or resource file is being used. Share one service. |
| Progress resets or achievements re-award | IDs changed, question IDs were reused, or a migration bypassed the completion marker. Restore prior IDs or use the public import transaction. |
| Variant fails at startup | Read `QuizVariantValidationError`; fix duplicate/uppercase IDs, invalid references, empty localization keys/icons, or invalid thresholds. |
| Strings show keys | The app omitted the localization entries named by its variant. |
| Multiplayer does not connect | The app did not supply a transport or omitted its capability, Bonjour, or Local Network configuration. |
