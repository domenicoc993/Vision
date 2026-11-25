import AppKit
import AVFoundation

public final class TimelineGridView: NSView {
    public var timelineModel: TimelineModel? {
        didSet {
            if oldValue?.id != timelineModel?.id {
                placeholderSlot = nil
                hoveredGapSlot = nil
            }
            recalculateLayout()
            needsDisplay = true
        }
    }
    public var selectedTrackIndex: Int = 0 {
        didSet {
            if oldValue != selectedTrackIndex {
                placeholderSlot = nil
                hoveredGapSlot = nil
            }
            recalculateLayout()
            needsDisplay = true
        }
    }

    public var onClipSelected: ((TimelineClip) -> Void)?
    public var onSelectionChanged: (() -> Void)?
    public var onReorderCommitted: (() -> Void)?
    public var onSectionActivated: (() -> Void)?
    public var onDropMediaIdsAtSlot: (([UUID], Int, Int) -> Void)?
    public var onDropURLsAtSlot: (([URL], Int, Int) -> Void)?
    public var onDropSelectionAtSlot: ((UUID, Int, Int) -> Void)?
    public var onDeleteSelectedFromGrid: (() -> Void)?
    public var onClipContextMenuRequested: ((_ clip: TimelineClip, _ event: NSEvent, _ sourceView: NSView, _ extraTopItems: [VisionMenuItem]) -> Void)?

    private var thumbObserver: Any?
    private var selectionObserver: Any?
    private var thumbRedrawWorkItem: DispatchWorkItem?
    private var isExternalDragOver: Bool = false

    private let baseMinCardWidth: CGFloat = 115
    private let spacing: CGFloat = 10
    private let margin: CGFloat = 12

    public var cardScale: CGFloat = 1.0 {
        didSet {
            let clamped = max(0.75, min(1.25, cardScale))
            if clamped != cardScale {
                cardScale = clamped
                return
            }
            if abs(oldValue - cardScale) > 0.001 {
                updateLayoutForCurrentWidth()
                needsDisplay = true
            }
        }
    }

    private var scaledMinCardWidth: CGFloat {
        round(baseMinCardWidth * cardScale)
    }

    private func cardHeight(forWidth cardW: CGFloat) -> CGFloat {
        let minH = round(96 * cardScale)
        let maxH = round(140 * cardScale)
        return max(minH, min(maxH, floor(cardW * 0.88)))
    }

    private var currentCardWidth: CGFloat = 125
    private var currentCardHeight: CGFloat = 110

    // Drag-to-reorder, Multi-selection & Inter-clip Segnaposto temporaneo state
    private var draggedIndex: Int? = nil
    private var draggedGroupIndices: Set<Int> = []
    private var selectionAnchorIndex: Int? = nil
    private var isDragging: Bool = false
    private var dragCurrentLocation: NSPoint = .zero
    private var dragStartLocation: NSPoint = .zero
    private var activeInsertionSlot: Int? = nil // Index 0...N where the glowing beam appears
    private var activeInsertionSlotBlocked: Bool = false
    public private(set) var placeholderSlot: Int? = nil
    private var hoveredGapSlot: Int? = nil
    private var gapTrackingArea: NSTrackingArea?

    private static let cachedCheckBadgeImage: NSImage = Lucide.image(.check, size: 9, color: .black)
    private static let cachedSnailBadgeImage: NSImage = Lucide.image(.snail, size: 10, color: .black)
    private static let cachedLockBadgeImage: NSImage = Lucide.image(.lock, size: 9, color: .black)

    // Rubber-Band Marquee Selection state
    private var isMarqueeSelecting: Bool = false
    private var marqueeRect: NSRect? = nil

    private var cardFrames: [NSRect] = []

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width]
        registerForDraggedTypes([
            kMediaItemPasteboardType,
            kSelectionPasteboardType,
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType")
        ])
        thumbObserver = NotificationCenter.default.addObserver(
            forName: ThumbnailCache.thumbnailReadyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, !self.isHidden else { return }
            self.thumbRedrawWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.needsDisplay = true
            }
            self.thumbRedrawWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: item)
        }
        selectionObserver = NotificationCenter.default.addObserver(
            forName: TimelineModel.selectionChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            guard let self = self else { return }
            if (notif.object as AnyObject?) === self.timelineModel {
                self.needsDisplay = true
            }
        }
    }

    deinit {
        if let obs = thumbObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        if let selObs = selectionObserver {
            NotificationCenter.default.removeObserver(selObs)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let superview = superview {
            postsFrameChangedNotifications = true
            superview.postsBoundsChangedNotifications = true
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: superview)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSuperviewBoundsChanged),
                name: NSView.boundsDidChangeNotification,
                object: superview
            )
            NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: superview)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleSuperviewBoundsChanged),
                name: NSView.frameDidChangeNotification,
                object: superview
            )
            updateLayoutForCurrentWidth()
        }
    }

    @objc private func handleSuperviewBoundsChanged() {
        updateLayoutForCurrentWidth()
    }

    public var currentClips: [TimelineClip] {
        guard let model = timelineModel, selectedTrackIndex < model.videoTracks.count else { return [] }
        return model.videoTracks[selectedTrackIndex].clips
    }

    public var calculatedTotalHeight: CGFloat {
        let clips = currentClips
        guard !clips.isEmpty else { return 240 }

        let width = bounds.width > 0 ? bounds.width : 320
        let minW = scaledMinCardWidth
        let availableWidth = max(minW, width - margin * 2)
        let cols = max(1, Int((availableWidth + spacing) / (minW + spacing)))
        let cardW = floor((availableWidth - CGFloat(cols - 1) * spacing) / CGFloat(cols))
        let rowH = cardHeight(forWidth: cardW)
        let rows = (clips.count + cols - 1) / cols
        let height = margin * 2 + CGFloat(rows) * rowH + CGFloat(max(0, rows - 1)) * spacing + 40
        return max(240, height)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: bounds.width > 0 ? bounds.width : 320, height: calculatedTotalHeight)
    }

    public func updateLayoutForCurrentWidth() {
        guard let clipView = superview as? NSClipView ?? superview else { return }
        let targetWidth = max(240, clipView.bounds.width)
        if abs(frame.width - targetWidth) > 1 {
            frame.size.width = targetWidth
        }
        recalculateLayout()
        let targetHeight = max(clipView.bounds.height, calculatedTotalHeight)
        if abs(frame.height - targetHeight) > 1 {
            frame.size.height = targetHeight
        }
        needsDisplay = true
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updateLayoutForCurrentWidth()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = gapTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        gapTrackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        guard !isDragging, !isMarqueeSelecting else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let hitGap = gapSlotAt(pt)
        if hitGap != hoveredGapSlot {
            hoveredGapSlot = hitGap
            needsDisplay = true
        }
        if hitGap != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        if hoveredGapSlot != nil {
            hoveredGapSlot = nil
            needsDisplay = true
        }
        NSCursor.arrow.set()
    }

    public func reloadData() {
        updateLayoutForCurrentWidth()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    public func scrollToClipIfNeeded(_ clipId: UUID) {
        let clips = currentClips
        guard let idx = clips.firstIndex(where: { $0.id == clipId }),
              idx < cardFrames.count else { return }
        scrollToVisible(cardFrames[idx].insetBy(dx: 0, dy: -8))
        needsDisplay = true
    }

    // MARK: - Multi-Column Responsive Layout (1 2 3 4 / 5 6 7 8 / 9 10 etc.)
    private func recalculateLayout() {
        let clips = currentClips
        cardFrames.removeAll()

        let width = bounds.width > 0 ? bounds.width : 320
        let minW = scaledMinCardWidth
        let availableWidth = max(minW, width - margin * 2)
        let cols = max(1, Int((availableWidth + spacing) / (minW + spacing)))

        currentCardWidth = floor((availableWidth - CGFloat(cols - 1) * spacing) / CGFloat(cols))
        currentCardHeight = cardHeight(forWidth: currentCardWidth)

        for idx in 0..<clips.count {
            let col = idx % cols
            let row = idx / cols
            let x = margin + CGFloat(col) * (currentCardWidth + spacing)
            let y = margin + CGFloat(row) * (currentCardHeight + spacing)
            cardFrames.append(NSRect(x: x, y: y, width: currentCardWidth, height: currentCardHeight))
        }

        if let p = placeholderSlot {
            if clips.isEmpty {
                placeholderSlot = nil
            } else {
                placeholderSlot = max(0, min(clips.count, p))
            }
        }
        if let h = hoveredGapSlot, h > clips.count {
            hoveredGapSlot = nil
        }

        invalidateIntrinsicContentSize()
    }

    // MARK: - Drawing
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dark Studio background
        ctx.setFillColor(NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor)
        ctx.fill(bounds)

        let clips = currentClips

        // Empty state message
        if clips.isEmpty {
            let msg = "Nessuna clip sulla traccia V\(selectedTrackIndex + 1)\nTrascina clip qui o dal Media Pool per iniziare il montaggio a griglia."
            drawCenteredText(msg, in: bounds, color: .secondaryLabelColor, fontSize: 13)
            return
        }

        // 1. Draw settled cards
        let selectedIds = timelineModel?.selectedClipIds ?? []
        for (idx, clip) in clips.enumerated() {
            guard idx < cardFrames.count else { continue }
            let frame = cardFrames[idx]

            if isDragging && (draggedIndex == idx || draggedGroupIndices.contains(idx)) {
                drawPlaceholderCard(frame: frame, index: idx + 1, ctx: ctx)
            } else {
                let isSelected = selectedIds.contains(clip.id)
                drawCard(clip: clip, frame: frame, sequenceNum: idx + 1, isSelected: isSelected, alpha: 1.0, ctx: ctx)
            }
        }

        // 2. Draw Hovered Gap Preview & Active Segnaposto Temporaneo & Insertion Slot Beam
        if !isDragging && !isExternalDragOver {
            if let hoverSlot = hoveredGapSlot, hoverSlot != placeholderSlot {
                drawInsertionBeam(slot: hoverSlot, color: NSColor.systemOrange.withAlphaComponent(0.55), isSolidPin: false, badgeTitle: nil, ctx: ctx)
            }
            if let pSlot = placeholderSlot {
                let isRemovingHover = (hoveredGapSlot == pSlot)
                drawInsertionBeam(
                    slot: pSlot,
                    color: isRemovingHover ? NSColor.systemYellow : NSColor.systemOrange,
                    isSolidPin: true,
                    badgeTitle: isRemovingHover ? "RIMUOVI" : "SEGNAPOSTO",
                    ctx: ctx
                )
            }
        }
        if (isDragging || isExternalDragOver), let slot = activeInsertionSlot {
            let beamColor: NSColor = (isDragging && activeInsertionSlotBlocked) ? .systemRed : .systemCyan
            drawInsertionBeam(slot: slot, color: beamColor, isSolidPin: true, badgeTitle: nil, ctx: ctx)
        }

        // 3. Draw Floating Dragged Ghost Card under cursor
        if isDragging, let idx = draggedIndex, idx < clips.count {
            let clip = clips[idx]
            let ghostOrigin = CGPoint(
                x: dragCurrentLocation.x - currentCardWidth / 2.0,
                y: dragCurrentLocation.y - currentCardHeight / 2.0
            )
            let ghostFrame = NSRect(origin: ghostOrigin, size: NSSize(width: currentCardWidth, height: currentCardHeight))
            drawFloatingGhostCard(clip: clip, frame: ghostFrame, sequenceNum: idx + 1, groupCount: max(1, draggedGroupIndices.count), ctx: ctx)
        }

        // 4. Draw Rubber-Band Marquee Selection Box
        if isMarqueeSelecting, let rect = marqueeRect {
            drawMarqueeBox(rect: rect, ctx: ctx)
        }
    }

    private func gridPriorityColor(for priority: Int) -> NSColor? {
        switch priority {
        case 1: return NSColor(calibratedRed: 0.36, green: 0.72, blue: 0.98, alpha: 1.0)
        case 2: return NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.85, alpha: 1.0)
        case 3: return NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.48, alpha: 1.0)
        case 4: return NSColor(calibratedRed: 0.56, green: 0.24, blue: 0.74, alpha: 1.0)
        default: return nil
        }
    }

    private func cardTimelineColor(for clip: TimelineClip) -> NSColor {
        if clip.isOrphan {
            return NSColor(calibratedRed: 0.55, green: 0.14, blue: 0.14, alpha: 1.0)
        }
        if clip.isApproved {
            return NSColor(calibratedRed: 0.13, green: 0.49, blue: 0.27, alpha: 1.0)
        }
        if let customColor = clip.colorTag?.nsColor {
            return customColor
        }
        if let p = clip.priority, let pColor = gridPriorityColor(for: p) {
            return pColor
        }
        return NSColor(calibratedWhite: 0.135, alpha: 1.0)
    }

    private func drawCard(clip: TimelineClip, frame: NSRect, sequenceNum: Int, isSelected: Bool, alpha: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(alpha)

        let footerHeight: CGFloat = 22
        let thumbHeight = max(50, frame.height - footerHeight - 6)
        let cardColor = cardTimelineColor(for: clip)
        let isCustomOrApproved = clip.isOrphan || clip.isApproved || clip.colorTag != nil || clip.priority != nil

        // Card Container rounded rectangle (colorata in modo speculare alla timeline)
        let path = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        if clip.isOrphan {
            NSColor(calibratedRed: 0.40, green: 0.10, blue: 0.10, alpha: 1.0).setFill()
        } else if isCustomOrApproved {
            cardColor.withAlphaComponent(0.92).setFill()
        } else {
            NSColor(calibratedWhite: 0.125, alpha: 1.0).setFill()
        }
        path.fill()

        // Thumbnail Area (top portion of card)
        let thumbRect = NSRect(x: frame.minX + 3, y: frame.minY + 3, width: frame.width - 6, height: thumbHeight)
        ctx.saveGState()
        let thumbPath = NSBezierPath(roundedRect: thumbRect, xRadius: 4, yRadius: 4)
        thumbPath.addClip()

        if clip.mediaItem.hasVideo {
            let captureSec = CMTimeGetSeconds(clip.sourceIn) + min(1.2, CMTimeGetSeconds(clip.duration) * 0.25)
            let cachedThumb = ThumbnailCache.shared.thumbnail(
                for: clip.mediaItem.effectiveURL,
                atSeconds: captureSec,
                durationSeconds: CMTimeGetSeconds(clip.mediaItem.duration),
                fallbackImage: clip.mediaItem.thumbnail
            )
            if let thumb = cachedThumb {
                Self.drawAspectFill(image: thumb, in: thumbRect)
            } else {
                NSColor(calibratedWhite: 0.08, alpha: 1.0).setFill()
                thumbPath.fill()
                let icon = Lucide.image(.film, size: 22, color: NSColor(calibratedWhite: 0.48, alpha: 1.0))
                icon.draw(in: NSRect(x: thumbRect.midX - 11, y: thumbRect.midY - 11, width: 22, height: 22))
            }
        } else {
            NSColor(srgbRed: 0.07, green: 0.14, blue: 0.11, alpha: 1.0).setFill()
            thumbPath.fill()
            let icon = Lucide.image(.music, size: 22, color: .systemGreen)
            icon.draw(in: NSRect(x: thumbRect.midX - 11, y: thumbRect.midY - 11, width: 22, height: 22))
        }
        ctx.restoreGState()

        // Card Outline (speculare ai bordi Timeline: Rosso = selezionata, Verde = approvata, Arancio = bloccata)
        if isSelected {
            NSColor.systemRed.setStroke()
            path.lineWidth = clip.isOrphan ? 3.0 : 2.5
            path.stroke()
        } else if clip.isOrphan {
            NSColor.systemRed.setStroke()
            path.lineWidth = 2.0
            path.stroke()
        } else if clip.isApproved {
            NSColor(calibratedRed: 0.30, green: 0.90, blue: 0.52, alpha: 1.0).setStroke()
            path.lineWidth = 2.0
            path.stroke()
        } else if clip.isLocked {
            NSColor.systemOrange.setStroke()
            path.lineWidth = 1.8
            path.stroke()
        } else {
            NSColor(calibratedWhite: 0.28, alpha: 1.0).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }

        // Clip Duration Badge in top-right (nessun #index e nessun nome)
        let clipDurSec = max(0.0, CMTimeGetSeconds(clip.duration))
        let durMin = Int(clipDurSec) / 60
        let durSec = Int(clipDurSec) % 60
        let durStr = String(format: "%02d:%02d", durMin, durSec)
        let durRect = NSRect(x: frame.maxX - 42, y: frame.minY + 6, width: 36, height: 15)
        let durPath = NSBezierPath(roundedRect: durRect, xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.82).setFill()
        durPath.fill()
        drawText(durStr, at: CGPoint(x: durRect.minX + 4, y: durRect.minY + 1.5), color: .white, fontSize: 9, bold: true)

        // Footer Area (senza nome clip: start timecode/gabbia a sinistra + badge spunta/snail/lock/span a destra)
        let footerY = frame.minY + thumbHeight + 4
        let footerMidY = footerY + (footerHeight - 2) * 0.5
        let inSec = max(0.0, CMTimeGetSeconds(clip.timelineStart))
        let inStr = String(format: "%02d:%02d", Int(inSec) / 60, Int(inSec) % 60)
        let timeColor: NSColor = isCustomOrApproved ? .white : .systemCyan
        drawText(inStr, at: CGPoint(x: frame.minX + 6, y: footerMidY - 6), color: timeColor, fontSize: 9.5, bold: true)

        var badgeX = frame.maxX - 5
        let pillY = footerMidY - 6

        if clip.speed < 0.99 {
            badgeX -= 15
            let snailPill = CGRect(x: badgeX, y: pillY, width: 15, height: 12)
            ctx.setFillColor(NSColor.systemYellow.cgColor)
            ctx.addPath(CGPath(roundedRect: snailPill, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            Self.cachedSnailBadgeImage.draw(in: CGRect(x: badgeX + 2.5, y: pillY + 1.0, width: 10, height: 10))
            badgeX -= 3
        } else if clip.speed > 1.01 {
            let speedStr = "\(Int(clip.speed * 100))%"
            let sAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold), .foregroundColor: NSColor.black]
            let sSize = (speedStr as NSString).size(withAttributes: sAttrs)
            let pillW = sSize.width + 6
            badgeX -= pillW
            let pill = CGRect(x: badgeX, y: pillY, width: pillW, height: 12)
            ctx.setFillColor(NSColor.systemYellow.cgColor)
            ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            (speedStr as NSString).draw(at: CGPoint(x: badgeX + 3, y: pillY + 0.5), withAttributes: sAttrs)
            badgeX -= 3
        }

        if clip.isApproved {
            badgeX -= 14
            let checkPill = CGRect(x: badgeX, y: pillY, width: 14, height: 12)
            ctx.setFillColor(NSColor(calibratedRed: 0.35, green: 0.92, blue: 0.54, alpha: 0.96).cgColor)
            ctx.addPath(CGPath(roundedRect: checkPill, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            Self.cachedCheckBadgeImage.draw(in: CGRect(x: badgeX + 2.5, y: pillY + 1.5, width: 9, height: 9))
            badgeX -= 3
        }

        if clip.isLocked {
            badgeX -= 14
            let lockPill = CGRect(x: badgeX, y: pillY, width: 14, height: 12)
            ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.95).cgColor)
            ctx.addPath(CGPath(roundedRect: lockPill, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            Self.cachedLockBadgeImage.draw(in: CGRect(x: badgeX + 2.5, y: pillY + 1.5, width: 9, height: 9))
            badgeX -= 3
        }

        if let p = clip.priority, let pColor = gridPriorityColor(for: p), badgeX - 14 > frame.minX + 38 {
            let pStr = "\(p)"
            let pAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold), .foregroundColor: NSColor.white]
            let pSize = (pStr as NSString).size(withAttributes: pAttrs)
            let pillW = max(13.0, pSize.width + 5)
            badgeX -= pillW
            let pPill = CGRect(x: badgeX, y: pillY, width: pillW, height: 12)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            let pPath = CGPath(roundedRect: pPill, cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.addPath(pPath)
            ctx.fillPath()
            ctx.setStrokeColor(pColor.cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(pPath)
            ctx.strokePath()
            (pStr as NSString).draw(at: CGPoint(x: badgeX + (pillW - pSize.width) * 0.5, y: pillY + 0.5), withAttributes: pAttrs)
        }

        ctx.restoreGState()
    }

    private func drawPlaceholderCard(frame: NSRect, index: Int, ctx: CGContext) {
        let path = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        NSColor(calibratedWhite: 0.10, alpha: 0.6).setFill()
        path.fill()

        let strokeColor = NSColor(calibratedWhite: 0.28, alpha: 0.6)
        strokeColor.setStroke()
        path.lineWidth = 1.5
        let pattern: [CGFloat] = [4, 4]
        path.setLineDash(pattern, count: 2, phase: 0)
        path.stroke()
    }

    private func drawFloatingGhostCard(clip: TimelineClip, frame: NSRect, sequenceNum: Int, groupCount: Int = 1, ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: NSColor.black.withAlphaComponent(0.8).cgColor)
        drawCard(clip: clip, frame: frame, sequenceNum: sequenceNum, isSelected: true, alpha: 0.72, ctx: ctx)
        if groupCount > 1 {
            let countStr = "×\(groupCount)"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.black]
            let sz = (countStr as NSString).size(withAttributes: attrs)
            let pillW = sz.width + 10
            let pillRect = CGRect(x: frame.minX + 6, y: frame.minY + 6, width: pillW, height: 16)
            ctx.setFillColor(NSColor.systemCyan.cgColor)
            ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            (countStr as NSString).draw(at: CGPoint(x: pillRect.minX + 5, y: pillRect.minY + 1.5), withAttributes: attrs)
        }
        ctx.restoreGState()
    }

    // Glowing vertical insertion / segnaposto beam ("le intersezioni verticali tra clip che si illuminano")
    private func drawInsertionBeam(
        slot: Int,
        color beamColor: NSColor,
        isSolidPin: Bool,
        badgeTitle: String?,
        ctx: CGContext
    ) {
        let clips = currentClips
        guard !clips.isEmpty else { return }

        let lineX: CGFloat
        let lineYTop: CGFloat
        let lineYBottom: CGFloat

        if slot == 0, let firstFrame = cardFrames.first {
            lineX = max(4, firstFrame.minX - spacing / 2.0)
            lineYTop = firstFrame.minY - 4
            lineYBottom = firstFrame.maxY + 4
        } else if slot >= cardFrames.count, let lastFrame = cardFrames.last {
            lineX = min(bounds.width - 4, lastFrame.maxX + spacing / 2.0)
            lineYTop = lastFrame.minY - 4
            lineYBottom = lastFrame.maxY + 4
        } else if slot < cardFrames.count {
            let leftFrame = cardFrames[slot - 1]
            let rightFrame = cardFrames[slot]

            if abs(leftFrame.midY - rightFrame.midY) < 12 {
                // Same row
                lineX = (leftFrame.maxX + rightFrame.minX) / 2.0
                lineYTop = leftFrame.minY - 4
                lineYBottom = leftFrame.maxY + 4
            } else {
                // Start of next row
                lineX = max(4, rightFrame.minX - spacing / 2.0)
                lineYTop = rightFrame.minY - 4
                lineYBottom = rightFrame.maxY + 4
            }
        } else {
            return
        }

        ctx.saveGState()

        if isSolidPin {
            ctx.setStrokeColor(beamColor.withAlphaComponent(0.38).cgColor)
            ctx.setLineWidth(8.0)
            ctx.setLineCap(.round)
            ctx.strokeLineSegments(between: [CGPoint(x: lineX, y: lineYTop), CGPoint(x: lineX, y: lineYBottom)])

            ctx.setStrokeColor(beamColor.withAlphaComponent(0.92).cgColor)
            ctx.setLineWidth(4.0)
            ctx.strokeLineSegments(between: [CGPoint(x: lineX, y: lineYTop), CGPoint(x: lineX, y: lineYBottom)])

            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.8)
            ctx.strokeLineSegments(between: [CGPoint(x: lineX, y: lineYTop + 2), CGPoint(x: lineX, y: lineYBottom - 2)])
        } else {
            ctx.setStrokeColor(beamColor.cgColor)
            ctx.setLineWidth(3.0)
            ctx.setLineCap(.round)
            ctx.strokeLineSegments(between: [CGPoint(x: lineX, y: lineYTop + 2), CGPoint(x: lineX, y: lineYBottom - 2)])
        }

        let dotSize: CGFloat = isSolidPin ? 8 : 6
        ctx.setFillColor(beamColor.cgColor)
        ctx.fillEllipse(in: CGRect(x: lineX - dotSize / 2, y: lineYTop - dotSize / 2, width: dotSize, height: dotSize))
        ctx.fillEllipse(in: CGRect(x: lineX - dotSize / 2, y: lineYBottom - dotSize / 2, width: dotSize, height: dotSize))

        if let badgeTitle = badgeTitle, !badgeTitle.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 8, weight: .heavy),
                .foregroundColor: NSColor.black
            ]
            let size = (badgeTitle as NSString).size(withAttributes: attrs)
            let pillW = size.width + 8
            let pillH: CGFloat = 13
            let pillX = max(4, min(bounds.width - pillW - 4, lineX - pillW * 0.5))
            let pillY = max(2, lineYTop - 7)
            let pillRect = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)
            ctx.setFillColor(beamColor.cgColor)
            ctx.addPath(CGPath(roundedRect: pillRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            (badgeTitle as NSString).draw(at: CGPoint(x: pillX + 4, y: pillY + 1.5), withAttributes: attrs)
        }

        ctx.restoreGState()
    }

    private func drawMarqueeBox(rect: NSRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.18).cgColor)
        ctx.fill(rect)

        ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.5)
        let path = NSBezierPath(rect: rect)
        let dash: [CGFloat] = [4, 4]
        path.setLineDash(dash, count: 2, phase: 0)
        path.stroke()
        ctx.restoreGState()
    }

    public func selectAllClips() {
        guard let model = timelineModel else { return }
        let clips = currentClips
        model.selectedClipIds = model.linkedSelectionIds(for: Set(clips.map(\.id)))
        onSelectionChanged?()
        needsDisplay = true
    }

    // MARK: - Interactive Event Tracking Loop (Smooth Dragging + Marquee Selection)
    public override func mouseDown(with event: NSEvent) {
        onSectionActivated?()
        let localPoint = convert(event.locationInWindow, from: nil)
        let isShift = event.modifierFlags.contains(.shift)
        let isCommand = event.modifierFlags.contains(.command)

        // 1. Check if user clicked on a card
        var hitIndex: Int? = nil
        for (idx, frame) in cardFrames.enumerated() {
            if frame.contains(localPoint) {
                hitIndex = idx
                break
            }
        }

        if let srcIdx = hitIndex {
            // Click or Drag on Card
            let clips = currentClips
            guard srcIdx < clips.count else { return }
            let hitClip = clips[srcIdx]
            let linkedPair = timelineModel?.linkedSelectionIds(for: [hitClip.id]) ?? [hitClip.id]
            var collapseToPairIfNoDrag: Set<UUID>? = nil

            if isShift {
                // Shift + Click: seleziona dal primo elemento (ancora) fino all'ultimo cliccato
                let currentSel = timelineModel?.selectedClipIds ?? []
                let anchor: Int = {
                    if let a = selectionAnchorIndex, a >= 0, a < clips.count { return a }
                    if let firstSel = clips.firstIndex(where: { currentSel.contains($0.id) }) { return firstSel }
                    return srcIdx
                }()
                if selectionAnchorIndex == nil {
                    selectionAnchorIndex = anchor
                }
                let lo = min(anchor, srcIdx)
                let hi = max(anchor, srcIdx)
                let baseRangeIds = Set((lo...hi).map { clips[$0].id })
                let expandedRange = timelineModel?.linkedSelectionIds(for: baseRangeIds) ?? baseRangeIds
                if isCommand {
                    timelineModel?.selectedClipIds.formUnion(expandedRange)
                } else {
                    timelineModel?.selectedClipIds = expandedRange
                }
            } else if isCommand {
                // Cmd + Click: toggle selezione del singolo elemento (con audio linkato)
                selectionAnchorIndex = srcIdx
                if timelineModel?.selectedClipIds.contains(hitClip.id) == true {
                    timelineModel?.selectedClipIds.subtract(linkedPair)
                } else {
                    timelineModel?.selectedClipIds.formUnion(linkedPair)
                }
            } else {
                selectionAnchorIndex = srcIdx
                let trackSelectedCount = clips.filter { timelineModel?.selectedClipIds.contains($0.id) == true }.count
                if timelineModel?.selectedClipIds.contains(hitClip.id) != true {
                    timelineModel?.selectedClipIds = linkedPair
                } else {
                    if let model = timelineModel {
                        model.selectedClipIds = model.linkedSelectionIds(for: model.selectedClipIds)
                    }
                    if trackSelectedCount > 1 {
                        collapseToPairIfNoDrag = linkedPair
                    }
                }
            }
            if !isShift && !isCommand {
                onClipSelected?(hitClip)
            }
            onSelectionChanged?()
            needsDisplay = true

            // Regole di Timeline specchiate: clip bloccate/approvate 🔒 non si trascinano!
            let selectedIds = timelineModel?.selectedClipIds ?? []
            let movingClipsOnTrack = clips.filter { selectedIds.contains($0.id) }
            let isLockedMove = hitClip.isEffectivelyLocked || (movingClipsOnTrack.count > 1 && selectedIds.contains(hitClip.id) && movingClipsOnTrack.contains(where: { $0.isEffectivelyLocked }))
            if isLockedMove {
                if let collapsePair = collapseToPairIfNoDrag {
                    timelineModel?.selectedClipIds = collapsePair
                    onSelectionChanged?()
                    needsDisplay = true
                }
                DebugLogger.shared.log("Clip bloccata o approvata 🔒: sblocca prima di spostarla.", level: .warning)
                return
            }

            // Run Modal Event Tracking Loop for Card Drag-and-Drop Reordering
            runCardDragTrackingLoop(fromIndex: srcIdx, startPoint: localPoint, collapseToSelectionIfNotDragged: collapseToPairIfNoDrag)
        } else if !isShift && !isCommand, let gapSlot = gapSlotAt(localPoint) {
            // Click in un intermezzo tra clip: piazza/rimuovi segnaposto temporaneo; se trascinato diventa Marquee Selection
            trackGapClickOrMarquee(startPoint: localPoint, gapSlot: gapSlot)
        } else {
            // Click or Drag on Empty Background: Rubber-Band Marquee Box Selection!
            runMarqueeTrackingLoop(startPoint: localPoint, isAdditive: isShift || isCommand)
        }
    }

    public override func rightMouseDown(with event: NSEvent) {
        onSectionActivated?()
        let localPoint = convert(event.locationInWindow, from: nil)
        let clips = currentClips
        var hitClip: TimelineClip? = nil
        for (idx, frame) in cardFrames.enumerated() where idx < clips.count {
            if frame.contains(localPoint) {
                hitClip = clips[idx]
                break
            }
        }
        if let clip = hitClip {
            if timelineModel?.selectedClipIds.contains(clip.id) != true {
                timelineModel?.selectedClipIds = timelineModel?.linkedSelectionIds(for: [clip.id]) ?? [clip.id]
                onSelectionChanged?()
                needsDisplay = true
            }
            onClipSelected?(clip)

            var extraItems: [VisionMenuItem] = []
            if let pSlot = placeholderSlot {
                let selectedIds = timelineModel?.selectedClipIds ?? []
                let trackSelectedIds = Set(clips.filter { selectedIds.contains($0.id) }.map(\.id))
                let movingIds: Set<UUID> = (trackSelectedIds.count > 1 && trackSelectedIds.contains(clip.id)) ? trackSelectedIds : [clip.id]
                let hasLockedInMoving = clips.filter { movingIds.contains($0.id) }.contains(where: { $0.isEffectivelyLocked })
                let canMove = !hasLockedInMoving && (timelineModel?.canDropGridReorder(movingClipIds: movingIds, toSlot: pSlot, trackIndex: selectedTrackIndex) ?? false)
                let moveTitle: String
                if hasLockedInMoving {
                    moveTitle = "Sposta a segnaposto (sblocca clip prima)"
                } else if !canMove {
                    moveTitle = "Sposta a segnaposto (bloccato 🔒)"
                } else if movingIds.count > 1 {
                    moveTitle = "Sposta \(movingIds.count) clip a segnaposto"
                } else {
                    moveTitle = "Sposta a segnaposto"
                }
                extraItems.append(.action(
                    title: moveTitle,
                    icon: .bookmark,
                    iconColor: .systemOrange,
                    isEnabled: canMove
                ) { [weak self] in
                    self?.moveClipsToPlaceholder(movingIds: movingIds, anchorClipId: clip.id, toSlot: pSlot)
                })
            }

            if let handler = onClipContextMenuRequested {
                handler(clip, event, self, extraItems)
            } else {
                var fallbackItems = extraItems
                if !fallbackItems.isEmpty { fallbackItems.append(.separator) }
                fallbackItems.append(.action(title: "Elimina dalla sequenza", icon: .trash, isDestructive: true) { [weak self] in
                    self?.onDeleteSelectedFromGrid?()
                })
                VisionMenu(items: fallbackItems).show(for: event, in: self)
            }
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? { nil }

    private func runCardDragTrackingLoop(fromIndex: Int, startPoint: NSPoint, collapseToSelectionIfNotDragged: Set<UUID>? = nil) {
        hoveredGapSlot = nil
        var didStartDrag = false
        let clips = currentClips
        let selIds = timelineModel?.selectedClipIds ?? []
        let groupIdxs = Set(clips.enumerated().compactMap { selIds.contains($0.element.id) ? $0.offset : nil })
        draggedGroupIndices = (groupIdxs.count > 1 && groupIdxs.contains(fromIndex)) ? groupIdxs : [fromIndex]
        draggedIndex = fromIndex
        dragStartLocation = startPoint
        dragCurrentLocation = startPoint
        activeInsertionSlot = nil
        activeInsertionSlotBlocked = false

        while true {
            guard let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let currentPt = convert(nextEvent.locationInWindow, from: nil)

            if nextEvent.type == .leftMouseDragged {
                let dx = abs(currentPt.x - startPoint.x)
                let dy = abs(currentPt.y - startPoint.y)

                if !didStartDrag && (dx > 4 || dy > 4) {
                    didStartDrag = true
                    isDragging = true
                }

                if didStartDrag {
                    dragCurrentLocation = currentPt
                    let slot = findInsertionSlot(at: currentPt, sourceIndex: fromIndex)
                    activeInsertionSlot = slot
                    let liveClips = currentClips
                    let selectedIds = timelineModel?.selectedClipIds ?? []
                    let trackSelectedIds = Set(liveClips.filter { selectedIds.contains($0.id) }.map(\.id))
                    let movingIds: Set<UUID> = (trackSelectedIds.count > 1 && fromIndex < liveClips.count && trackSelectedIds.contains(liveClips[fromIndex].id))
                        ? trackSelectedIds
                        : (fromIndex < liveClips.count ? [liveClips[fromIndex].id] : [])
                    activeInsertionSlotBlocked = !(timelineModel?.canDropGridReorder(movingClipIds: movingIds, toSlot: slot, trackIndex: selectedTrackIndex) ?? false)
                    needsDisplay = true
                }
            } else if nextEvent.type == .leftMouseUp {
                if !didStartDrag, let collapseIds = collapseToSelectionIfNotDragged {
                    timelineModel?.selectedClipIds = collapseIds
                    onSelectionChanged?()
                } else if didStartDrag, let slot = activeInsertionSlot, !activeInsertionSlotBlocked {
                    let liveClips = currentClips
                    let selectedIds = timelineModel?.selectedClipIds ?? []
                    let trackSelectedCount = liveClips.filter { selectedIds.contains($0.id) }.count
                    if trackSelectedCount > 1, fromIndex < liveClips.count, selectedIds.contains(liveClips[fromIndex].id) {
                        if timelineModel?.reorderClipGroup(
                            clipIds: selectedIds,
                            trackIndex: selectedTrackIndex,
                            isVideo: true,
                            toSlot: slot
                        ) == true {
                            recalculateLayout()
                            onReorderCommitted?()
                        }
                    } else {
                        let targetIdx = (slot > fromIndex) ? (slot - 1) : slot
                        if targetIdx != fromIndex && targetIdx >= 0 && targetIdx < liveClips.count {
                            timelineModel?.reorderClips(
                                trackIndex: selectedTrackIndex,
                                isVideo: true,
                                fromIndex: fromIndex,
                                toIndex: targetIdx
                            )
                            recalculateLayout()
                            onReorderCommitted?()
                        }
                    }
                } else if didStartDrag && activeInsertionSlotBlocked {
                    DebugLogger.shared.log("Spostamento bloccato: clip bloccata o approvata 🔒 in quella posizione.", level: .warning)
                }
                isDragging = false
                draggedIndex = nil
                draggedGroupIndices.removeAll()
                activeInsertionSlot = nil
                activeInsertionSlotBlocked = false
                needsDisplay = true
                break
            }
        }
    }

    private func gapSlotAt(_ point: NSPoint) -> Int? {
        let clips = currentClips
        guard !clips.isEmpty, !cardFrames.isEmpty else { return nil }
        for frame in cardFrames where frame.contains(point) {
            return nil
        }

        for (idx, frame) in cardFrames.enumerated() {
            guard point.y >= frame.minY - 3 && point.y <= frame.maxY + 3 else { continue }
            let isRowStart = (idx == 0) || abs(cardFrames[idx - 1].midY - frame.midY) >= 12
            if isRowStart {
                let leftZone = CGRect(x: max(0, frame.minX - margin), y: frame.minY - 3, width: margin, height: frame.height + 6)
                if leftZone.contains(point) {
                    return idx
                }
            }

            let isRowEnd = (idx == cardFrames.count - 1) || abs(cardFrames[idx + 1].midY - frame.midY) >= 12
            if isRowEnd {
                let rightZone = CGRect(x: frame.maxX, y: frame.minY - 3, width: margin + 4, height: frame.height + 6)
                if rightZone.contains(point) {
                    return idx + 1
                }
            } else {
                let rightFrame = cardFrames[idx + 1]
                let interZone = CGRect(x: frame.maxX, y: frame.minY - 3, width: max(spacing, rightFrame.minX - frame.maxX), height: frame.height + 6)
                if interZone.contains(point) {
                    return idx + 1
                }
            }
        }
        return nil
    }

    private func trackGapClickOrMarquee(startPoint: NSPoint, gapSlot: Int) {
        while true {
            guard let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let currentPt = convert(nextEvent.locationInWindow, from: nil)
            if nextEvent.type == .leftMouseDragged {
                if hypot(currentPt.x - startPoint.x, currentPt.y - startPoint.y) >= 4 {
                    runMarqueeTrackingLoop(startPoint: startPoint, isAdditive: false, initialCurrentPoint: currentPt)
                    return
                }
            } else if nextEvent.type == .leftMouseUp {
                placeholderSlot = (placeholderSlot == gapSlot) ? nil : gapSlot
                hoveredGapSlot = gapSlotAt(currentPt)
                needsDisplay = true
                return
            }
        }
    }

    private func moveClipsToPlaceholder(movingIds: Set<UUID>, anchorClipId: UUID, toSlot slot: Int) {
        guard let model = timelineModel else { return }
        let didMove = model.reorderClipGroup(
            clipIds: movingIds,
            trackIndex: selectedTrackIndex,
            isVideo: true,
            toSlot: slot
        )
        if didMove {
            placeholderSlot = nil
            recalculateLayout()
            onReorderCommitted?()
            scrollToClipIfNeeded(anchorClipId)
            needsDisplay = true
            DebugLogger.shared.log(
                movingIds.count > 1 ? "Spostate \(movingIds.count) clip al segnaposto." : "Clip spostata al segnaposto.",
                level: .info
            )
        } else {
            DebugLogger.shared.log("Impossibile spostare al segnaposto (nessuna variazione o clip bloccata 🔒).", level: .warning)
        }
    }

    private func runMarqueeTrackingLoop(startPoint: NSPoint, isAdditive: Bool, initialCurrentPoint: NSPoint? = nil) {
        let marqueeStart = startPoint
        var marqueeCurrent = initialCurrentPoint ?? startPoint
        isMarqueeSelecting = true
        marqueeRect = NSRect(origin: marqueeStart, size: .zero)

        let initialSelectedIds = isAdditive ? (timelineModel?.selectedClipIds ?? []) : []
        if !isAdditive {
            selectionAnchorIndex = nil
            timelineModel?.selectedClipIds.removeAll()
            onSelectionChanged?()
            needsDisplay = true
        }

        if let initialPt = initialCurrentPoint {
            marqueeCurrent = initialPt
            let rect = NSRect(
                x: min(marqueeStart.x, marqueeCurrent.x),
                y: min(marqueeStart.y, marqueeCurrent.y),
                width: abs(marqueeCurrent.x - marqueeStart.x),
                height: abs(marqueeCurrent.y - marqueeStart.y)
            )
            marqueeRect = rect
        }

        while true {
            guard let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let currentPt = convert(nextEvent.locationInWindow, from: nil)

            if nextEvent.type == .leftMouseDragged {
                marqueeCurrent = currentPt
                let rect = NSRect(
                    x: min(marqueeStart.x, marqueeCurrent.x),
                    y: min(marqueeStart.y, marqueeCurrent.y),
                    width: abs(marqueeCurrent.x - marqueeStart.x),
                    height: abs(marqueeCurrent.y - marqueeStart.y)
                )
                marqueeRect = rect

                var baseSelected: Set<UUID> = []
                let clips = currentClips
                for (idx, frame) in cardFrames.enumerated() {
                    if idx < clips.count && rect.intersects(frame) {
                        baseSelected.insert(clips[idx].id)
                        if selectionAnchorIndex == nil { selectionAnchorIndex = idx }
                    }
                }
                let linked = timelineModel?.linkedSelectionIds(for: baseSelected) ?? baseSelected
                timelineModel?.selectedClipIds = initialSelectedIds.union(linked)
                onSelectionChanged?()
                needsDisplay = true
            } else if nextEvent.type == .leftMouseUp {
                isMarqueeSelecting = false
                marqueeRect = nil
                onSelectionChanged?()
                needsDisplay = true
                break
            }
        }
    }

    private func findInsertionSlot(at point: NSPoint, sourceIndex: Int) -> Int {
        let clips = currentClips
        guard !clips.isEmpty else { return 0 }

        var closestSlot = 0
        var minDistance: CGFloat = .greatestFiniteMagnitude

        for (idx, frame) in cardFrames.enumerated() {
            // Left edge slot (before card)
            let leftSlotPt = CGPoint(x: frame.minX - spacing / 2.0, y: frame.midY)
            let distLeft = hypot(point.x - leftSlotPt.x, point.y - leftSlotPt.y)
            if distLeft < minDistance {
                minDistance = distLeft
                closestSlot = idx
            }

            // Right edge slot (after card)
            let rightSlotPt = CGPoint(x: frame.maxX + spacing / 2.0, y: frame.midY)
            let distRight = hypot(point.x - rightSlotPt.x, point.y - rightSlotPt.y)
            if distRight < minDistance {
                minDistance = distRight
                closestSlot = idx + 1
            }
        }

        return max(0, min(clips.count, closestSlot))
    }

    // MARK: - Text Rendering Helpers
    private func drawText(_ text: String, at point: CGPoint, color: NSColor, fontSize: CGFloat, bold: Bool) {
        let font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        attrStr.draw(at: point)
    }

    private func drawText(_ text: String, in rect: NSRect, color: NSColor, fontSize: CGFloat, bold: Bool) {
        let font = bold ? NSFont.boldSystemFont(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        attrStr.draw(in: rect)
    }

    private func drawCenteredText(_ text: String, in rect: NSRect, color: NSColor, fontSize: CGFloat) {
        let font = NSFont.systemFont(ofSize: fontSize)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.size()
        let centeredRect = NSRect(
            x: rect.minX,
            y: rect.midY - textSize.height / 2.0,
            width: rect.width,
            height: textSize.height
        )
        attrStr.draw(in: centeredRect)
    }

    public static func drawAspectFill(image: NSImage, in destRect: NSRect) {
        let imgSize = image.size
        guard imgSize.width > 0 && imgSize.height > 0 && destRect.width > 0 && destRect.height > 0 else {
            image.draw(in: destRect)
            return
        }
        let imgRatio = imgSize.width / imgSize.height
        let destRatio = destRect.width / destRect.height
        var srcRect = NSRect(origin: .zero, size: imgSize)
        if imgRatio > destRatio {
            let cropW = imgSize.height * destRatio
            srcRect.origin.x = (imgSize.width - cropW) * 0.5
            srcRect.size.width = cropW
        } else if imgRatio < destRatio {
            let cropH = imgSize.width / destRatio
            srcRect.origin.y = (imgSize.height - cropH) * 0.5
            srcRect.size.height = cropH
        }
        image.draw(in: destRect, from: srcRect, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.medium])
    }

    // MARK: - NSDraggingDestination (Drop from Media Pool, Libreria Musicale & Finder)

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateExternalDragSlot(from: sender) ? .copy : []
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        updateExternalDragSlot(from: sender) ? .copy : []
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        isExternalDragOver = false
        activeInsertionSlot = nil
        needsDisplay = true
    }

    private func updateExternalDragSlot(from sender: NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard
        let hasKnownType = pboard.types?.contains(kMediaItemPasteboardType) == true
            || pboard.types?.contains(kSelectionPasteboardType) == true
            || pboard.types?.contains(.fileURL) == true
            || !MediaPoolViewController.extractFileURLs(from: pboard).isEmpty
        guard hasKnownType else { return false }

        isExternalDragOver = true
        let localPt = convert(sender.draggingLocation, from: nil)
        activeInsertionSlot = findInsertionSlot(at: localPt, sourceIndex: -1)
        needsDisplay = true
        return true
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard
        let localPt = convert(sender.draggingLocation, from: nil)
        let slot = findInsertionSlot(at: localPt, sourceIndex: -1)
        isExternalDragOver = false
        activeInsertionSlot = nil
        needsDisplay = true

        if let selIdStr = pboard.string(forType: kSelectionPasteboardType), let selId = UUID(uuidString: selIdStr) {
            onDropSelectionAtSlot?(selId, slot, selectedTrackIndex)
            return true
        }

        var mediaIds: [UUID] = []
        if let pbItems = pboard.pasteboardItems {
            for item in pbItems {
                if let str = item.string(forType: kMediaItemPasteboardType), let uuid = UUID(uuidString: str) {
                    mediaIds.append(uuid)
                }
            }
        }
        if !mediaIds.isEmpty {
            onDropMediaIdsAtSlot?(mediaIds, slot, selectedTrackIndex)
            return true
        }

        let urls = MediaPoolViewController.extractFileURLs(from: pboard)
        if !urls.isEmpty {
            onDropURLsAtSlot?(urls, slot, selectedTrackIndex)
            return true
        }
        return false
    }
}
