import Foundation

/// Plain-text rendering of events and durations, for the command-line tools and
/// for copying from the viewer.
public enum EventFormatter {
    /// One line per event, e.g.
    /// `2026-09-28 10:32:15.120  ▶ started   Safari (com.apple.WebKit.GPU, pid 812) → MacBook Pro Speakers`
    public static func line(for event: AudioEvent, calendar: Calendar = .current) -> String {
        let time = timestamp(event.timestamp, calendar: calendar)
        let devices = event.devices.map(\.name).joined(separator: ", ")
        let process = event.process.map(describe) ?? "unknown process"
        let detail: String
        switch event.kind {
        case .outputStarted:
            let approximate = event.flags.contains(.alreadyPlayingAtMonitorStart) ? " (already playing)" : ""
            detail = "▶ started   \(process)\(devices.isEmpty ? "" : " → \(devices)")\(approximate)"
        case .outputStopped:
            let length = event.sessionStart.map { " after " + duration(event.timestamp.timeIntervalSince($0)) } ?? ""
            detail = "■ stopped   \(process)\(length)\(reason(event.flags))"
        case .outputDevicesChanged:
            detail = "↪ devices   \(process) → \(devices)"
        case .monitorStarted:
            let note = event.note.map { " (\($0))" } ?? ""
            detail = "● monitoring started\(note)\(devices.isEmpty ? "" : "; default output: \(devices)")"
        case .monitorStopped:
            detail = "○ monitoring stopped"
        case .defaultOutputDeviceChanged:
            detail = "⇄ default output → \(devices)"
        }
        return "\(time)  \(detail)"
    }

    /// "Safari (com.apple.WebKit.GPU, pid 812)" or "afplay (pid 4410)".
    public static func describe(_ process: ProcessIdentity) -> String {
        if let appName = process.appName, appName != process.processName {
            return "\(appName) (\(process.processName), pid \(process.pid))"
        }
        return "\(process.processName) (pid \(process.pid))"
    }

    /// "0.4 s", "42 s", "3 min 20 s", "1 h 5 min".
    public static func duration(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        if seconds < 10 {
            return String(format: "%.1f s", seconds)
        }
        let whole = Int(seconds.rounded())
        if whole < 60 {
            return "\(whole) s"
        }
        if whole < 3600 {
            let remainder = whole % 60
            return remainder == 0 ? "\(whole / 60) min" : "\(whole / 60) min \(remainder) s"
        }
        let minutes = (whole % 3600) / 60
        return minutes == 0 ? "\(whole / 3600) h" : "\(whole / 3600) h \(minutes) min"
    }

    /// `yyyy-MM-dd HH:mm:ss.SSS` in the calendar's time zone.
    public static func timestamp(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d.%03d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, (parts.nanosecond ?? 0) / 1_000_000
        )
    }

    private static func reason(_ flags: AudioEventFlags) -> String {
        if flags.contains(.monitorStopped) { return " (monitoring stopped)" }
        if flags.contains(.audioServerRestarted) { return " (audio server restarted)" }
        if flags.contains(.processExited) { return " (process exited)" }
        return ""
    }
}
