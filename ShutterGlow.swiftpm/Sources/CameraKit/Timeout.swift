import Foundation

public enum TimeoutError: Error {
    case timedOut
}

/// Races `operation` against a deadline. Network.framework reads have no
/// built-in timeout of their own — a connection that goes silently dead
/// (Wi-Fi drops out of range, no clean FIN/RST) leaves a pending `receive`
/// callback waiting forever. Without an outer race like this, that hang
/// propagates straight into the UI with no way out.
public func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError.timedOut
        }
        guard let result = try await group.next() else {
            throw TimeoutError.timedOut
        }
        group.cancelAll()
        return result
    }
}
