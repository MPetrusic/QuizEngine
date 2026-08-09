# Optional multiplayer

Link `QuizEngineMultiplayer` only in apps that ship multiplayer. The package owns vendor-neutral messages, connection coordination, and quiz state. The app owns the transport.

Implement `MultiplayerTransport` in the app for the platform/service you choose, then attach or start that transport through `MultiplayerConnectionManager`. An inbound Game Center invite, nearby-device connection, or custom server connection must be converted into an app-owned transport before it reaches the package. Do not expose GameKit or MultipeerConnectivity types to QuizEngine.

For nearby-device multiplayer, the app configures its Bonjour service type, Local Network usage description, and any required privacy/capability declarations. For Game Center, the app configures authentication, leaderboard/matchmaking identifiers, and invite handling.

Use the Serbian app's GameKit and Multipeer adapters only as implementation examples. Copy the adapter pattern, not its Bonjour value, IDs, UI, or behavior assumptions.

Create host questions from `QuestionDataService(variant:)` so the configured multiplayer question count is applied, and pass the same `variant.rules` to both peers' `MultiplayerQuizViewModel`. QE-3 rules configure the round timer, tie threshold, scoring, answer coins, standard/Premium outcome bonuses, interstitial probability input, and anti-farming thresholds.

Inject the same deterministic inputs in tests: a seeded host RNG determines the transmitted match seed, that seed plus question index determines answer order, and the clock/scheduler pair determines timeout decisions. Timer rollback cannot increase remaining time. Pause, reconnect, and app background stop elapsed-time accounting; resuming starts from the preserved remainder.

For QE-6 hardened matches, implement the additive raw-payload members of `MultiplayerTransport`, start through the `matchConfiguration:` coordinator overload, and forward bytes unchanged. `MultiplayerMatchConfiguration` requires an app-supplied content version and analytics transport label. The package requires an exact content-version match and all QE-6 capabilities before configuration; it does not infer either value from an app bundle or hardcode a transport name.

## Hardened match configuration

`MultiplayerMatchConfiguration` also carries the content policy the match is played under: the expected question count, the canonical category IDs, and the multiplayer rules. Prefer `init(variant:contentVersion:analyticsTransportLabel:)`, which derives all three from the variant both peers already agreed on, so the wire policy cannot drift from `rules.sessions.multiplayerQuestionCount`, the variant's categories, or its scoring rules.

## Content validation

Wire content is held to the same structural rules as local content. `QuizQuestionStructureRules` in `QuizEngineCore` is the single definition of answer count, answer-text normalization, correct-answer count, difficulty bounds, and category membership; both `QuizContentValidator` and the multiplayer wire validator resolve against it.

A game configuration is refused unless the question count equals the configured count, question IDs are positive and unique, every question has exactly four nonblank normalized-distinct answers with exactly one correct answer, difficulty is within `1...3`, every category is nonblank, non-duplicated, and canonical for the variant, and every byte bound passes. The host validates before transmitting and the guest validates before publishing `receivedGameConfig`, so an unplayable match ends at the sender rather than after the guest has loaded it.

Round payloads are validated against the active round and the actual question, not against broad constants. An answer index must be a real position in that question's answers or a skip/timeout sentinel, and a response time must fall within the configured round timer. A question result must name a real answer index, award points the configured scoring rules can produce for the reported correctness and response times, and carry running totals that are exactly the previous totals plus the points awarded that round. A terminal payload may not restate scores that rounds already committed.

## Ordering policy

Every envelope a peer sends is numbered contiguously from zero, and the receiver processes them in that order through a bounded contiguous-sequence buffer:

- a sequence below the next expected one has already been committed and is ignored, as is a repeated message ID;
- the next expected sequence is committed immediately, then buffered successors drain in order;
- a higher sequence is buffered until the gap closes, for at most 16 messages and a gap of at most 32;
- a wider gap, a full buffer, or a gap unresolved within five seconds ends the match deterministically;
- the buffer is cleared when the match ends or a new match begins.

Because nothing reaches a payload handler out of order, pause and resume, round transitions, and terminal processing need no per-payload reordering tolerance. A resume that does not follow a pause is ignored rather than moving the session into a phase it never left.

## Terminal outcomes

`MultiplayerWireCodec` rejects payloads above 256 KiB and empty payloads. The coordinator validates sender, match ID, replay ID, sequence order, phase, round index, bounded fields, and host/guest authority before mutating state. Duplicate, stale, and future-round inputs are ignored; a malformed payload, an invalid configuration, an impossible round payload, a message from the wrong role, a round payload before any configuration, an unresolved ordering gap, an elapsed phase deadline, or a refused transport send ends the match once with a typed `MultiplayerSessionFailure`. The first terminal outcome is authoritative, cancels every scheduled callback, and cannot be replaced by a late event or affect a subsequent match. Legacy typed-message transports remain source-compatible but are not a hardened path.

Configuration and ready deadlines end the match directly with `MultiplayerSessionFailure.timedOut`. A pause deadline and an exhausted question-result retry escalate to a disconnect, which terminates once after its grace period. Ready and question-result deadlines retry twice before escalating.

## Terminal commit and retry

Supply the shared `PlayerProgressManager` to `MultiplayerQuizViewModel`. A terminal result is not applied by a boolean "already handled" flag; it moves through an explicit commit state that the app can observe on `terminalCommitState`:

| State | Meaning |
| --- | --- |
| `idle` | No terminal record has been prepared. |
| `pending(record)` | Immutable terminal data exists but is **not** durably committed. |
| `committing(record)` | A commit attempt is in flight. |
| `committed(receiptID:)` | The durable receipt exists. |

Entering `pending` builds one immutable `MultiplayerTerminalRecord` from stable inputs only — match ID, local role, terminal reason, both final scores, questions completed and correct, awarded coins, and response times — plus a canonical fingerprint derived from exactly those fields. The fingerprint never incorporates localized strings, `String(describing:)`, object identity, the current time, or view state, so the same match produces the same fingerprint in a different process, locale, or time zone.

The state becomes `committed` only after the manager reports `.recorded` or `.alreadyRecorded`. This is the property v0.2.0 lacked: there, the guard was set before the save, so a failed write lost the result permanently.

**A retryable persistence failure returns the record to `pending` and keeps it.** Call `retryPendingTerminalCommit()` to attempt it again; an automatic retry, if used, runs through the injected `QuizEngineScheduler` under a bounded policy, never an unbounded loop. Coins, statistics, and the receipt are written in one `PlayerProgressManager` transaction, so a failed save leaves no partial mutation in memory or on disk.

Duplicate delivery is harmless at every point. Before commit it is folded into the same pending record; during commit it does not start a second write; after commit it converges to `.alreadyRecorded` without a second award. A recreated view model that receives the same record and stable match ID reaches `.alreadyRecorded` rather than awarding again.

A **conflicting receipt** — the same match ID already recorded under a different fingerprint — is surfaced as a typed failure and never applied. It is not silently treated as a duplicate, because a mismatch means either tampering or a nondeterministic terminal calculation, and both need to be visible.

Completion analytics sit on the durable receipt boundary: emitted once after `.recorded`, never after `.alreadyRecorded`, and never on a failed or conflicting commit.

Permanently invalid input and arithmetic overflow are rejected outright rather than retried, and leave progress untouched.
