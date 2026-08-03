# Persistence, upgrades, and troubleshooting

## Storage contracts

`PlayerProgressManager` stores progress in `Documents/player_progress.plist` unless the app injects a different URL or `QuizEnginePersistenceStore`. New files use a schema-1 property-list envelope with `schemaVersion` and `payload`. The following are persistent contracts after first release:

- category IDs;
- achievement IDs;
- question integer IDs and their meaning;
- purchase-status keys owned by the app.

Renaming an ID, deleting a category that appears in saved progress, or reusing a question ID for different content requires an explicit migration. Do not ship such a change as a normal content edit.

QuizEngine has no automated historical installed-user save fixture yet. A consumer app must add one before changing its own persistence contract.

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

The app maps its legacy sources into a complete `PlayerProgress` value and submits a `PlayerProgressImportRequest` with a stable identifier and source fingerprint. QuizEngine writes a pending marker before replacing progress, verifies the replacement, and writes a completed marker last. A matching completed request returns `.alreadyImported` only when the destination remains a valid persistence document; a destination that matches the pre-import snapshot is treated as an incomplete transaction. A different fingerprint for the same identifier fails as a conflict. A pending marker found on the next launch restores the prior backup only when it matches the marker's recorded previous progress (or removes a newly created primary), clears the marker, and leaves the import retryable. Legacy source files are never deleted by the package.

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
