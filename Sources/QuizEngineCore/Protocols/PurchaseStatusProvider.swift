import Foundation

/// Protocol for reading purchase/premium status.
/// App provides an implementation reading from UserDefaults, StoreKit, or any other source.
public protocol PurchaseStatusProvider: AnyObject {
    var isPremium: Bool { get }
    var adsRemoved: Bool { get }
}
