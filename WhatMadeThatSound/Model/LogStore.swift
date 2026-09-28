import Foundation
import Observation
import os
import WhatMadeThatSoundKit

/// The viewer's copy of the event log, kept up to date as the agent writes.
///
/// Loads the whole log once in the background, then reads only new records
/// whenever the agent posts its "log changed" Darwin notification.
@MainActor
@Observable
final class LogStore {
    enum Selection: Hashable {
        case all
        case day(Date)
    }

    struct Day: Identifiable, Hashable {
        /// Start of the day.
        let id: Date
        /// Sessions starting on this day that match the current search.
        let count: Int
    }

    /// All sessions, sorted by start time.
    private(set) var assembler = SessionAssembler()
    private(set) var days: [Day] = []
    /// Sessions for the current selection and search, in `sortOrder`.
    private(set) var displayedSessions: [AudioSession] = []
    /// True when "All" was capped at `allSessionsDisplayLimit`.
    private(set) var isDisplayTruncated = false
    private(set) var matchingSessionCount = 0
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var stats: RingLog.Stats?

    var selection: Selection? = .all {
        didSet { if selection != oldValue { updateDisplayedSessions() } }
    }

    var searchText = "" {
        didSet { if searchText != oldValue { updateDays(); updateDisplayedSessions() } }
    }

    var sortOrder: [KeyPathComparator<AudioSession>] = [KeyPathComparator(\.start, order: .reverse)] {
        didSet { updateDisplayedSessions() }
    }

    /// Showing hundreds of thousands of rows at once helps no one; pick a day to see more.
    static let allSessionsDisplayLimit = 5_000

    let paths: AppPaths
    private var position: RingLog.Position?
    private var observation: DarwinNotification.Observation?
    private var isRefreshing = false
    private var needsRefresh = false
    private var calendarObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: AppConstants.loggingSubsystem, category: "viewer")

    init(paths: AppPaths = .standard()) {
        self.paths = paths
    }

    /// Loads the log and starts following changes.
    func start() {
        guard observation == nil else { return }
        observation = DarwinNotification.Observation(name: AppConstants.logChangedNotification, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Day boundaries move at midnight and when the time zone changes.
        calendarObserver = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDays()
                self?.updateDisplayedSessions()
            }
        }
        refresh()
    }

    /// Reads whatever the agent has written since the last read.
    func refresh() {
        guard !isRefreshing else {
            needsRefresh = true
            return
        }
        isRefreshing = true
        let url = paths.logFile
        let position = self.position
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try LogLoader.load(url: url, from: position) }
            }.value
            self.apply(result)
            self.isRefreshing = false
            if self.needsRefresh {
                self.needsRefresh = false
                self.refresh()
            }
        }
    }

    /// Deletes every event from the log (the agent keeps recording new ones).
    func clearLog() throws {
        guard let log = try RingLog.openExisting(url: paths.logFile) else { return }
        try log.clear()
        DarwinNotification.post(AppConstants.logChangedNotification)
    }

    // MARK: Applying loaded data

    private func apply(_ result: Result<LogLoader.Result, Error>) {
        switch result {
        case let .success(loaded):
            loadError = nil
            switch loaded.content {
            case let .full(assembler):
                self.assembler = assembler
            case let .incremental(events):
                guard !events.isEmpty else { break }
                assembler.apply(contentsOf: events)
            }
            position = loaded.position
            stats = loaded.stats
        case let .failure(error):
            logger.error("Could not read the log: \(String(describing: error), privacy: .public)")
            loadError = String(describing: error)
        }
        hasLoaded = true
        updateDays()
        updateDisplayedSessions()
    }

    // MARK: Derived state

    private var searchTokens: [String] {
        searchText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func updateDays() {
        let matcher = SessionMatcher(tokens: searchTokens)
        let calendar = Calendar.current
        var result: [Day] = []
        var currentDay: Date?
        var currentDayEnd = Date.distantPast
        var count = 0
        for session in assembler.sessions {
            if session.start >= currentDayEnd || currentDay == nil {
                if let currentDay, count > 0 {
                    result.append(Day(id: currentDay, count: count))
                }
                let day = calendar.startOfDay(for: session.start)
                currentDay = day
                currentDayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
                count = 0
            }
            if matcher.matches(session) { count += 1 }
        }
        if let currentDay, count > 0 {
            result.append(Day(id: currentDay, count: count))
        }
        days = result.reversed()

        // Keep the selection meaningful when a search hides the selected day.
        if case let .day(day) = selection, !days.contains(where: { $0.id == day }) {
            selection = days.first.map { .day($0.id) } ?? .all
        }
    }

    private func updateDisplayedSessions() {
        let matcher = SessionMatcher(tokens: searchTokens)
        let candidates: ArraySlice<AudioSession>
        switch selection {
        case let .day(day):
            let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
            candidates = assembler.sessions[sessionRange(from: day, to: end)]
        case .all, nil:
            candidates = assembler.sessions[...]
        }

        let matches = candidates.filter(matcher.matches)
        matchingSessionCount = matches.count
        var sorted: [AudioSession]
        if sortOrder == [KeyPathComparator(\.start, order: .reverse)] {
            sorted = matches.reversed() // Already sorted by start.
        } else {
            sorted = matches.sorted(using: sortOrder)
        }
        isDisplayTruncated = selection == .all && sorted.count > Self.allSessionsDisplayLimit
        if isDisplayTruncated {
            sorted = Array(sorted.prefix(Self.allSessionsDisplayLimit))
        }
        displayedSessions = sorted
    }

    /// Indices of sessions starting in `[from, to)`, found by binary search.
    private func sessionRange(from start: Date, to end: Date) -> Range<Int> {
        let sessions = assembler.sessions
        func firstIndex(notBefore date: Date) -> Int {
            var low = 0
            var high = sessions.count
            while low < high {
                let middle = (low + high) / 2
                if sessions[middle].start < date { low = middle + 1 } else { high = middle }
            }
            return low
        }
        return firstIndex(notBefore: start) ..< firstIndex(notBefore: end)
    }
}

/// Matches sessions against search tokens. Each token must appear in the
/// process/app description or the device names. Results are cached per shared
/// `SoundSource` / `OutputDeviceList`, so matching is cheap even for huge logs.
struct SessionMatcher {
    let tokens: [String]
    private let sourceCache = Cache<SoundSource>()
    private let deviceCache = Cache<OutputDeviceList>()

    init(tokens: [String]) {
        self.tokens = tokens
    }

    func matches(_ session: AudioSession) -> Bool {
        guard !tokens.isEmpty else { return true }
        let sourceMatches = sourceCache.value(for: session.source) { source in
            tokens.map { source.searchText.contains($0) }
        }
        let deviceMatches = deviceCache.value(for: session.devices) { devices in
            tokens.map { devices.searchText.contains($0) }
        }
        return zip(sourceMatches, deviceMatches).allSatisfy { $0 || $1 }
    }

    private final class Cache<Key: AnyObject> {
        private var storage: [ObjectIdentifier: [Bool]] = [:]

        func value(for key: Key, compute: (Key) -> [Bool]) -> [Bool] {
            let id = ObjectIdentifier(key)
            if let cached = storage[id] { return cached }
            let value = compute(key)
            storage[id] = value
            return value
        }
    }
}

/// Reads the log off the main thread.
enum LogLoader {
    struct Result: Sendable {
        enum Content: Sendable {
            /// A complete, freshly assembled log (first load, or the log was cleared/replaced).
            case full(SessionAssembler)
            /// Events appended since the previous read.
            case incremental([AudioEvent])
        }

        var content: Content
        var position: RingLog.Position?
        var stats: RingLog.Stats?
    }

    static func load(url: URL, from position: RingLog.Position?) throws -> Result {
        guard let log = try RingLog.openForReading(url: url) else {
            return Result(content: .full(SessionAssembler()), position: nil, stats: nil)
        }
        let reader = try log.makeReader(from: position)
        if reader.isContinuation {
            var events: [AudioEvent] = []
            while let record = try reader.next() {
                if let event = try? EventCodec.decode(record.payload) {
                    events.append(event)
                }
            }
            return Result(content: .incremental(events), position: reader.position, stats: try log.stats())
        } else {
            var assembler = SessionAssembler()
            while let record = try reader.next() {
                if let event = try? EventCodec.decode(record.payload) {
                    assembler.apply(event)
                }
            }
            return Result(content: .full(assembler), position: reader.position, stats: try log.stats())
        }
    }
}
