import Foundation

/// Plausible, deterministic synthetic events for previews, UI testing and
/// performance testing with large logs.
public enum SampleData {
    public static let speakers = OutputDevice(name: "MacBook Pro Speakers", uid: "BuiltInSpeakerDevice")
    public static let airPods = OutputDevice(name: "AirPods Pro", uid: "00-11-22-33-44-55:output")
    public static let display = OutputDevice(name: "Studio Display Speakers", uid: "StudioDisplay:output")

    struct Profile {
        var identity: ProcessIdentity
        var weight: Int
        /// Range of session lengths in seconds.
        var duration: ClosedRange<Double>
    }

    static let profiles: [Profile] = [
        Profile(identity: ProcessIdentity(pid: 812, processName: "com.apple.WebKit.GPU", processBundleID: "com.apple.WebKit.GPU",
                                          executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc/Contents/MacOS/com.apple.WebKit.GPU",
                                          responsiblePID: 790, appName: "Safari", appBundleID: "com.apple.Safari", appPath: "/Applications/Safari.app"),
                weight: 12, duration: 3 ... 900),
        Profile(identity: ProcessIdentity(pid: 1403, processName: "Google Chrome Helper", processBundleID: "com.google.Chrome.helper",
                                          executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/131.0.6778.86/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper",
                                          responsiblePID: 1398, appName: "Google Chrome", appBundleID: "com.google.Chrome", appPath: "/Applications/Google Chrome.app"),
                weight: 10, duration: 2 ... 1200),
        Profile(identity: ProcessIdentity(pid: 655, processName: "Music", processBundleID: "com.apple.Music",
                                          executablePath: "/System/Applications/Music.app/Contents/MacOS/Music",
                                          appName: "Music", appBundleID: "com.apple.Music", appPath: "/System/Applications/Music.app"),
                weight: 4, duration: 120 ... 3600),
        Profile(identity: ProcessIdentity(pid: 2011, processName: "Slack Helper", processBundleID: "com.tinyspeck.slackmacgap.helper",
                                          executablePath: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper",
                                          responsiblePID: 2004, appName: "Slack", appBundleID: "com.tinyspeck.slackmacgap", appPath: "/Applications/Slack.app"),
                weight: 14, duration: 0.3 ... 1.5),
        Profile(identity: ProcessIdentity(pid: 3120, processName: "zoom.us", processBundleID: "us.zoom.xos",
                                          executablePath: "/Applications/zoom.us.app/Contents/MacOS/zoom.us",
                                          appName: "zoom.us", appBundleID: "us.zoom.xos", appPath: "/Applications/zoom.us.app"),
                weight: 2, duration: 600 ... 3600),
        Profile(identity: ProcessIdentity(pid: 505, processName: "Messages", processBundleID: "com.apple.MobileSMS",
                                          executablePath: "/System/Applications/Messages.app/Contents/MacOS/Messages",
                                          appName: "Messages", appBundleID: "com.apple.MobileSMS", appPath: "/System/Applications/Messages.app"),
                weight: 8, duration: 0.4 ... 1.2),
        Profile(identity: ProcessIdentity(pid: 871, processName: "systemsoundserverd", processBundleID: "systemsoundserverd",
                                          executablePath: "/usr/sbin/systemsoundserverd"),
                weight: 10, duration: 0.2 ... 1.0),
        Profile(identity: ProcessIdentity(pid: 4410, processName: "afplay", executablePath: "/usr/bin/afplay",
                                          responsiblePID: 4300, appName: "Terminal", appBundleID: "com.apple.Terminal",
                                          appPath: "/System/Applications/Utilities/Terminal.app"),
                weight: 2, duration: 0.5 ... 4),
        Profile(identity: ProcessIdentity(pid: 2890, processName: "Spotify", processBundleID: "com.spotify.client",
                                          executablePath: "/Applications/Spotify.app/Contents/MacOS/Spotify",
                                          appName: "Spotify", appBundleID: "com.spotify.client", appPath: "/Applications/Spotify.app"),
                weight: 3, duration: 180 ... 5400),
    ]

    /// Events for `sessions` playback sessions spread over the `days` days before `now`,
    /// in the order an agent would have logged them.
    public static func events(sessions: Int, days: Int, now: Date = Date(), seed: UInt64 = 0x5EED) -> [AudioEvent] {
        var random = SplitMix64(seed: seed)
        let totalWeight = profiles.reduce(0) { $0 + $1.weight }
        let span = Double(days) * 86_400
        let begin = now.addingTimeInterval(-span)

        var events: [AudioEvent] = [
            AudioEvent(kind: .monitorStarted, timestamp: begin.addingTimeInterval(-1), devices: [speakers], note: "sample data"),
        ]
        for _ in 0 ..< sessions {
            var pick = Int(random.next() % UInt64(totalWeight))
            let profile = profiles.first { pick -= $0.weight; return pick < 0 } ?? profiles[0]
            // Cluster activity in waking hours so the day view looks natural.
            let day = Double(random.next() % UInt64(max(days, 1)))
            let hour = 8 + Double(random.next() % 1500) / 100
            var start = begin.addingTimeInterval(day * 86_400 + hour * 3600)
            if start > now { start = now.addingTimeInterval(-Double(random.next() % 3600)) }
            let length = profile.duration.lowerBound
                + (profile.duration.upperBound - profile.duration.lowerBound) * pow(random.unit(), 3)
            let end = start.addingTimeInterval(length)
            let device = random.next() % 5 == 0 ? airPods : (random.next() % 7 == 0 ? display : speakers)
            let id = random.next() | 1
            events.append(AudioEvent(kind: .outputStarted, timestamp: start, sessionID: id, sessionStart: start,
                                     process: profile.identity, devices: [device]))
            if end < now {
                events.append(AudioEvent(kind: .outputStopped, timestamp: end, sessionID: id, sessionStart: start,
                                         process: profile.identity, devices: [device]))
            }
        }
        events.sort { $0.timestamp < $1.timestamp }
        return events
    }
}

/// Small, fast, seedable PRNG so sample data is reproducible.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}
