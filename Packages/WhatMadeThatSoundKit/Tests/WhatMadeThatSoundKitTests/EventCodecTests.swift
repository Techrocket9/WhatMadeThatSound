import Foundation
import Testing
@testable import WhatMadeThatSoundKit

@Suite struct EventCodecTests {
    static let fullEvent = AudioEvent(
        kind: .outputStopped,
        timestamp: Date(timeIntervalSinceReferenceDate: 780_000_123.456_789),
        sessionID: 0xDEAD_BEEF_CAFE_F00D,
        sessionStart: Date(timeIntervalSinceReferenceDate: 780_000_100.25),
        flags: [.processExited, .alreadyPlayingAtMonitorStart],
        process: ProcessIdentity(
            pid: 4242,
            processName: "Google Chrome Helper",
            processBundleID: "com.google.Chrome.helper",
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Google Chrome Helper",
            responsiblePID: 4000,
            appName: "Google Chrome",
            appBundleID: "com.google.Chrome",
            appPath: "/Applications/Google Chrome.app"
        ),
        devices: [
            OutputDevice(name: "MacBook Pro Speakers", uid: "BuiltInSpeakerDevice"),
            OutputDevice(name: "Café AirPods 🎧", uid: "AA-BB-CC:output"),
        ],
        note: "ünïcødé note"
    )

    @Test func roundTripsEveryField() throws {
        let bytes = EventCodec.encode(Self.fullEvent)
        let decoded = try EventCodec.decode(bytes)
        #expect(decoded == Self.fullEvent)
    }

    @Test func roundTripsMinimalEvents() throws {
        for kind in AudioEventKind.allCases {
            let event = AudioEvent(kind: kind, timestamp: Date(timeIntervalSinceReferenceDate: 12.5))
            #expect(try EventCodec.decode(EventCodec.encode(event)) == event)
        }
    }

    @Test func roundTripsProcessWithOnlyRequiredFields() throws {
        let event = AudioEvent(
            kind: .outputStarted,
            timestamp: Date(timeIntervalSinceReferenceDate: 1),
            sessionID: 7,
            process: ProcessIdentity(pid: -1, processName: "afplay")
        )
        #expect(try EventCodec.decode(EventCodec.encode(event)) == event)
    }

    @Test func skipsUnknownFields() throws {
        var bytes = EventCodec.encode(Self.fullEvent)
        // A field from some future version: tag 200, 3 bytes of value.
        bytes += [200, 3, 1, 2, 3]
        #expect(try EventCodec.decode(bytes) == Self.fullEvent)
    }

    @Test func rejectsTruncatedPayloads() {
        let bytes = EventCodec.encode(Self.fullEvent)
        for length in [0, 1, 5, 17, bytes.count - 1] {
            #expect(throws: EventCodec.DecodingError.self) {
                try EventCodec.decode(Array(bytes.prefix(length)))
            }
        }
    }

    @Test func rejectsUnknownVersionAndKind() {
        var bytes = EventCodec.encode(Self.fullEvent)
        bytes[0] = 99
        #expect(throws: EventCodec.DecodingError.unsupportedVersion(99)) { try EventCodec.decode(bytes) }

        bytes = EventCodec.encode(Self.fullEvent)
        bytes[1] = 250
        #expect(throws: EventCodec.DecodingError.unknownKind(250)) { try EventCodec.decode(bytes) }
    }

    @Test func decodesFromArraySlice() throws {
        let bytes = [0xAA] + EventCodec.encode(Self.fullEvent) + [0xBB]
        let slice = bytes[1 ..< bytes.count - 1]
        #expect(try EventCodec.decode(slice) == Self.fullEvent)
    }

    @Test func typicalEventIsCompact() {
        #expect(EventCodec.encode(Self.fullEvent).count < 400)
    }
}
