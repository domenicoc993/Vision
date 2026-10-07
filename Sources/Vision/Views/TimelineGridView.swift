import AppKit
import AVFoundation

public final class TimelineGridView: NSView {
    public var timelineModel: TimelineModel? {
        didSet {
            recalculateLayout()
            needsDisplay = true
        }
    }
    public var selectedTrackIndex: Int = 0 {
        didSet {
            recalculateLayout()
            needsDisplay = true
        }
    }

    public var onClipSelected: ((TimelineClip) -> Void)?
    public var onReorderCommitted: (() -> Void)?
    public var onSectionActivated: (() -> Void)?

    private let minCardWidth: CGFloat = 115
    private let spacing: CGFloat = 10
    private let margin: CGFloat = 12

    private var currentCardWidth: CGFloat = 125
    private var currentCardHeight: CGFloat = 110

    // Drag-to-reorder state
    private var draggedIndex: Int? = nil
    private var isDragging: Bool = false
    private var dragCurrentLocation: NSPoint = .zero
    private var dragStartLocation: NSPoint = .zero
    private var activeInsertionSlot: Int? = nil // Index 0...N where the glowing beam appears

    // Rubber-Band Marquee Selection state
    private var isMarqueeSelecting: Bool = false
    private var marqueeRect: NSRect? = nil

    private var cardFrames: [NSRect] = []

    public override var isFlipped: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        autoresizingMask = [.width]
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
        let availableWidth = max(minCardWidth, width - margin * 2)
        let cols = max(1, Int((availableWidth + spacing) / (minCardWidth + spacing)))
        let rows = (clips.count + cols - 1) / cols
        let height = margin * 2 + CGFloat(rows) * currentCardHeight + CGFloat(max(0, rows - 1)) * spacing + 40
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

    public func reloadData() {
        updateLayoutForCurrentWidth()
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    // MARK: - Multi-Column Responsive Layout (1 2 3 4 / 5 6 7 8 / 9 10 etc.)
    private func recalculateLayout() {
        let clips = currentClips
        cardFrames.removeAll()

        let width = bounds.width > 0 ? bounds.width : 320
        let availableWidth = max(minCardWidth, width - margin * 2)
        let cols = max(1, Int((availableWidth + spacing) / (minCardWidth + spacing)))

        currentCardWidth = floor((availableWidth - CGFloat(cols - 1) * spacing) / CGFloat(cols))
        currentCardHeight = max(96, min(140, floor(currentCardWidth * 0.88)))

        for idx in 0..<clips.count {
            let col = idx % cols
            let row = idx / cols
            let x = margin + CGFloat(col) * (currentCardWidth + spacing)
            let y = margin + CGFloat(row) * (currentCardHeight + spacing)
            cardFrames.append(NSRect(x: x, y: y, width: currentCardWidth, height: currentCardHeight))
        }

        invalidateIntrinsicContentSize()
    }

    // MARK: - Drawing
    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dark Studio background
        ctx.setFillColor(NSColor(calibratedWhite: 0.11, alpha: 1.0).cgColor)
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

            if isDragging && draggedIndex == idx {
                drawPlaceholderCard(frame: frame, index: idx + 1, ctx: ctx)
            } else {
                let isSelected = selectedIds.contains(clip.id)
                drawCard(clip: clip, frame: frame, sequenceNum: idx + 1, isSelected: isSelected, alpha: 1.0, ctx: ctx)
            }
        }

        // 2. Draw Glowing Vertical Insertion Slot between clips
        if isDragging, let slot = activeInsertionSlot {
            drawGlowingInsertionBeam(slot: slot, ctx: ctx)
        }

        // 3. Draw Floating Dragged Ghost Card under cursor
        if isDragging, let idx = draggedIndex, idx < clips.count {
            let clip = clips[idx]
            let ghostOrigin = CGPoint(
                x: dragCurrentLocation.x - currentCardWidth / 2.0,
                y: dragCurrentLocation.y - currentCardHeight / 2.0
            )
            let ghostFrame = NSRect(origin: ghostOrigin, size: NSSize(width: currentCardWidth, height: currentCardHeight))
            drawFloatingGhostCard(clip: clip, frame: ghostFrame, sequenceNum: idx + 1, ctx: ctx)
        }

        // 4. Draw Rubber-Band Marquee Selection Box
        if isMarqueeSelecting, let rect = marqueeRect {
            drawMarqueeBox(rect: rect, ctx: ctx)
        }
    }

    private func drawCard(clip: TimelineClip, frame: NSRect, sequenceNum: Int, isSelected: Bool, alpha: CGFloat, ctx: CGContext) {
        ctx.saveGState()
        ctx.setAlpha(alpha)

        // Card Container rounded rectangle
        let path = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        NSColor(calibratedWhite: 0.18, alpha: 1.0).setFill()
        path.fill()

        if clip.isOrphan {
            NSColor.systemRed.setStroke()
            path.lineWidth = isSelected ? 3.0 : 2.0
            path.stroke()
        } else if isSelected {
            NSColor.systemCyan.setStroke()
            path.lineWidth = 2.5
            path.stroke()
        } else {
            NSColor(calibratedWhite: 0.28, alpha: 1.0).setStroke()
            path.lineWidth = 1.0
            path.stroke()
        }

        // Thumbnail Area (top portion of card)
        let thumbHeight = max(50, frame.height - 38)
        let thumbRect = NSRect(x: frame.minX + 3, y: frame.minY + 3, width: frame.width - 6, height: thumbHeight)
        let thumbPath = NSBezierPath(roundedRect: thumbRect, xRadius: 4, yRadius: 4)
        thumbPath.addClip()

        if let thumb = clip.mediaItem.thumbnail {
            thumb.draw(in: thumbRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        } else {
            NSColor.black.setFill()
            thumbPath.fill()
            let icon = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
            icon?.draw(in: NSRect(x: thumbRect.midX - 14, y: thumbRect.midY - 14, width: 28, height: 28))
        }

        ctx.restoreGState()

        // Sequence Number Badge (#1, #2, #3...) in top-left
        let badgeRect = NSRect(x: frame.minX + 6, y: frame.minY + 6, width: 26, height: 16)
        let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.85).setFill()
        badgePath.fill()
        drawText("#\(sequenceNum)", at: CGPoint(x: badgeRect.minX + 4, y: badgeRect.minY + 2), color: .systemYellow, fontSize: 10, bold: true)

        // Duration Badge in top-right
        let durStr = clip.mediaItem.formattedDuration
        let durRect = NSRect(x: frame.maxX - 48, y: frame.minY + 6, width: 42, height: 16)
        let durPath = NSBezierPath(roundedRect: durRect, xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.85).setFill()
        durPath.fill()
        drawText(durStr, at: CGPoint(x: durRect.minX + 4, y: durRect.minY + 2), color: .white, fontSize: 9, bold: true)

        // Timeline Start Timecode in bottom-right of thumbnail
        let inSec = CMTimeGetSeconds(clip.timelineStart)
        let inStr = String(format: "%02d:%02d", Int(inSec) / 60, Int(inSec) % 60)
        let inRect = NSRect(x: frame.maxX - 38, y: frame.minY + thumbHeight - 16, width: 34, height: 14)
        let inPath = NSBezierPath(roundedRect: inRect, xRadius: 3, yRadius: 3)
        NSColor.black.withAlphaComponent(0.75).setFill()
        inPath.fill()
        drawText(inStr, at: CGPoint(x: inRect.minX + 3, y: inRect.minY + 1), color: .systemCyan, fontSize: 8.5, bold: true)

        // Bottom Title Label
        let titleRect = NSRect(x: frame.minX + 6, y: frame.minY + thumbHeight + 5, width: frame.width - 12, height: 26)
        let titleColor: NSColor = clip.isOrphan ? .systemRed : .labelColor
        let titleText = clip.mediaItem.name
        drawText(titleText, in: titleRect, color: titleColor, fontSize: 10, bold: true)
    }

    private func drawPlaceholderCard(frame: NSRect, index: Int, ctx: CGContext) {
        let path = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        NSColor(calibratedWhite: 0.14, alpha: 0.6).setFill()
        path.fill()

        let strokeColor = NSColor(calibratedWhite: 0.28, alpha: 0.6)
        strokeColor.setStroke()
        path.lineWidth = 1.5
        let pattern: [CGFloat] = [4, 4]
        path.setLineDash(pattern, count: 2, phase: 0)
        path.stroke()
    }

    private func drawFloatingGhostCard(clip: TimelineClip, frame: NSRect, sequenceNum: Int, ctx: CGContext) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: NSColor.black.withAlphaComponent(0.8).cgColor)
        drawCard(clip: clip, frame: frame, sequenceNum: sequenceNum, isSelected: true, alpha: 0.72, ctx: ctx)
        ctx.restoreGState()
    }

    // Glowing vertical insertion beam ("le intersezioni verticali tra clip che si illuminano")
    private func drawGlowingInsertionBeam(slot: Int, ctx: CGContext) {
        let clips = currentClips
        guard !clips.isEmpty else { return }

        let lineX: CGFloat
        let lineYTop: CGFloat
        let lineYBottom: CGFloat

        if slot == 0, let firstFrame = cardFrames.first {
            lineX = firstFrame.minX - spacing / 2.0
            lineYTop = firstFrame.minY - 4
            lineYBottom = firstFrame.maxY + 4
        } else if slot >= cardFrames.count, let lastFrame = cardFrames.last {
            lineX = lastFrame.maxX + spacing / 2.0
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
                lineX = rightFrame.minX - spacing / 2.0
                lineYTop = rightFrame.minY - 4
                lineYBottom = rightFrame.maxY + 4
            }
        } else {
            return
        }

        ctx.saveGState()

        // 1. Outer cyan glow halo
        ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(8.0)
        ctx.setLineCap(.round)
        ctx.strokeLineSegments(between: [CGPoint(x: lineX, y: lineYTop), CGPoint(x: lineX, y: lineYBottom)])

        // 2. Mid bright glow
        ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(4.0)
        ctx.strokeLineSegments(between: [CGPoint(x: lineX, y: lineYTop), CGPoint(x: lineX, y: lineYBottom)])

        // 3. Bright white core
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(2.0)
        ctx.strokeLineSegments(between: [CGPoint(x: lineX, y: lineYTop + 2), CGPoint(x: lineX, y: lineYBottom - 2)])

        // 4. Caret pins at top and bottom
        let dotSize: CGFloat = 8
        ctx.setFillColor(NSColor.systemCyan.cgColor)
        ctx.fillEllipse(in: CGRect(x: lineX - dotSize / 2, y: lineYTop - dotSize / 2, width: dotSize, height: dotSize))
        ctx.fillEllipse(in: CGRect(x: lineX - dotSize / 2, y: lineYBottom - dotSize / 2, width: dotSize, height: dotSize))

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
        let clips = currentClips
        timelineModel?.selectedClipIds = Set(clips.map(\.id))
        needsDisplay = true
    }

    // MARK: - Interactive Event Tracking Loop (Smooth Dragging + Marquee Selection)
    public override func mouseDown(with event: NSEvent) {
        onSectionActivated?()
        let localPoint = convert(event.locationInWindow, from: nil)
        let isShift = event.modifierFlags.contains(.shift)

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

            if isShift {
                if timelineModel?.selectedClipIds.contains(hitClip.id) == true {
                    timelineModel?.selectedClipIds.remove(hitClip.id)
                } else {
                    timelineModel?.selectedClipIds.insert(hitClip.id)
                }
            } else {
                if timelineModel?.selectedClipIds.contains(hitClip.id) != true {
                    timelineModel?.selectedClipIds = [hitClip.id]
                }
            }
            onClipSelected?(hitClip)
            needsDisplay = true

            // Run Modal Event Tracking Loop for Card Drag-and-Drop Reordering
            runCardDragTrackingLoop(fromIndex: srcIdx, startPoint: localPoint)
        } else {
            // Click or Drag on Empty Background: Rubber-Band Marquee Box Selection!
            runMarqueeTrackingLoop(startPoint: localPoint, isShift: isShift)
        }
    }

    private func runCardDragTrackingLoop(fromIndex: Int, startPoint: NSPoint) {
        var didStartDrag = false
        draggedIndex = fromIndex
        dragStartLocation = startPoint
        dragCurrentLocation = startPoint
        activeInsertionSlot = nil

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
                    activeInsertionSlot = findInsertionSlot(at: currentPt, sourceIndex: fromIndex)
                    needsDisplay = true
                }
            } else if nextEvent.type == .leftMouseUp {
                if didStartDrag, let slot = activeInsertionSlot {
                    let targetIdx = (slot > fromIndex) ? (slot - 1) : slot
                    let clips = currentClips
                    if targetIdx != fromIndex && targetIdx >= 0 && targetIdx < clips.count {
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
                isDragging = false
                draggedIndex = nil
                activeInsertionSlot = nil
                needsDisplay = true
                break
            }
        }
    }

    private func runMarqueeTrackingLoop(startPoint: NSPoint, isShift: Bool) {
        let marqueeStart = startPoint
        var marqueeCurrent = startPoint
        isMarqueeSelecting = true
        marqueeRect = NSRect(origin: marqueeStart, size: .zero)

        let initialSelectedIds = isShift ? (timelineModel?.selectedClipIds ?? []) : []
        if !isShift {
            timelineModel?.selectedClipIds.removeAll()
            needsDisplay = true
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

                var newlySelected = initialSelectedIds
                let clips = currentClips
                for (idx, frame) in cardFrames.enumerated() {
                    if idx < clips.count && rect.intersects(frame) {
                        newlySelected.insert(clips[idx].id)
                    }
                }
                timelineModel?.selectedClipIds = newlySelected
                needsDisplay = true
            } else if nextEvent.type == .leftMouseUp {
                isMarqueeSelecting = false
                marqueeRect = nil
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
}
