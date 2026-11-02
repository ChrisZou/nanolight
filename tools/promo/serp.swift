// Google's results page as Nanolight's panel shows it: a WKWebView that
// says it is Safari (as preview.zig's does), in a window never put on
// screen, snapshotted to PNG. swift tools/promo/serp.swift <query> <out.png>
import AppKit
import WebKit

final class Grab: NSObject, WKNavigationDelegate {
    let web: WKWebView
    let out: String
    init(query: String, out: String) {
        self.out = out
        let config = WKWebViewConfiguration()
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 680, height: 580), configuration: config)
        super.init()
        let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 680, height: 580), styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: .darkAqua)
        win.contentView = web
        web.navigationDelegate = self
        var c = URLComponents(string: "https://www.google.com/search")!
        c.queryItems = [.init(name: "q", value: query), .init(name: "hl", value: "en")]
        web.load(URLRequest(url: c.url!))
    }
    func webView(_ w: WKWebView, didFinish _: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
            w.takeSnapshot(with: nil) { img, err in
                print(w.url?.absoluteString ?? "", err?.localizedDescription ?? "")
                if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: self.out))
                }
                exit(0)
            }
        }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let g = Grab(query: CommandLine.arguments[1], out: CommandLine.arguments[2])
DispatchQueue.main.asyncAfter(deadline: .now() + 40) { print("timeout"); exit(1) }
app.run()
_ = g
