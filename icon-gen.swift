// Generates the ToshLLM app icon (macOS 26 style: gradient squircle with a chip glyph).
// Usage: swift icon-gen.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no graphics context") }

// Transparent canvas with Big Sur/Tahoe style margins (824pt artwork, centered)
let margin: CGFloat = 100
let artRect = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
let radius: CGFloat = 185

// Soft drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36,
              color: NSColor.black.withAlphaComponent(0.35).cgColor)
let squircle = CGPath(roundedRect: artRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(squircle)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// Background: deep indigo to raspberry gradient
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let colors = [
    NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.32, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.42, green: 0.16, blue: 0.42, alpha: 1).cgColor,
    NSColor(calibratedRed: 0.80, green: 0.23, blue: 0.40, alpha: 1).cgColor,
] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                          locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient,
                       start: CGPoint(x: artRect.minX, y: artRect.maxY),
                       end: CGPoint(x: artRect.maxX, y: artRect.minY),
                       options: [])

// Subtle top gloss (glass effect)
let gloss = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [NSColor.white.withAlphaComponent(0.18).cgColor,
                                NSColor.white.withAlphaComponent(0.0).cgColor] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(gloss,
                       start: CGPoint(x: size / 2, y: artRect.maxY),
                       end: CGPoint(x: size / 2, y: artRect.midY + 60),
                       options: [])
ctx.restoreGState()

// Glyph: GPU chip with pins
let chipSide: CGFloat = 400
let chip = CGRect(x: (size - chipSide) / 2, y: (size - chipSide) / 2, width: chipSide, height: chipSide)
let white = NSColor.white.withAlphaComponent(0.95)

ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 24, color: NSColor.black.withAlphaComponent(0.30).cgColor)

// Pins (5 per side)
ctx.setStrokeColor(white.cgColor)
ctx.setLineWidth(26)
ctx.setLineCap(.round)
let pinLen: CGFloat = 58
let pinGap = chipSide / 6
for i in 1...5 {
    let offset = chip.minX + CGFloat(i) * pinGap
    // bottom and top
    ctx.move(to: CGPoint(x: offset, y: chip.minY - 14)); ctx.addLine(to: CGPoint(x: offset, y: chip.minY - 14 - pinLen))
    ctx.move(to: CGPoint(x: offset, y: chip.maxY + 14)); ctx.addLine(to: CGPoint(x: offset, y: chip.maxY + 14 + pinLen))
    // left and right
    let yoff = chip.minY + CGFloat(i) * pinGap
    ctx.move(to: CGPoint(x: chip.minX - 14, y: yoff)); ctx.addLine(to: CGPoint(x: chip.minX - 14 - pinLen, y: yoff))
    ctx.move(to: CGPoint(x: chip.maxX + 14, y: yoff)); ctx.addLine(to: CGPoint(x: chip.maxX + 14 + pinLen, y: yoff))
}
ctx.strokePath()

// Chip body
let chipPath = CGPath(roundedRect: chip, cornerWidth: 64, cornerHeight: 64, transform: nil)
ctx.setLineWidth(34)
ctx.addPath(chipPath)
ctx.strokePath()
ctx.restoreGState()

// Monogram centered inside the chip
let font = NSFont.systemFont(ofSize: 150, weight: .heavy)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: white,
    .kern: 4,
]
let text = NSAttributedString(string: "LLM", attributes: attrs)
let tsize = text.size()
text.draw(at: NSPoint(x: (size - tsize.width) / 2, y: (size - tsize.height) / 2 - 8))

image.unlockFocus()

// Save PNG
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { fatalError("failed to render") }
try! png.write(to: URL(fileURLWithPath: out))
print("Icon generated: \(out)")
