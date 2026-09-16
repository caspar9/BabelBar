// Renders the BabelBar app icon to a 1024×1024 PNG with CoreGraphics.
// Usage: swift Resources/icon/make-icon.swift <output.png>
// The Makefile `icon` target turns the PNG into Resources/AppIcon.icns.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high

// MARK: Squircle (macOS icon grid: 824 pt tile on a 1024 canvas)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow under the tile, like Apple's template.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(squircle); ctx.setFillColor(rgb(0x1A1F5C)); ctx.fillPath()
ctx.restoreGState()

// Background: deep indigo → violet → teal, diagonal.
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
let bg = CGGradient(colorsSpace: cs,
                    colors: [rgb(0x2A1F8F), rgb(0x4B33D6), rgb(0x0FB2C9)] as CFArray,
                    locations: [0, 0.48, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: tile.minX, y: tile.maxY),
                       end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// Soft top highlight for depth.
let sheen = CGGradient(colorsSpace: cs,
                       colors: [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: tile.maxY),
                       end: CGPoint(x: 0, y: tile.midY), options: [])
ctx.restoreGState()

// MARK: Speech bubble
let bubble = CGRect(x: 212, y: 318, width: 600, height: 430)
let bubblePath = CGMutablePath()
bubblePath.addRoundedRect(in: bubble, cornerWidth: 96, cornerHeight: 96)
// Tail at bottom-left.
bubblePath.move(to: CGPoint(x: 300, y: 330))
bubblePath.addLine(to: CGPoint(x: 258, y: 236))
bubblePath.addLine(to: CGPoint(x: 400, y: 320))
bubblePath.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: rgb(0x000000, 0.28))
ctx.addPath(bubblePath); ctx.setFillColor(rgb(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()

// MARK: Two caption lines: original ("A" + bar) and translation ("文" + bar)
func draw(text: String, at origin: CGPoint, size fontSize: CGFloat, color: CGColor,
          fontName: String? = nil) {
    let font = fontName.flatMap { NSFont(name: $0, size: fontSize) }
        ?? NSFont.systemFont(ofSize: fontSize, weight: .heavy)
    let attr = NSAttributedString(string: text, attributes: [
        .font: font, .foregroundColor: NSColor(cgColor: color)!,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = origin
    CTLineDraw(line, ctx)
}
func bar(_ rect: CGRect, _ color: CGColor) {
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2,
                       cornerHeight: rect.height / 2, transform: nil))
    ctx.setFillColor(color); ctx.fillPath()
}

let ink = rgb(0x1E2160)      // original: near-black indigo
let accent = rgb(0x0FA8BE)   // translation: teal
draw(text: "A", at: CGPoint(x: 292, y: 566), size: 168, color: ink)
bar(CGRect(x: 440, y: 606, width: 300, height: 56), ink)
// System CJK font (PingFang) tops out at Semibold; ask for it explicitly so
// the glyph reads as bold as the Latin "A" above it.
draw(text: "文", at: CGPoint(x: 292, y: 386), size: 150, color: accent,
     fontName: "PingFangSC-Semibold")
bar(CGRect(x: 440, y: 420, width: 220, height: 56), accent)

// MARK: Write PNG
let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
