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

`QuizRulesConfiguration` owns only deterministic ad-policy inputs: rewarded-ad coin value/cooldown and solo/multiplayer interstitial probabilities. Providers still own SDK readiness and presentation. Premium/ad-removal checks remain engine eligibility gates; a configured probability never bypasses an entitlement.

For rewarded ads, the app creates a stable request ID before presentation and retains it until the transaction reaches a durable outcome. Only the provider's earned callback may submit `RewardedAdRewardRequest` to `recordRewardedAdReward(_:)`; dismissal, failure, and non-earned callbacks must not submit it. Repeated callbacks and retries reuse the same ID and semantic reward version. Do not derive the ID from a timestamp. The request amount mirrors the configured reward-ad rule and cannot override it.

For a Premium welcome bonus, the app first resolves authoritative entitlement state, then submits one `PremiumBonusClaimRequest` to `claimPremiumBonus(_:)`. The app owns the positive bonus amount and semantic reward version because product catalog policy is outside QuizEngine. A verified StoreKit transaction ID may be used as the stable receipt ID, but the app passes only its string value and entitlement result; StoreKit types stay outside the package.

Treat `.recorded` and `.alreadyRecorded` as completed. A `.persistenceFailed` result is retryable with the identical request. Surface or log `.conflictingReceipt` as an integration/data error; `.ineligible` means cooldown, missing entitlement, or a previously claimed legacy bonus; `.rejected` means invalid input, a rules mismatch, or arithmetic overflow. Do not create a fresh receipt ID when retrying a failed or repeated callback.

Inject a seeded random generator into solo or multiplayer view models when interstitial eligibility decisions must be replayable. Identical entitlement state, eligibility rules, seed, and call order produce the same decision; provider readiness and presentation remain app-owned effects.

The starter app intentionally has no providers. It demonstrates that the engine runs without any vendor SDK.
