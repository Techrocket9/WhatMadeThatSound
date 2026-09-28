import CoreAudio
import Foundation
import Testing
@testable import WhatMadeThatSoundKit

final class CollectingSink: AudioEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AudioEvent] = []

    func record(_ event: AudioEvent) {
        lock.withLock { events.append(event) }
    }

    var snapshot: [AudioEvent] {
        lock.withLock { events }
    }

    /// Waits (up to `timeout`) until `condition` holds for the recorded events.
    func wait(timeout: Duration = .seconds(5), until condition: ([AudioEvent]) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition(snapshot) { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition(snapshot)
    }
}

@Suite struct EventRecorderTests {
    @Test func writesBatchesAndPostsNotification() async throws {
        let directory = try TemporaryDirectory()
        let log = try RingLog.openForWriting(url: directory.file("events.ringlog"), capacity: 1 << 16)
        let name = "com.matthewy.WhatMadeThatSound.tests.\(UUID().uuidString)"
        let notified = CollectingSink()
        let observation = DarwinNotification.Observation(name: name, queue: .global()) {
            notified.record(AudioEvent(kind: .monitorStarted, timestamp: Date()))
        }
        #expect(observation != nil)

        let recorder = EventRecorder(log: log, notificationName: name)
        let events = (0 ..< 25).map { index in
            AudioEvent(kind: .outputStarted, timestamp: Date(timeIntervalSinceReferenceDate: Double(index)),
                       sessionID: UInt64(index + 1), process: ProcessIdentity(pid: 1, processName: "p\(index)"))
        }
        events.forEach(recorder.record)
        recorder.flush()

        let reader = try #require(try RingLog.openForReading(url: directory.file("events.ringlog")))
        let decoded = try reader.readAll().records.map { try EventCodec.decode($0.payload) }
        #expect(decoded == events)
        #expect(await notified.wait { !$0.isEmpty })
        observation?.cancel()
    }
}

/// Exercises the real Core Audio HAL: plays a silent sound with `afplay` and
/// checks that the monitor reports it. Skipped on machines without audio output.
@Suite(.serialized) struct AudioActivityMonitorTests {
    static var canPlayAudio: Bool {
        HAL.objectID(HAL.systemObject, kAudioHardwarePropertyDefaultOutputDevice) != nil
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/afplay")
    }

    @Test(.enabled(if: canPlayAudio), .timeLimit(.minutes(1)))
    func reportsProcessStartingAndStoppingOutput() async throws {
        let sink = CollectingSink()
        let monitor = AudioActivityMonitor(sink: sink)
        monitor.start()
        defer { monitor.stop() }

        let afplay = Process()
        afplay.executableURL = URL(filePath: "/usr/bin/afplay")
        // Volume 0: the output stream runs, but nothing is audible.
        afplay.arguments = ["-v", "0", "-t", "0.6", "/System/Library/Sounds/Submarine.aiff"]
        try afplay.run()
        let pid = afplay.processIdentifier
        afplay.waitUntilExit()

        let finished = await sink.wait { events in
            events.contains { $0.kind == .outputStopped && $0.process?.pid == pid }
        }
        #expect(finished)

        let events = sink.snapshot.filter { $0.process?.pid == pid }
        #expect(events.map(\.kind) == [.outputStarted, .outputStopped])
        guard events.count == 2 else { return }
        let (start, stop) = (events[0], events[1])
        #expect(start.sessionID == stop.sessionID)
        #expect(stop.sessionStart == start.timestamp)
        #expect(start.process?.processName == "afplay")
        #expect(start.process?.executablePath == "/usr/bin/afplay")
        #expect(!start.devices.isEmpty)
        let duration = stop.timestamp.timeIntervalSince(start.timestamp)
        #expect(duration > 0.2 && duration < 5)
        #expect(sink.snapshot.first?.kind == .monitorStarted)
    }

    @Test(.enabled(if: canPlayAudio))
    func stopEndsOpenSessionsAndRecordsMonitorStopped() async throws {
        let sink = CollectingSink()
        let monitor = AudioActivityMonitor(sink: sink)
        monitor.start()

        let afplay = Process()
        afplay.executableURL = URL(filePath: "/usr/bin/afplay")
        afplay.arguments = ["-v", "0", "-t", "5", "/System/Library/Sounds/Submarine.aiff"]
        try afplay.run()
        defer { afplay.terminate() }
        let pid = afplay.processIdentifier

        let started = await sink.wait { events in
            events.contains { $0.kind == .outputStarted && $0.process?.pid == pid }
        }
        #expect(started)
        monitor.stop()

        let events = sink.snapshot
        let stop = events.last { $0.kind == .outputStopped && $0.process?.pid == pid }
        #expect(stop?.flags.contains(.monitorStopped) == true)
        #expect(events.last?.kind == .monitorStopped)
        #expect(monitor.activeSessionCount == 0)
    }
}
