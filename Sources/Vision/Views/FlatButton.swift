import AppKit

private final class FlatButtonCell: NSButtonCell {
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let btn = controlView as? FlatButton
        let tint = btn?.contentTintColor ?? .labelColor
        let hPad: CGFloat = 8
        let gap: CGFloat = 6

        let hasImage = (imagePosition != .noImage) && (image != nil)
        let rawTitle = self.title ?? ""
        let hasTitle = !rawTitle.isEmpty && (imagePosition != .imageOnly)

        let drawFont = font ?? NSFont.systemFont(ofSize: 11, weight: .medium)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = .left
        let attrTitle = NSAttributedString(
            string: rawTitle,
            attributes: [
                .font: drawFont,
                .foregroundColor: tint,
                .paragraphStyle: style
            ]
        )

        func drawTintedImage(_ img: NSImage, in rect: NSRect) {
            let finalImg: NSImage
            if img.isTemplate {
                let targetSize = rect.size
                finalImg = NSImage(size: targetSize, flipped: false) { bounds in
                    img.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1.0)
                    tint.setFill()
                    bounds.fill(using: .sourceAtop)
                    return true
                }
            } else {
                finalImg = img
            }
            finalImg.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        }

        if hasImage, let img = image, hasTitle {
            let imgSize = img.size
            let textSize = attrTitle.size()
            let totalW = imgSize.width + gap + ceil(textSize.width)
            let startX = max(cellFrame.minX + hPad, floor(cellFrame.midX - totalW * 0.5))
            let imgRect = NSRect(
                x: startX,
                y: floor(cellFrame.midY - imgSize.height * 0.5),
                width: imgSize.width,
                height: imgSize.height
            )
            drawTintedImage(img, in: imgRect)

            let textX = startX + imgSize.width + gap
            let maxTextW = max(0, cellFrame.maxX - hPad - textX)
            let textRect = NSRect(
                x: textX,
                y: floor(cellFrame.midY - textSize.height * 0.5),
                width: min(ceil(textSize.width), maxTextW),
                height: ceil(textSize.height)
            )
            attrTitle.draw(in: textRect)
        } else if hasImage, let img = image {
            let imgSize = img.size
            let imgRect = NSRect(
                x: floor(cellFrame.midX - imgSize.width * 0.5),
                y: floor(cellFrame.midY - imgSize.height * 0.5),
                width: imgSize.width,
                height: imgSize.height
            )
            drawTintedImage(img, in: imgRect)
        } else if hasTitle {
            let textSize = attrTitle.size()
            let maxTextW = max(0, cellFrame.width - hPad * 2)
            let drawW = min(ceil(textSize.width), maxTextW)
            let textX = max(cellFrame.minX + hPad, floor(cellFrame.midX - drawW * 0.5))
            let textRect = NSRect(
                x: textX,
                y: floor(cellFrame.midY - textSize.height * 0.5),
                width: drawW,
                height: ceil(textSize.height)
            )
            attrTitle.draw(in: textRect)
        }
    }
}

public final class FlatButton: NSButton {
    public override class var cellClass: AnyClass? {
        get { FlatButtonCell.self }
        set {}
    }

    public var customBackgroundColor: NSColor? { didSet { updateColors() } }
    public var customBorderColor: NSColor? { didSet { updateColors() } }
    public var customTextColor: NSColor? { didSet { updateColors() } }

    public override var isEnabled: Bool {
        didSet {
            if !isEnabled {
                isHovered = false
                isPressed = false
            }
            updateColors()
        }
    }

    public var isAccentActive: Bool = false {
        didSet {
            updateColors()
        }
    }

    public var isBoxless: Bool = false {
        didSet {
            updateColors()
        }
    }

    private var isHovered: Bool = false
    private var isPressed: Bool = false
    private var trackingArea: NSTrackingArea?

    public init(title: String = "", image: NSImage? = nil, target: AnyObject? = nil, action: Selector? = nil) {
        super.init(frame: .zero)
        self.title = title
        self.image = image
        self.target = target
        self.action = action
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override var intrinsicContentSize: NSSize {
        let hPad: CGFloat = 10
        let gap: CGFloat = 6
        let hasImg = (imagePosition != .noImage) && (image != nil)
        let hasTxt = !title.isEmpty && (imagePosition != .imageOnly)
        let imgW = hasImg ? (image?.size.width ?? 0) : 0
        let imgH = hasImg ? (image?.size.height ?? 0) : 0
        let textSize = hasTxt ? (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 11, weight: .medium)]) : .zero
        var w = hPad * 2
        if hasImg && hasTxt {
            w += imgW + gap + ceil(textSize.width)
        } else if hasImg {
            w += imgW
        } else if hasTxt {
            w += ceil(textSize.width)
        }
        let h = max(22, max(imgH, ceil(textSize.height)) + 6)
        return NSSize(width: ceil(w), height: ceil(h))
    }

    private func setupUI() {
        if !(cell is FlatButtonCell) {
            let newCell = FlatButtonCell(textCell: title)
            newCell.image = image
            newCell.target = target
            newCell.action = action
            self.cell = newCell
        }
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        imagePosition = image != nil ? (title.isEmpty ? .imageOnly : .imageLeading) : .noImage
        font = NSFont.systemFont(ofSize: 11, weight: .medium)
        contentTintColor = .labelColor

        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        updateColors()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let current = trackingArea {
            removeTrackingArea(current)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovered = true
        updateColors()
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateColors()
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        updateColors()
        super.mouseDown(with: event)
        isPressed = false
        updateColors()
    }

    private func updateColors() {
        alphaValue = isEnabled ? 1.0 : 0.45

        if isBoxless {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            if !isEnabled {
                contentTintColor = NSColor(calibratedWhite: 0.50, alpha: 1.0)
            } else if isAccentActive {
                contentTintColor = .systemCyan
            } else if isPressed || isHovered {
                contentTintColor = .white
            } else {
                contentTintColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
            }
            needsDisplay = true
            return
        }

        if let customBg = customBackgroundColor {
            layer?.backgroundColor = customBg.withAlphaComponent(isPressed ? 0.42 : (isHovered ? 0.34 : customBg.alphaComponent)).cgColor
            layer?.borderColor = (customBorderColor ?? customBg).cgColor
            layer?.borderWidth = 1.0
            contentTintColor = customTextColor ?? .white
        } else if !isEnabled {
            layer?.backgroundColor = NSColor(calibratedWhite: 0.11, alpha: 1.0).cgColor
            layer?.borderColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
            layer?.borderWidth = 1.0
            contentTintColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)
        } else if isAccentActive {
            layer?.backgroundColor = NSColor(calibratedRed: 0.16, green: 0.32, blue: 0.46, alpha: 1.0).cgColor
            layer?.borderColor = NSColor.systemCyan.cgColor
            layer?.borderWidth = 1.2
            contentTintColor = .systemCyan
        } else if isPressed {
            layer?.backgroundColor = NSColor(calibratedWhite: 0.32, alpha: 1.0).cgColor
            layer?.borderColor = NSColor(calibratedWhite: 0.45, alpha: 1.0).cgColor
            layer?.borderWidth = 1.0
            contentTintColor = .white
        } else if isHovered {
            layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
            layer?.borderColor = NSColor(calibratedWhite: 0.30, alpha: 1.0).cgColor
            layer?.borderWidth = 1.0
            contentTintColor = .white
        } else {
            layer?.backgroundColor = NSColor(calibratedWhite: 0.125, alpha: 1.0).cgColor
            layer?.borderColor = NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor
            layer?.borderWidth = 1.0
            contentTintColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        }
        needsDisplay = true
    }
}

/// Boxless, icon-only button that displays active state via bright tint vs. greyed-out inactive tint,
/// with optional long-press support.
public final class IconActionButton: NSButton {
    public var isToggleActive: Bool = false {
        didSet {
            updateAppearance()
        }
    }

    public var isToggleMode: Bool = true {
        didSet {
            updateAppearance()
        }
    }

    public var activeTintColor: NSColor = .white {
        didSet {
            updateAppearance()
        }
    }

    public var inactiveTintColor: NSColor = NSColor(calibratedWhite: 0.45, alpha: 1.0) {
        didSet {
            updateAppearance()
        }
    }

    public var onLongPress: (() -> Void)?

    private var isHovered: Bool = false
    private var isPressed: Bool = false
    private var trackingArea: NSTrackingArea?

    public init(
        icon: NSImage? = nil,
        toolTip: String? = nil,
        isToggleMode: Bool = true,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) {
        self.isToggleMode = isToggleMode
        super.init(frame: .zero)
        self.image = icon
        self.toolTip = toolTip
        self.target = target
        self.action = action
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func setupUI() {
        wantsLayer = true
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        title = ""
        updateAppearance()
    }

    public override var isEnabled: Bool {
        didSet {
            updateAppearance()
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let current = trackingArea {
            removeTrackingArea(current)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateAppearance()
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateAppearance()
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        updateAppearance()

        if let onLongPress = onLongPress {
            let deadline = Date(timeIntervalSinceNow: 0.42)
            var triggeredLongPress = false
            var releasedInside = true
            let hitRect = bounds.insetBy(dx: -4, dy: -4)

            while true {
                if let next = window?.nextEvent(
                    matching: [.leftMouseDragged, .leftMouseUp],
                    until: deadline,
                    inMode: .eventTracking,
                    dequeue: true
                ) {
                    let pt = convert(next.locationInWindow, from: nil)
                    if next.type == .leftMouseUp {
                        releasedInside = hitRect.contains(pt)
                        break
                    } else {
                        isPressed = hitRect.contains(pt)
                        updateAppearance()
                    }
                } else {
                    triggeredLongPress = true
                    isPressed = false
                    updateAppearance()
                    onLongPress()
                    break
                }
            }

            isPressed = false
            updateAppearance()
            if !triggeredLongPress && releasedInside, let action = action {
                NSApp.sendAction(action, to: target, from: self)
            }
            return
        }

        super.mouseDown(with: event)
        isPressed = false
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0

        if !isEnabled {
            contentTintColor = NSColor(calibratedWhite: 0.28, alpha: 1.0)
            alphaValue = 0.55
            return
        }
        alphaValue = 1.0

        if isToggleMode {
            if isToggleActive {
                contentTintColor = isPressed ? activeTintColor.withAlphaComponent(0.75) : activeTintColor
            } else if isPressed || isHovered {
                contentTintColor = NSColor(calibratedWhite: 0.78, alpha: 1.0)
            } else {
                contentTintColor = inactiveTintColor
            }
        } else {
            if isPressed {
                contentTintColor = .white
            } else if isHovered {
                contentTintColor = activeTintColor
            } else {
                contentTintColor = NSColor(calibratedWhite: 0.80, alpha: 1.0)
            }
        }
    }
}
