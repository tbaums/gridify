// gridify — crop an image to W:H inches (default 5x7), overlay an inch grid,
// write a print-ready PDF (print at 100% / Actual size). With --ui, opens a
// window to position and zoom the crop before saving.
// Build: swiftc -O gridify.swift -o ~/.local/bin/gridify
import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let usage = """
usage: gridify IMAGE... [options]
       gridify --ui [IMAGE...] [options]
  --ui               open a window to drag/zoom/rotate crops, then Save
                     (images optional; open more with ⌘O)
  -o, --out PATH     output PDF (one image only; default: iCloud Drive/<name>_grid.pdf)
  --width IN         print width, inches (default 5)
  --height IN        print height, inches (default 7)
  --cell IN          grid cell size, inches (default 1)
  --focus-x 0..1     crop position, 0=left (default 0.5)
  --focus-y 0..1     crop position, 0=top (default 0.5)
  --page letter|a4   page size (default letter)
  --labels           label columns A.. and rows 1..
  --rotate DEG       rotate the image clockwise before cropping (any angle)
  --no-max-2mb       don't cap the PDF size (default: shrink the photo so
                     each PDF is 2 MB or less; --max-2mb turns it back on)
 drawing adjustments (auto-contrast is on unless --no-auto):
  --no-auto          don't auto-stretch tones / lift dark images
  --gray             black and white
  --steps 3|4|5      simplify to N flat tones (a value map; implies --gray)
  --brightness X     -1..1 (default 0)
  --contrast X       -1..1 (default 0)
  --shadows X        0..1, lift dark areas (default 0)
  --highlights X     0..1, recover bright areas (default 0)
"""

func die(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

struct Fail: Error { let msg: String }

struct Opts {
    var width = 5.0, height = 7.0, cell = 1.0, fx = 0.5, fy = 0.5
    var page = "letter", labels = false
    var rotate = 0.0  // degrees clockwise
    var maxBytes = sizeCap  // 0 = no cap
    var adjust = Adjust()  // per image
}

// Tone adjustments that make a photo easier to sketch from.
struct Adjust: Equatable {
    var auto = true, gray = false
    var steps = 0  // 0 = off, else 3...5 flat tones
    var brightness = 0.0, contrast = 0.0  // -1...1
    var shadows = 0.0, highlights = 0.0  // 0...1
}

let sizeCap = 2_000_000  // "2 MB", decimal, as Finder reports it
let softPPI = 100.0  // below this a pencil-sketch reference starts to look soft

let pages: [String: (Double, Double)] = ["letter": (8.5, 11.0), "a4": (8.27, 11.69)]
let icloud = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")

// Grid line offsets (inches) strictly inside 0..size.
func gridPositions(_ size: Double, _ cell: Double) -> [Double] {
    var pos: [Double] = [], i = 1.0
    while i * cell < size - 1e-6 { pos.append(i * cell); i += 1 }
    return pos
}

// Decode with EXIF orientation applied (phone photos are often rotated).
func loadOriented(_ path: String) throws -> CGImage {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw Fail(msg: "cannot open \(path)") }
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
    let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
    ]
    guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
        throw Fail(msg: "cannot decode \(path)")
    }
    return img
}

// Rotate clockwise by deg onto a white canvas just large enough to hold it.
func rotated(_ img: CGImage, _ deg: Double) -> CGImage {
    let d = deg.truncatingRemainder(dividingBy: 360)
    if d == 0 { return img }
    let r = d * .pi / 180, w = Double(img.width), h = Double(img.height)
    let nw = (abs(w * cos(r)) + abs(h * sin(r))).rounded()
    let nh = (abs(w * sin(r)) + abs(h * cos(r))).rounded()
    guard let ctx = CGContext(data: nil, width: Int(nw), height: Int(nh), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: nw, height: nh))
    ctx.interpolationQuality = .high
    ctx.translateBy(x: nw / 2, y: nh / 2)
    ctx.rotate(by: -r)  // CG is y-up, so negative = clockwise on screen
    ctx.draw(img, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
    return ctx.makeImage() ?? img
}

// Largest crop of the given aspect ratio, scaled by zoom (0..1], placed by
// focus (0=left/top, 1=right/bottom). Pixel coords, top-left origin.
func cropRect(_ w: Double, _ h: Double, ratio: Double, fx: Double, fy: Double, zoom: Double = 1) -> CGRect {
    let cw = (w / h > ratio ? h * ratio : w) * zoom
    let ch = cw / ratio
    return CGRect(x: (w - cw) * fx, y: (h - ch) * fy, width: cw, height: ch)
}

// Auto-contrast parameters for a whole image: the 0.5% / 99.5% luminance
// points become black and white, and a dark image's midtones are lifted
// (gamma < 1) so the median lands near middle grey. Never darkens.
struct Levels { var lo = 0.0, hi = 1.0, gamma = 1.0 }

func autoLevels(_ img: CGImage) -> Levels {
    let n = 256.0, s = min(1, n / Double(max(img.width, img.height)))
    let w = max(1, Int(Double(img.width) * s)), h = max(1, Int(Double(img.height) * s))
    var px = [UInt8](repeating: 0, count: w * h)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return Levels() }
    ctx.interpolationQuality = .medium
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    var hist = [Int](repeating: 0, count: 256)
    for p in px { hist[Int(p)] += 1 }
    func pct(_ f: Double) -> Double {
        let target = Int(f * Double(px.count)); var acc = 0
        for (v, c) in hist.enumerated() { acc += c; if acc > target { return Double(v) / 255 } }
        return 1
    }
    var lo = pct(0.005), hi = pct(0.995)
    if hi - lo < 0.1 { lo = 0; hi = 1 }  // flat image: leave it alone
    let mid = min(max((pct(0.5) - lo) / (hi - lo), 0.01), 0.99)
    let gamma = mid < 0.45 ? min(max(log(0.5) / log(mid), 0.5), 1) : 1
    return Levels(lo: lo, hi: hi, gamma: gamma)
}

let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

// Apply the adjustments (auto levels from the whole image, so the preview and
// the PDF match). Works in sRGB so steps and gamma are perceptual.
func adjusted(_ img: CGImage, _ a: Adjust, _ lv: Levels) -> CGImage {
    if a == Adjust(auto: false) { return img }
    var x = CIImage(cgImage: img)
    if a.auto {
        let s = 1 / (lv.hi - lv.lo), b = -lv.lo * s
        x = x.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: s, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: s, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: s, w: 0), "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0),
        ]).applyingFilter("CIColorClamp")
        if lv.gamma < 1 { x = x.applyingFilter("CIGammaAdjust", parameters: ["inputPower": lv.gamma]) }
    }
    if a.shadows != 0 || a.highlights != 0 {
        x = x.applyingFilter("CIHighlightShadowAdjust", parameters: [
            "inputShadowAmount": a.shadows, "inputHighlightAmount": 1 - a.highlights, "inputRadius": 0,
        ])
    }
    let mono = a.gray || a.steps > 0
    if a.brightness != 0 || a.contrast != 0 || mono {
        x = x.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: a.brightness * 0.3, kCIInputContrastKey: 1 + a.contrast * 0.6,
            kCIInputSaturationKey: mono ? 0 : 1,
        ])
    }
    if a.steps > 0 { x = x.applyingFilter("CIColorPosterize", parameters: ["inputLevels": a.steps]) }
    let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    return ciContext.createCGImage(x.cropped(to: r), from: r, format: .RGBA8,
                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? img
}

func defaultDest(_ path: String) -> URL {
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    return icloud.appendingPathComponent("\(stem)_grid.pdf")
}

// Resample to w x h on an opaque white RGB canvas.
func scaled(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage? {
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

// JPEG-backed image: Quartz embeds its JPEG bytes in the PDF as-is (DCTDecode).
func jpegBacked(_ img: CGImage, quality: Double) -> CGImage? {
    let data = NSMutableData()
    guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dst), let provider = CGDataProvider(data: data) else { return nil }
    return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

// Under the cap: lower JPEG quality first, then resolution, until the PDF fits.
// Returns the PDF and the effective resolution of the embedded photo.
func fittedPDF(_ cropped: CGImage, _ o: Opts) throws -> (Data, Double) {
    var w = Double(cropped.width), h = Double(cropped.height)
    while true {
        guard let base = scaled(cropped, Int(w), Int(h)) else { throw Fail(msg: "resample failed") }
        for q in [0.9, 0.8, 0.7, 0.6] {
            guard let jpg = jpegBacked(base, quality: q) else { throw Fail(msg: "JPEG encode failed") }
            let data = try pdfData(jpg, o)
            if data.count <= o.maxBytes || w < 100 { return (data, w / o.width) }
        }
        w *= 0.8; h *= 0.8
    }
}

func render(_ img: CGImage, crop: CGRect, _ o: Opts, to dest: URL) throws -> String {
    guard let (pw, ph) = pages[o.page] else { throw Fail(msg: "--page must be letter or a4") }
    if o.width > pw - 1 || o.height > ph - 1 {
        throw Fail(msg: "\(o.width)x\(o.height) in does not fit on \(o.page) with 0.5 in margins")
    }
    guard let raw = img.cropping(to: crop.integral) else { throw Fail(msg: "crop failed") }
    let cropped = adjusted(raw, o.adjust, autoLevels(img))
    let (data, ppi) = o.maxBytes > 0
        ? try fittedPDF(cropped, o)
        : (try pdfData(cropped, o), Double(cropped.width) / o.width)
    do { try data.write(to: dest, options: .atomic) } catch { throw Fail(msg: "cannot write \(dest.path)") }
    let cols = gridPositions(o.width, o.cell).count + 1, rows = gridPositions(o.height, o.cell).count + 1
    let size = String(format: "%.2f MB, %.0f px/in", Double(data.count) / 1e6, ppi)
    let warn = ppi < softPPI ? " — low-res, expect softness" : ""
    return "saved: \(dest.path)  (\(cols) columns x \(rows) rows; \(size)\(warn))"
}

// The page: photo, vector grid, labels and margin ticks, as PDF bytes.
func pdfData(_ cropped: CGImage, _ o: Opts) throws -> Data {
    let (pw, ph) = pages[o.page]!
    // PDF space: 72 pt/in, origin bottom-left.
    var media = CGRect(x: 0, y: 0, width: pw * 72, height: ph * 72)
    let out = NSMutableData()
    guard let consumer = CGDataConsumer(data: out),
          let ctx = CGContext(consumer: consumer, mediaBox: &media, nil) else {
        throw Fail(msg: "cannot create PDF")
    }
    let W = o.width * 72, H = o.height * 72
    let ox = (media.width - W) / 2, oy = (media.height - H) / 2
    let xs = gridPositions(o.width, o.cell).map { $0 * 72 }
    let ys = gridPositions(o.height, o.cell).map { $0 * 72 }  // measured from the top

    ctx.beginPDFPage(nil)
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(media)
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: CGRect(x: ox, y: oy, width: W, height: H))

    func stroke(_ a: CGPoint, _ b: CGPoint, _ color: CGColor, _ lw: Double) {
        ctx.setStrokeColor(color); ctx.setLineWidth(lw)
        ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
    }
    let white = CGColor(gray: 1, alpha: 1), black = CGColor(gray: 0, alpha: 1)
    // white halo + black core: visible on dark and light areas
    var segs: [(CGPoint, CGPoint)] = []
    for x in xs { segs.append((CGPoint(x: ox + x, y: oy), CGPoint(x: ox + x, y: oy + H))) }
    for y in ys { segs.append((CGPoint(x: ox, y: oy + H - y), CGPoint(x: ox + W, y: oy + H - y))) }
    for (a, b) in segs { stroke(a, b, white, 1.0) }
    for (a, b) in segs { stroke(a, b, black, 0.5) }
    ctx.setStrokeColor(black); ctx.setLineWidth(0.75)
    ctx.stroke(CGRect(x: ox, y: oy, width: W, height: H))

    if o.labels {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 9, nil)
        func label(_ s: String, _ x: Double, _ yTop: Double) {
            let attr = NSAttributedString(string: s, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String):
                    CGColor(red: 1, green: 0.9, blue: 0, alpha: 1),
                NSAttributedString.Key(kCTStrokeColorAttributeName as String): black,
                NSAttributedString.Key(kCTStrokeWidthAttributeName as String): -3.0,
            ])
            ctx.textPosition = CGPoint(x: x, y: yTop - 9)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        for (i, x) in ([0.0] + xs).enumerated() {
            let ch = i < 26 ? String(UnicodeScalar(UInt8(65 + i))) : "A\(i - 25)"
            label(ch, ox + x + 3, oy + H - 3)
        }
        for (j, y) in ([0.0] + ys).enumerated() { label("\(j + 1)", ox + 3, oy + H - y - 14) }
    }

    // margin tick marks at every grid line, for ruling the same grid on paper
    let tick = 0.15 * 72, gap = 1.2
    for x in [0.0] + xs + [W] {
        stroke(CGPoint(x: ox + x, y: oy + H + gap), CGPoint(x: ox + x, y: oy + H + tick), black, 0.5)
        stroke(CGPoint(x: ox + x, y: oy - gap), CGPoint(x: ox + x, y: oy - tick), black, 0.5)
    }
    for y in [0.0] + ys + [H] {
        stroke(CGPoint(x: ox - tick, y: oy + H - y), CGPoint(x: ox - gap, y: oy + H - y), black, 0.5)
        stroke(CGPoint(x: ox + W + gap, y: oy + H - y), CGPoint(x: ox + W + tick, y: oy + H - y), black, 0.5)
    }
    ctx.endPDFPage()
    ctx.closePDF()
    return out as Data
}

// MARK: - UI

final class CropView: NSView {
    let base: CGImage  // as loaded, before rotation
    var img: CGImage   // rotated; what the crop and the PDF use
    var nsimg: NSImage
    var opts: Opts
    var zoom = 1.0
    var crop: CGRect  // pixels of img, top-left origin
    var onChange: () -> Void = {}
    private var last = CGPoint.zero

    var preview: CGImage  // img downscaled for fast adjustment previews
    var levels = Levels()  // auto-contrast parameters for img

    init(img: CGImage, opts: Opts) {
        base = img
        self.img = rotated(img, opts.rotate)
        self.opts = opts
        preview = self.img
        nsimg = NSImage(cgImage: self.img, size: NSSize(width: self.img.width, height: self.img.height))
        crop = cropRect(Double(self.img.width), Double(self.img.height), ratio: opts.width / opts.height,
                        fx: opts.fx, fy: opts.fy)
        super.init(frame: .zero)
        imageChanged()
    }

    // img changed (load, rotation): rebuild the preview copy and auto levels.
    private func imageChanged() {
        let s = min(1, 1600 / Double(max(img.width, img.height)))
        preview = s < 1 ? (scaled(img, Int(Double(img.width) * s), Int(Double(img.height) * s)) ?? img) : img
        levels = autoLevels(img)
        refreshPreview()
    }

    // Redraw the on-screen image with the current adjustments.
    func refreshPreview() {
        let shown = adjusted(preview, opts.adjust, levels)
        nsimg = NSImage(cgImage: shown, size: NSSize(width: img.width, height: img.height))
        needsDisplay = true
    }

    func setAdjust(_ a: Adjust) { opts.adjust = a; refreshPreview() }

    // Re-rotate from the original, keeping the crop's zoom and relative center.
    func setRotation(_ deg: Double) {
        let rx = crop.midX / Double(img.width), ry = crop.midY / Double(img.height)
        opts.rotate = deg
        img = rotated(base, deg)
        imageChanged()
        let full = cropRect(Double(img.width), Double(img.height), ratio: opts.width / opts.height,
                            fx: 0, fy: 0, zoom: zoom)
        crop = CGRect(x: rx * Double(img.width) - full.width / 2, y: ry * Double(img.height) - full.height / 2,
                      width: full.width, height: full.height)
        clamp(); changed()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // image-to-view scale and offset (image fitted and centered)
    private var fit: (s: Double, ox: Double, oy: Double) {
        let s = min(bounds.width / Double(img.width), bounds.height / Double(img.height))
        return (s, (bounds.width - Double(img.width) * s) / 2, (bounds.height - Double(img.height) * s) / 2)
    }
    private func toView(_ r: CGRect) -> CGRect {
        let f = fit
        return CGRect(x: f.ox + r.minX * f.s, y: f.oy + r.minY * f.s, width: r.width * f.s, height: r.height * f.s)
    }

    private func clamp() {
        crop.origin.x = min(max(crop.origin.x, 0), Double(img.width) - crop.width)
        crop.origin.y = min(max(crop.origin.y, 0), Double(img.height) - crop.height)
    }

    func setZoom(_ z: Double) {
        let c = CGPoint(x: crop.midX, y: crop.midY)
        zoom = min(max(z, 0.1), 1)
        let full = cropRect(Double(img.width), Double(img.height), ratio: opts.width / opts.height,
                            fx: 0, fy: 0, zoom: zoom)
        crop = CGRect(x: c.x - full.width / 2, y: c.y - full.height / 2, width: full.width, height: full.height)
        clamp(); changed()
    }

    private func changed() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        onChange()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.15, alpha: 1).setFill()
        bounds.fill()
        let f = fit
        let ir = CGRect(x: f.ox, y: f.oy, width: Double(img.width) * f.s, height: Double(img.height) * f.s)
        nsimg.draw(in: ir, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high.rawValue])
        let cr = toView(crop)
        let shade = NSBezierPath(rect: ir)
        shade.append(NSBezierPath(rect: cr))
        shade.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.6).setFill()
        shade.fill()

        let perIn = cr.width / opts.width
        let grid = NSBezierPath()
        for x in gridPositions(opts.width, opts.cell) {
            grid.move(to: CGPoint(x: cr.minX + x * perIn, y: cr.minY))
            grid.line(to: CGPoint(x: cr.minX + x * perIn, y: cr.maxY))
        }
        for y in gridPositions(opts.height, opts.cell) {
            grid.move(to: CGPoint(x: cr.minX, y: cr.minY + y * perIn))
            grid.line(to: CGPoint(x: cr.maxX, y: cr.minY + y * perIn))
        }
        grid.lineWidth = 2; NSColor.white.setStroke(); grid.stroke()
        grid.lineWidth = 1; NSColor.black.setStroke(); grid.stroke()
        let border = NSBezierPath(rect: cr)
        border.lineWidth = 2; NSColor.systemYellow.setStroke(); border.stroke()
    }

    override func resetCursorRects() { addCursorRect(toView(crop), cursor: .openHand) }

    override func mouseDown(with e: NSEvent) { last = convert(e.locationInWindow, from: nil) }
    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil), s = fit.s
        crop.origin.x += (p.x - last.x) / s
        crop.origin.y += (p.y - last.y) / s
        last = p
        clamp(); changed()
    }
    override func scrollWheel(with e: NSEvent) {
        setZoom(zoom * exp(-e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.005 : 0.05)))
    }
    override func magnify(with e: NSEvent) { setZoom(zoom / (1 + e.magnification)) }
    override func keyDown(with e: NSEvent) {
        let step = 2 / fit.s  // 2 screen points
        switch e.keyCode {
        case 123: crop.origin.x -= step
        case 124: crop.origin.x += step
        case 125: crop.origin.y += step
        case 126: crop.origin.y -= step
        case 24: setZoom(zoom / 1.05); return  // =/+
        case 27: setZoom(zoom * 1.05); return  // -
        default: super.keyDown(with: e); return
        }
        clamp(); changed()
    }
}

// One open image: its own crop, zoom and rotation.
struct Doc {
    let path: String
    let dest: URL
    let view: CropView
}

final class Controller: NSObject, NSApplicationDelegate {
    let paths: [String], out: URL?
    var opts: Opts  // shared: print size, cell, page, labels (rotation is per image)
    var docs: [Doc] = []
    var current = -1
    var view: CropView? { current >= 0 ? docs[current].view : nil }

    var window: NSWindow!
    var root: NSStackView!
    let status = NSTextField(labelWithString: "")
    let files = NSPopUpButton()
    let placeholder = NSTextField(labelWithString: "Open one or more images with ⌘O")
    let empty = NSView()
    let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove image")!,
                          target: nil, action: nil)
    // After saving: open the PDF / reveal PDFs. Swappable so tests stay off screen.
    var openPDF: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var reveal: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }
    let save = NSButton(title: "Save PDF", target: nil, action: nil)
    let saveAll = NSButton(title: "Save All", target: nil, action: nil)
    let cells = [1.0, 0.5, 0.25]
    let fine = NSSlider()
    var quarter = 0.0  // 90° turns; total rotation = quarter * 90 + fine
    var rotateControls: [NSControl] = []
    // Drawing adjustments (per image).
    let autoBox = NSButton(checkboxWithTitle: "Auto", target: nil, action: nil)
    let grayBox = NSButton(checkboxWithTitle: "B&W", target: nil, action: nil)
    let stepsBox = NSButton(checkboxWithTitle: "Steps", target: nil, action: nil)
    let stepsPop = NSPopUpButton()
    let sliders: [(name: String, key: WritableKeyPath<Adjust, Double>, min: Double, slider: NSSlider)] = [
        ("Bright", \.brightness, -1, NSSlider()), ("Contrast", \.contrast, -1, NSSlider()),
        ("Shadows", \.shadows, 0, NSSlider()), ("Highlights", \.highlights, 0, NSSlider()),
    ]

    init(paths: [String], opts: Opts, out: URL?) {
        self.paths = paths
        self.opts = opts
        self.out = out
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildWindow()
        window.makeKeyAndOrderFront(nil)
        addFiles(paths + pending)
        pending = []
        if docs.isEmpty { refresh(); openFiles() }
    }

    func buildWindow() {
        let open = NSButton(title: "Open…", target: self, action: #selector(openFiles))
        remove.target = self; remove.action = #selector(removeCurrent)
        remove.toolTip = "remove this image from the list (the file is not deleted)"
        files.target = self; files.action = #selector(fileChanged)
        files.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        save.target = self; save.action = #selector(saveCurrent)
        save.keyEquivalent = "\r"
        saveAll.target = self; saveAll.action = #selector(saveEverything)
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let top = NSStackView(views: [open, files, remove, status, saveAll, save])

        let cell = NSPopUpButton(title: "", target: self, action: #selector(cellChanged))
        cell.addItems(withTitles: ["1 in cells", "½ in cells", "¼ in cells"])
        if let i = cells.firstIndex(of: opts.cell) { cell.selectItem(at: i) } else {
            cell.addItem(withTitle: "\(opts.cell) in cells"); cell.selectItem(at: 3)
        }
        let page = NSPopUpButton(title: "", target: self, action: #selector(pageChanged))
        page.addItems(withTitles: ["letter", "a4"])
        page.selectItem(withTitle: opts.page)
        let labels = NSButton(checkboxWithTitle: "Labels", target: self, action: #selector(labelsChanged))
        labels.state = opts.labels ? .on : .off
        let cap = NSButton(checkboxWithTitle: "≤ 2 MB", target: self, action: #selector(capChanged))
        cap.state = opts.maxBytes > 0 ? .on : .off
        cap.toolTip = "shrink the photo (JPEG quality, then resolution) so each PDF is 2 MB or less"
        let reset = NSButton(title: "Fit", target: self, action: #selector(resetZoom))
        fine.minValue = -45; fine.maxValue = 45
        fine.isContinuous = true
        fine.target = self; fine.action = #selector(fineChanged)
        fine.toolTip = "straighten (±45°)"
        fine.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let ccw = NSButton(image: NSImage(systemSymbolName: "rotate.left", accessibilityDescription: "Rotate left")!,
                           target: self, action: #selector(turnLeft))
        let cw = NSButton(image: NSImage(systemSymbolName: "rotate.right", accessibilityDescription: "Rotate right")!,
                          target: self, action: #selector(turnRight))
        ccw.toolTip = "rotate 90° left"; cw.toolTip = "rotate 90° right"
        let bottom = NSStackView(views: [cell, page, labels, cap, reset, ccw, cw, fine])

        for b in [autoBox, grayBox, stepsBox] { b.target = self; b.action = #selector(adjustChanged) }
        autoBox.toolTip = "stretch darks and lights to the full range; lift a dark image's midtones"
        grayBox.toolTip = "black and white"
        stepsBox.toolTip = "simplify to a few flat tones (a value map)"
        stepsPop.addItems(withTitles: ["3", "4", "5"]); stepsPop.selectItem(withTitle: "4")
        stepsPop.target = self; stepsPop.action = #selector(adjustChanged)
        var adjustViews: [NSView] = [autoBox, grayBox, stepsBox, stepsPop]
        for s in sliders {
            s.slider.minValue = s.min; s.slider.maxValue = 1; s.slider.isContinuous = true
            s.slider.target = self; s.slider.action = #selector(adjustChanged)
            s.slider.widthAnchor.constraint(equalToConstant: 70).isActive = true
            s.slider.toolTip = s.name.lowercased()
            let label = NSTextField(labelWithString: s.name)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            adjustViews += [label, s.slider]
        }
        let resetAdjust = NSButton(title: "Reset", target: self, action: #selector(resetAdjust))
        resetAdjust.toolTip = "back to the defaults (Auto on, everything else off)"
        adjustViews.append(resetAdjust)
        let adjustBar = NSStackView(views: adjustViews)
        rotateControls = [reset, ccw, cw, fine, autoBox, grayBox, stepsBox, stepsPop, resetAdjust]
            + sliders.map(\.slider)
        for bar in [top, bottom, adjustBar] {
            bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
            bar.setHuggingPriority(.defaultLow, for: .horizontal)
        }

        // Empty state: a size-less container so the bars stay pinned top and bottom.
        placeholder.textColor = .secondaryLabelColor
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        empty.addSubview(placeholder)
        placeholder.centerXAnchor.constraint(equalTo: empty.centerXAnchor).isActive = true
        placeholder.centerYAnchor.constraint(equalTo: empty.centerYAnchor).isActive = true
        empty.setContentHuggingPriority(.defaultLow, for: .vertical)
        root = NSStackView(views: [top, empty, bottom, adjustBar])
        root.orientation = .vertical
        root.spacing = 0

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 860),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.contentView = root
        window.center()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // Files dropped on the app icon or sent with "Open With". At launch these
    // arrive before the window exists, so hold them until it does.
    var pending: [String] = []
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if window == nil { pending += filenames } else { addFiles(filenames) }
        sender.reply(toOpenOrPrint: .success)
    }

    // Load images and show the first new one. Already-open paths are just selected.
    func addFiles(_ ps: [String]) {
        var first: Int?, errors: [String] = []
        for p in ps {
            let full = URL(fileURLWithPath: p).standardizedFileURL.path
            if let i = docs.firstIndex(where: { $0.path == full }) { first = first ?? i; continue }
            do {
                let v = CropView(img: try loadOriented(full), opts: opts)
                v.onChange = { [weak self] in self?.updateStatus() }
                let dest = (out != nil && paths.count == 1 && docs.isEmpty) ? out! : defaultDest(full)
                docs.append(Doc(path: full, dest: dest, view: v))
                first = first ?? docs.count - 1
            } catch let e as Fail {
                errors.append(e.msg)
            } catch {
                errors.append("\(error)")
            }
        }
        if let i = first { select(i) } else { refresh() }
        if !errors.isEmpty { updateStatus("error: " + errors.joined(separator: "; ")) }
    }

    // Replace the middle of the window (image view or empty state).
    func showContent(_ v: NSView) {
        let old = root.arrangedSubviews[1]
        root.removeArrangedSubview(old)
        old.removeFromSuperview()
        root.insertArrangedSubview(v, at: 1)
    }

    func select(_ i: Int) {
        current = i
        let v = docs[i].view
        v.opts.cell = opts.cell; v.opts.page = opts.page; v.opts.labels = opts.labels
        v.opts.maxBytes = opts.maxBytes
        showContent(v)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        quarter = (v.opts.rotate / 90).rounded()
        fine.doubleValue = v.opts.rotate - quarter * 90
        showAdjust(v.opts.adjust)
        window.makeFirstResponder(v)
        v.needsDisplay = true
        refresh()
    }

    // Sync the file menu, title, button state and status with the current doc.
    func refresh() {
        files.removeAllItems()
        files.addItems(withTitles: docs.enumerated().map { "\($0.offset + 1). \(URL(fileURLWithPath: $0.element.path).lastPathComponent)" })
        files.isHidden = docs.isEmpty
        remove.isHidden = docs.isEmpty
        if current >= 0 { files.selectItem(at: current) }
        window.title = view.map { _ in "gridify — \(URL(fileURLWithPath: docs[current].path).lastPathComponent)" } ?? "gridify"
        save.isEnabled = view != nil
        saveAll.isHidden = docs.count < 2
        for c in rotateControls { c.isEnabled = view != nil }
        updateStatus()
    }

    func updateStatus(_ prefix: String = "") {
        guard let v = view else { status.stringValue = prefix; return }
        let ppi = v.crop.width / v.opts.width
        let warn = ppi < softPPI ? " — low-res, expect softness" : ""
        status.stringValue = prefix.isEmpty
            ? String(format: "%.1f° · %.0f px/in%@", v.opts.rotate, ppi, warn)
            : prefix
    }

    @objc func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose images to grid"
        panel.beginSheetModal(for: window) { [weak self] resp in
            if resp == .OK { self?.addFiles(panel.urls.map(\.path)) }
        }
    }
    @objc func fileChanged(_ s: NSPopUpButton) { if s.indexOfSelectedItem >= 0 { select(s.indexOfSelectedItem) } }
    @objc func nextFile() { if docs.count > 1 { select((current + 1) % docs.count) } }
    @objc func prevFile() { if docs.count > 1 { select((current + docs.count - 1) % docs.count) } }

    // Drop the current image from the list (not from disk); show the next one.
    @objc func removeCurrent() {
        guard current >= 0 else { return }
        docs.remove(at: current)
        if docs.isEmpty {
            current = -1
            showContent(empty)
            refresh()
        } else {
            select(min(current, docs.count - 1))
        }
    }

    func applyRotation() {
        let deg = (quarter * 90 + (fine.doubleValue * 10).rounded() / 10)
            .truncatingRemainder(dividingBy: 360)
        view?.setRotation(deg < 0 ? deg + 360 : deg)
    }
    @objc func fineChanged() { applyRotation() }
    @objc func turnLeft() { quarter -= 1; applyRotation() }
    @objc func turnRight() { quarter += 1; applyRotation() }

    // Shared settings apply to every open image.
    func setShared(_ f: (inout Opts) -> Void) {
        f(&opts)
        for d in docs { f(&d.view.opts); d.view.needsDisplay = true }
    }
    @objc func cellChanged(_ s: NSPopUpButton) {
        if s.indexOfSelectedItem < cells.count { let c = cells[s.indexOfSelectedItem]; setShared { $0.cell = c } }
    }
    @objc func pageChanged(_ s: NSPopUpButton) { let p = s.titleOfSelectedItem ?? "letter"; setShared { $0.page = p } }
    @objc func labelsChanged(_ s: NSButton) { let on = s.state == .on; setShared { $0.labels = on } }
    @objc func capChanged(_ s: NSButton) {
        let on = s.state == .on
        prefs.set(on, forKey: capKey)
        setShared { $0.maxBytes = on ? sizeCap : 0 }
    }
    @objc func resetZoom() { view?.setZoom(1) }

    // Per-image adjustments: controls mirror the current image's settings.
    func showAdjust(_ a: Adjust) {
        autoBox.state = a.auto ? .on : .off
        grayBox.state = a.gray || a.steps > 0 ? .on : .off  // see adjustChanged
        grayBox.isEnabled = a.steps == 0
        stepsBox.state = a.steps > 0 ? .on : .off
        if a.steps > 0 { stepsPop.selectItem(withTitle: "\(a.steps)") }
        for s in sliders { s.slider.doubleValue = a[keyPath: s.key] }
    }
    @objc func adjustChanged() {
        guard let v = view else { return }
        var a = v.opts.adjust
        a.auto = autoBox.state == .on
        // B&W is forced (and its box disabled) while Steps is on; keep the
        // user's own B&W choice for when Steps goes off again.
        if a.steps == 0 { a.gray = grayBox.state == .on }
        a.steps = stepsBox.state == .on ? Int(stepsPop.titleOfSelectedItem ?? "4") ?? 4 : 0
        for s in sliders { a[keyPath: s.key] = (s.slider.doubleValue * 100).rounded() / 100 }
        v.setAdjust(a)
        showAdjust(a)
    }
    @objc func resetAdjust() {
        view?.setAdjust(Adjust())
        showAdjust(Adjust())
    }

    func write(_ d: Doc) throws -> String {
        let msg = try render(d.view.img, crop: d.view.crop, d.view.opts, to: d.dest)
        print(msg)
        return msg
    }
    @objc func saveCurrent() {
        guard current >= 0 else { return }
        let d = docs[current]
        do {
            _ = try write(d)
            updateStatus("saved \(d.dest.lastPathComponent) to \(d.dest.deletingLastPathComponent().lastPathComponent)")
            openPDF(d.dest)
        } catch let e as Fail { updateStatus("error: \(e.msg)") } catch { updateStatus("error: \(error)") }
    }
    @objc func saveEverything() {
        var saved: [URL] = [], errors: [String] = []
        for d in docs {
            do { _ = try write(d); saved.append(d.dest) } catch let e as Fail { errors.append(e.msg) } catch {
                errors.append("\(error)")
            }
        }
        updateStatus(errors.isEmpty ? "saved \(saved.count) PDFs" : "saved \(saved.count); error: " + errors.joined(separator: "; "))
        if !saved.isEmpty { reveal(saved) }
    }
}

// Remembered UI choices. The CLI flag, when given, wins for that launch.
let prefs = UserDefaults(suiteName: "com.github.tbaums.gridify") ?? .standard
let capKey = "maxTwoMB"

func runUI(_ paths: [String], _ o: Opts, out: URL?, capFlag: Bool?) -> Never {
    let app = NSApplication.shared
    var o = o
    let capOn = capFlag ?? (prefs.object(forKey: capKey) as? Bool ?? true)
    o.maxBytes = capOn ? sizeCap : 0
    let controller = Controller(paths: paths, opts: o, out: out)
    app.delegate = controller
    let menu = NSMenu()
    let appItem = NSMenuItem(), fileItem = NSMenuItem()
    menu.addItem(appItem); menu.addItem(fileItem)
    appItem.submenu = NSMenu()
    appItem.submenu!.addItem(withTitle: "Quit gridify", action: #selector(NSApplication.terminate(_:)),
                             keyEquivalent: "q")
    let file = NSMenu(title: "File")
    for (title, sel, key, mods) in [
        ("Open…", #selector(Controller.openFiles), "o", NSEvent.ModifierFlags.command),
        ("Save PDF", #selector(Controller.saveCurrent), "s", .command),
        ("Save All", #selector(Controller.saveEverything), "s", [.command, .option]),
        ("Next Image", #selector(Controller.nextFile), "]", .command),
        ("Previous Image", #selector(Controller.prevFile), "[", .command),
        ("Remove Image", #selector(Controller.removeCurrent), "\u{8}", .command),
    ] {
        let item = file.addItem(withTitle: title, action: sel, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.target = controller
    }
    fileItem.submenu = file
    app.mainMenu = menu
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}

// MARK: - CLI

var images: [String] = []
var out: String?
var o = Opts()
var ui = false
var capFlag: Bool?

var argv = CommandLine.arguments.dropFirst().makeIterator()
func str(_ flag: String) -> String {
    guard let s = argv.next() else { die("\(flag) needs a value") }
    return s
}
func num(_ flag: String) -> Double {
    guard let s = argv.next(), let v = Double(s) else { die("\(flag) needs a number") }
    return v
}
// Launched as gridify.app (Finder, Dock): always the UI. Ignore the
// -psn_ argument older macOS versions pass to apps.
if Bundle.main.bundleURL.pathExtension == "app" { ui = true }
while let a = argv.next() {
    if a.hasPrefix("-psn_") { continue }
    switch a {
    case "-h", "--help": print(usage); exit(0)
    case "--ui": ui = true
    case "-o", "--out": out = str(a)
    case "--width": o.width = num(a)
    case "--height": o.height = num(a)
    case "--cell": o.cell = num(a)
    case "--focus-x": o.fx = num(a)
    case "--focus-y": o.fy = num(a)
    case "--page": o.page = str(a)
    case "--labels": o.labels = true
    case "--rotate": o.rotate = num(a)
    case "--max-2mb": capFlag = true; o.maxBytes = sizeCap
    case "--no-max-2mb": capFlag = false; o.maxBytes = 0
    case "--no-auto": o.adjust.auto = false
    case "--gray": o.adjust.gray = true
    case "--steps": o.adjust.steps = Int(num(a))
    case "--brightness": o.adjust.brightness = num(a)
    case "--contrast": o.adjust.contrast = num(a)
    case "--shadows": o.adjust.shadows = num(a)
    case "--highlights": o.adjust.highlights = num(a)
    default:
        if a.hasPrefix("-") { die("unknown option \(a)\n\n\(usage)") }
        images.append(a)
    }
}
if images.isEmpty && !ui { die(usage) }
if out != nil && images.count > 1 { die("--out works with one image only") }
if o.width <= 0 || o.height <= 0 || o.cell <= 0 || !(0...1).contains(o.fx) || !(0...1).contains(o.fy) {
    die("sizes must be > 0 and --focus-x/-y within 0..1")
}
if pages[o.page] == nil { die("--page must be letter or a4") }
let aj = o.adjust
if ![0, 3, 4, 5].contains(aj.steps) { die("--steps must be 3, 4 or 5") }
if ![aj.brightness, aj.contrast].allSatisfy({ (-1...1).contains($0) })
    || ![aj.shadows, aj.highlights].allSatisfy({ (0...1).contains($0) }) {
    die("--brightness/--contrast must be within -1..1, --shadows/--highlights within 0..1")
}

if ui { runUI(images, o, out: out.map { URL(fileURLWithPath: $0) }, capFlag: capFlag) }

for p in images {
    do {
        let img = rotated(try loadOriented(p), o.rotate)
        print("source: \(img.width)x\(img.height) px\(o.rotate == 0 ? "" : " (rotated \(o.rotate)°)")")
        let r = cropRect(Double(img.width), Double(img.height), ratio: o.width / o.height, fx: o.fx, fy: o.fy)
        let ppi = r.width / o.width
        print(String(format: "cropped: %.0fx%.0f px -> %.3gx%.3g in (%.0f px/in)",
                     r.width, r.height, o.width, o.height, ppi))
        if ppi < softPPI { print("warning: source is low-res for this print size; expect softness") }
        print(try render(img, crop: r, o, to: out.map { URL(fileURLWithPath: $0) } ?? defaultDest(p)))
    } catch let e as Fail {
        die(e.msg)
    } catch {
        die("\(error)")
    }
}
