#!/usr/bin/env swift

// Draws Resources/AppIcon.icns: a usage gauge, in the same green/amber/red the panel's meters
// use, on a dark squircle. Run with `make icon` after changing anything here.
//
// Every size is drawn natively rather than downsampled from one big render, so the arc and
// needle keep their proportions and stay legible at 16pt.
//
// The shapes are hand-drawn on purpose: SF Symbols may be used inside an app, but Apple's
// licence does not allow them in an app icon.

import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]

/// iconutil expects these exact names; @2x entries are the same pixels as the next size up.
let iconsetNames: [(pixels: Int, name: String)] = [
  (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
  (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
  (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
  (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
  (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]

func color(_ hex: UInt32) -> NSColor {
  NSColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255,
    alpha: 1)
}

let backgroundTop = color(0x33_383F)
let backgroundBottom = color(0x14_171B)
let track = color(0x3A_4048)
let green = color(0x34_C759)
let amber = color(0xFF_9F0A)
let red = color(0xFF_453B)
let needle = color(0xF7_F9FB)

/// Sweep of the gauge, in degrees, drawn clockwise so it passes over the top.
let sweepStart: CGFloat = 205
let sweepEnd: CGFloat = -25

func draw(canvas: CGFloat, into context: CGContext) {
  context.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))

  // Squircle. The inset and radius follow macOS proportions closely enough to sit comfortably
  // beside system icons in Finder.
  let inset = canvas * 0.086
  let body = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
  let squircle = CGPath(
    roundedRect: body, cornerWidth: canvas * 0.225, cornerHeight: canvas * 0.225, transform: nil)
  context.saveGState()
  context.addPath(squircle)
  context.clip()
  let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [backgroundTop.cgColor, backgroundBottom.cgColor] as CFArray,
    locations: [0, 1])!
  context.drawLinearGradient(
    gradient, start: CGPoint(x: 0, y: canvas), end: CGPoint(x: 0, y: 0), options: [])
  context.restoreGState()

  let center = CGPoint(x: canvas * 0.5, y: canvas * 0.42)
  let radius = canvas * 0.235
  let width = canvas * 0.082

  func arc(from: CGFloat, to: CGFloat, color: NSColor) {
    context.setLineWidth(width)
    context.setLineCap(.butt)
    context.setStrokeColor(color.cgColor)
    context.addArc(
      center: center, radius: radius, startAngle: from * .pi / 180, endAngle: to * .pi / 180, clockwise: true)
    context.strokePath()
  }

  // A hair of track behind the segments keeps the ends from looking clipped at small sizes.
  arc(from: sweepStart, to: sweepEnd, color: track)
  let third = (sweepStart - sweepEnd) / 3
  arc(from: sweepStart, to: sweepStart - third, color: green)
  arc(from: sweepStart - third, to: sweepStart - third * 2, color: amber)
  arc(from: sweepStart - third * 2, to: sweepEnd, color: red)

  // Needle into the amber band: a gauge reading zero says nothing about what the app is for.
  let angle = (sweepStart - third * 1.55) * .pi / 180
  let tip = CGPoint(x: center.x + cos(angle) * radius * 0.82, y: center.y + sin(angle) * radius * 0.82)
  context.setStrokeColor(needle.cgColor)
  context.setLineWidth(canvas * 0.038)
  context.setLineCap(.round)
  context.move(to: center)
  context.addLine(to: tip)
  context.strokePath()

  context.setFillColor(needle.cgColor)
  let hub = canvas * 0.052
  context.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2))
  context.setFillColor(backgroundBottom.cgColor)
  let pin = canvas * 0.019
  context.fillEllipse(in: CGRect(x: center.x - pin, y: center.y - pin, width: pin * 2, height: pin * 2))
}

func png(pixels: Int) -> Data {
  let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  let context = NSGraphicsContext(bitmapImageRep: rep)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  draw(canvas: CGFloat(pixels), into: context.cgContext)
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
// Intermediates are scratch: only the .icns belongs in the repo.
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tokenration-icon")
try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
let iconset = scratch.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

var cache: [Int: Data] = [:]
for pixels in sizes { cache[pixels] = png(pixels: pixels) }
for entry in iconsetNames {
  try cache[entry.pixels]!.write(to: iconset.appendingPathComponent(entry.name))
}

let resources = root.appendingPathComponent("Resources")
try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let icns = resources.appendingPathComponent("AppIcon.icns")

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
  FileHandle.standardError.write(Data("iconutil failed\n".utf8))
  exit(1)
}
print("==> Wrote \(icns.path)")

// A strip for eyeballing small-size legibility, which is where icons usually fail.
let strip = NSBitmapImageRep(
  bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 256, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
let stripContext = NSGraphicsContext(bitmapImageRep: strip)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = stripContext
var x: CGFloat = 16
for pixels in [256, 128, 64, 32, 16] {
  let image = NSImage(data: cache[pixels]!)!
  image.draw(in: CGRect(x: x, y: 16, width: CGFloat(pixels), height: CGFloat(pixels)))
  x += CGFloat(pixels) + 24
}
NSGraphicsContext.restoreGraphicsState()
let preview = scratch.appendingPathComponent("icon-preview.png")
try strip.representation(using: .png, properties: [:])!.write(to: preview)
print("==> Wrote \(preview.path)")
