// Renders a simple app icon (AirPods symbol on a rounded gradient) to AppIcon.iconset PNGs.
import Cocoa
let outDir = CommandLine.arguments[1]
let sizes: [(Int, String)] = [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")]
for (px, name) in sizes {
    let size = NSSize(width: px, height: px)
    let image = NSImage(size: size)
    image.lockFocus()
    let inset = CGFloat(px) * 0.1
    let rect = NSRect(x: inset, y: inset, width: CGFloat(px) - 2*inset, height: CGFloat(px) - 2*inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22)
    NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.20, blue: 0.30, alpha: 1),
               ending: NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.12, alpha: 1))!.draw(in: path, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: CGFloat(px) * 0.5, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "airpodspro", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
        let s = tinted.size
        tinted.draw(in: NSRect(x: rect.midX - s.width/2, y: rect.midY - s.height/2, width: s.width, height: s.height))
    }
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/icon_\(name).png"))
}
