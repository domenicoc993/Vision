import AppKit

public final class FlatButton: NSButton {
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

    private func setupUI() {
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
        isHovered = true
        updateColors()
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateColors()
    }

    public override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateColors()
        super.mouseDown(with: event)
        isPressed = false
        updateColors()
    }

    private func updateColors() {
        if isBoxless {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderColor = NSColor.clear.cgColor
            layer?.borderWidth = 0
            if isAccentActive {
                contentTintColor = .systemCyan
            } else if isPressed || isHovered {
                contentTintColor = .white
            } else {
                contentTintColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
            }
            return
        }

        if isAccentActive {
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
