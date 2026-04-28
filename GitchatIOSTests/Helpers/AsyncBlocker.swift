import Foundation

/// A test helper that allows an async task to be paused until explicitly
/// released. Use `wait()` inside a stub to block the stub's execution;
/// call `release()` from the test body when you want the stub to proceed.
///
/// Usage:
/// ```swift
/// let block = AsyncBlocker()
/// mock.sendStub = { _, _, _, _, _ in
///     await block.wait()
///     return someMessage
/// }
/// // ... enqueue message, wait for .sending state ...
/// block.release()
/// ```
final class AsyncBlocker: @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Never>?
    private let lock = NSLock()

    func wait() async {
        await withCheckedContinuation { c in
            lock.lock()
            self.continuation = c
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
