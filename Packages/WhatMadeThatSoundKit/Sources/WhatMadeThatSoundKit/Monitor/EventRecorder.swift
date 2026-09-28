import Foundation
import os

/// Writes events to the ring buffer on a background queue, batching events that
/// arrive together into one append, then announces the change to viewers.
///
/// Disk I/O never happens on the monitor's queue, so a slow disk (or a viewer
/// briefly holding the log's lock) can't delay the timestamps of new events.
public final class EventRecorder: AudioEventSink, @unchecked Sendable {
    private let log: RingLog
    private let notificationName: String?
    private let onCommit: (@Sendable ([AudioEvent]) -> Void)?
    private let queue = DispatchQueue(label: "com.matthewy.WhatMadeThatSound.recorder", qos: .utility)
    private let logger = Logger(subsystem: AppConstants.loggingSubsystem, category: "recorder")
    /// Upper bound on events held in memory while the disk refuses writes.
    private let maxPending = 10_000

    // Confined to `queue`.
    private var pending: [AudioEvent] = []
    private var flushScheduled = false

    /// - Parameters:
    ///   - notificationName: Darwin notification posted after each successful write.
    ///   - onCommit: Called on the recorder's queue with each batch that was written.
    public init(
        log: RingLog,
        notificationName: String? = AppConstants.logChangedNotification,
        onCommit: (@Sendable ([AudioEvent]) -> Void)? = nil
    ) {
        self.log = log
        self.notificationName = notificationName
        self.onCommit = onCommit
    }

    public func record(_ event: AudioEvent) {
        queue.async { [self] in
            pending.append(event)
            if pending.count > maxPending {
                let dropped = pending.count - maxPending
                pending.removeFirst(dropped)
                logger.error("Dropped \(dropped) unwritten events")
            }
            guard !flushScheduled else { return }
            flushScheduled = true
            // Runs after any other events already queued, so bursts share one write.
            queue.async { self.flushPending() }
        }
    }

    /// Writes everything recorded so far before returning.
    public func flush() {
        queue.sync { flushPending() }
    }

    private func flushPending() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        let batch = pending
        do {
            try log.append(batch.map(EventCodec.encode))
            pending.removeAll()
        } catch {
            // Keep the events; the next recorded event triggers another attempt.
            logger.error("Failed to write \(batch.count) events: \(String(describing: error), privacy: .public)")
            return
        }
        if let notificationName {
            DarwinNotification.post(notificationName)
        }
        onCommit?(batch)
    }
}
