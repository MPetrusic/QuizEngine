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
        private final class CancellationState: @unchecked Sendable {
            var isCancelled = false
        }

        fileprivate let workItem: DispatchWorkItem
        private let cancellationState: CancellationState

        init(operation: @escaping @MainActor () -> Void) {
            let cancellationState = CancellationState()
            self.cancellationState = cancellationState
            self.workItem = DispatchWorkItem { [cancellationState] in
                guard !cancellationState.isCancelled else { return }
                operation()
            }
        }

        func cancel() {
            cancellationState.isCancelled = true
            workItem.cancel()
        }
    }

    nonisolated public init() {}

    @discardableResult
    public func schedule(
        after delay: TimeInterval,
        _ operation: @escaping @MainActor () -> Void
    ) -> any QuizEngineScheduledTask {
        let task = ScheduledTask(operation: operation)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: task.workItem
        )
        return task
    }
}
