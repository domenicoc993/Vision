import AppKit

private final class VisionSliderCell: NSSliderCell {
    var accentColor: NSColor = .systemCyan

    override var knobThickness: CGFloat { 11 }

    override func barRect(flipped: Bool) -> NSRect {
        let base = super.barRect(flipped: flipped)
        let h: CGFloat = 3.5
        return NSRect(x: base.minX, y: floor(base.midY - h * 0.5) + 0.5, width: base.width, height: h)
    }

    override func knobRect(flipped: Bool) -> NSRect {
        let base = super.knobRect(flipped: flipped)
        let d: CGFloat = 11
        return NSRect(x: round(base.midX - d * 0.5), y: round(base.midY - d * 0.5), width: d, height: d)
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        let trackH: CGFloat = 3.5
        let trackRect = NSRect(x: rect.minX, y: rect.midY - trackH * 0.5, width: rect.width, height: trackH)
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: trackH * 0.5, yRadius: trackH * 0.5)

        let enabledAlpha: CGFloat = isEnabled ? 1.0 : 0.45
        NSColor(calibratedWhite: 0.20, alpha: enabledAlpha).setFill()
        trackPath.fill()

        NSColor.white.withAlphaComponent(0.10 * enabledAlpha).setStroke()
        trackPath.lineWidth = 0.75
        trackPath.stroke()

        let span = max(0.0001, maxValue - minValue)
        let fraction = max(0.0, min(1.0, CGFloat((doubleValue - minValue) / span)))
        let fillW = trackRect.width * fraction
        if fillW > 0.5 {
            let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: fillW, height: trackRect.height)
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: trackH * 0.5, yRadius: trackH * 0.5)
            accentColor.withAlphaComponent(0.85 * enabledAlpha).setFill()
            fillPath.fill()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        let d: CGFloat = isHighlighted ? 11.5 : 10.5
        let circle = NSRect(x: knobRect.midX - d * 0.5, y: knobRect.midY - d * 0.5, width: d, height: d)
        let path = NSBezierPath(ovalIn: circle)

        let enabledAlpha: CGFloat = isEnabled ? 1.0 : 0.55
        NSColor(calibratedWhite: isHighlighted ? 0.98 : 0.90, alpha: enabledAlpha).setFill()
        path.fill()

        let ringColor = isHighlighted
            ? accentColor
            : NSColor(calibratedWhite: 0.10, alpha: 0.85)
        ringColor.withAlphaComponent(enabledAlpha).setStroke()
        path.lineWidth = isHighlighted ? 1.5 : 1.0
        path.stroke()
    }
}

public final class VisionSlider: NSSlider {
    public override class var cellClass: AnyClass? {
        get { VisionSliderCell.self }
        set {}
    }

    public var defaultDoubleValue: Double?
    public var onDoubleClickReset: ((Double) -> Void)?

    public var accentColor: NSColor = .systemCyan {
        didSet {
            (cell as? VisionSliderCell)?.accentColor = accentColor
            needsDisplay = true
        }
    }

    public convenience init(
        value: Double,
        minValue: Double,
        maxValue: Double,
        defaultValue: Double? = nil,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) {
        self.init(frame: .zero)
        self.minValue = minValue
        self.maxValue = maxValue
        self.doubleValue = value
        self.defaultDoubleValue = defaultValue
        self.target = target
        self.action = action
        self.isContinuous = true
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupCell()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCell()
    }

    private func setupCell() {
        if !(cell is VisionSliderCell) {
            let custom = VisionSliderCell()
            custom.minValue = minValue
            custom.maxValue = maxValue
            custom.doubleValue = doubleValue
            custom.isContinuous = isContinuous
            custom.target = target
            custom.action = action
            self.cell = custom
        }
        (cell as? VisionSliderCell)?.accentColor = accentColor
        focusRingType = .none
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: super.intrinsicContentSize.width, height: 18)
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if event.clickCount == 2, let def = defaultDoubleValue {
            let clamped = min(maxValue, max(minValue, def))
            self.doubleValue = clamped
            if let action = self.action {
                NSApp.sendAction(action, to: target, from: self)
            }
            onDoubleClickReset?(clamped)
            needsDisplay = true
            return
        }
        super.mouseDown(with: event)
    }
}
