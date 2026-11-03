// The promo's opening titles, white on a clear 1920×1080 frame, in two
// beats; tools/promo.sh fades them in and out over black before the
// laptops come up.
//
//     swift tools/promo/title.swift now out.png          // "Nanolight is now on" / "Mac · Windows · Linux"
//     swift tools/promo/title.swift intro out.png icon.png  // the icon, "Introducing" / "Nanolight 2.0" / Raycast
import AppKit

let args = CommandLine.arguments
let beat = args[1], out = args[2]
let w = 1920, h = 1080
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSColor.clear.set()
NSRect(x: 0, y: 0, width: w, height: h).fill()

/// A line centred across the frame, its middle `y` points from the top.
func line(_ s: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, y: CGFloat, tracking: CGFloat = 0) {
    let a = NSAttributedString(string: s, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: NSColor.white.withAlphaComponent(alpha),
        .kern: tracking,
    ])
    let sz = a.size()
    a.draw(at: NSPoint(x: (CGFloat(w) - sz.width) / 2, y: CGFloat(h) - y - sz.height / 2))
}

if beat == "now" {
    line("Nanolight is now on", size: 44, weight: .regular, alpha: 0.72, y: 470, tracking: -0.4)
    line("Mac  ·  Windows  ·  Linux", size: 96, weight: .semibold, alpha: 1, y: 572, tracking: -2)
} else {
    if args.count > 3, let icon = NSImage(contentsOfFile: args[3]) {
        icon.draw(in: NSRect(x: (w - 136) / 2, y: h - 300 - 136, width: 136, height: 136))
    }
    line("Introducing", size: 40, weight: .regular, alpha: 0.7, y: 500, tracking: -0.3)
    line("Nanolight 2.0", size: 112, weight: .bold, alpha: 1, y: 592, tracking: -3)
    line("with Raycast extension support", size: 40, weight: .medium, alpha: 0.78, y: 690, tracking: -0.3)
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
