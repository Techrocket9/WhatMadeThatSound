import Foundation
import os
import WhatMadeThatSoundKit

// The background agent. launchd starts it (via SMAppService) with no arguments,
// which means `run`. The other commands are for inspecting the log by hand.

let usage = """
USAGE: WhatMadeThatSoundAgent [command] [options]

Commands:
  run                   Monitor audio output and record events (default; used by launchd)
  status                Show whether the agent is running and summarize the log
  dump [--limit N]      Print logged events, oldest first (the last N if --limit is given)
  follow                Print events as they are recorded (Ctrl-C to stop)
  generate-sample-log   Fill a log with synthetic events (requires --data-dir)
      [--events N]      Number of sessions to generate (default 2000)
      [--days N]        Spread them over the last N days (default 14)

Options:
  --data-dir PATH       Use PATH instead of ~/Library/Application Support/WhatMadeThatSound
  --capacity-mb N       Ring buffer size for a newly created log (default 200)
  --verbose             With run: also print each recorded event
"""

struct Options {
    var command = "run"
    var dataDirectory: String?
    var capacity = AppConstants.defaultLogCapacity
    var limit: Int?
    var verbose = false
    var sampleEvents = 2000
    var sampleDays = 14

    var paths: AppPaths {
        dataDirectory.map { AppPaths(directory: URL(filePath: $0, directoryHint: .isDirectory)) } ?? .standard()
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("WhatMadeThatSoundAgent: \(message)\n".utf8))
    exit(1)
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var remaining = arguments[...]
    func value(for flag: String) -> String {
        guard let value = remaining.popFirst() else { fail("\(flag) needs a value") }
        return value
    }
    func integer(for flag: String) -> Int {
        guard let number = Int(value(for: flag)), number > 0 else { fail("\(flag) needs a positive number") }
        return number
    }
    var sawCommand = false
    while let argument = remaining.popFirst() {
        switch argument {
        case "--data-dir": options.dataDirectory = value(for: argument)
        case "--capacity-mb": options.capacity = UInt64(integer(for: argument)) * 1024 * 1024
        case "--limit": options.limit = integer(for: argument)
        case "--events": options.sampleEvents = integer(for: argument)
        case "--days": options.sampleDays = integer(for: argument)
        case "--verbose", "-v": options.verbose = true
        case "--help", "-h", "help":
            print(usage)
            exit(0)
        case _ where argument.hasPrefix("-"):
            fail("unknown option \(argument)\n\n\(usage)")
        default:
            guard !sawCommand else { fail("unexpected argument \(argument)") }
            options.command = argument
            sawCommand = true
        }
    }
    return options
}

let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

switch options.command {
case "run":
    runAgent(options)
case "status":
    printStatus(options)
case "dump":
    dumpLog(options)
case "follow":
    followLog(options)
case "generate-sample-log":
    generateSampleLog(options)
default:
    fail("unknown command \(options.command)\n\n\(usage)")
}

// MARK: - run

/// Kept alive for the life of the process.
var signalSources: [DispatchSourceSignal] = []

@MainActor
func runAgent(_ options: Options) -> Never {
    let logger = Logger(subsystem: AppConstants.loggingSubsystem, category: "agent")
    let paths = options.paths
    do {
        try paths.createDirectoryIfNeeded()
    } catch {
        fail("cannot create \(paths.directory.path): \(error)")
    }

    let owner = AgentInstanceLock.Owner(
        pid: getpid(),
        executablePath: Bundle.main.executablePath ?? CommandLine.arguments[0],
        version: version,
        startedAt: Date()
    )
    // If another agent (e.g. one started by hand) is running, wait for it to exit
    // rather than recording every sound twice.
    let instanceLock: AgentInstanceLock
    do {
        if let lock = try AgentInstanceLock.acquire(at: paths.agentLockFile, owner: owner, wait: false) {
            instanceLock = lock
        } else {
            logger.notice("Another agent is running; waiting for it to exit")
            print("Another agent is already running; waiting for it to exit…")
            guard let lock = try AgentInstanceLock.acquire(at: paths.agentLockFile, owner: owner, wait: true) else {
                fail("could not acquire the agent lock")
            }
            instanceLock = lock
        }
    } catch {
        fail("cannot lock \(paths.agentLockFile.path): \(error)")
    }

    let log: RingLog
    do {
        log = try RingLog.openForWriting(url: paths.logFile, capacity: options.capacity)
    } catch {
        logger.error("Cannot open log: \(String(describing: error), privacy: .public)")
        fail("cannot open \(paths.logFile.path): \(error)")
    }

    let verbose = options.verbose
    let recorder = EventRecorder(log: log) { batch in
        guard verbose else { return }
        for event in batch {
            print(EventFormatter.line(for: event))
        }
        fflush(stdout)
    }
    let monitor = AudioActivityMonitor(sink: recorder, options: .init(note: "agent \(version), pid \(getpid())"))

    for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            logger.notice("Received signal \(signalNumber); stopping")
            monitor.stop()
            recorder.flush()
            instanceLock.release()
            DarwinNotification.post(AppConstants.agentStateChangedNotification)
            exit(0)
        }
        source.resume()
        signalSources.append(source)
    }

    monitor.start()
    recorder.flush()
    DarwinNotification.post(AppConstants.agentStateChangedNotification)
    logger.notice("Agent \(version, privacy: .public) recording to \(paths.logFile.path, privacy: .public)")
    if verbose {
        print("Recording to \(paths.logFile.path). Press Ctrl-C to stop.")
    }
    dispatchMain()
}

// MARK: - status / dump / follow

func printStatus(_ options: Options) {
    let paths = options.paths
    if let owner = AgentInstanceLock.currentOwner(at: paths.agentLockFile) {
        let started = owner.startedAt.formatted(date: .abbreviated, time: .standard)
        print("Agent:     running (pid \(owner.pid), version \(owner.version), since \(started))")
        if !owner.executablePath.isEmpty {
            print("           \(owner.executablePath)")
        }
    } else {
        print("Agent:     not running")
    }
    print("Log:       \(paths.logFile.path)")
    do {
        guard let log = try RingLog.openForReading(url: paths.logFile), let stats = try log.stats() else {
            print("           (no log yet)")
            return
        }
        let byteFormat = ByteCountFormatStyle(style: .file)
        print("Used:      \(stats.usedBytes.formatted(byteFormat)) of \(stats.capacity.formatted(byteFormat))")
        print("Records:   \(stats.recordCount)")
    } catch {
        fail("cannot read \(paths.logFile.path): \(error)")
    }
}

func readEvents(from log: RingLog, position: RingLog.Position?) throws -> (events: [AudioEvent], position: RingLog.Position) {
    let reader = try log.makeReader(from: position)
    var events: [AudioEvent] = []
    while let record = try reader.next() {
        if let event = try? EventCodec.decode(record.payload) {
            events.append(event)
        }
    }
    return (events, reader.position)
}

func dumpLog(_ options: Options) {
    do {
        guard let log = try RingLog.openForReading(url: options.paths.logFile) else {
            fail("no log at \(options.paths.logFile.path)")
        }
        var events = try readEvents(from: log, position: nil).events
        if let limit = options.limit {
            events = Array(events.suffix(limit))
        }
        for event in events {
            print(EventFormatter.line(for: event))
        }
    } catch {
        fail("cannot read log: \(error)")
    }
}

/// Prints new events each time the agent announces a write. Main queue only.
@MainActor
final class Follower {
    let url: URL
    var position: RingLog.Position?
    var observation: DarwinNotification.Observation?

    init(url: URL) {
        self.url = url
    }

    func printNew(limit: Int?) {
        do {
            guard let log = try RingLog.openForReading(url: url) else { return }
            let result = try readEvents(from: log, position: position)
            position = result.position
            for event in limit.map({ result.events.suffix($0) }) ?? result.events[...] {
                print(EventFormatter.line(for: event))
            }
            fflush(stdout)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        }
    }
}

var follower: Follower?

@MainActor
func followLog(_ options: Options) -> Never {
    let newFollower = Follower(url: options.paths.logFile)
    newFollower.printNew(limit: options.limit ?? 10)
    newFollower.observation = DarwinNotification.Observation(name: AppConstants.logChangedNotification, queue: .main) {
        MainActor.assumeIsolated { newFollower.printNew(limit: nil) }
    }
    follower = newFollower
    dispatchMain()
}

// MARK: - generate-sample-log

func generateSampleLog(_ options: Options) {
    guard options.dataDirectory != nil else {
        fail("generate-sample-log requires --data-dir so it never touches your real log")
    }
    let paths = options.paths
    do {
        try paths.createDirectoryIfNeeded()
        let log = try RingLog.openForWriting(url: paths.logFile, capacity: options.capacity)
        let events = SampleData.events(sessions: options.sampleEvents, days: options.sampleDays)
        for chunk in stride(from: 0, to: events.count, by: 1000) {
            try log.append(events[chunk ..< min(chunk + 1000, events.count)].map(EventCodec.encode))
        }
        DarwinNotification.post(AppConstants.logChangedNotification)
        print("Wrote \(events.count) events to \(paths.logFile.path)")
    } catch {
        fail("\(error)")
    }
}
