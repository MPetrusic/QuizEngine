# Rules and economy configuration

`QuizVariantDefinition.rules` is the single product-policy input for reusable gameplay and economy behavior. Construct a validated `QuizRulesConfiguration` in app code and pass the same variant rules to question services, progress managers, solo sessions, and multiplayer sessions.

Configuration is immutable, `Sendable`, and intentionally not `Codable`. It describes bundled product behavior; it is not player progress and does not belong in the persistence schema.

## Rule inventory

| Domain | Configured behavior | Serbian-compatible default |
| --- | --- | --- |
| Fresh economy | initial coins | 100 |
| Solo rewards | coins per correct answer | 1 |
| Solo game | timer, lives | 15 seconds, 3 lives |
| Solo scoring | base points, streak points, threshold | 10, 20 after a 5-answer streak |
| Power-ups | costs, enabled modes, uses per session | 35/40/25/25, both solo modes, once each |
| Power-up effects | wrong answers removed, freeze duration, shield threshold | 2, 10 seconds, streak 5 |
| Extra life | coin cost, funding methods, uses | 50, coins or rewarded ad, once |
| Daily reward | ordered streak tiers | 10/15/20/30/40/50 |
| Rewarded ad | coin value, cooldown | 25 coins, 6 hours |
| Interstitial input | solo and multiplayer probability | 2/5 and 1/2 |
| Session construction | competitive/category/practice/multiplayer counts | all/all/20/15 |
| Practice selection | unanswered-question ratio | 0.8 |
| Multiplayer game | timer and tie threshold | 10,000 ms and 10 ms |
| Multiplayer scoring | faster/slower/tie/wrong | 10/0/5/-5 |
| Multiplayer answer reward | coins per correct answer | 1 |
| Multiplayer outcome reward | standard win/loss/draw/disconnect | 5/2/3/5 |
| Multiplayer Premium reward | Premium win/loss/draw/disconnect | 8/3/5/8 |
| Anti-farming | any-reward/outcome/full thresholds and partial divisor | 0/5/10 and 2 |

The default anti-farming values deliberately preserve released Serbian behavior: correct-answer coins accrue before question five, while outcome bonuses are absent below five, halved for questions 5–9, and full from question 10. A stricter variant can raise `minimumQuestionsForAnyReward` so no coins accrue before its threshold.

## Durable reward transactions

Rewarded-ad coins must be committed with `PlayerProgressManager.recordRewardedAdReward(_:)`. The app supplies a stable receipt ID and semantic reward version in `RewardedAdRewardRequest`, but the awarded amount is owned by `rules.economy.rewardAd.coinReward`. The submitted amount must match that rule; the manager checks cooldown from `rules.economy.rewardAd.cooldownSeconds` inside the same transaction that updates coins, total earned, cooldown date, and the receipt.

Premium bonus value is intentionally app-owned and is supplied in `PremiumBonusClaimRequest`. QuizEngine has no product catalog, so moving that amount into the engine rules would duplicate product policy that the app must already resolve with its authoritative entitlement state. The app supplies the stable receipt ID, semantic reward version, positive coin amount, and resolved entitlement; `claimPremiumBonus(_:)` atomically writes the balances, Premium-received flag, permanent claim identity, and receipt.

Both APIs return `RewardTransactionOutcome`: `.recorded`, `.alreadyRecorded`, `.conflictingReceipt`, `.ineligible`, `.rejected`, or `.persistenceFailed`. A persistence failure rolls back every in-memory field and is safe to retry with the same request.

Reward receipts use FIFO retention with a maximum of 256 entries. Premium claim version and fingerprint are persisted separately and never pruned, so evicting its receipt cannot make the one-time reward claimable again. A migrated legacy Premium-received flag also becomes a permanent claim identity.

## Validation

`QuizRulesConfiguration.init` throws `QuizRulesValidationError` deterministically. It rejects negative economy inputs, non-positive gameplay durations, malformed probabilities, missing or inconsistent power-up entries, daily-tier gaps/overlaps, invalid session limits, and multiplayer thresholds outside the configured match size.

Daily tiers must start at day 0, be ordered and contiguous, use unique IDs and non-empty labels, and cover through `Int.max`. Disabled power-ups retain persisted credits but cannot be activated; an enabled power-up requires at least one allowed mode and a positive session-use limit.

## Compatibility APIs

Existing variant, service, game, and multiplayer initializers use `.serbianCompatible`. Existing `PowerUp.cost`, `allStreakTiers`, and multiplayer static constants remain Serbian-default compatibility views. Custom consumers must read costs, timers, and other UI values from their variant or view-model `rules` instead of those static compatibility values.

`recordRewardAdWatched()`, `recordRewardAdWatched(coinsAwarded:)`, and `markPremiumBonusCoinsReceived()` remain deprecated source-compatibility bridges. The rewarded-ad bridges enforce cooldown and roll back a failed save, but have no durable callback identity and are not suitable for shipping reward fulfillment. The Premium bridge records only a permanent legacy claim marker; it does not award coins. New code must use the receipt-backed transaction APIs.

Explicit legacy session-size/count overloads continue to honor their arguments. The exact no-count overloads on a variant-created `QuestionDataService` use configured session values.

Transport retries, disconnect/pause timeouts, delayed UI presentation, clocks, random generators, schedulers, and multiplayer protocol negotiation are not product-balance rules. QE-4 routes rule time, selection, answer order, timers, restart, and lifecycle pause/resume through injected dependencies. Delayed presentation-state extraction remains QE-5, and multiplayer negotiation/payload hardening remains QE-6.

QE-5 exposes solo session phases/effects separately from SwiftUI presentation. The delay values remain compatibility behavior inside `QuizViewModel`; applications animate an emitted effect rather than implementing answer, timeout, skip, restart, exit, or terminal rules themselves. Multiplayer wire protocol hardening remains QE-6.
