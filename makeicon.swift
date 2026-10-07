import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 62, y: 62, width: 900, height: 900)
let path = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(calibratedRed: 0.30, green: 0.62, blue: 1.0, alpha: 1),
           ending: NSColor(calibratedRed: 0.10, green: 0.25, blue: 0.80, alpha: 1))!.draw(in: path, angle: -60)
let names = ["wifi"]
var sym: NSImage?
for n in names { if let s = NSImage(systemSymbolName: n, accessibilityDescription: nil) { sym = s; break } }
if let s = sym {
    let cfg = NSImage.SymbolConfiguration(pointSize: 520, weight: .semibold)
    let big = s.withSymbolConfiguration(cfg) ?? s
    let tinted = NSImage(size: big.size)
    tinted.lockFocus()
    big.draw(in: NSRect(origin: .zero, size: big.size))
    NSColor.white.set()
    NSRect(origin: .zero, size: big.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let w = tinted.size.width, h = tinted.size.height
    let scale = min(620 / w, 620 / h)
    let dw = w * scale, dh = h * scale
    tinted.draw(in: NSRect(x: (size - dw) / 2, y: (size - dh) / 2, width: dw, height: dh))
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("ok", sym != nil)
