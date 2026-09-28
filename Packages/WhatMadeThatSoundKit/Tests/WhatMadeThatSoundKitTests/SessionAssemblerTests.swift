import Foundation
import Testing
@testable import WhatMadeThatSoundKit

@Suite struct SessionAssemblerTests {
    static let safari = ProcessIdentity(pid: 10, processName: "com.apple.WebKit.GPU", responsiblePID: 9,
                                        appName: "Safari", appBundleID: "com.apple.Safari", appPath: "/Applications/Safari.app")
    static let music = ProcessIdentity(pid: 20, processName: "Music", appName: "Music", appBundleID: "com.apple.Music")
    static let speakers = OutputDevice(name: "MacBook Pro Speakers", uid: "BuiltIn")
    static let airpods = OutputDevice(name: "AirPods", uid: "AirPods-UID")

    func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + seconds) }

    func started(_ id: UInt64, _ process: ProcessIdentity, at seconds: TimeInterval,
                 devices: [OutputDevice] = [speakers], flags: AudioEventFlags = []) -> AudioEvent {
        AudioEvent(kind: .outputStarted, timestamp: at(seconds), sessionID: id, sessionStart: at(seconds),
                   flags: flags, process: process, devices: devices)
    }

    func stopped(_ id: UInt64, _ process: ProcessIdentity, from start: TimeInterval, at seconds: TimeInterval,
                 devices: [OutputDevice] = [speakers], flags: AudioEventFlags = []) -> AudioEvent {
        AudioEvent(kind: .outputStopped, timestamp: at(seconds), sessionID: id, sessionStart: at(start),
                   flags: flags, process: process, devices: devices)
    }

    @Test func pairsStartsWithStops() throws {
        var assembler = SessionAssembler()
        assembler.apply(contentsOf: [
            started(1, Self.safari, at: 0),
            started(2, Self.music, at: 5),
            stopped(1, Self.safari, from: 0, at: 12.5),
        ])
        #expect(assembler.sessions.map(\.id) == [1, 2])
        let first = try #require(assembler.session(withID: 1))
        #expect(first.status == .ended)
        #expect(first.duration == 12.5)
        #expect(first.source.displayName == "Safari")
        #expect(first.devices.displayName == "MacBook Pro Speakers")
        let second = try #require(assembler.session(withID: 2))
        #expect(second.status == .open)
        #expect(second.end == nil)
    }

    @Test func reconstructsSessionWhoseStartWasEvicted() throws {
        var assembler = SessionAssembler()
        assembler.apply(stopped(7, Self.music, from: 100, at: 160, flags: .processExited))
        let session = try #require(assembler.session(withID: 7))
        #expect(session.start == at(100))
        #expect(session.end == at(160))
        #expect(session.status == .ended)
        #expect(session.flags.contains(.processExited))
    }

    @Test func monitorRestartInterruptsOpenSessions() throws {
        var assembler = SessionAssembler()
        assembler.apply(AudioEvent(kind: .monitorStarted, timestamp: at(0), devices: [Self.speakers]))
        assembler.apply(started(1, Self.safari, at: 1))
        #expect(assembler.monitorRunning)
        // Agent crashed; a new one started without having recorded a stop.
        assembler.apply(AudioEvent(kind: .monitorStarted, timestamp: at(50)))
        #expect(assembler.session(withID: 1)?.status == .interrupted)
        #expect(assembler.lastMonitorStart == at(50))

        assembler.apply(started(2, Self.music, at: 60))
        assembler.apply(AudioEvent(kind: .monitorStopped, timestamp: at(70)))
        #expect(assembler.session(withID: 2)?.status == .interrupted)
        #expect(assembler.monitorRunning == false)
    }

    @Test func accumulatesDevicesAcrossTheSession() throws {
        var assembler = SessionAssembler()
        assembler.apply(started(1, Self.music, at: 0, devices: []))
        assembler.apply(AudioEvent(kind: .outputDevicesChanged, timestamp: at(1), sessionID: 1, sessionStart: at(0),
                                   process: Self.music, devices: [Self.speakers]))
        assembler.apply(AudioEvent(kind: .outputDevicesChanged, timestamp: at(2), sessionID: 1, sessionStart: at(0),
                                   process: Self.music, devices: [Self.speakers, Self.airpods]))
        assembler.apply(stopped(1, Self.music, from: 0, at: 3, devices: [Self.airpods]))
        let session = try #require(assembler.session(withID: 1))
        #expect(session.devices.devices == [Self.speakers, Self.airpods])
        #expect(session.devices.displayName == "MacBook Pro Speakers, AirPods")
    }

    @Test func keepsSessionsSortedWhenStartsArriveOutOfOrder() {
        var assembler = SessionAssembler()
        assembler.apply(started(2, Self.music, at: 10))
        assembler.apply(started(1, Self.safari, at: 9.95)) // Recorded after its settle delay.
        assembler.apply(started(3, Self.safari, at: 20))
        assembler.apply(stopped(4, Self.music, from: 1, at: 30)) // Start long gone.
        #expect(assembler.sessions.map(\.id) == [4, 1, 2, 3])
        // The index stays correct after inserting in the middle.
        assembler.apply(stopped(2, Self.music, from: 10, at: 40))
        #expect(assembler.session(withID: 2)?.end == at(40))
        #expect(assembler.sessions.first { $0.id == 2 }?.status == .ended)
    }

    @Test func sharesSourcesAndDeviceListsBetweenSessions() {
        var assembler = SessionAssembler()
        for id in 1 ... 50 as ClosedRange<UInt64> {
            assembler.apply(started(id, Self.safari, at: Double(id)))
        }
        let first = assembler.sessions[0]
        #expect(assembler.sessions.allSatisfy { $0.source === first.source && $0.devices === first.devices })
        #expect(assembler.allSources.count == 1)
    }

    @Test func ignoresDuplicateStarts() {
        var assembler = SessionAssembler()
        assembler.apply(started(1, Self.safari, at: 0))
        assembler.apply(started(1, Self.safari, at: 0, flags: .alreadyPlayingAtMonitorStart))
        #expect(assembler.sessions.count == 1)
        #expect(assembler.sessions[0].flags.contains(.alreadyPlayingAtMonitorStart))
    }

    @Test func tracksDefaultOutputDevice() {
        var assembler = SessionAssembler()
        assembler.apply(AudioEvent(kind: .monitorStarted, timestamp: at(0), devices: [Self.speakers]))
        #expect(assembler.currentDefaultOutput == Self.speakers)
        assembler.apply(AudioEvent(kind: .defaultOutputDeviceChanged, timestamp: at(1), devices: [Self.airpods]))
        #expect(assembler.currentDefaultOutput == Self.airpods)
    }

    @Test func searchTextCoversNamesAndBundleIDs() {
        let source = SoundSource(identity: Self.safari)
        #expect(source.searchText.contains("safari"))
        #expect(source.searchText.contains("com.apple.webkit.gpu"))
        #expect(source.searchText.contains("com.apple.safari"))
    }
}
