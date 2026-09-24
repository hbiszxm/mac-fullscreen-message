import AppKit

enum StatusItemLogo {
    static let glyphWidth: CGFloat = 20
    static let imageHeight: CGFloat = 20

    static func badgeText(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    static func badgeWidth(for count: Int) -> CGFloat {
        guard let text = badgeText(for: count) else { return 0 }
        return max(13, ceil((text as NSString).size(withAttributes: [.font: badgeFont]).width) + 6)
    }

    static var badgeFont: NSFont { .monospacedDigitSystemFont(ofSize: 9, weight: .bold) }

    static func imageWidth(for count: Int) -> CGFloat {
        count > 0 ? 14 + badgeWidth(for: count) : glyphWidth
    }

    static func templateImage(unreadCount: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: imageWidth(for: unreadCount), height: imageHeight), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 4.5, width: 17, height: 13), xRadius: 4, yRadius: 4).fill()
            let tail = NSBezierPath()
            tail.move(to: NSPoint(x: 4, y: 5.5))
            tail.line(to: NSPoint(x: 4, y: 1.5))
            tail.line(to: NSPoint(x: 9, y: 5.5))
            tail.close()
            tail.fill()
            let bolt = NSBezierPath()
            bolt.move(to: NSPoint(x: 11.8, y: 15.6))
            for point in [NSPoint(x: 7.2, y: 9.5), NSPoint(x: 10, y: 9.5), NSPoint(x: 8.4, y: 6.3),
                          NSPoint(x: 13.5, y: 12), NSPoint(x: 10.6, y: 12)] {
                bolt.line(to: point)
            }
            bolt.close()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            bolt.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "全屏消息"
        return image
    }
}

// The system tints the template logo; a separate non-vibrant view keeps the badge red.
final class StatusUnreadBadgeView: NSView {
    var unreadCount = 0 {
        didSet {
            isHidden = unreadCount <= 0
            needsDisplay = true
        }
    }
    override var allowsVibrancy: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let text = StatusItemLogo.badgeText(for: unreadCount) else { return }
        let width = StatusItemLogo.badgeWidth(for: unreadCount)
        let imageLeft = (bounds.width - StatusItemLogo.imageWidth(for: unreadCount)) / 2
        let rect = NSRect(x: imageLeft + 14, y: bounds.height - 14, width: width, height: 13)
        NSColor(calibratedRed: 0.88, green: 0.13, blue: 0.22, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6.5, yRadius: 6.5).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: StatusItemLogo.badgeFont, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
    }
}
