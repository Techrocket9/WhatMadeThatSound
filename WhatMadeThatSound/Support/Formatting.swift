import Foundation
import WhatMadeThatSoundKit

enum Formatting {
    /// "Today", "Yesterday", "Monday, September 22" or "Monday, September 22, 2025".
    static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.wide).month(.wide).day())
        }
        return day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }

    static func time(_ date: Date, includingDate: Bool) -> String {
        date.formatted(date: includingDate ? .abbreviated : .omitted, time: .standard)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        EventFormatter.duration(seconds)
    }

    static func bytes(_ count: UInt64) -> String {
        count.formatted(.byteCount(style: .file))
    }
}

extension AudioSession {
    /// End time for sorting; sessions still playing sort as the most recent.
    var sortableEnd: Date { end ?? .distantFuture }

    /// Duration for sorting; sessions still playing sort as the longest.
    var sortableDuration: TimeInterval {
        if let duration { return duration }
        return status == .open ? .greatestFiniteMagnitude : -1
    }

    var processDescription: String {
        "\(source.identity.processName) (\(source.identity.pid))"
    }

    /// Tab-separated summary used when copying rows.
    var copyText: String {
        let identity = source.identity
        return [
            EventFormatter.timestamp(start),
            end.map { EventFormatter.timestamp($0) } ?? "",
            duration.map(Formatting.duration) ?? "",
            identity.displayName,
            identity.processName,
            String(identity.pid),
            identity.appBundleID ?? identity.processBundleID ?? "",
            devices.displayName,
        ].joined(separator: "\t")
    }
}
