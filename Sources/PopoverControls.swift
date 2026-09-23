import AppKit

enum PopoverPalette {
    static func isDark(_ view: NSView) -> Bool {
        view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    static func background(_ view: NSView) -> NSColor {
        NSColor(white: isDark(view) ? 0.12 : 0.97, alpha: 1)
    }
    static func surface(_ view: NSView) -> NSColor {
        NSColor(white: isDark(view) ? 0.19 : 1, alpha: 1)
    }
    static func border(_ view: NSView) -> NSColor {
        NSColor(white: isDark(view) ? 0.30 : 0.86, alpha: 1)
    }
    static let accent = NSColor(calibratedRed: 0.12, green: 0.40, blue: 0.90, alpha: 1)
}

final class PopoverBackgroundView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var allowsVibrancy: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        PopoverPalette.background(self).setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// Draw the full surface so system bezel rendering cannot obscure its colors.
class PopoverButton: NSButton {
    override var allowsVibrancy: Bool { false }
    var primary = false { didSet { needsDisplay = true } }
    var symbolName: String? { didSet { needsDisplay = true } }
    var leadingAligned = false
    var chosen = false { didSet { state = chosen ? .on : .off; needsDisplay = true } }
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        font = .systemFont(ofSize: 13, weight: .medium)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: 80, height: 34) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let accented = chosen || (primary && isEnabled)
        var fill = accented ? PopoverPalette.accent : PopoverPalette.surface(self)
        if isEnabled && (isHighlighted || hovering) {
            fill = fill.blended(withFraction: isHighlighted ? 0.16 : 0.06, of: accented ? .black : .systemBlue) ?? fill
        }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        fill.setFill()
        path.fill()
        (accented ? fill : PopoverPalette.border(self)).setStroke()
        path.lineWidth = 1
        path.stroke()

        let foreground: NSColor = !isEnabled ? .disabledControlTextColor : (accented ? .white : .labelColor)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = leadingAligned ? .left : .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: foreground, .paragraphStyle: paragraph
        ]
        let iconName = chosen ? "checkmark.circle.fill" : symbolName
        let symbol = iconName.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        let iconWidth: CGFloat = symbol == nil ? 0 : 21
        let maxWidth = max(0, bounds.width - 24 - iconWidth)
        let textWidth = min(maxWidth, (title as NSString).size(withAttributes: attributes).width)
        let groupWidth = textWidth + iconWidth
        let left: CGFloat = leadingAligned ? 12 : max(12, (bounds.width - groupWidth) / 2)
        if let symbol {
            let tinted = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
                symbol.draw(in: rect)
                foreground.setFill()
                rect.fill(using: .sourceIn)
                return true
            }
            tinted.draw(in: NSRect(x: left, y: (bounds.height - 14) / 2, width: 14, height: 14))
        }
        let height = (title as NSString).size(withAttributes: attributes).height
        (title as NSString).draw(in: NSRect(x: left + iconWidth, y: (bounds.height - height) / 2,
                                          width: textWidth, height: height), withAttributes: attributes)
    }
}

final class DeviceChoiceButton: PopoverButton {
    var peerID = ""
    var isChosen: Bool {
        get { chosen }
        set { chosen = newValue }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { super.rightMouseDown(with: event); return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class PopoverEditorFrame: NSView {
    override var allowsVibrancy: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        PopoverPalette.surface(self).setFill()
        path.fill()
        PopoverPalette.border(self).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

final class PopoverMessageTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "v": paste(nil)
        case "x": cut(nil)
        case "z":
            if modifiers.contains(.shift) { undoManager?.redo() }
            else { undoManager?.undo() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
