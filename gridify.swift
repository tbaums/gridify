// gridify — crop an image to W:H inches (default 5x7), overlay an inch grid,
// write a print-ready PDF (print at 100% / Actual size). With --ui, opens a
// window to position and zoom the crop before saving.
// Build: swiftc -O gridify.swift -o ~/.local/bin/gridify
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

let usage = """
usage: gridify IMAGE... [options]
  --ui               open a window to drag/zoom the crop, then Save (one image)
  -o, --out PATH     output PDF (one image only; default: iCloud Drive/<name>_grid.pdf)
  --width IN         print width, inches (default 5)
  --height IN        print height, inches (default 7)
  --cell IN          grid cell size, inches (default 1)
  --focus-x 0..1     crop position, 0=left (default 0.5)
  --focus-y 0..1     crop position, 0=top (default 0.5)
  --page letter|a4   page size (default letter)
  --labels           label columns A.. and rows 1..
  --rotate DEG       rotate the image clockwise before cropping (any angle)
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
}

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

func defaultDest(_ path: String) -> URL {
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    return icloud.appendingPathComponent("\(stem)_grid.pdf")
}

func render(_ img: CGImage, crop: CGRect, _ o: Opts, to dest: URL) throws -> String {
    guard let (pw, ph) = pages[o.page] else { throw Fail(msg: "--page must be letter or a4") }
    if o.width > pw - 1 || o.height > ph - 1 {
        throw Fail(msg: "\(o.width)x\(o.height) in does not fit on \(o.page) with 0.5 in margins")
    }
    guard let cropped = img.cropping(to: crop.integral) else { throw Fail(msg: "crop failed") }

    // PDF space: 72 pt/in, origin bottom-left.
    var media = CGRect(x: 0, y: 0, width: pw * 72, height: ph * 72)
    guard let ctx = CGContext(dest as CFURL, mediaBox: &media, nil) else {
        throw Fail(msg: "cannot write \(dest.path)")
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
    return "saved: \(dest.path)  (\(xs.count + 1) columns x \(ys.count + 1) rows)"
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

    init(img: CGImage, opts: Opts) {
        base = img
        self.img = rotated(img, opts.rotate)
        self.opts = opts
        nsimg = NSImage(cgImage: self.img, size: NSSize(width: self.img.width, height: self.img.height))
        crop = cropRect(Double(self.img.width), Double(self.img.height), ratio: opts.width / opts.height,
                        fx: opts.fx, fy: opts.fy)
        super.init(frame: .zero)
    }

    // Re-rotate from the original, keeping the crop's zoom and relative center.
    func setRotation(_ deg: Double) {
        let rx = crop.midX / Double(img.width), ry = crop.midY / Double(img.height)
        opts.rotate = deg
        img = rotated(base, deg)
        nsimg = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
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

final class Controller: NSObject, NSApplicationDelegate {
    let path: String, dest: URL
    let view: CropView
    let status = NSTextField(labelWithString: "")
    var window: NSWindow!
    let cells = [1.0, 0.5, 0.25]
    let fine = NSSlider()
    var quarter = 0.0  // 90° turns; total rotation = quarter * 90 + fine

    init(path: String, img: CGImage, opts: Opts, dest: URL) {
        self.path = path
        self.dest = dest
        view = CropView(img: img, opts: opts)
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let cell = NSPopUpButton(title: "", target: self, action: #selector(cellChanged))
        cell.addItems(withTitles: ["1 in cells", "½ in cells", "¼ in cells"])
        if let i = cells.firstIndex(of: view.opts.cell) { cell.selectItem(at: i) } else {
            cell.addItem(withTitle: "\(view.opts.cell) in cells"); cell.selectItem(at: 3)
        }
        let page = NSPopUpButton(title: "", target: self, action: #selector(pageChanged))
        page.addItems(withTitles: ["letter", "a4"])
        page.selectItem(withTitle: view.opts.page)
        let labels = NSButton(checkboxWithTitle: "Labels", target: self, action: #selector(labelsChanged))
        labels.state = view.opts.labels ? .on : .off
        let reset = NSButton(title: "Fit", target: self, action: #selector(resetZoom))
        quarter = (view.opts.rotate / 90).rounded()
        fine.minValue = -45; fine.maxValue = 45
        fine.doubleValue = view.opts.rotate - quarter * 90
        fine.isContinuous = true
        fine.target = self; fine.action = #selector(fineChanged)
        fine.toolTip = "straighten (±45°)"
        fine.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let ccw = NSButton(image: NSImage(systemSymbolName: "rotate.left", accessibilityDescription: "Rotate left")!,
                           target: self, action: #selector(turnLeft))
        let cw = NSButton(image: NSImage(systemSymbolName: "rotate.right", accessibilityDescription: "Rotate right")!,
                          target: self, action: #selector(turnRight))
        ccw.toolTip = "rotate 90° left"; cw.toolTip = "rotate 90° right"
        let save = NSButton(title: "Save PDF", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [cell, page, labels, reset, ccw, cw, fine, status, save])
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.setHuggingPriority(.defaultLow, for: .horizontal)
        let root = NSStackView(views: [view, bar])
        root.orientation = .vertical
        root.spacing = 0
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 820),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "gridify — \(URL(fileURLWithPath: path).lastPathComponent)"
        window.contentView = root
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        view.onChange = { [weak self] in self?.updateStatus() }
        updateStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    func updateStatus(_ prefix: String = "") {
        let ppi = view.crop.width / view.opts.width
        let warn = ppi < 180 ? " — low-res, expect softness" : ""
        status.stringValue = prefix.isEmpty
            ? String(format: "%.1f° · %.0f px/in%@", view.opts.rotate, ppi, warn)
            : prefix
    }

    func applyRotation() {
        let deg = (quarter * 90 + (fine.doubleValue * 10).rounded() / 10)
            .truncatingRemainder(dividingBy: 360)
        view.setRotation(deg < 0 ? deg + 360 : deg)
    }
    @objc func fineChanged() { applyRotation() }
    @objc func turnLeft() { quarter -= 1; applyRotation() }
    @objc func turnRight() { quarter += 1; applyRotation() }

    @objc func cellChanged(_ s: NSPopUpButton) {
        if s.indexOfSelectedItem < cells.count { view.opts.cell = cells[s.indexOfSelectedItem] }
        view.needsDisplay = true
    }
    @objc func pageChanged(_ s: NSPopUpButton) { view.opts.page = s.titleOfSelectedItem ?? "letter" }
    @objc func labelsChanged(_ s: NSButton) { view.opts.labels = s.state == .on }
    @objc func resetZoom() { view.setZoom(1) }
    @objc func save() {
        do {
            let msg = try render(view.img, crop: view.crop, view.opts, to: dest)
            print(msg)
            updateStatus("saved \(dest.lastPathComponent) to \(dest.deletingLastPathComponent().lastPathComponent)")
            NSWorkspace.shared.open(dest)
        } catch let e as Fail {
            updateStatus("error: \(e.msg)")
        } catch {
            updateStatus("error: \(error)")
        }
    }
}

func runUI(_ path: String, _ o: Opts, dest: URL) -> Never {
    let img: CGImage
    do { img = try loadOriented(path) } catch let e as Fail { die(e.msg) } catch { die("\(error)") }
    let app = NSApplication.shared
    let controller = Controller(path: path, img: img, opts: o, dest: dest)
    app.delegate = controller
    let menu = NSMenu(), appItem = NSMenuItem()
    menu.addItem(appItem)
    appItem.submenu = NSMenu()
    appItem.submenu!.addItem(withTitle: "Quit gridify", action: #selector(NSApplication.terminate(_:)),
                             keyEquivalent: "q")
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

var argv = CommandLine.arguments.dropFirst().makeIterator()
func str(_ flag: String) -> String {
    guard let s = argv.next() else { die("\(flag) needs a value") }
    return s
}
func num(_ flag: String) -> Double {
    guard let s = argv.next(), let v = Double(s) else { die("\(flag) needs a number") }
    return v
}
while let a = argv.next() {
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
    default:
        if a.hasPrefix("-") { die("unknown option \(a)\n\n\(usage)") }
        images.append(a)
    }
}
if images.isEmpty { die(usage) }
if (out != nil || ui) && images.count > 1 { die("--out and --ui work with one image only") }
if o.width <= 0 || o.height <= 0 || o.cell <= 0 || !(0...1).contains(o.fx) || !(0...1).contains(o.fy) {
    die("sizes must be > 0 and --focus-x/-y within 0..1")
}
if pages[o.page] == nil { die("--page must be letter or a4") }

if ui { runUI(images[0], o, dest: out.map { URL(fileURLWithPath: $0) } ?? defaultDest(images[0])) }

for p in images {
    do {
        let img = rotated(try loadOriented(p), o.rotate)
        print("source: \(img.width)x\(img.height) px\(o.rotate == 0 ? "" : " (rotated \(o.rotate)°)")")
        let r = cropRect(Double(img.width), Double(img.height), ratio: o.width / o.height, fx: o.fx, fy: o.fy)
        let ppi = r.width / o.width
        print(String(format: "cropped: %.0fx%.0f px -> %.3gx%.3g in (%.0f px/in)",
                     r.width, r.height, o.width, o.height, ppi))
        if ppi < 180 { print("warning: source is low-res for this print size; expect softness") }
        print(try render(img, crop: r, o, to: out.map { URL(fileURLWithPath: $0) } ?? defaultDest(p)))
    } catch let e as Fail {
        die(e.msg)
    } catch {
        die("\(error)")
    }
}
