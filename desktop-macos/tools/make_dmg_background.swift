// Renders the installer window background: an arrow from the app to the Applications folder.
// Usage: swift make_dmg_background.swift <output.tiff>
// Writes a 1x and a 2x (Retina) representation into one TIFF, which Finder picks between.
import AppKit

let width: CGFloat = 640
let height: CGFloat = 400
// Icon centres in Finder window coordinates (origin top left); keep in sync with dmg_settings.py.
let appX: CGFloat = 170, appsX: CGFloat = 470, iconY: CGFloat = 190

func render(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(starting: NSColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1),
               ending: NSColor(red: 0.89, green: 0.92, blue: 0.97, alpha: 1))!.draw(in: bounds, angle: -90)

    let ink = NSColor(red: 0.20, green: 0.27, blue: 0.40, alpha: 1)
    func centred(_ string: String, size: CGFloat, weight: NSFont.Weight, alpha: CGFloat, top: CGFloat) {
        let text = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: ink.withAlphaComponent(alpha),
        ])
        let s = text.size()
        text.draw(at: NSPoint(x: (width - s.width) / 2, y: height - top - s.height))
    }
    centred("Install MarkItDown", size: 22, weight: .semibold, alpha: 1, top: 34)
    centred("Drag the app onto the Applications folder", size: 13, weight: .regular, alpha: 0.75, top: 68)

    // Arrow between the two icons (y flipped: AppKit's origin is bottom left).
    let y = height - iconY
    let start = appX + 75, end = appsX - 75
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: start, y: y))
    arrow.line(to: NSPoint(x: end - 4, y: y))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    ink.withAlphaComponent(0.55).setStroke()
    arrow.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end + 6, y: y))
    head.line(to: NSPoint(x: end - 14, y: y + 13))
    head.line(to: NSPoint(x: end - 14, y: y - 13))
    head.close()
    ink.withAlphaComponent(0.55).setFill()
    head.fill()

    centred("First launch: if macOS blocks the app, open System Settings → Privacy & Security",
            size: 11, weight: .regular, alpha: 0.7, top: 330)
    centred("and click “Open Anyway”. See the README for details.",
            size: 11, weight: .regular, alpha: 0.7, top: 347)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let tiff = NSBitmapImageRep.tiffRepresentationOfImageReps(
    in: [render(scale: 1), render(scale: 2)], using: .lzw, factor: 0)!
try tiff.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
