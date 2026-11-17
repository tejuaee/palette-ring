// Palette Ring: hold Shift on a selected photo in Finder to see its colour palette
// in a ring around the cursor. Move onto a colour and release Shift to save the palette.
import AppKit
import UniformTypeIdentifiers

// MARK: - Palette extraction (k-means on a small thumbnail)

struct RGB { var r: Double, g: Double, b: Double }

func dist2(_ a: RGB, _ b: RGB) -> Double {
    let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
    return dr * dr + dg * dg + db * db
}

func extractPalette(_ url: URL, k: Int = 6) -> [NSColor] {
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceThumbnailMaxPixelSize: 96,
                                 kCGImageSourceCreateThumbnailWithTransform: true]
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return [] }
    let w = img.width, h = img.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var px: [RGB] = []
    for i in stride(from: 0, to: data.count, by: 4) where data[i + 3] > 128 {
        px.append(RGB(r: Double(data[i]), g: Double(data[i + 1]), b: Double(data[i + 2])))
    }
    guard px.count >= k else { return [] }

    // k-means++ seeding with a fixed seed so the same photo always gives the same palette
    var seed: UInt64 = 0x9E3779B97F4A7C15
    func rand() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) }
    var cents = [px[px.count / 2]]
    while cents.count < k {
        let d = px.map { p in cents.map { dist2(p, $0) }.min()! }
        var target = rand() * d.reduce(0, +), idx = 0
        while idx < d.count - 1 && target > d[idx] { target -= d[idx]; idx += 1 }
        cents.append(px[idx])
    }
    var counts = [Int](repeating: 0, count: k)
    for _ in 0..<15 {
        var sums = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: k)
        counts = [Int](repeating: 0, count: k)
        for p in px {
            var best = 0, bd = Double.infinity
            for (j, c) in cents.enumerated() { let dd = dist2(p, c); if dd < bd { bd = dd; best = j } }
            sums[best].r += p.r; sums[best].g += p.g; sums[best].b += p.b; counts[best] += 1
        }
        for j in 0..<k where counts[j] > 0 {
            let n = Double(counts[j]); cents[j] = RGB(r: sums[j].r / n, g: sums[j].g / n, b: sums[j].b / n)
        }
    }
    return zip(cents, counts).filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        .map { NSColor(srgbRed: $0.0.r / 255, green: $0.0.g / 255, blue: $0.0.b / 255, alpha: 1) }
}

func hex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB) ?? c
    return String(format: "#%02X%02X%02X", Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
}

func isLight(_ c: NSColor) -> Bool {
    let s = c.usingColorSpace(.sRGB) ?? c
    return 0.299 * s.redComponent + 0.587 * s.greenComponent + 0.114 * s.blueComponent > 0.6
}

// MARK: - Saving

func savePalette(_ colors: [NSColor], source: URL, to dir: URL) -> URL? {
    let fm = FileManager.default
    let base = source.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespaces)
    var name = "\(base.isEmpty ? "photo" : base) palette", n = 2
    let first = name
    while fm.fileExists(atPath: dir.appendingPathComponent(name + ".png").path) { name = "\(first) \(n)"; n += 1 }

    let sw = 200, W = sw * colors.count, H = 600
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (i, c) in colors.enumerated() {
        c.setFill(); NSRect(x: i * sw, y: 0, width: sw, height: H).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .semibold),
            .foregroundColor: isLight(c) ? NSColor.black.withAlphaComponent(0.75) : NSColor.white.withAlphaComponent(0.9)]
        (hex(c) as NSString).draw(at: NSPoint(x: CGFloat(i * sw) + 20, y: 24), withAttributes: attrs)
    }
    NSGraphicsContext.restoreGraphicsState()

    let png = dir.appendingPathComponent(name + ".png")
    let css = dir.appendingPathComponent(name + ".css")
    var text = "/* palette from \(source.lastPathComponent) */\n:root {\n"
    for (i, c) in colors.enumerated() { text += "  --color-\(i + 1): \(hex(c));\n" }
    text += "}\n"
    do {
        try rep.representation(using: .png, properties: [:])?.write(to: png)
        try text.write(to: css, atomically: true, encoding: .utf8)
    } catch { NSLog("save failed: \(error)"); return nil }
    return png
}

// MARK: - Ring overlay

final class RingView: NSView {
    var colors: [NSColor] = []
    var image: NSImage?
    var hovered: Int?
    var progress: CGFloat = 0       // 0...1 appear animation
    var message: String?
    // photo radius, colour-arc centre radius, arc thickness
    let r0: CGFloat = 38, rm: CGFloat = 66, t: CGFloat = 18
    var outerEdge: CGFloat { rm + t / 2 + 6 }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let n = colors.count
        guard n > 0 else { return }
        let e = 1 - pow(1 - min(1, progress), 3)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28 * e)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = NSSize(width: 0, height: -2)

        // colour arcs with rounded ends and even gaps
        let step = 360 / CGFloat(n)
        for i in 0..<n {
            let local = max(0, min(1, progress * 1.8 - CGFloat(i) * 0.8 / CGFloat(n)))
            guard local > 0 else { continue }
            let le = 1 - pow(1 - local, 3)
            let hov = hovered == i
            let width = (hov ? t + 6 : t) * le
            let radius = r0 + (rm - r0) * le + (hov ? 5 : 0)
            let trim = min(step / 2 - 1, (width / 2 + 3) / radius * 180 / .pi)
            let mid = 90 - (CGFloat(i) + 0.5) * step
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: radius, startAngle: mid + step / 2 - trim,
                        endAngle: mid - step / 2 + trim, clockwise: true)
            p.lineWidth = width; p.lineCapStyle = .round
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            colors[i].withAlphaComponent(hovered == nil || hov ? 1 : 0.55).setStroke()
            p.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // photo in the centre, hairline white rim
        let pr = r0 * (0.7 + 0.3 * e)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill(); NSBezierPath(ovalIn: circle(c, pr + 1.5)).fill()
        NSGraphicsContext.restoreGraphicsState()
        if let img = image, img.size.width > 0 {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: circle(c, pr)).addClip()
            let s = max(2 * pr / img.size.width, 2 * pr / img.size.height)
            let sz = NSSize(width: img.size.width * s, height: img.size.height * s)
            img.draw(in: NSRect(x: c.x - sz.width / 2, y: c.y - sz.height / 2, width: sz.width, height: sz.height))
            NSGraphicsContext.restoreGraphicsState()
        }

        // small label: hovered hex with a swatch dot, or a status message
        let label = message ?? hovered.map { hex(colors[$0]) } ?? "release ⇧ on a colour"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95), .kern: 0.4]
        let ts = (label as NSString).size(withAttributes: attrs)
        let dot: CGFloat = hovered != nil && message == nil ? 7 : 0
        let gap: CGFloat = dot > 0 ? 6 : 0
        let w = ts.width + dot + gap + 20, h = ts.height + 8
        let pill = NSRect(x: c.x - w / 2, y: c.y - outerEdge - h - 8, width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor(white: 0.08, alpha: 0.72 * e).setFill()
        NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        if dot > 0, let i = hovered {
            colors[i].setFill()
            NSBezierPath(ovalIn: NSRect(x: pill.minX + 10, y: pill.midY - dot / 2, width: dot, height: dot)).fill()
        }
        (label as NSString).draw(at: NSPoint(x: pill.minX + 10 + dot + gap, y: pill.minY + 4), withAttributes: attrs)
    }

    func circle(_ c: NSPoint, _ r: CGFloat) -> NSRect { NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r) }

    /// Which wedge a point (relative to the centre, y up) is over, or nil when it is in the cancel zone.
    func wedge(dx: CGFloat, dy: CGFloat) -> Int? {
        guard !colors.isEmpty, hypot(dx, dy) > r0 * 0.8 else { return nil }
        let a = atan2(dy, dx) * 180 / .pi
        let fromTop = (90 - a).truncatingRemainder(dividingBy: 360)
        let norm = fromTop < 0 ? fromTop + 360 : fromTop
        return min(colors.count - 1, Int(norm / (360 / CGFloat(colors.count))))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    enum State { case idle, pending(Date, NSPoint), showing(Date), waitRelease }
    var state = State.idle
    var panel: NSPanel!
    let ring = RingView(frame: NSRect(x: 0, y: 0, width: 260, height: 260))
    var center = NSPoint.zero
    var source: URL?
    var statusItem: NSStatusItem!
    var timer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        panel = NSPanel(contentRect: ring.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .popUpMenu; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = ring

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "◐"
        let menu = NSMenu()
        menu.addItem(withTitle: "Hold ⇧ on a photo in Finder", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Downloads", action: #selector(openDownloads), keyEquivalent: "")
        menu.addItem(withTitle: "Quit Palette Ring", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu

        // Polling the modifier state needs no Accessibility / Input Monitoring permission.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    @objc func openDownloads() { NSWorkspace.shared.open(downloadsDir) }
    var downloadsDir: URL { FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0] }

    func tick() {
        let flags = NSEvent.modifierFlags.intersection([.shift, .command, .option, .control])
        let shiftOnly = flags == .shift, shiftDown = flags.contains(.shift)
        // Shift + click / drag is Finder multi-select, not a ring request.
        let clicking = NSEvent.pressedMouseButtons != 0
        switch state {
        case .idle:
            if shiftOnly && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" {
                state = clicking ? .waitRelease : .pending(Date(), NSEvent.mouseLocation)
            }
        case .pending(let since, let start):
            let m = NSEvent.mouseLocation
            if !shiftOnly { state = .idle }
            else if clicking || hypot(m.x - start.x, m.y - start.y) > 6 { state = .waitRelease }
            else if Date().timeIntervalSince(since) > 0.25 { state = trigger() ? .showing(Date()) : .waitRelease }
        case .showing(let since):
            ring.progress = CGFloat(Date().timeIntervalSince(since) / 0.28)
            let m = NSEvent.mouseLocation
            ring.hovered = ring.wedge(dx: m.x - center.x, dy: m.y - center.y)
            ring.needsDisplay = true
            if clicking { hide(after: 0); state = .waitRelease }   // they were selecting files after all
            else if !shiftDown { release(); state = .idle }
        case .waitRelease:
            if !shiftDown { state = .idle }
        }
    }

    func finderSelectedImage() -> URL? {
        let src = """
        tell application "Finder"
          set out to ""
          repeat with a in (selection as alias list)
            set out to out & POSIX path of a & linefeed
          end repeat
          return out
        end tell
        """
        var err: NSDictionary?
        guard let res = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue else {
            if let err { NSLog("Finder query failed: \(err)") }
            return nil
        }
        return res.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }.first { url in
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType?.conforms(to: .image)) == true
        }
    }

    func trigger() -> Bool {
        guard let url = finderSelectedImage() else { return false }
        let colors = extractPalette(url)
        guard !colors.isEmpty else { return false }
        source = url
        ring.colors = colors; ring.image = NSImage(contentsOf: url)
        ring.hovered = nil; ring.message = nil; ring.progress = 0
        center = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: center.x - ring.frame.width / 2, y: center.y - ring.frame.height / 2))
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        return true
    }

    func release() {
        guard let idx = ring.hovered, let url = source else { hide(after: 0); return }
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(hex(ring.colors[idx]), forType: .string)
        if savePalette(ring.colors, source: url, to: downloadsDir) != nil {
            ring.message = "saved to Downloads · \(hex(ring.colors[idx])) copied"
            NSSound(named: "Pop")?.play()
        } else {
            ring.message = "couldn't save palette"
        }
        ring.needsDisplay = true
        hide(after: 0.9)
    }

    func hide(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            if case .showing = self.state { return }   // a new ring opened meanwhile
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; self.panel.animator().alphaValue = 0 },
                                                 completionHandler: { self.panel.orderOut(nil) })
        }
    }
}

// MARK: - Entry

let args = CommandLine.arguments
if args.count == 4 && args[1] == "--preview" {
    // Headless check: palette-ring --preview <image> <outdir>
    let url = URL(fileURLWithPath: args[2]), out = URL(fileURLWithPath: args[3])
    let colors = extractPalette(url)
    print(colors.map(hex).joined(separator: " "))
    _ = savePalette(colors, source: url, to: out)
    let v = RingView(frame: NSRect(x: 0, y: 0, width: 260, height: 260))
    v.colors = colors; v.image = NSImage(contentsOf: url); v.progress = 1; v.hovered = 1
    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("ring preview.png"))
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
