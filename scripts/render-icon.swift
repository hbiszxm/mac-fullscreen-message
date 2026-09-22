import AppKit

guard CommandLine.arguments.count == 2 else { exit(1) }
let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()

let rect = NSRect(origin: .zero, size: size)
let background = NSBezierPath(roundedRect: rect.insetBy(dx: 42, dy: 42), xRadius: 220, yRadius: 220)
NSColor(calibratedRed: 0.08, green: 0.32, blue: 0.82, alpha: 1).setFill()
background.fill()

let paragraph = NSMutableParagraphStyle()
paragraph.alignment = .center
let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 318, weight: .heavy),
    .foregroundColor: NSColor.white,
    .paragraphStyle: paragraph
]
let textRect = NSRect(x: 55, y: 320, width: 914, height: 400)
("上班" as NSString).draw(in: textRect, withAttributes: attributes)
image.unlockFocus()

guard let data = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data),
      let png = bitmap.representation(using: .png, properties: [:]) else { exit(2) }
try png.write(to: URL(fileURLWithPath: output))

