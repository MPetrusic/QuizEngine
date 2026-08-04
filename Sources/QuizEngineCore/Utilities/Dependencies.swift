import Foundation

/// A source of wall-clock time owned by the application or a test.
public protocol QuizEngineClock: Sendable {
    var now: Date { get }
}

/// The production clock used when a consumer does not provide one.
public struct SystemQuizEngineClock: QuizEngineClock, Sendable {
    public init() {}

    public var now: Date { Date() }
}

/// A cancellable delayed operation scheduled by QuizEngine.
@MainActor
public protocol QuizEngineScheduledTask: AnyObject {
    func cancel()
}

/// Schedules delayed main-actor work owned by a game or multiplayer session.
@MainActor
public protocol QuizEngineScheduler: AnyObject {
    @discardableResult
    func schedule(
        after delay: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
    ) -> any QuizEngineScheduledTask
}

/// Production scheduler that preserves the existing main-queue timing behavior.
@MainActor
public final class MainQueueQuizEngineScheduler: QuizEngineScheduler {
    private final class ScheduledTask: QuizEngineScheduledTask {
        fileprivate var task: Task<Void, Never>?

        func cancel() {
            task?.cancel()
            task = nil
        }
    }

    nonisolated public init() {}

    @discardableResult
    public func schedule(
        after delay: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
    ) -> any QuizEngineScheduledTask {
        let scheduledTask = ScheduledTask()
        scheduledTask.task = Task { @MainActor [scheduledTask] in
            let delay = max(0, delay)
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            operation()
            scheduledTask.task = nil
        }
        return scheduledTask
    }
}
