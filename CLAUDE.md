# CLAUDE.md — QuizEngine package

Guidance for agents working **on the QuizEngine package itself**. For consuming the package in an app, read [README.md](README.md) instead; it owns the integration story and the ownership boundary.

## Where you are, and why

This directory is a **standalone git repository** with its own history and release tags, checked out inside a consumer's tree. Three things share this folder tree and they are not the same project:

| Path | What it is | Git repo |
| --- | --- | --- |
| `/` (AmericanQuiz) | The app being built | AmericanQuiz |
| `SerbianQuizSwiftUI/` | The shipped Serbian app, kept here **on purpose** as a reference implementation | AmericanQuiz |
| `SerbianQuizSwiftUI/Packages/QuizEngine/` | This package | **QuizEngine (separate)** |

The Serbian app is present deliberately. It is the working proof of the behavior the engine is meant to generalize: when a question comes up about what a rule should do, what a real transport adapter looks like, or which behavior must survive extraction, read the Serbian implementation. AmericanQuiz is meant to resemble that core logic while supplying its own content, theme, and language. So the reading order for "should the engine do X?" is: engine tests → Serbian implementation → master plan.

Do not treat the Serbian app as a place to make engine changes, and do not copy its Bonjour service type, bundle IDs, Serbian Cyrillic strings, or asset names into the package.

### The git trap

`git log` at the AmericanQuiz root will **not** show engine work, and engine branches do not exist there. Before any `git` command, know which repo you are standing in:

```bash
git rev-parse --show-toplevel
```

Engine commits, branches, and the `v0.1.x`/`v0.2.x` tags live only in this directory's repo.

There is also a `CLAUDE.md` at `SerbianQuizSwiftUI/` that documents the **Serbian app**, not this package. Its folder layout, `project.pbxproj` rules, and Serbian-Cyrillic-only rule do not apply here.

## Commands

Run everything from this directory.

```bash
sh Scripts/verify.sh
```

That is the full package gate: boundary validation, the strict test suite, and a whitespace check. Run it before reporting any work complete. To run pieces individually:

```bash
sh Scripts/validate-package-boundaries.sh
```

```bash
swift test -Xswiftc -target -Xswiftc arm64-apple-macosx14.0 -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

Strict concurrency with warnings-as-errors is the standing bar. It currently passes; do not lower the flags to get a build through.

## Modules

| Target | Contents |
| --- | --- |
| `QuizEngineCore` | questions, progress, persistence, categories, unlocks, achievements, rules configuration, provider protocols |
| `QuizEngineGame` | single-player and practice state |
| `QuizEngineMultiplayer` | optional multiplayer state, wire protocol, coordinator |
| `QuizEngineTestSupport` | test fakes; a target, deliberately **not** a package product |

`QuizEngineGame` and `QuizEngineMultiplayer` both depend on Core and not on each other. Anything two of them need belongs in Core — that is why the shared question-structure rules live there rather than being defined twice.

## Testing conventions

`Tests/QuizEngineTestSupport/DeterministicTestSupport.swift` already provides what you need. Use it rather than inventing new doubles:

- `TestClock` — settable time, no real waiting.
- `TestScheduler` — deterministic ordered task queue with `advance(by:)`, `runNext()`, `runAll()`.
- `CancellationIgnoringTestScheduler` — delivers work *after* cancellation, to prove stale-callback guards actually hold.
- `FakeTransport` — multiplayer transport with raw-payload emission and injectable send failure.
- `FakePersistenceStore` — in-memory store with named failure-injection points (`replacePrimary`, `partialReplacePrimary`, `insufficientStorage`, …).
- `QuizEngineTestFixtures` — canonical valid questions and a valid variant.

Rules:

- **No wall-clock sleeps, ever.** Inject a clock and a scheduler. A test that waits on real time is a broken test, not a slow one.
- **One defect per fixture** in negative tests. Two bugs in one payload means the first guard fires and the second guard is never proven. Prefer a table of single-defect cases.
- **A unit test on a private helper does not close an integration defect.** If the bug lives in a coordinator or view-model path, the test must drive that path.
- Test files are already large. Add new cases near their concern and prefer table-driven cases over copy-pasted near-duplicates.

## Standing constraints

- **No vendor SDKs and no app configuration.** Firebase, Google Mobile Ads, StoreKit, GameKit, MultipeerConnectivity, their IDs, `Bundle.main`, and app-specific names are all out. The boundary script enforces this; it is not advisory.
- **Published tags are immutable.** Never move, delete, or recreate a released tag. Fixes ship as a new version.
- **Preserve source compatibility** unless a planning document explicitly replaces an API. Keep old entry points as deprecated bridges, and make sure the bridge is *safe* — keeping an unsafe legacy path does not close a blocker.
- **Do not change consumer pins to produce validation evidence.** Both apps resolve QuizEngine from its public GitHub release (AmericanQuiz on `0.1.3`, SerbianQuiz on `0.1.0`). Validate against isolated copies until a cutover is authorized.
- Rules and economy policy belong in `QuizRulesConfiguration`, owned by the variant — not in hardcoded constants. Some pre-extraction static constants still linger next to their configured equivalents (for example in `MultiplayerQuizViewModel`); the configuration is the source of truth.

## Planning documents

The authoritative work queue lives in the **AmericanQuiz** repo, not here:

- `Docs/AmericanQuizMasterPlan/00_MASTER_PLAN.md` — overall plan
- `Docs/AmericanQuizMasterPlan/03_FEATURE_AND_ENGINE_MAPPING.md` — the QE-1…QE-8 hardening requirements
- `Docs/AmericanQuizMasterPlan/06_QUALITY_AND_RELEASE.md` — release gates
- `Docs/AmericanQuizMasterPlan/17_QUIZENGINE_V0_2_0_BLOCKING_GAPS.md` — the open QEB-01…QEB-06 blockers

Where an older status document says an item is complete but the blocking-gaps handoff says it is open, **the handoff wins** until its acceptance criteria actually pass.

Package-level docs in `Docs/` describe behavior for consumers; update them in the same change that alters the behavior they describe.
