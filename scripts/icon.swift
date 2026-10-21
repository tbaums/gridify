// Draws the gridify app icon: a sheet of paper with a ruled drawing grid, a
// pencil sketch and the yellow crop frame from the UI.
// Usage: swift scripts/icon.swift OUT.png   (1024x1024)
import AppKit

let size = 1024.0
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

// macOS icon grid: 824pt rounded square centered on the 1024 canvas.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(CGColor(red: 0.20, green: 0.22, blue: 0.27, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let bg = CGGradient(colorsSpace: nil, colors: [
    CGColor(red: 0.27, green: 0.30, blue: 0.37, alpha: 1),
    CGColor(red: 0.15, green: 0.17, blue: 0.21, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Paper, 5:7, slightly rotated like a sheet on a desk.
let pw = 400.0, ph = pw * 7 / 5
ctx.translateBy(x: 512, y: 512)
ctx.rotate(by: -0.06)
let paper = CGRect(x: -pw / 2, y: -ph / 2, width: pw, height: ph)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: CGColor(gray: 0, alpha: 0.45))
ctx.setFillColor(CGColor(red: 0.98, green: 0.96, blue: 0.91, alpha: 1))
ctx.fill(paper)
ctx.restoreGState()

// Pencil sketch: a simple head-and-shoulders study.
ctx.saveGState()
ctx.clip(to: paper)
ctx.setStrokeColor(CGColor(red: 0.25, green: 0.25, blue: 0.28, alpha: 0.85))
ctx.setLineCap(.round)
ctx.setLineWidth(9)
ctx.addEllipse(in: CGRect(x: -80, y: 10, width: 160, height: 205))
ctx.strokePath()
ctx.setLineWidth(8)
ctx.move(to: CGPoint(x: -175, y: -290))
ctx.addCurve(to: CGPoint(x: -35, y: 5), control1: CGPoint(x: -165, y: -130), control2: CGPoint(x: -105, y: -35))
ctx.move(to: CGPoint(x: 175, y: -290))
ctx.addCurve(to: CGPoint(x: 35, y: 5), control1: CGPoint(x: 165, y: -130), control2: CGPoint(x: 105, y: -35))
ctx.strokePath()
ctx.setLineWidth(5)
ctx.setStrokeColor(CGColor(red: 0.25, green: 0.25, blue: 0.28, alpha: 0.35))
for i in 0..<7 {  // hatching on one cheek
    let x = -62.0 + Double(i) * 9
    ctx.move(to: CGPoint(x: x, y: 50)); ctx.addLine(to: CGPoint(x: x + 22, y: 105))
}
ctx.strokePath()
ctx.restoreGState()

// Ruled grid: 5 x 7 cells.
let cell = pw / 5
ctx.setStrokeColor(CGColor(red: 0.20, green: 0.24, blue: 0.32, alpha: 0.75))
ctx.setLineWidth(4)
for i in 1..<5 { let x = paper.minX + Double(i) * cell; ctx.move(to: CGPoint(x: x, y: paper.minY)); ctx.addLine(to: CGPoint(x: x, y: paper.maxY)) }
for j in 1..<7 { let y = paper.minY + Double(j) * cell; ctx.move(to: CGPoint(x: paper.minX, y: y)); ctx.addLine(to: CGPoint(x: paper.maxX, y: y)) }
ctx.strokePath()

// Yellow crop frame with corner handles.
let frame = paper.insetBy(dx: -14, dy: -14)
ctx.setStrokeColor(CGColor(red: 1.0, green: 0.80, blue: 0.10, alpha: 1))
ctx.setLineWidth(10)
ctx.stroke(frame)
ctx.setLineWidth(22)
ctx.setLineCap(.square)
let h = 70.0
for (cx, cy, sx, sy) in [(frame.minX, frame.minY, 1.0, 1.0), (frame.maxX, frame.minY, -1.0, 1.0),
                         (frame.minX, frame.maxY, 1.0, -1.0), (frame.maxX, frame.maxY, -1.0, -1.0)] {
    ctx.move(to: CGPoint(x: cx + sx * h, y: cy)); ctx.addLine(to: CGPoint(x: cx, y: cy))
    ctx.addLine(to: CGPoint(x: cx, y: cy + sy * h))
}
ctx.strokePath()
ctx.restoreGState()

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: out)
