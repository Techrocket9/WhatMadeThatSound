#!/usr/bin/env swift
// Draws the app icon at every size macOS needs and writes the PNGs into the
// asset catalog. Run from the repository root: swift scripts/generate-icon.swift
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outputDirectory = URL(filePath: "WhatMadeThatSound/Assets.xcassets/AppIcon.appiconset", directoryHint: .isDirectory)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws on a 1024×1024 canvas (y up), scaled to `pixels`.
func drawIcon(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setShouldAntialias(true)

    // Rounded-square base with a soft shadow, per the macOS icon grid (824pt body).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let basePath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, alpha: 0.35))
    context.addPath(basePath)
    context.setFillColor(color(0x3B2FB8))
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(basePath)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x7B6BFF), color(0x3A2DB0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Gentle top highlight.
    let highlight = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, alpha: 0.18), color(0xFFFFFF, alpha: 0)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(highlight, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    context.restoreGState()

    // Speaker.
    let speaker = CGMutablePath()
    speaker.addRoundedRect(in: CGRect(x: 236, y: 440, width: 104, height: 144), cornerWidth: 22, cornerHeight: 22)
    speaker.move(to: CGPoint(x: 318, y: 440))
    speaker.addLine(to: CGPoint(x: 462, y: 322))
    speaker.addQuadCurve(to: CGPoint(x: 490, y: 346), control: CGPoint(x: 490, y: 318))
    speaker.addLine(to: CGPoint(x: 490, y: 678))
    speaker.addQuadCurve(to: CGPoint(x: 462, y: 702), control: CGPoint(x: 490, y: 706))
    speaker.addLine(to: CGPoint(x: 318, y: 584))
    speaker.closeSubpath()
    context.addPath(speaker)
    context.setFillColor(color(0xFFFFFF))
    context.fillPath()

    // Sound waves.
    context.setLineCap(.round)
    context.setLineWidth(46)
    let center = CGPoint(x: 470, y: 512)
    for (radius, alpha) in [(118.0, 1.0), (206.0, 0.75)] {
        context.setStrokeColor(color(0xFFFFFF, alpha: alpha))
        context.addArc(center: center, radius: radius, startAngle: -.pi / 4.2, endAngle: .pi / 4.2, clockwise: false)
        context.strokePath()
    }

    // Question mark: "what made that sound?"
    let yellow = color(0xFFD23F)
    context.setStrokeColor(yellow)
    context.setLineWidth(50)
    let hook = CGMutablePath()
    let hookCenter = CGPoint(x: 796, y: 596)
    hook.addArc(center: hookCenter, radius: 58, startAngle: .pi * 1.0, endAngle: -.pi * 0.35, clockwise: true)
    hook.addQuadCurve(to: CGPoint(x: 796, y: 482), control: CGPoint(x: 796, y: 516))
    context.addPath(hook)
    context.strokePath()
    context.setFillColor(yellow)
    context.fillEllipse(in: CGRect(x: 796 - 30, y: 386, width: 60, height: 60))

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(url.path)") }
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        writePNG(drawIcon(pixels: points * scale), to: outputDirectory.appending(path: name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appending(path: "Contents.json"))
print("Wrote \(images.count) icon images to \(outputDirectory.path)")
