#!/usr/bin/env swift
// Renders the VidFlow icon (the Windows app's two ribbons and play mark, branding/AppIcon.xaml) on a macOS icon tile,
// at every size the asset catalog wants.
//   swift scripts/gen-icon.swift VidFlow/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func ribbon(_ c: CGContext, from: CGPoint, to: CGPoint, colors: [CGColor], alpha: CGFloat) {
    c.saveGState()
    c.setAlpha(alpha)
    c.beginPath()
    c.move(to: from)
    c.addLine(to: to)
    c.setLineWidth(58)
    c.setLineCap(.round)
    c.replacePathWithStrokedPath()
    c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}

func render(_ px: Int) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let c = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    c.scaleBy(x: s, y: s)
    // Apple's icon grid: an 824 pt tile on a 1024 pt canvas, leaving room for the system shadow's fall-off.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0.3))
    c.addPath(path)
    c.setFillColor(color(0xFFFFFF))
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(path)
    c.clip()
    let bg = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xE9EDF7)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.restoreGState()

    // The artwork is drawn on a 256-unit canvas, y down.
    c.saveGState()
    c.translateBy(x: 512, y: 512)
    c.scaleBy(x: 2.72, y: -2.72)
    c.translateBy(x: -128, y: -128)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 3), blur: 8, color: color(0, 0.2))
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    ribbon(c, from: CGPoint(x: 194, y: 70), to: CGPoint(x: 128, y: 196), colors: [color(0xA06CFF), color(0x4F5CF2)], alpha: 1)
    ribbon(c, from: CGPoint(x: 62, y: 70), to: CGPoint(x: 128, y: 196), colors: [color(0x2EE6C8), color(0x1C8CF2)], alpha: 0.92)
    c.endTransparencyLayer()
    c.restoreGState()
    c.beginPath()
    c.move(to: CGPoint(x: 115, y: 46))
    c.addLine(to: CGPoint(x: 115, y: 86))
    c.addLine(to: CGPoint(x: 146, y: 66))
    c.closePath()
    c.setFillColor(color(0xFF6B6B))
    c.setStrokeColor(color(0xFF6B6B))
    c.setLineWidth(10)
    c.setLineJoin(.round)
    c.drawPath(using: .fillStroke)
    c.restoreGState()

    return NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try render(pt * scale).write(to: dir.appendingPathComponent(name))
        images.append(["idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)", "filename": name])
    }
}
let json = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]],
                                      options: [.prettyPrinted, .sortedKeys])
try json.write(to: dir.appendingPathComponent("Contents.json"))
