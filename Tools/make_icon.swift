// Renders the VOIX app icon to a 1024x1024 PNG: swift Tools/make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext
let cs = CGColorSpaceCreateDeviceRGB()

// macOS icon grid: 824pt body inset in a 1024 canvas.
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow + background gradient.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.45))
ctx.addPath(squircle); ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.20, green: 0.07, blue: 0.13, alpha: 1),
    CGColor(red: 0.05, green: 0.04, blue: 0.07, alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])

// Red glow behind the waveform.
let center = CGPoint(x: size / 2, y: size / 2)
let glow = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1.0, green: 0.18, blue: 0.25, alpha: 0.55),
    CGColor(red: 1.0, green: 0.18, blue: 0.25, alpha: 0.0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: 360, options: [])

// Record ring.
ctx.setStrokeColor(CGColor(red: 1.0, green: 0.27, blue: 0.32, alpha: 0.9))
ctx.setLineWidth(22)
ctx.strokeEllipse(in: CGRect(x: center.x - 270, y: center.y - 270, width: 540, height: 540))

// Waveform bars.
let heights: [CGFloat] = [0.22, 0.45, 0.72, 1.0, 0.62, 0.86, 0.48, 0.28]
let barW: CGFloat = 34, gap: CGFloat = 22
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
var x = center.x - total / 2
let barGrad = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1, green: 1, blue: 1, alpha: 1),
    CGColor(red: 1.0, green: 0.55, blue: 0.58, alpha: 1)] as CFArray, locations: [0, 1])!
for h in heights {
    let bh = 360 * h
    let r = CGRect(x: x, y: center.y - bh / 2, width: barW, height: bh)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(barGrad, start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.minY), options: [])
    ctx.restoreGState()
    x += barW + gap
}

// Subtle top highlight.
let hl = CGGradient(colorsSpace: cs, colors: [
    CGColor(gray: 1, alpha: 0.10), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hl, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
