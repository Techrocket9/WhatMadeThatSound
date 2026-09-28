import Dispatch
import notify

/// System-wide notifications (`notify(3)`) used to tell the viewer that the
/// agent wrote to the log, without either side polling.
public enum DarwinNotification {
    public static func post(_ name: String) {
        notify_post(name)
    }

    /// Delivers a named notification to `handler` on `queue` until cancelled or released.
    public final class Observation: @unchecked Sendable {
        private var token: Int32 = 0
        private var isActive = false

        public init?(name: String, queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
            let status = notify_register_dispatch(name, &token, queue) { _ in handler() }
            guard status == NOTIFY_STATUS_OK else { return nil }
            isActive = true
        }

        public func cancel() {
            guard isActive else { return }
            isActive = false
            notify_cancel(token)
        }

        deinit {
            cancel()
        }
    }
}
