// Renders the extension's icons from the app icon, in Apple's rounded shape.
//
//     swift Extension/make-icons.swift
//
// The app icon is drawn square and left to iOS to round. Nothing rounds it for a browser
// toolbar or a Mac app, so here it is cut to the same continuous-corner shape — the one
// SwiftUI's `.continuous` rounded rectangle draws, which is the shape iOS and macOS use.
//
// Two layouts. The browser icons are nearly full-bleed, since a toolbar button is small
// and already has space around it; the 128 keeps Chrome's 16-pixel margin for its store
// and extensions page. The Mac app's icon follows the macOS grid: an 824-point body on a
// 1024 canvas, with the soft shadow every Mac icon carries.

import AppKit
import SwiftUI

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repo = here.deletingLastPathComponent()
let source = repo.appendingPathComponent("AmberGlow/Assets.xcassets/AppIcon.appiconset/AppIcon.png")

guard let image = NSImage(contentsOf: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Couldn't read \(source.path)")
}

/// The icon at `size` pixels, its body inset by `margin` on every side.
func render(size: Int, margin: Double, shadow: Bool) -> Data {
    let s = Double(size)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high

    let body = CGRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    // macOS's icon corner: 185.4 on an 824 body.
    let shape = RoundedRectangle(cornerRadius: body.width * 0.225, style: .continuous)
        .path(in: body).cgPath

    if shadow {
        let scale = s / 1024
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 20 * scale,
                          color: CGColor(gray: 0, alpha: 0.35))
        context.addPath(shape)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fillPath()
        context.restoreGState()
    }

    context.addPath(shape)
    context.clip()
    context.draw(image, in: body)

    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, to path: String) {
    let url = here.appendingPathComponent(path)
    try! data.write(to: url)
    print(path)
}

// The extension's own icons, for the toolbar, the menus and the extensions page.
for size in [16, 32, 48] {
    write(render(size: size, margin: Double(size) / 32, shadow: false), to: "web/icons/icon-\(size).png")
}
write(render(size: 128, margin: 16, shadow: false), to: "web/icons/icon-128.png")

// The Mac app that carries the Safari extension.
let appIcons = "Safari/Evening Reader Saver/Assets.xcassets/AppIcon.appiconset"
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let size = points * scale
        write(render(size: size, margin: Double(size) * 100 / 1024, shadow: true),
              to: "\(appIcons)/mac-icon-\(points)@\(scale)x.png")
    }
}
// Shown in the app's window, beside the switch-it-on instructions.
write(render(size: 256, margin: 256 * 100 / 1024, shadow: true),
      to: "Safari/Evening Reader Saver/Resources/Icon.png")
