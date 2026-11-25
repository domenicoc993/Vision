import AppKit

/// Unified custom minimal rounded menu item (replaces NSMenuItem across Vision).
public enum VisionMenuItem {
    case action(
        title: String,
        icon: LucideIcon? = nil,
        iconColor: NSColor? = nil,
        shortcut: String? = nil,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        handler: (() -> Void)? = nil
    )
    case submenu(
        title: String,
        icon: LucideIcon? = nil,
        iconColor: NSColor? = nil,
        isEnabled: Bool = true,
        items: [VisionMenuItem]
    )
    case header(String)
    case separator
}

private final class VisionMenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override var worksWhenModal: Bool {
        get { true }
        set { }
    }
}

private final class FlippedStackHost: NSView {
    override var isFlipped: Bool { true }
}

private final class VisionMenuRowView: NSView {
    let item: VisionMenuItem
    var onHover: ((VisionMenuRowView) -> Void)?
    var onActivate: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    var isHighlighted: Bool = false {
        didSet { updateHighlightVisual() }
    }
    private let bgLayerView = NSView()

    init(item: VisionMenuItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        setupContent()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(self)
    }

    override func mouseExited(with event: NSEvent) {
        if case .action = item {
            isHighlighted = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        switch item {
        case .action(_, _, _, _, _, let isEnabled, _, _):
            guard isEnabled else { return }
            onActivate?()
        case .submenu(_, _, _, let isEnabled, _):
            guard isEnabled else { return }
            onHover?(self)
        default:
            break
        }
    }

    private func setupContent() {
        bgLayerView.wantsLayer = true
        bgLayerView.layer?.cornerRadius = 6
        bgLayerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bgLayerView)

        NSLayoutConstraint.activate([
            bgLayerView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            bgLayerView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            bgLayerView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            bgLayerView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4)
        ])

        switch item {
        case .separator:
            let line = NSView()
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            line.translatesAutoresizingMaskIntoConstraints = false
            addSubview(line)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 9),
                line.heightAnchor.constraint(equalToConstant: 1),
                line.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
                line.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                line.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])

        case .header(let title):
            let lbl = NSTextField(labelWithString: title)
            lbl.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
            lbl.textColor = NSColor(calibratedWhite: 0.54, alpha: 1.0)
            lbl.lineBreakMode = .byTruncatingTail
            lbl.translatesAutoresizingMaskIntoConstraints = false
            addSubview(lbl)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: 24),
                lbl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                lbl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                lbl.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])

        case .action(let title, let icon, let iconColor, let shortcut, let isSelected, let isEnabled, let isDestructive, _):
            setupInteractiveRow(
                title: title,
                icon: icon,
                iconColor: iconColor,
                shortcut: shortcut,
                isSelected: isSelected,
                isEnabled: isEnabled,
                isDestructive: isDestructive,
                hasSubmenu: false
            )

        case .submenu(let title, let icon, let iconColor, let isEnabled, _):
            setupInteractiveRow(
                title: title,
                icon: icon,
                iconColor: iconColor,
                shortcut: nil,
                isSelected: false,
                isEnabled: isEnabled,
                isDestructive: false,
                hasSubmenu: true
            )
        }
    }

    private func setupInteractiveRow(
        title: String,
        icon: LucideIcon?,
        iconColor: NSColor?,
        shortcut: String?,
        isSelected: Bool,
        isEnabled: Bool,
        isDestructive: Bool,
        hasSubmenu: Bool
    ) {
        let baseTextColor: NSColor
        if !isEnabled {
            baseTextColor = NSColor(calibratedWhite: 0.42, alpha: 1.0)
        } else if isDestructive {
            baseTextColor = NSColor(calibratedRed: 0.98, green: 0.42, blue: 0.42, alpha: 1.0)
        } else {
            baseTextColor = NSColor(calibratedWhite: 0.93, alpha: 1.0)
        }

        let resolvedIconColor: NSColor
        if !isEnabled {
            resolvedIconColor = NSColor(calibratedWhite: 0.42, alpha: 1.0)
        } else if let custom = iconColor {
            resolvedIconColor = custom
        } else if isDestructive {
            resolvedIconColor = NSColor(calibratedRed: 0.98, green: 0.42, blue: 0.42, alpha: 1.0)
        } else {
            resolvedIconColor = NSColor(calibratedWhite: 0.78, alpha: 1.0)
        }

        let leadingIconView = NSImageView()
        leadingIconView.translatesAutoresizingMaskIntoConstraints = false
        if let icon = icon {
            leadingIconView.image = Lucide.image(icon, size: 14, color: resolvedIconColor)
        } else if isSelected {
            leadingIconView.image = Lucide.image(.check, size: 14, color: .systemCyan)
        }
        addSubview(leadingIconView)

        let titleLbl = NSTextField(labelWithString: title)
        titleLbl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLbl.textColor = baseTextColor
        titleLbl.lineBreakMode = .byTruncatingTail
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLbl)

        var trailingAnchorRef = trailingAnchor
        var trailingPadding: CGFloat = -12

        if hasSubmenu {
            let chev = NSImageView()
            chev.image = Lucide.image(.chevronRight, size: 13, color: NSColor(calibratedWhite: 0.58, alpha: 1.0))
            chev.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chev)
            NSLayoutConstraint.activate([
                chev.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                chev.centerYAnchor.constraint(equalTo: centerYAnchor),
                chev.widthAnchor.constraint(equalToConstant: 13),
                chev.heightAnchor.constraint(equalToConstant: 13)
            ])
            trailingAnchorRef = chev.leadingAnchor
            trailingPadding = -8
        } else if icon != nil && isSelected {
            let chk = NSImageView()
            chk.image = Lucide.image(.check, size: 13, color: .systemCyan)
            chk.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chk)
            NSLayoutConstraint.activate([
                chk.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
                chk.centerYAnchor.constraint(equalTo: centerYAnchor),
                chk.widthAnchor.constraint(equalToConstant: 13),
                chk.heightAnchor.constraint(equalToConstant: 13)
            ])
            trailingAnchorRef = chk.leadingAnchor
            trailingPadding = -8
        } else if let shortcut = shortcut, !shortcut.isEmpty {
            let scLbl = NSTextField(labelWithString: shortcut)
            scLbl.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
            scLbl.textColor = NSColor(calibratedWhite: 0.52, alpha: 1.0)
            scLbl.translatesAutoresizingMaskIntoConstraints = false
            scLbl.setContentHuggingPriority(.required, for: .horizontal)
            scLbl.setContentCompressionResistancePriority(.required, for: .horizontal)
            addSubview(scLbl)
            NSLayoutConstraint.activate([
                scLbl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                scLbl.centerYAnchor.constraint(equalTo: centerYAnchor)
            ])
            trailingAnchorRef = scLbl.leadingAnchor
            trailingPadding = -12
        }

        let hasLeadingVisual = (icon != nil || isSelected)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            leadingIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            leadingIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingIconView.widthAnchor.constraint(equalToConstant: hasLeadingVisual ? 15 : 0),
            leadingIconView.heightAnchor.constraint(equalToConstant: 15),

            titleLbl.leadingAnchor.constraint(
                equalTo: leadingIconView.trailingAnchor,
                constant: hasLeadingVisual ? 8 : 0
            ),
            titleLbl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchorRef, constant: trailingPadding),
            titleLbl.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    private func updateHighlightVisual() {
        switch item {
        case .action(_, _, _, _, _, let isEnabled, let isDestructive, _):
            guard isEnabled else {
                bgLayerView.layer?.backgroundColor = NSColor.clear.cgColor
                return
            }
            if isHighlighted {
                bgLayerView.layer?.backgroundColor = (
                    isDestructive
                    ? NSColor.systemRed.withAlphaComponent(0.18)
                    : NSColor.white.withAlphaComponent(0.11)
                ).cgColor
            } else {
                bgLayerView.layer?.backgroundColor = NSColor.clear.cgColor
            }
        case .submenu(_, _, _, let isEnabled, _):
            guard isEnabled else {
                bgLayerView.layer?.backgroundColor = NSColor.clear.cgColor
                return
            }
            bgLayerView.layer?.backgroundColor = (
                isHighlighted ? NSColor.white.withAlphaComponent(0.11) : NSColor.clear
            ).cgColor
        default:
            bgLayerView.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}

/// Custom floating minimal rounded dark menu (supports nested submenus, click-outside & Esc dismissal).
public final class VisionMenu: NSObject {
    private static var activeRootMenu: VisionMenu?

    private let items: [VisionMenuItem]
    private var panel: VisionMenuPanel?
    private var childSubmenu: VisionMenu?
    private weak var parentMenu: VisionMenu?
    private var rowViews: [VisionMenuRowView] = []
    private var eventMonitor: Any?
    private var onCloseCallback: (() -> Void)?

    public init(items: [VisionMenuItem]) {
        self.items = items
        super.init()
    }

    public static func dismissActive() {
        activeRootMenu?.dismissAll()
    }

    /// Presents below or above an anchor view (ideal for dropdown buttons).
    public func show(below anchorView: NSView, minWidth: CGFloat? = nil, onClose: (() -> Void)? = nil) {
        guard let parentWindow = anchorView.window else { return }
        let anchorRectInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorRectOnScreen = parentWindow.convertToScreen(anchorRectInWindow)
        let resolvedMinWidth = max(minWidth ?? anchorView.bounds.width, 190)
        present(
            nearScreenRect: anchorRectOnScreen,
            preferBelow: true,
            minWidth: resolvedMinWidth,
            parentWindow: parentWindow,
            onClose: onClose
        )
    }

    /// Presents at an NSEvent mouse location (ideal for right-click context menus).
    public func show(for event: NSEvent, in view: NSView, minWidth: CGFloat = 220, onClose: (() -> Void)? = nil) {
        guard let parentWindow = view.window else { return }
        let screenPoint = parentWindow.convertPoint(toScreen: event.locationInWindow)
        let rect = NSRect(origin: screenPoint, size: NSSize(width: 2, height: 2))
        present(
            nearScreenRect: rect,
            preferBelow: true,
            minWidth: minWidth,
            parentWindow: parentWindow,
            onClose: onClose
        )
    }

    private func present(
        nearScreenRect anchorRect: NSRect,
        preferBelow: Bool,
        minWidth: CGFloat,
        parentWindow: NSWindow?,
        onClose: (() -> Void)?
    ) {
        if parentMenu == nil {
            VisionMenu.dismissActive()
            VisionMenu.activeRootMenu = self
        }
        self.onCloseCallback = onClose

        let measuredWidth = computeMenuWidth(minWidth: minWidth)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false

        rowViews.removeAll()
        for item in items {
            let row = VisionMenuRowView(item: item)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.onHover = { [weak self, weak row] _ in
                guard let self = self, let row = row else { return }
                self.handleRowHover(row, width: measuredWidth, parentWindow: parentWindow)
            }
            row.onActivate = { [weak self, weak row] in
                guard let self = self, let row = row else { return }
                self.handleRowActivate(row)
            }
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            rowViews.append(row)
        }

        let container = FlippedStackHost()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 0.98).cgColor
        container.layer?.cornerRadius = 10
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        container.layer?.masksToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let widthConstraint = container.widthAnchor.constraint(equalToConstant: measuredWidth)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            widthConstraint
        ])

        container.layoutSubtreeIfNeeded()
        let totalHeight = max(36, container.fittingSize.height)
        let contentHeight = min(460, totalHeight)

        widthConstraint.isActive = false
        container.translatesAutoresizingMaskIntoConstraints = true
        container.autoresizingMask = [.width]
        container.frame = NSRect(x: 0, y: 0, width: measuredWidth, height: totalHeight)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: measuredWidth, height: contentHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = totalHeight > 460
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = container
        scroll.contentView.scroll(to: .zero)
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.masksToBounds = true

        // Position cleanly on screen without overflow
        let screenFrame = (parentWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var originX = anchorRect.minX
        if originX + measuredWidth > screenFrame.maxX - 8 {
            originX = max(screenFrame.minX + 8, screenFrame.maxX - measuredWidth - 8)
        }
        originX = max(screenFrame.minX + 8, originX)

        var originY: CGFloat
        if preferBelow {
            originY = anchorRect.minY - contentHeight - 4
            if originY < screenFrame.minY + 8 {
                originY = min(screenFrame.maxY - contentHeight - 8, anchorRect.maxY + 4)
            }
        } else {
            originY = anchorRect.maxY - contentHeight
            if originY < screenFrame.minY + 8 {
                originY = screenFrame.minY + 8
            }
        }

        let panelFrame = NSRect(x: originX, y: originY, width: measuredWidth, height: contentHeight)
        let menuPanel = VisionMenuPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        menuPanel.isOpaque = false
        menuPanel.backgroundColor = .clear
        menuPanel.hasShadow = true
        menuPanel.isReleasedWhenClosed = false
        menuPanel.level = .popUpMenu
        menuPanel.contentView = scroll
        self.panel = menuPanel

        parentWindow?.addChildWindow(menuPanel, ordered: .above)
        menuPanel.orderFrontRegardless()

        if parentMenu == nil {
            installDismissMonitor()
        }
    }

    private func computeMenuWidth(minWidth: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        var maxW = minWidth
        for item in items {
            switch item {
            case .action(let title, let icon, _, let shortcut, _, _, _, _):
                let titleW = (title as NSString).size(withAttributes: [.font: font]).width
                let scW = shortcut.map { ($0 as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)]).width + 16 } ?? 0
                let iconW: CGFloat = (icon != nil) ? 24 : 0
                maxW = max(maxW, titleW + scW + iconW + 34)
            case .submenu(let title, let icon, _, _, _):
                let titleW = (title as NSString).size(withAttributes: [.font: font]).width
                let iconW: CGFloat = (icon != nil) ? 24 : 0
                maxW = max(maxW, titleW + iconW + 52)
            case .header(let title):
                let titleW = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold)]).width
                maxW = max(maxW, titleW + 28)
            case .separator:
                break
            }
        }
        return min(380, ceil(maxW))
    }

    private func handleRowHover(_ row: VisionMenuRowView, width: CGFloat, parentWindow: NSWindow?) {
        for r in rowViews {
            r.isHighlighted = (r === row)
        }
        childSubmenu?.dismissPanelOnly()
        childSubmenu = nil

        if case .submenu(_, _, _, let isEnabled, let subItems) = row.item, isEnabled, !subItems.isEmpty, let panel = panel {
            let rowRectInPanel = row.convert(row.bounds, to: nil)
            let rowRectOnScreen = panel.convertToScreen(rowRectInPanel)
            let screenFrame = (parentWindow?.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

            let sub = VisionMenu(items: subItems)
            sub.parentMenu = self
            let subWidth = sub.computeMenuWidth(minWidth: 180)
            var anchorX = panel.frame.maxX - 4
            if anchorX + subWidth > screenFrame.maxX - 8 {
                anchorX = max(screenFrame.minX + 8, panel.frame.minX - subWidth + 4)
            }
            let subAnchor = NSRect(x: anchorX, y: rowRectOnScreen.minY, width: subWidth, height: rowRectOnScreen.height + 6)
            sub.present(nearScreenRect: subAnchor, preferBelow: false, minWidth: subWidth, parentWindow: parentWindow, onClose: nil)
            self.childSubmenu = sub
        }
    }

    private func handleRowActivate(_ row: VisionMenuRowView) {
        guard case .action(_, _, _, _, _, let isEnabled, _, let handler) = row.item, isEnabled else { return }
        rootMenu.dismissAll()
        handler?()
    }

    private var rootMenu: VisionMenu {
        var cur: VisionMenu = self
        while let p = cur.parentMenu { cur = p }
        return cur
    }

    private func menuOwning(_ window: NSWindow?) -> VisionMenu? {
        guard let window = window else { return nil }
        if panel === window { return self }
        return childSubmenu?.menuOwning(window)
    }

    private func ownsWindow(_ window: NSWindow?) -> Bool {
        menuOwning(window) != nil
    }

    private func hitRowView(atWindowPoint windowPoint: NSPoint) -> VisionMenuRowView? {
        guard let contentView = panel?.contentView else { return nil }
        // `NSView.hitTest(_:)` expects a point in `contentView.superview`'s coordinate space
        // (matching `windowPoint` directly; converting into flipped `NSScrollView` beforehand would double-flip Y).
        let ptInSuperview = contentView.superview?.convert(windowPoint, from: nil) ?? windowPoint
        var hit: NSView? = contentView.hitTest(ptInSuperview)
        while let v = hit {
            if let rowView = v as? VisionMenuRowView {
                return rowView
            }
            hit = v.superview
        }
        return nil
    }

    public static func testHitItemTitle(titles: [String], clickingVisualRowAt index: Int, parentWindow: NSWindow) -> String? {
        guard index >= 0 && index < titles.count else { return nil }
        let items: [VisionMenuItem] = titles.map { .action(title: $0) }
        let menu = VisionMenu(items: items)
        menu.present(
            nearScreenRect: NSRect(x: 100, y: 500, width: 140, height: 26),
            preferBelow: true,
            minWidth: 140,
            parentWindow: parentWindow,
            onClose: nil
        )
        defer { menu.dismissAll() }
        menu.panel?.contentView?.layoutSubtreeIfNeeded()
        // Sort rowViews visually from top of screen (maxY in window coords) to bottom
        let visualTopToBottom = menu.rowViews.sorted {
            let y0 = $0.convert($0.bounds, to: nil).midY
            let y1 = $1.convert($1.bounds, to: nil).midY
            return y0 > y1
        }
        guard index < visualTopToBottom.count else { return nil }
        let targetRow = visualTopToBottom[index]
        let windowPt = targetRow.convert(NSPoint(x: targetRow.bounds.midX, y: targetRow.bounds.midY), to: nil)
        guard let hitRow = menu.hitRowView(atWindowPoint: windowPt) else { return nil }
        if case .action(let title, _, _, _, _, _, _, _) = hitRow.item {
            return title
        }
        return nil
    }

    private func installDismissMonitor() {
        removeDismissMonitor()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Esc
                    self.dismissAll()
                    return nil
                }
                return event
            }
            if let owningMenu = self.menuOwning(event.window) {
                if (NSApp.modalWindow != nil || owningMenu.panel?.parent?.isSheet == true),
                   event.type == .leftMouseDown,
                   let rowView = owningMenu.hitRowView(atWindowPoint: event.locationInWindow) {
                    rowView.mouseDown(with: event)
                    return nil
                }
            } else {
                self.dismissAll()
            }
            return event
        }
    }

    private func removeDismissMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func dismissPanelOnly() {
        childSubmenu?.dismissPanelOnly()
        childSubmenu = nil
        if let p = panel {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
        panel = nil
    }

    private func dismissAll() {
        removeDismissMonitor()
        dismissPanelOnly()
        if VisionMenu.activeRootMenu === self {
            VisionMenu.activeRootMenu = nil
        }
        onCloseCallback?()
        onCloseCallback = nil
    }

    deinit {
        removeDismissMonitor()
    }
}

/// Custom unified minimal rounded dropdown button (replaces NSPopUpButton).
public final class VisionDropdownButton: NSView {
    private let bgButton = NSButton()
    private let leadingIconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private var leadingIconWidthConstraint: NSLayoutConstraint?
    private var titleLeadingConstraint: NSLayoutConstraint?

    public private(set) var itemTitles: [String] = []
    public private(set) var selectedIndex: Int = -1
    public var selectedTitle: String? {
        guard selectedIndex >= 0 && selectedIndex < itemTitles.count else { return nil }
        return itemTitles[selectedIndex]
    }
    public var leadingIcon: LucideIcon? {
        didSet { updateLeadingIcon() }
    }
    public var isEnabled: Bool = true {
        didSet { updateEnabledVisual() }
    }

    public weak var target: AnyObject?
    public var action: Selector?
    public var onSelectionChanged: ((Int, String) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, !isHidden, alphaValue > 0.01 else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? bgButton : nil
    }

    private func setupUI() {
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.backgroundColor = NSColor(calibratedWhite: 0.145, alpha: 1.0).cgColor

        leadingIconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leadingIconView)

        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        chevronView.image = Lucide.image(.chevronDown, size: 13, color: NSColor(calibratedWhite: 0.68, alpha: 1.0))
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevronView)

        bgButton.title = ""
        bgButton.isBordered = false
        bgButton.setButtonType(.momentaryChange)
        bgButton.bezelStyle = .regularSquare
        bgButton.target = self
        bgButton.action = #selector(onClicked)
        bgButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bgButton)

        let lw = leadingIconView.widthAnchor.constraint(equalToConstant: 0)
        leadingIconWidthConstraint = lw
        let tl = titleLabel.leadingAnchor.constraint(equalTo: leadingIconView.trailingAnchor, constant: 0)
        titleLeadingConstraint = tl

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 26),

            bgButton.topAnchor.constraint(equalTo: topAnchor),
            bgButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            bgButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            bgButton.trailingAnchor.constraint(equalTo: trailingAnchor),

            leadingIconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            leadingIconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            lw,
            leadingIconView.heightAnchor.constraint(equalToConstant: 14),

            tl,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevronView.leadingAnchor, constant: -6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 13),
            chevronView.heightAnchor.constraint(equalToConstant: 13)
        ])
    }

    public func removeAllItems() {
        itemTitles.removeAll()
        selectedIndex = -1
        titleLabel.stringValue = ""
    }

    public func addItem(withTitle title: String) {
        itemTitles.append(title)
        if selectedIndex < 0 {
            selectedIndex = 0
            titleLabel.stringValue = title
        }
    }

    public func setItems(_ titles: [String]) {
        itemTitles = titles
        if titles.isEmpty {
            selectedIndex = -1
            titleLabel.stringValue = ""
        } else {
            selectedIndex = min(max(0, selectedIndex), titles.count - 1)
            titleLabel.stringValue = titles[selectedIndex]
        }
    }

    public func selectItem(at index: Int) {
        guard index >= 0 && index < itemTitles.count else { return }
        selectedIndex = index
        titleLabel.stringValue = itemTitles[index]
    }

    public func selectItem(withTitle title: String) {
        if let idx = itemTitles.firstIndex(of: title) {
            selectItem(at: idx)
        }
    }

    private func updateLeadingIcon() {
        if let icon = leadingIcon {
            leadingIconView.image = Lucide.image(icon, size: 13, color: isEnabled ? .systemCyan : NSColor(calibratedWhite: 0.45, alpha: 1.0))
            leadingIconWidthConstraint?.constant = 14
            titleLeadingConstraint?.constant = 6
        } else {
            leadingIconView.image = nil
            leadingIconWidthConstraint?.constant = 0
            titleLeadingConstraint?.constant = 0
        }
    }

    private func updateEnabledVisual() {
        bgButton.isEnabled = isEnabled
        titleLabel.textColor = isEnabled ? .white : NSColor(calibratedWhite: 0.45, alpha: 1.0)
        chevronView.image = Lucide.image(.chevronDown, size: 13, color: isEnabled ? NSColor(calibratedWhite: 0.68, alpha: 1.0) : NSColor(calibratedWhite: 0.35, alpha: 1.0))
        layer?.backgroundColor = isEnabled ? NSColor(calibratedWhite: 0.145, alpha: 1.0).cgColor : NSColor(calibratedWhite: 0.11, alpha: 1.0).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(isEnabled ? 0.14 : 0.06).cgColor
        updateLeadingIcon()
        needsDisplay = true
    }

    @objc private func onClicked() {
        guard isEnabled, !itemTitles.isEmpty else { return }
        layer?.borderColor = NSColor.systemCyan.withAlphaComponent(0.75).cgColor
        let menuItems: [VisionMenuItem] = itemTitles.enumerated().map { idx, title in
            .action(
                title: title,
                isSelected: idx == self.selectedIndex,
                handler: { [weak self] in
                    guard let self = self else { return }
                    self.selectItem(at: idx)
                    self.onSelectionChanged?(idx, title)
                    if let target = self.target, let action = self.action {
                        NSApp.sendAction(action, to: target, from: self)
                    }
                }
            )
        }
        let menu = VisionMenu(items: menuItems)
        menu.show(below: self) { [weak self] in
            self?.updateEnabledVisual()
        }
    }
}
