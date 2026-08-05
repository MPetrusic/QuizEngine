# Release checklist

Before publishing a QuizEngine release:

- Update `CHANGELOG.md` with the exact version and behavior impact.
- Keep existing tags immutable. Documentation-only changes are a patch release.
- Run the package boundary scan and strict-concurrency test command from the README.
- Verify the public content-validation contract with deterministic package tests; it must remain opt-in and source-compatible.
- Build and test `Examples/StarterQuiz` on an iOS 17 simulator. Its bundled-content test must call `QuizContentValidator` directly rather than duplicate structural checks.
- Verify the README dependency declaration and every copyable setup snippet against the starter source.
- Before tagging, build/test StarterQuiz plus isolated AmericanQuiz and SerbianQuiz copies against the local candidate. Keep production consumer checkouts and their pins untouched.
- Perform a clean-consumer smoke test in a blank app outside this checkout: add the public remote at the exact published tag, configure an explicit resource/variant, build, load questions, and call `QuizContentValidator`.
- Tag the validated commit and push the branch and tag.

Consumer apps update intentionally: select an exact new tag, build, run tests, and manually verify any engine flow affected by the release notes. Before a content cutover or update, run `QuizContentValidator` against the variant categories, then run app-owned asset-catalog and editorial gates. Do not renumber or reuse released question IDs without an explicit migration.
