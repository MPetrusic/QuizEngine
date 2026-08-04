# Optional multiplayer

Link `QuizEngineMultiplayer` only in apps that ship multiplayer. The package owns vendor-neutral messages, connection coordination, and quiz state. The app owns the transport.

Implement `MultiplayerTransport` in the app for the platform/service you choose, then attach or start that transport through `MultiplayerConnectionManager`. An inbound Game Center invite, nearby-device connection, or custom server connection must be converted into an app-owned transport before it reaches the package. Do not expose GameKit or MultipeerConnectivity types to QuizEngine.

For nearby-device multiplayer, the app configures its Bonjour service type, Local Network usage description, and any required privacy/capability declarations. For Game Center, the app configures authentication, leaderboard/matchmaking identifiers, and invite handling.

Use the Serbian app's GameKit and Multipeer adapters only as implementation examples. Copy the adapter pattern, not its Bonjour value, IDs, UI, or behavior assumptions.

Create host questions from `QuestionDataService(variant:)` so the configured multiplayer question count is applied, and pass the same `variant.rules` to both peers' `MultiplayerQuizViewModel`. QE-3 rules configure the round timer, tie threshold, scoring, answer coins, standard/Premium outcome bonuses, interstitial probability input, and anti-farming thresholds.

Inject the same deterministic inputs in tests: a seeded host RNG determines the transmitted match seed, that seed plus question index determines answer order, and the clock/scheduler pair determines timeout decisions. Timer rollback cannot increase remaining time. Pause, reconnect, and app background stop elapsed-time accounting; resuming starts from the preserved remainder.

Rules are not yet negotiated on the wire. Both peers must use the same bundled variant. Protocol/version negotiation, payload hardening, reconnect idempotence, and coordinator timeout policy belong to later multiplayer hardening work.
