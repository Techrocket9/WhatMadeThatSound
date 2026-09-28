#if DEBUG
import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
import WhatMadeThatSoundKit

/// Development aid: with `WMTS_SNAPSHOT_DIR` set, walks the UI through a few
/// states, captures each window into a PNG in that directory, then quits. Lets
/// the UI be checked from scripts. Capturing the app's own windows through
/// ScreenCaptureKit's current-process content needs no screen-recording permission.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(store: LogStore) {
        guard let directory = ProcessInfo.processInfo.environment["WMTS_SNAPSHOT_DIR"] else { return }
        let output = URL(filePath: directory, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            await capture(mainWindow, as: output.appending(path: "1-all.png"))

            if let day = store.days.first {
                store.selection = .day(day.id)
                try? await Task.sleep(for: .seconds(1))
                await capture(mainWindow, as: output.appending(path: "2-day.png"))
            }

            store.searchText = ProcessInfo.processInfo.environment["WMTS_SNAPSHOT_SEARCH"] ?? "slack"
            try? await Task.sleep(for: .seconds(1))
            await capture(mainWindow, as: output.appending(path: "3-search.png"))
            store.searchText = ""

            // Open Settings the way a person would: through the app menu's item.
            if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }),
               let action = item.action {
                NSApp.sendAction(action, to: item.target, from: item)
            }
            try? await Task.sleep(for: .seconds(1.5))
            let settings = NSApp.windows.first { $0.isVisible && $0 !== mainWindow && $0.title.isEmpty == false }
            await capture(settings, as: output.appending(path: "4-settings.png"))

            NSApp.terminate(nil)
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("main") == true }
            ?? NSApp.windows.first { $0.isVisible }
    }

    private static func capture(_ window: NSWindow?, as url: URL) async {
        guard let window else {
            print("[\(url.lastPathComponent)] no window")
            return
        }
        guard #available(macOS 14.4, *) else { return }
        do {
            let content = try await SCShareableContent.currentProcess
            guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                print("[\(url.lastPathComponent)] window not shareable")
                return
            }
            let filter = SCContentFilter(desktopIndependentWindow: target)
            let configuration = SCStreamConfiguration()
            configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        } catch {
            print("[\(url.lastPathComponent)] ScreenCaptureKit failed (\(error.localizedDescription)); rendering layers instead")
            renderLayers(of: window, to: url)
        }
    }

    /// Renders the window's layer tree. Less faithful than a real capture (no
    /// vibrancy), but honours the layer transforms SwiftUI's split views use.
    private static func renderLayers(of window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        guard let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
        context.scaleBy(x: scale, y: scale)
        if !layer.isGeometryFlipped, view.isFlipped {
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
#endif
