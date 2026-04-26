#!/usr/bin/env swift
//
//  generate-icon.swift
//
//  Renders the EML Viewer app icon (envelope on a blue gradient with the
//  squircle macOS mask) at every size required for AppIcon.appiconset and
//  writes Contents.json next to them.
//
//  Run:  swift scripts/generate-icon.swift
//

import AppKit
import CoreGraphics

// MARK: - Sizes (point size, scale)
let sizes: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

// MARK: - Output paths
let scriptURL  = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let projectURL = scriptURL.deletingLastPathComponent()
let assetURL   = projectURL
    .appendingPathComponent("eml-viewer/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

try? FileManager.default.createDirectory(at: assetURL, withIntermediateDirectories: true)

// MARK: - Drawing

func drawIcon(pixelSize: CGFloat) -> CGImage {
    let width  = Int(pixelSize)
    let height = Int(pixelSize)
    let bytesPerRow = width * 4
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil,
                              width: width, height: height,
                              bitsPerComponent: 8,
                              bytesPerRow: bytesPerRow,
                              space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create bitmap context")
    }

    let rect = CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize)

    // Squircle mask (macOS Big Sur+ icon shape, approximated via rounded rect).
    let cornerRadius = pixelSize * 0.2237
    let squircle = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Background gradient: deep indigo → bright blue.
    let topColor    = CGColor(red: 0.10, green: 0.36, blue: 0.95, alpha: 1.0)
    let bottomColor = CGColor(red: 0.05, green: 0.16, blue: 0.55, alpha: 1.0)
    let gradient = CGGradient(colorsSpace: cs,
                              colors: [topColor, bottomColor] as CFArray,
                              locations: [0.0, 1.0])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: pixelSize),
                           end: CGPoint(x: 0, y: 0),
                           options: [])

    // Envelope geometry, sized as a fraction of the icon.
    let envWidth  = pixelSize * 0.62
    let envHeight = envWidth * 0.66
    let envX = (pixelSize - envWidth) / 2
    let envY = (pixelSize - envHeight) / 2 - pixelSize * 0.02
    let envRect = CGRect(x: envX, y: envY, width: envWidth, height: envHeight)
    let envCorner = pixelSize * 0.02

    // Soft drop shadow on the envelope.
    ctx.setShadow(offset: CGSize(width: 0, height: -pixelSize * 0.012),
                  blur: pixelSize * 0.025,
                  color: CGColor(gray: 0, alpha: 0.30))

    // Envelope body (white).
    let envPath = CGPath(roundedRect: envRect,
                         cornerWidth: envCorner, cornerHeight: envCorner,
                         transform: nil)
    ctx.setFillColor(CGColor(gray: 1.0, alpha: 1.0))
    ctx.addPath(envPath)
    ctx.fillPath()

    // Disable shadow for inner strokes.
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Envelope flap (V-shape) — outline only, in the brand blue.
    ctx.setStrokeColor(CGColor(red: 0.10, green: 0.36, blue: 0.95, alpha: 1.0))
    ctx.setLineWidth(max(1, pixelSize * 0.018))
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)

    let flapPath = CGMutablePath()
    let inset = pixelSize * 0.012
    flapPath.move(to: CGPoint(x: envRect.minX + inset, y: envRect.maxY - inset))
    flapPath.addLine(to: CGPoint(x: envRect.midX, y: envRect.midY + envHeight * 0.05))
    flapPath.addLine(to: CGPoint(x: envRect.maxX - inset, y: envRect.maxY - inset))
    ctx.addPath(flapPath)
    ctx.strokePath()

    // A subtle horizontal "lines of text" inside the envelope, for the small icon.
    let lineColor = CGColor(red: 0.10, green: 0.36, blue: 0.95, alpha: 0.18)
    ctx.setFillColor(lineColor)
    let lineHeight = max(1, pixelSize * 0.012)
    let lineGap    = pixelSize * 0.04
    let lineLeft   = envRect.minX + envWidth * 0.18
    let lineRight  = envRect.maxX - envWidth * 0.18
    let firstY     = envRect.minY + envHeight * 0.22
    for i in 0..<2 {
        let y = firstY + CGFloat(i) * lineGap
        let widthFactor: CGFloat = (i == 1) ? 0.65 : 1.0
        let r = CGRect(x: lineLeft,
                       y: y,
                       width: (lineRight - lineLeft) * widthFactor,
                       height: lineHeight)
        ctx.fill(r)
    }

    ctx.restoreGState()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed")
    }
    try! data.write(to: url, options: .atomic)
}

// MARK: - Generate

var images: [[String: String]] = []

for (point, scale) in sizes {
    let pixelSize = point * scale
    let filename = "icon_\(point)x\(point)@\(scale)x.png"
    let url = assetURL.appendingPathComponent(filename)
    let img = drawIcon(pixelSize: CGFloat(pixelSize))
    writePNG(img, to: url)
    images.append([
        "idiom": "mac",
        "scale": "\(scale)x",
        "size": "\(point)x\(point)",
        "filename": filename,
    ])
    print("wrote \(filename)  (\(pixelSize)x\(pixelSize))")
}

// Write a one-off, large 1024x1024 master for documentation / store assets.
let masterURL = projectURL.appendingPathComponent("scripts/icon-master-1024.png")
writePNG(drawIcon(pixelSize: 1024), to: masterURL)
print("wrote \(masterURL.lastPathComponent)")

// MARK: - Contents.json

let contents: [String: Any] = [
    "images": images,
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(withJSONObject: contents,
                                      options: [.prettyPrinted, .sortedKeys])
let contentsURL = assetURL.appendingPathComponent("Contents.json")
try json.write(to: contentsURL, options: .atomic)
print("wrote Contents.json")
