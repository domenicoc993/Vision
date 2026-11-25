import AppKit

public extension ClipColorTag {
    var nsColor: NSColor {
        let c = rgb
        return NSColor(calibratedRed: c.r, green: c.g, blue: c.b, alpha: 1.0)
    }
}

private final class ClipColorPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var worksWhenModal: Bool {
        get { true }
        set { }
    }
}

public final class ClipColorPalette: NSObject {
    private static var activePalette: ClipColorPalette?

    private var panel: ClipColorPalettePanel?
    private var eventMonitor: Any?
    private let onSelectColor: (ClipColorTag?) -> Void
    private let footerLabel = NSTextField(labelWithString: "Scegli colore")

    private init(onSelectColor: @escaping (ClipColorTag?) -> Void) {
        self.onSelectColor = onSelectColor
        super.init()
    }

    public static func dismissActive() {
        activePalette?.dismiss()
    }

    public static func show(
        currentColor: ClipColorTag?,
        hasMixedColors: Bool = false,
        targetCount: Int = 1,
        nearScreenRect anchorRect: NSRect,
        parentWindow: NSWindow?,
        onSelectColor: @escaping (ClipColorTag?) -> Void
    ) {
        dismissActive()
        let palette = ClipColorPalette(onSelectColor: onSelectColor)
        activePalette = palette
        palette.present(
            currentColor: currentColor,
            hasMixedColors: hasMixedColors,
            targetCount: targetCount,
            nearScreenRect: anchorRect,
            parentWindow: parentWindow
        )
    }

    private func present(
        currentColor: ClipColorTag?,
        hasMixedColors: Bool,
        targetCount: Int,
        nearScreenRect anchorRect: NSRect,
        parentWindow: NSWindow?
    ) {
        let width: CGFloat = 188
        let height: CGFloat = 224

        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 0.98).cgColor
        root.layer?.cornerRadius = 10
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        root.layer?.masksToBounds = true

        // Header
        let titleText = targetCount > 1 ? "Colore Clip (\(targetCount))" : "Colore Clip"
        let headerLbl = NSTextField(labelWithString: titleText)
        headerLbl.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        headerLbl.textColor = NSColor(calibratedWhite: 0.88, alpha: 1.0)
        headerLbl.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(headerLbl)

        let scLbl = NSTextField(labelWithString: "C")
        scLbl.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        scLbl.textColor = NSColor(calibratedWhite: 0.50, alpha: 1.0)
        scLbl.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scLbl)

        // Default (Neutro) option row
        let defaultBtn = DefaultColorRowView(
            isSelected: !hasMixedColors && currentColor == nil,
            onHoverChanged: { [weak self] hovered in
                self?.footerLabel.stringValue = hovered ? "Default (Neutro)" : "Scegli colore"
            },
            onActivate: { [weak self] in
                self?.selectAndDismiss(nil)
            }
        )
        defaultBtn.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(defaultBtn)

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(divider)

        // 4 x 3 Swatch Grid (12 alternative balanced colors)
        let gridStack = NSStackView()
        gridStack.orientation = .vertical
        gridStack.spacing = 8
        gridStack.alignment = .centerX
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(gridStack)

        let allColors = ClipColorTag.allCases
        let cols = 4
        for rowStart in stride(from: 0, to: allColors.count, by: cols) {
            let rowStack = NSStackView()
            rowStack.orientation = .horizontal
            rowStack.spacing = 10
            rowStack.alignment = .centerY
            for colOffset in 0..<cols {
                let idx = rowStart + colOffset
                guard idx < allColors.count else { break }
                let tag = allColors[idx]
                let swatch = ColorSwatchButton(
                    tag: tag,
                    isSelected: !hasMixedColors && currentColor == tag,
                    onHoverChanged: { [weak self] hovered in
                        self?.footerLabel.stringValue = hovered ? tag.displayName : "Scegli colore"
                    },
                    onActivate: { [weak self] in
                        self?.selectAndDismiss(tag)
                    }
                )
                swatch.translatesAutoresizingMaskIntoConstraints = false
                swatch.widthAnchor.constraint(equalToConstant: 32).isActive = true
                swatch.heightAnchor.constraint(equalToConstant: 32).isActive = true
                rowStack.addArrangedSubview(swatch)
            }
            gridStack.addArrangedSubview(rowStack)
        }

        // Footer label showing hovered color name
        footerLabel.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        footerLabel.textColor = NSColor(calibratedWhite: 0.60, alpha: 1.0)
        footerLabel.alignment = .center
        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            headerLbl.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            headerLbl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),

            scLbl.centerYAnchor.constraint(equalTo: headerLbl.centerYAnchor),
            scLbl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),

            defaultBtn.topAnchor.constraint(equalTo: headerLbl.bottomAnchor, constant: 8),
            defaultBtn.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            defaultBtn.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            defaultBtn.heightAnchor.constraint(equalToConstant: 28),

            divider.topAnchor.constraint(equalTo: defaultBtn.bottomAnchor, constant: 6),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            divider.heightAnchor.constraint(equalToConstant: 1),

            gridStack.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 10),
            gridStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),

            footerLabel.topAnchor.constraint(equalTo: gridStack.bottomAnchor, constant: 9),
            footerLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            footerLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10)
        ])

        let screenFrame = (parentWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var originX = anchorRect.minX
        if originX + width > screenFrame.maxX - 8 {
            originX = max(screenFrame.minX + 8, screenFrame.maxX - width - 8)
        }
        originX = max(screenFrame.minX + 8, originX)

        var originY = anchorRect.minY - height - 4
        if originY < screenFrame.minY + 8 {
            originY = min(screenFrame.maxY - height - 8, anchorRect.maxY + 4)
        }

        let panelRect = NSRect(x: originX, y: originY, width: width, height: height)
        let p = ClipColorPalettePanel(
            contentRect: panelRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.level = .popUpMenu
        p.appearance = NSAppearance(named: .darkAqua)
        p.contentView = root
        self.panel = p

        parentWindow?.addChildWindow(p, ordered: .above)
        p.orderFrontRegardless()
        installMonitor()
    }

    private func selectAndDismiss(_ color: ClipColorTag?) {
        let cb = onSelectColor
        dismiss()
        cb(color)
    }

    private func installMonitor() {
        removeMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Esc
                    self.dismiss()
                    return nil
                }
                return event
            }
            if event.window !== self.panel {
                self.dismiss()
            }
            return event
        }
    }

    private func removeMonitor() {
        if let m = eventMonitor {
            NSEvent.removeMonitor(m)
            eventMonitor = nil
        }
    }

    private func dismiss() {
        removeMonitor()
        if let p = panel {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
        panel = nil
        if ClipColorPalette.activePalette === self {
            ClipColorPalette.activePalette = nil
        }
    }

    deinit {
        removeMonitor()
    }
}

private final class DefaultColorRowView: NSView {
    private let isSelected: Bool
    private let onHoverChanged: (Bool) -> Void
    private let onActivate: () -> Void
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?

    init(isSelected: Bool, onHoverChanged: @escaping (Bool) -> Void, onActivate: @escaping () -> Void) {
        self.isSelected = isSelected
        self.onHoverChanged = onHoverChanged
        self.onActivate = onActivate
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChanged(false)
    }

    override func mouseDown(with event: NSEvent) {
        onActivate()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        if isHovered {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.11).cgColor)
            let bgPath = CGPath(roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.addPath(bgPath)
            ctx.fillPath()
        }

        // Split neutral swatch (default video blue + audio green)
        let swatchRect = CGRect(x: 8, y: (bounds.height - 16) * 0.5, width: 16, height: 16)
        ctx.saveGState()
        ctx.addEllipse(in: swatchRect)
        ctx.clip()
        ctx.setFillColor(NSColor(calibratedRed: 0.18, green: 0.35, blue: 0.58, alpha: 1.0).cgColor)
        ctx.fill(CGRect(x: swatchRect.minX, y: swatchRect.minY, width: swatchRect.width * 0.5, height: swatchRect.height))
        ctx.setFillColor(NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.38, alpha: 1.0).cgColor)
        ctx.fill(CGRect(x: swatchRect.midX, y: swatchRect.minY, width: swatchRect.width * 0.5, height: swatchRect.height))
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(isSelected ? 0.85 : 0.25).cgColor)
        ctx.setLineWidth(isSelected ? 1.5 : 1.0)
        ctx.strokeEllipse(in: swatchRect)

        let titleAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.93, alpha: 1.0)
        ]
        ("Default (Neutro)" as NSString).draw(at: NSPoint(x: swatchRect.maxX + 8, y: (bounds.height - 14) * 0.5), withAttributes: titleAttr)

        if isSelected {
            let check = Lucide.image(.check, size: 13, color: .systemCyan)
            let checkRect = NSRect(x: bounds.maxX - 21, y: (bounds.height - 13) * 0.5, width: 13, height: 13)
            check.draw(in: checkRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }
}

private final class ColorSwatchButton: NSView {
    private let tagValue: ClipColorTag
    private let isSelected: Bool
    private let onHoverChanged: (Bool) -> Void
    private let onActivate: () -> Void
    private var isHovered = false {
        didSet { needsDisplay = true }
    }
    private var trackingArea: NSTrackingArea?

    init(tag: ClipColorTag, isSelected: Bool, onHoverChanged: @escaping (Bool) -> Void, onActivate: @escaping () -> Void) {
        self.tagValue = tag
        self.isSelected = isSelected
        self.onHoverChanged = onHoverChanged
        self.onActivate = onActivate
        super.init(frame: .zero)
        wantsLayer = true
        toolTip = tag.displayName
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHoverChanged(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHoverChanged(false)
    }

    override func mouseDown(with event: NSEvent) {
        onActivate()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let circleRect = bounds.insetBy(dx: isHovered ? 2.5 : 3.5, dy: isHovered ? 2.5 : 3.5)
        ctx.setFillColor(tagValue.nsColor.cgColor)
        ctx.fillEllipse(in: circleRect)

        if isSelected {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2.0)
            ctx.strokeEllipse(in: circleRect.insetBy(dx: -1.5, dy: -1.5))

            let check = Lucide.image(.check, size: 13, color: .white)
            let checkRect = NSRect(x: bounds.midX - 6.5, y: bounds.midY - 6.5, width: 13, height: 13)
            check.draw(in: checkRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(isHovered ? 0.65 : 0.18).cgColor)
            ctx.setLineWidth(isHovered ? 1.5 : 1.0)
            ctx.strokeEllipse(in: circleRect)
        }
    }
}
