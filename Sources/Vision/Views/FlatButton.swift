import AppKit

public final class FlatButton: NSButton {
    public var isAccentActive: Bool = false {
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
            layer?.backgroundColor = NSColor(calibratedWhite: 0.24, alpha: 1.0).cgColor
            layer?.borderColor = NSColor(calibratedWhite: 0.38, alpha: 1.0).cgColor
            layer?.borderWidth = 1.0
            contentTintColor = .white
        } else {
            layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
            layer?.borderColor = NSColor(calibratedWhite: 0.28, alpha: 1.0).cgColor
            layer?.borderWidth = 1.0
            contentTintColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        }
    }
}
