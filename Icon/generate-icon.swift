#!/usr/bin/env swift
// Generates the ScreenGrabber app icon: a 1024×1024 master PNG, a full .iconset,
// and AppIcon.icns — all drawn programmatically (no external image tools).
//
//   swift Icon/generate-icon.swift
//
// Concept: a macOS "squircle" with an indigo→violet gradient, white selection
// brackets (the screenshot region marquee), and a coral annotation arrow.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Drawing

func makeIcon(size S: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let u = S / 1024.0   // scale factor so all constants are in 1024-space

    // --- Squircle body (Apple-style: art inset inside the 1024 canvas) ---
    let margin: CGFloat = 92 * u
    let body = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let radius = body.width * 0.2237
    let squircle = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft contact shadow under the squircle.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * u), blur: 34 * u,
                  color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.30))
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill, clipped to the squircle.
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let top    = CGColor(red: 0.40, green: 0.36, blue: 0.95, alpha: 1) // indigo
    let bottom = CGColor(red: 0.55, green: 0.27, blue: 0.92, alpha: 1) // violet
    let grad = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY), options: [])

    // Subtle diagonal sheen for depth.
    let sheen = CGGradient(colorsSpace: cs,
                           colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.16),
                                    CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.minX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY), options: [])
    ctx.restoreGState()

    // --- Selection brackets (the screenshot region marquee) ---
    let sel: CGFloat = 486 * u
    let selRect = CGRect(x: (S - sel) / 2, y: (S - sel) / 2, width: sel, height: sel)
    let arm: CGFloat = 132 * u
    let lw: CGFloat = 46 * u
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.96))
    ctx.setLineWidth(lw)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    let corners: [(CGPoint, CGPoint, CGPoint)] = [
        // (horizontal-end, corner, vertical-end) for each L-bracket
        (CGPoint(x: selRect.minX + arm, y: selRect.maxY), CGPoint(x: selRect.minX, y: selRect.maxY), CGPoint(x: selRect.minX, y: selRect.maxY - arm)), // top-left
        (CGPoint(x: selRect.maxX - arm, y: selRect.maxY), CGPoint(x: selRect.maxX, y: selRect.maxY), CGPoint(x: selRect.maxX, y: selRect.maxY - arm)), // top-right
        (CGPoint(x: selRect.minX + arm, y: selRect.minY), CGPoint(x: selRect.minX, y: selRect.minY), CGPoint(x: selRect.minX, y: selRect.minY + arm)), // bottom-left
        (CGPoint(x: selRect.maxX - arm, y: selRect.minY), CGPoint(x: selRect.maxX, y: selRect.minY), CGPoint(x: selRect.maxX, y: selRect.minY + arm)), // bottom-right
    ]
    for (a, c, b) in corners {
        ctx.move(to: a); ctx.addLine(to: c); ctx.addLine(to: b)
        ctx.strokePath()
    }

    // --- Annotation arrow (coral), drawn diagonally inside the selection ---
    let coral = CGColor(red: 1.0, green: 0.42, blue: 0.36, alpha: 1)
    let tail = CGPoint(x: 405 * u, y: 405 * u)
    let tip  = CGPoint(x: 660 * u, y: 660 * u)
    let shaftW: CGFloat = 50 * u
    let headLen: CGFloat = 168 * u
    let headHalf: CGFloat = 105 * u

    let dx = tip.x - tail.x, dy = tip.y - tail.y
    let len = (dx * dx + dy * dy).squareRoot()
    let ux = dx / len, uy = dy / len            // unit along arrow
    let px = -uy, py = ux                        // unit perpendicular
    let neck = CGPoint(x: tip.x - ux * headLen, y: tip.y - uy * headLen)

    ctx.setFillColor(coral)
    ctx.setStrokeColor(coral)
    ctx.setLineWidth(shaftW)
    ctx.setLineCap(.round)
    // Shaft (stop a touch before the neck so the round cap blends into the head).
    ctx.move(to: tail)
    ctx.addLine(to: CGPoint(x: neck.x + ux * 18 * u, y: neck.y + uy * 18 * u))
    ctx.strokePath()
    // Arrowhead triangle.
    ctx.move(to: tip)
    ctx.addLine(to: CGPoint(x: neck.x + px * headHalf, y: neck.y + py * headHalf))
    ctx.addLine(to: CGPoint(x: neck.x - px * headHalf, y: neck.y - py * headHalf))
    ctx.closePath()
    ctx.fillPath()

    return ctx.makeImage()!
}

// MARK: - Encoding helpers

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// MARK: - Build outputs

let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let fm = FileManager.default

// 1024 master.
let master = makeIcon(size: 1024)
writePNG(master, to: here.appendingPathComponent("AppIcon-1024.png"))

// Full .iconset (every size macOS expects, @1x and @2x).
let iconset = here.appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
let specs: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in specs {
    writePNG(makeIcon(size: CGFloat(px)), to: iconset.appendingPathComponent("\(name).png"))
}

// AppIcon.icns via iconutil.
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try! p.run(); p.waitUntilExit()

print("Wrote AppIcon.icns, AppIcon.iconset, AppIcon-1024.png in \(here.path)")
