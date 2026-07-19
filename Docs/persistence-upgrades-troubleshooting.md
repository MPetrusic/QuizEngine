# Persistence, upgrades, and troubleshooting

## Storage contracts

`PlayerProgressManager` stores progress in `Documents/player_progress.plist` unless the app injects a different URL. The following are persistent contracts after first release:

- category IDs;
- achievement IDs;
- question integer IDs and their meaning;
- purchase-status keys owned by the app.

Renaming an ID, deleting a category that appears in saved progress, or reusing a question ID for different content requires an explicit migration. Do not ship such a change as a normal content edit.

QuizEngine has no automated historical installed-user save fixture yet. A consumer app must add one before changing its own persistence contract.

## From StarterQuiz to your app

1. Add the remote package at exact `0.1.1` and select only the products you need.
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
| Progress resets or achievements re-award | IDs changed or question IDs were reused. Restore prior IDs or write a migration. |
| Variant fails at startup | Read `QuizVariantValidationError`; fix duplicate/uppercase IDs, invalid references, empty localization keys/icons, or invalid thresholds. |
| Strings show keys | The app omitted the localization entries named by its variant. |
| Multiplayer does not connect | The app did not supply a transport or omitted its capability, Bonjour, or Local Network configuration. |
