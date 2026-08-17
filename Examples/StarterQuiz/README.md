# StarterQuiz

Minimal iOS 17 SwiftUI reference app for QuizEngine. It has no Firebase, ads, StoreKit, Game Center, or multiplayer implementation.

## Run from this checkout

Open `StarterQuiz.xcodeproj`. The project resolves QuizEngine through its local relative package reference (`../..`) so the example builds with the checked-out package.

## Use the package in a real app

In Xcode, add a package dependency with:

```swift
.package(url: "https://github.com/MPetrusic/QuizEngine.git", exact: "0.2.3")
```

Do not pin `0.2.0`; see the [changelog](../../CHANGELOG.md) for the multiplayer defect it carries.

Add `QuizEngineCore` and `QuizEngineGame`. Do not add `QuizEngineMultiplayer` unless the app implements a transport.

This example deliberately shows:

- app-owned `StarterQuizVariantDefinition`;
- an explicit `.main` bundle and `starter_questions` resource;
- one shared `QuestionDataService` used to create `PlayerProgressManager` and sessions;
- app-owned localization and question resources;
- no-op analytics/purchase/haptic providers.

Replace the sample's IDs, strings, assets, question JSON, and UI before release. Keep your own IDs stable once users have progress.
