# Question JSON

`QuestionDataService` always needs an explicit bundle and filename. If the resource is `Resources/my_questions.json`, configure `fileName: "my_questions"`; do not include `.json` and do not rely on `Bundle.main` inside the package.

```json
{
  "questions": [
    {
      "id": 1,
      "question": "Which planet is known as the Red Planet?",
      "answers": [
        { "text": "Mars", "correct": true },
        { "text": "Venus", "correct": false }
      ],
      "categories": ["science"],
      "difficulty": 1,
      "imageName": "mars",
      "description": "Mars appears red because of iron oxide."
    }
  ]
}
```

Required for new content: top-level `questions`, and for every question a stable positive integer `id`, `question`, `answers`, and `categories`. Each category string must exactly match a declared variant category. Supply exactly four non-empty answers with exactly one correct answer, and set `difficulty` to `1...3`. `imageName` and `description` are optional.

Use `QuizContentValidator.validate(_:categories:)` in consumer CI after decoding content. It reports all structural failures in stable input order. Answer uniqueness ignores repeated whitespace and case, so values such as `"New York"` and `"  new\\t york "` are duplicates. The validator intentionally does not inspect question text, image names, asset catalogs, or editorial metadata.

The decoder accepts legacy singular `category` and absent IDs for old data. Do not use either in a new app: absent IDs decode as `0`, which destroys progress and seen-question tracking when repeated.

Question IDs are persisted in seen/correct-answer sets. Never rename or reuse an ID for a different question after release. Adding new IDs is safe. Changing a question's category changes progress semantics and should be treated as a content migration.

Images named by `imageName` are app resources. Verify that any non-empty image name exists with correct case in the same app target/bundle as the question JSON; this is outside QuizEngine because the package cannot inspect an app asset catalog.
