import Foundation

/// Protocol for leaderboard score submission.
/// App provides an implementation wrapping GameKit or other leaderboard service.
@MainActor
public protocol LeaderboardProvider: AnyObject {
    func submitScore(_ score: Int) async
}
