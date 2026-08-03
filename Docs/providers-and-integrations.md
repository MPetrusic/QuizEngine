# Providers and vendor integrations

The package exposes protocols so app code can connect services without importing their SDKs into QuizEngine.

| Protocol | App responsibility |
| --- | --- |
| `AnalyticsProvider` | analytics events; Firebase is one possible implementation |
| `InterstitialAdProvider` / `RewardAdProvider` | load/show ads and callback handling |
| `PurchaseStatusProvider` | report premium/ad-removal state from StoreKit or app storage |
| `LeaderboardProvider` | submit a score to Game Center or another service |
| `HapticProvider` | map engine haptic events to UIKit feedback |

All provider instances are optional. Start with no provider or no-op adapters while building the app; add a real adapter only when its SDK and capability are configured in the app target.

Power-up analytics can implement `logPowerUpUsed(type:fundingSource:coinsSpent:)` to distinguish free-credit use from coin spending. Existing adapters that only implement `logPowerUpUsed(type:coinsSpent:)` remain compatible: the enriched default callback forwards the actual amount, including zero for a free credit.

Keep SDK imports, Firebase plist, AdMob app/unit IDs, StoreKit product IDs, Game Center leaderboard IDs, privacy text, entitlements, and purchase restoration in the app. The package must remain vendor-neutral.

The starter app intentionally has no providers. It demonstrates that the engine runs without any vendor SDK.
