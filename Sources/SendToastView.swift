import AppKit

/// A compact, non-interactive delivery banner. Long content stays a preview;
/// the complete message and delivery details remain in history.
final class SendToastView: NSView {
    private let material = NSVisualEffectView()
    private var maskSize = NSSize.zero
    override var isOpaque: Bool { false }

    init(message: String, recipients: String, failures: Int,
         titleOverride: String? = nil, detailOverride: String? = nil,
         width: CGFloat = 360) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 16
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 0.5
        material.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)

        let icon = NSImageView()
        let symbol = failures == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: failures == 0 ? "发送成功" : "发送未完成")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        icon.contentTintColor = failures == 0 ? .systemGreen : .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        let textWidth = width - 74
        func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                   color: NSColor, lines: Int) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: size, weight: weight)
            field.textColor = color
            field.maximumNumberOfLines = lines
            field.lineBreakMode = lines > 1 ? .byWordWrapping : .byTruncatingTail
            field.cell?.truncatesLastVisibleLine = true
            field.preferredMaxLayoutWidth = textWidth
            field.setContentCompressionResistancePriority(.required, for: .vertical)
            return field
        }
        let title = label(titleOverride ?? (failures == 0 ? "消息发送成功" : "消息发送未完成"),
                          size: 13, weight: .semibold, color: .labelColor, lines: 1)
        let detail = label(detailOverride ?? (failures == 0 ? "已发送给：\(recipients)" : "\(failures) 台电脑未确认收到"),
                           size: 11, weight: .regular, color: .secondaryLabelColor, lines: 1)
        let preview = message.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        var labels = [title, detail]
        if !preview.isEmpty {
            labels.append(label(String(preview.prefix(160)), size: 13, weight: .regular, color: .labelColor, lines: 2))
        }
        let text = NSStackView(views: labels)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)
        labels.forEach { $0.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
        setFrameSize(NSSize(width: width, height: ceil(fittingSize.height)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard bounds.size != maskSize, bounds.width > 0, bounds.height > 0 else { return }
        maskSize = bounds.size
        // Mask the visual-effect backdrop as well as its layer; a layer radius
        // alone leaves a rectangular material visible outside the corners.
        material.maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
            return true
        }
    }
}
