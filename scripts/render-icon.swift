import AppKit

guard CommandLine.arguments.count == 2 else { exit(1) }
let output = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                    pixelsWide: 1024, pixelsHigh: 1024,
                                    bitsPerSample: 8, samplesPerPixel: 4,
                                    hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else { exit(2) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context

let rect = NSRect(origin: .zero, size: size)
let background = NSBezierPath(roundedRect: rect.insetBy(dx: 42, dy: 42), xRadius: 220, yRadius: 220)
let blue = NSColor(calibratedRed: 0.08, green: 0.32, blue: 0.82, alpha: 1)
blue.setFill()
background.fill()

// The same 20-unit chat-and-lightning silhouette is used in the menu bar.
let transform = AffineTransform(translationByX: 202, byY: 217)
let scale = AffineTransform(scale: 31)
var logoTransform = scale
logoTransform.append(transform)

let bubble = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4.5, width: 17, height: 13),
                          xRadius: 4, yRadius: 4)
bubble.transform(using: logoTransform)
NSColor.white.setFill()
bubble.fill()

let tail = NSBezierPath()
tail.move(to: NSPoint(x: 4, y: 5.5))
tail.line(to: NSPoint(x: 4, y: 1.5))
tail.line(to: NSPoint(x: 9, y: 5.5))
tail.close()
tail.transform(using: logoTransform)
tail.fill()

let lightning = NSBezierPath()
lightning.move(to: NSPoint(x: 11.8, y: 15.6))
lightning.line(to: NSPoint(x: 7.2, y: 9.5))
lightning.line(to: NSPoint(x: 10, y: 9.5))
lightning.line(to: NSPoint(x: 8.4, y: 6.3))
lightning.line(to: NSPoint(x: 13.5, y: 12))
lightning.line(to: NSPoint(x: 10.6, y: 12))
lightning.close()
lightning.transform(using: logoTransform)
blue.setFill()
lightning.fill()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else { exit(2) }
try png.write(to: URL(fileURLWithPath: output))
