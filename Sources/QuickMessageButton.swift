import AppKit

/// A click sends; crossing the drag threshold only reorders, never sends.
final class QuickMessageButton: PopoverButton {
    var messageText = ""
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onMove: ((String, String) -> Void)?
    private var dropTargeted = false { didSet { needsDisplay = true } }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let origin = event.locationInWindow
        var dragging = false
        var destination: QuickMessageButton?
        isHighlighted = isEnabled
        needsDisplay = true
        defer {
            isHighlighted = false
            needsDisplay = true
            destination?.dropTargeted = false
            if dragging { onDragEnded?() }
        }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown],
                                           until: .distantFuture, inMode: .eventTracking, dequeue: true) {
            if next.type == .keyDown {
                if next.keyCode == 53 { return }
                continue
            }
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                if dragging {
                    if let target = target(at: next.locationInWindow, in: window) {
                        onMove?(messageText, target.messageText)
                    }
                } else if isEnabled && bounds.contains(point) {
                    performClick(nil)
                }
                return
            }
            if !dragging && hypot(next.locationInWindow.x - origin.x, next.locationInWindow.y - origin.y) >= 5 {
                dragging = true
                isHighlighted = false
                needsDisplay = true
                onDragBegan?()
            }
            if dragging {
                let target = target(at: next.locationInWindow, in: window)
                if target !== destination {
                    destination?.dropTargeted = false
                    destination = target
                    destination?.dropTargeted = true
                }
            }
        }
    }

    private func target(at point: NSPoint, in window: NSWindow) -> QuickMessageButton? {
        guard let content = window.contentView else { return nil }
        var pending = content.subviews
        while let view = pending.popLast() {
            if let button = view as? QuickMessageButton,
               button !== self, !button.isHidden,
               button.bounds.contains(button.convert(point, from: nil)) {
                return button
            }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if dropTargeted {
            PopoverPalette.accent.setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8)
            outline.lineWidth = 2
            outline.stroke()
        }
    }
}
