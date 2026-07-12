import Foundation

/// Protocol for interstitial ad management.
/// App provides an implementation wrapping its ad SDK (e.g., GoogleMobileAds).
@MainActor
public protocol InterstitialAdProvider: AnyObject {
    func load()
    func isReady() -> Bool
    func show()
}

/// Protocol for reward ad management.
/// The `show(completion:)` callback replaces the FullScreenContentDelegate pattern —
/// the adapter handles the delegate internally and calls back with whether the user earned a reward.
@MainActor
public protocol RewardAdProvider: AnyObject {
    var isLoaded: Bool { get }
    func load()
    /// Shows the reward ad. Completion is called with `true` if the user earned the reward, `false` otherwise.
    func show(completion: @escaping @MainActor (Bool) -> Void)
}
