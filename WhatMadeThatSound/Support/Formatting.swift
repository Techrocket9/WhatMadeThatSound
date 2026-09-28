import Foundation
import WhatMadeThatSoundKit

enum Formatting {
    /// "Today", "Yesterday", "Mon, Sep 22" or "Mon, Sep 22, 2025".
    static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let format = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if calendar.isDate(day, equalTo: Date(), toGranularity: .year) {
            return day.formatted(format)
        }
        return day.formatted(format.year())
    }

    /// "11:35:38 AM"
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    /// "Sep 27, 11:35:38 AM", with the year only when it isn't this year.
    static func dayAndTime(_ date: Date, calendar: Calendar = .current) -> String {
        let format = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute().second()
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return date.formatted(format)
        }
        return date.formatted(format.year())
    }

    static func duration(_ seconds: TimeInterval) -> String {
        EventFormatter.duration(seconds)
    }

    /// Binary units, so the 200 MiB buffer reads as "200 MB".
    static func bytes(_ count: UInt64) -> String {
        count.formatted(.byteCount(style: .memory))
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
