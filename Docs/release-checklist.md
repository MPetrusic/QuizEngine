# Release checklist

Before publishing a QuizEngine release:

- Update `CHANGELOG.md` with the exact version and behavior impact.
- Keep existing tags immutable. Documentation-only changes are a patch release.
- Run the package boundary scan and strict-concurrency test command from the README.
- Verify the public content-validation contract with deterministic package tests; it must remain opt-in and source-compatible.
- Build and test `Examples/StarterQuiz` on an iOS 17 simulator.
- Verify the README dependency declaration and every copyable setup snippet against the starter source.
- Perform a clean-consumer smoke test in a blank app outside this checkout: add the private remote at the exact candidate tag, configure an explicit resource/variant, build, and load questions.
- Tag the validated commit and push the branch and tag.

Consumer apps update intentionally: select an exact new tag, build, run tests, and manually verify any engine flow affected by the release notes. Before a content cutover or update, run `QuizContentValidator` against the variant categories, then run app-owned asset-catalog and editorial gates. Do not renumber or reuse released question IDs without an explicit migration.
