# Variant definitions and content

Every app defines one `QuizVariantDefinition`. Its initializer throws early when content configuration is invalid; fail startup clearly rather than silently shipping a broken variant.

```swift
enum MyQuizVariant {
    static let categories: [QuizCategoryDefinition] = [
        .init(
            id: "science",
            displayNameKey: "quiz.category.science",
            iconName: "atom",
            displayOrder: 0,
            unlockRequirement: .free
        ),
        .init(
            id: "history",
            displayNameKey: "quiz.category.history",
            iconName: "book.closed.fill",
            displayOrder: 1,
            unlockRequirement: .coins(amount: 100)
        )
    ]

    static let achievements: [AchievementDefinition] = [
        .init(
            id: "first_game",
            type: .special,
            coinReward: 5,
            rule: .lifetimeGames(minimum: 1)
        )
    ]
}
```

Add a validated `QuizRulesConfiguration` when product behavior differs from the Serbian-compatible defaults:

```swift
let variant = try QuizVariantDefinition(
    categories: MyQuizVariant.categories,
    achievements: MyQuizVariant.achievements,
    questionResource: .init(bundle: .main, fileName: "questions"),
    rules: MyQuizVariant.rules
)
let questions = QuestionDataService(variant: variant)
```

See [Rules and economy configuration](rules-and-economy.md) for the complete inventory and validation contract. The initializer without `rules` remains source-compatible and selects `.serbianCompatible`.

`id` values must be lowercase, non-empty, unique, and permanent after release. Category display orders must be unique. The package sorts categories by display order.

## Consumer content gate

After decoding the configured question resource, run the package validator against the same categories used to construct the variant:

```swift
let content = try questions.getQuestionData()
let validation = QuizContentValidator.validate(content, categories: variant.categories)
precondition(validation.isValid, "Invalid quiz content: \(validation.issues)")
```

`QuizContentValidator` checks structural rules only: positive unique question IDs, declared categories, exactly four non-empty distinct answers, exactly one correct answer, and difficulty `1...3`. It does not load resources, mutate the question service, inspect app assets, or validate editorial policy. Keep asset-catalog, source, approval, and distribution checks in consumer CI.

Question IDs are migration identifiers after release. Run the content gate before a cutover or content update, and never renumber or reuse a released ID. Use the app-owned migration plan and `PlayerProgressImportRequest` for any persistence transition.

## Category unlock rules

- `.free`
- `.questionsCorrect(count:)`
- `.categoryCompletion(categoryID:percentage:)`
- `.coins(amount:)`
- `.anyOf([...])`

Unlock category references must point at a declared category. Coin and question thresholds must be positive; completion percentages must be in `1...100`; `anyOf` cannot be empty.

## Achievement rules

- `playStreak`, `bestScore`, `bestAnswerStreak`
- `anyCategoryCorrect`, `categoryCorrect`, `categoriesCorrect`
- `lifetimeGames`, `lifetimeQuestions`, `totalCoinsEarned`
- `powerUpTypesUsed`, `lifetimePowerUpsUsed`
- `comeback`, `localHour`

All thresholds are positive. Category references must exist. `categoriesCorrect` cannot ask for more categories than the variant declares. A local-hour rule uses `startInclusive` in `0..<24`, `endExclusive` in `1...24`, and requires start before end.

## Localization and assets

Category definitions carry `displayNameKey`. Achievement definitions default to `achievement.<id>.name` and `achievement.<id>.description`, unless explicit keys are supplied. The app owns all corresponding localized strings. Icons are SF Symbol names or app-resolved names selected by the app UI; non-empty icon names are required.

Do not use display text as an ID. Display text changes; stored IDs must not.
