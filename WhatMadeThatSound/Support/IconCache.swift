import AppKit
import SwiftUI
import WhatMadeThatSoundKit

/// Finder icons for the apps and executables that made sounds, cached by path.
@MainActor
enum IconCache {
    private static var icons: [String: NSImage] = [:]

    static func icon(for identity: ProcessIdentity) -> NSImage {
        let path = identity.appPath ?? identity.executablePath ?? ""
        if let cached = icons[path] { return cached }
        let icon: NSImage
        if !path.isEmpty, FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        } else if identity.appPath != nil {
            icon = NSWorkspace.shared.icon(for: .application)
        } else {
            icon = NSWorkspace.shared.icon(for: .unixExecutable)
        }
        icons[path] = icon
        return icon
    }
}

struct SourceIcon: View {
    let identity: ProcessIdentity
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: IconCache.icon(for: identity))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
