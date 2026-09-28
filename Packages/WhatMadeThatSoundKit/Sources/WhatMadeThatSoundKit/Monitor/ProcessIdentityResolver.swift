import Darwin
import Foundation

/// Works out which process is making sound and which application it belongs to.
///
/// Audio is frequently rendered by helper processes (browser renderers, the
/// WebKit GPU process, XPC services). macOS tracks a "responsible" process for
/// every process — the app that launched the helper, which is what TCC uses to
/// attribute permissions — and that is what we attribute sounds to. If the
/// (private, but long-stable) responsibility API is unavailable, we fall back to
/// the outermost `.app` bundle containing the helper's executable.
public struct ProcessIdentityResolver: Sendable {
    public init() {}

    public func resolve(pid: pid_t, coreAudioBundleID: String? = nil) -> ProcessIdentity {
        let executablePath = Self.executablePath(of: pid)
        let processName = executablePath.map { ($0 as NSString).lastPathComponent }
            ?? Self.shortName(of: pid)
            ?? "PID \(pid)"

        var processBundleID = coreAudioBundleID.flatMap { $0.isEmpty ? nil : $0 }
        if processBundleID == nil, let executablePath, let bundlePath = Self.innermostBundlePath(containing: executablePath) {
            processBundleID = Bundle(path: bundlePath)?.bundleIdentifier
        }

        var responsiblePID: pid_t?
        var appPath: String?
        if let responsible = Self.responsiblePID(for: pid), responsible != pid, responsible > 0 {
            responsiblePID = responsible
            appPath = Self.executablePath(of: responsible).flatMap(Self.outermostApplicationPath)
        }
        if appPath == nil {
            appPath = executablePath.flatMap(Self.outermostApplicationPath)
        }

        var appName: String?
        var appBundleID: String?
        if let appPath {
            appName = Self.displayName(ofBundleAt: appPath)
            appBundleID = Bundle(path: appPath)?.bundleIdentifier
        }

        return ProcessIdentity(
            pid: pid,
            processName: processName,
            processBundleID: processBundleID,
            executablePath: executablePath,
            responsiblePID: responsiblePID,
            appName: appName,
            appBundleID: appBundleID,
            appPath: appPath
        )
    }

    // MARK: Process information

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN)) // PROC_PIDPATHINFO_MAXSIZE
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func shortName(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    private static let responsibilityFunction: ResponsibilityFunction? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: ResponsibilityFunction.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let function = responsibilityFunction else { return nil }
        let responsible = function(pid)
        return responsible > 0 ? responsible : nil
    }

    // MARK: Bundles

    /// `/Applications/Foo.app` for `/Applications/Foo.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper`.
    static func outermostApplicationPath(containing path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return String(path[..<range.upperBound].dropLast())
    }

    /// The bundle whose `Contents/MacOS` holds the executable (`.app`, `.xpc`, `.appex`, …).
    static func innermostBundlePath(containing executablePath: String) -> String? {
        guard let range = executablePath.range(of: "/Contents/MacOS/", options: .backwards) else { return nil }
        return String(executablePath[..<range.lowerBound])
    }

    /// The name Finder shows for a bundle, e.g. "Visual Studio Code", localized.
    static func displayName(ofBundleAt path: String) -> String {
        var name = FileManager.default.displayName(atPath: path)
        for suffix in [".app", ".xpc", ".appex"] where name.lowercased().hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name.isEmpty ? ((path as NSString).lastPathComponent as NSString).deletingPathExtension : name
    }
}
