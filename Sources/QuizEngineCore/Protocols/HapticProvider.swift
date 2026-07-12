import Foundation

public enum HapticNotificationType: Sendable {
    case success, warning, error
}

public enum HapticImpactStyle: Sendable {
    case light, medium, heavy, soft, rigid
}

/// Protocol for haptic feedback.
/// App provides an implementation wrapping UIKit feedback generators.
public protocol HapticProvider: AnyObject {
    func notification(_ type: HapticNotificationType)
    func impact(_ style: HapticImpactStyle)
}
