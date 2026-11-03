// A caption for the promo's PC shots, as the panel's labels look (a dark
// pill, white text, a key cap on the right), on a clear 1920×1080 frame,
// centred `y` points from the top. tools/promo.sh overlays it.
//
//     swift tools/promo/caption.swift "Windows 11" "Alt Space" out.png [y]
import AppKit

let args = CommandLine.arguments
let text = args[1], key = args[2], out = args[3]
let top = args.count > 4 ? CGFloat(Double(args[4]) ?? 980) : 980
let w = 1920, h = 1080
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.set()
NSRect(x: 0, y: 0, width: w, height: h).fill()

let font = NSFont.systemFont(ofSize: 30, weight: .medium)
let words = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.white.withAlphaComponent(0.9)])
let keyFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
let cap = NSAttributedString(string: key, attributes: [.font: keyFont, .foregroundColor: NSColor.white])
let tw = words.size().width, kw = key.isEmpty ? 0 : cap.size().width + 26
let pillW = tw + (key.isEmpty ? 0 : kw + 16) + 56, pillH: CGFloat = 70
let y = CGFloat(h) - top - pillH / 2
let pill = NSRect(x: (CGFloat(w) - pillW) / 2, y: y, width: pillW, height: pillH)
let path = NSBezierPath(roundedRect: pill, xRadius: pillH / 2, yRadius: pillH / 2)
NSColor.black.withAlphaComponent(0.55).setFill()
path.fill()
NSColor.white.withAlphaComponent(0.12).setStroke()
path.lineWidth = 1.5
path.stroke()
words.draw(at: NSPoint(x: pill.minX + 28, y: pill.midY - words.size().height / 2))
if !key.isEmpty {
    let kr = NSRect(x: pill.maxX - 28 - kw, y: pill.midY - 21, width: kw, height: 42)
    let kp = NSBezierPath(roundedRect: kr, xRadius: 10, yRadius: 10)
    NSColor.white.withAlphaComponent(0.14).setFill()
    kp.fill()
    NSColor.white.withAlphaComponent(0.2).setStroke()
    kp.stroke()
    cap.draw(at: NSPoint(x: kr.minX + 13, y: kr.midY - cap.size().height / 2))
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
