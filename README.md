# QuizEngine

Reusable iOS 17 quiz rules and state. It is not a complete app or a UI kit.

## Start here

Use the smallest product set your app needs:

| Product | Use it for |
| --- | --- |
| `QuizEngineCore` | questions, progress, categories, unlocks, achievements, persistence, provider protocols |
| `QuizEngineGame` | single-player and practice game state |
| `QuizEngineMultiplayer` | optional vendor-neutral multiplayer state and wire protocol |

Add the private package at the exact validated release:

```swift
.package(url: "git@github.com:MPetrusic/QuizEngine.git", exact: "0.1.1")
```

Every developer and CI runner needs GitHub read access and a working SSH key, GitHub App, or deploy key. Do not put access tokens in a package URL, source file, or project file.

Open [StarterQuiz](Examples/StarterQuiz/README.md) for a minimal runnable iOS app. Its [setup checklist](Docs/persistence-upgrades-troubleshooting.md#from-starterquiz-to-your-app) is the intended first integration path.

## Ownership boundary

| QuizEngine owns | Your app owns |
| --- | --- |
| quiz rules, scoring, game state, progress, unlock evaluation, achievement evaluation, persistence format | questions, localizations, views, theme, images, icons, analytics, ads, purchases, leaderboards, entitlements, SDK setup, multiplayer transports |

Firebase, Google Mobile Ads, StoreKit, Game Center, MultipeerConnectivity, their IDs, and their capabilities do not belong in this package.

## Required composition

1. Create one validated `QuizVariantDefinition` with your categories, achievements, and explicit `QuestionResource`.
2. Create exactly one `QuestionDataService` from that resource.
3. Pass that same service and variant to `PlayerProgressManager`; build game sessions from the same service.
4. Keep category IDs, achievement IDs, and question IDs stable after release.
5. Add app-owned adapters only for integrations your app actually uses.

## Guides

- [Architecture and product selection](Docs/architecture.md)
- [Variant definitions and content](Docs/variant-and-content.md)
- [Question JSON](Docs/question-json.md)
- [Providers and vendor integrations](Docs/providers-and-integrations.md)
- [Optional multiplayer](Docs/multiplayer.md)
- [Persistence, upgrades, and troubleshooting](Docs/persistence-upgrades-troubleshooting.md)
- [Release checklist](Docs/release-checklist.md)

## Verification

```sh
Scripts/validate-package-boundaries.sh
swift test -Xswiftc -target -Xswiftc arm64-apple-macosx14.0 -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

The macOS target is only the Swift test host. Package products support iOS 17 and later.
