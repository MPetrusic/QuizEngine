# Optional multiplayer

Link `QuizEngineMultiplayer` only in apps that ship multiplayer. The package owns vendor-neutral messages, connection coordination, and quiz state. The app owns the transport.

Implement `MultiplayerTransport` in the app for the platform/service you choose, then attach or start that transport through `MultiplayerConnectionManager`. An inbound Game Center invite, nearby-device connection, or custom server connection must be converted into an app-owned transport before it reaches the package. Do not expose GameKit or MultipeerConnectivity types to QuizEngine.

For nearby-device multiplayer, the app configures its Bonjour service type, Local Network usage description, and any required privacy/capability declarations. For Game Center, the app configures authentication, leaderboard/matchmaking identifiers, and invite handling.

Use the Serbian app's GameKit and Multipeer adapters only as implementation examples. Copy the adapter pattern, not its Bonjour value, IDs, UI, or behavior assumptions.
