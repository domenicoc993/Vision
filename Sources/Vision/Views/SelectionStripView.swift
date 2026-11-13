import AppKit
import AVFoundation

public final class SelectionStripView: NSView {
    public let stripType: SelectionStripType
    public weak var selectionModel: SelectionModel?
    public var playbackController: PlaybackController

    public var isActiveStrip: Bool = false {
        didSet { needsDisplay = true }
    }

    public var isMinimized: Bool = false {
        didSet {
            heightConstraint?.constant = isMinimized ? 22 : 74
            needsDisplay = true
        }
    }

    public var pixelsPerSecond: Double = 50.0 {
        didSet { needsDisplay = true }
    }

    public let leftMargin: CGFloat = 48.0
    public var heightConstraint: NSLayoutConstraint?

    public var onStripClicked: (() -> Void)?
    public var onClipMovedOrTrimmed: (() -> Void)?
    public var onClipMovedOrTrimmedWithTargetTime: ((CMTime?) -> Void)?
    public var onPlayheadScrubbed: ((CMTime) -> Void)?
    public var onMinimizeToggled: (() -> Void)?

    // Edge trimming state
    private var trackingArea: NSTrackingArea?
    private var hoveredClipId: UUID? = nil
    private var hoveredEdge: ClipEdge? = nil
    private var isDraggingEdge = false
    private var activeEdgeClipId: UUID? = nil
    private var activeEdgeIsStart = false
    private var dragInitialPoint: CGPoint = .zero
    private var dragInitialIn: CMTime = .zero
    private var dragInitialDur: CMTime = .zero

    public override var isFlipped: Bool { true }

    public init(stripType: SelectionStripType, playbackController: PlaybackController) {
        self.stripType = stripType
        self.playbackController = playbackController
        super.init(frame: .zero)
        self.wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func updateTrackingAreas() {
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        self.trackingArea = ta
        super.updateTrackingAreas()
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let boundsRect = bounds

        // 1. Sfondo della striscia secondo il tipo (Rosso, Blu, Verde)
        let bgColor: NSColor
        let borderColor: NSColor
        let accentColor: NSColor

        switch stripType {
        case .rejected: // ROSSA: Scarti
            bgColor = isActiveStrip ? NSColor(calibratedRed: 0.22, green: 0.08, blue: 0.09, alpha: 1.0) : NSColor(calibratedRed: 0.15, green: 0.05, blue: 0.06, alpha: 1.0)
            borderColor = isActiveStrip ? NSColor.systemRed : NSColor(calibratedRed: 0.38, green: 0.12, blue: 0.14, alpha: 0.7)
            accentColor = NSColor.systemRed

        case .analysis: // BLU: Da analizzare
            bgColor = isActiveStrip ? NSColor(calibratedRed: 0.08, green: 0.15, blue: 0.26, alpha: 1.0) : NSColor(calibratedRed: 0.06, green: 0.10, blue: 0.18, alpha: 1.0)
            borderColor = isActiveStrip ? NSColor.systemCyan : NSColor(calibratedRed: 0.15, green: 0.28, blue: 0.45, alpha: 0.7)
            accentColor = NSColor.systemCyan

        case .selected: // VERDE: Selezionati
            bgColor = isActiveStrip ? NSColor(calibratedRed: 0.06, green: 0.20, blue: 0.10, alpha: 1.0) : NSColor(calibratedRed: 0.04, green: 0.13, blue: 0.07, alpha: 1.0)
            borderColor = isActiveStrip ? NSColor.systemGreen : NSColor(calibratedRed: 0.12, green: 0.35, blue: 0.18, alpha: 0.7)
            accentColor = NSColor.systemGreen
        }

        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(boundsRect)

        // Bordo di selezione / attivo
        ctx.setStrokeColor(borderColor.cgColor)
        ctx.setLineWidth(isActiveStrip ? 2.0 : 1.0)
        ctx.stroke(boundsRect.insetBy(dx: 0.5, dy: 0.5))

        // 2. Colonna Intestazione Sinistra (Eye Icon + Color Pill)
        drawLeftHeader(accentColor: accentColor, ctx: ctx)

        // Se ridotta al minimo, disegna solo un sottile filo indicatore
        if isMinimized {
            drawMinimizedIndicator(accentColor: accentColor, ctx: ctx)
            return
        }

        // 3. Disegno delle Clip
        guard let model = selectionModel else { return }
        let clips = model.clips(for: stripType)

        let playheadTime = playbackController.currentTime
        let playheadSec = CMTimeGetSeconds(playheadTime)

        var currentX: CGFloat = leftMargin
        let clipY: CGFloat = 8
        let clipH: CGFloat = boundsRect.height - 16

        for clip in clips {
            let durSec = CMTimeGetSeconds(clip.duration)
            let clipW = CGFloat(durSec * pixelsPerSecond)
            let clipRect = CGRect(x: currentX, y: clipY, width: clipW, height: clipH)

            let clipStartSec = Double(currentX - leftMargin) / pixelsPerSecond
            let clipEndSec = clipStartSec + durSec
            let isUnderPlayhead = isActiveStrip && (playheadSec >= clipStartSec && playheadSec <= clipEndSec)

            drawClipCard(clip, rect: clipRect, isUnderPlayhead: isUnderPlayhead, ctx: ctx)

            currentX += clipW
        }

        // 4. Disegno della Testina di Riproduzione
        if isActiveStrip {
            let phX: CGFloat = leftMargin + CGFloat(playheadSec * pixelsPerSecond)
            if phX >= leftMargin && phX <= boundsRect.width {
                ctx.setStrokeColor(NSColor.systemRed.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeLineSegments(between: [
                    CGPoint(x: phX, y: 0),
                    CGPoint(x: phX, y: boundsRect.height)
                ])

                // Puntina / Indicatore testina in alto
                let headPath = CGMutablePath()
                headPath.move(to: CGPoint(x: phX - 5, y: 0))
                headPath.addLine(to: CGPoint(x: phX + 5, y: 0))
                headPath.addLine(to: CGPoint(x: phX + 5, y: 6))
                headPath.addLine(to: CGPoint(x: phX, y: 11))
                headPath.addLine(to: CGPoint(x: phX - 5, y: 6))
                headPath.closeSubpath()

                ctx.setFillColor(NSColor.systemRed.cgColor)
                ctx.addPath(headPath)
                ctx.fillPath()
            }
        }
    }

    private func drawLeftHeader(accentColor: NSColor, ctx: CGContext) {
        // Linea separatrice verticale prima dell'inizio delle clip
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokeLineSegments(between: [
            CGPoint(x: leftMargin - 6, y: 0),
            CGPoint(x: leftMargin - 6, y: bounds.height)
        ])

        // Color Pill verticale (spessore 4px)
        let pillRect = CGRect(x: leftMargin - 12, y: 6, width: 4, height: bounds.height - 12)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
        ctx.setFillColor(accentColor.cgColor)
        ctx.addPath(pillPath)
        ctx.fillPath()

        // Icona Occhio (👁️ o occhio sbarrato se minimizzato)
        let eyeRect = CGRect(x: 6, y: (bounds.height - 18) / 2, width: 22, height: 18)
        let eyeSymbol = isMinimized ? "eye.slash" : "eye"
        if let eyeImg = NSImage(systemSymbolName: eyeSymbol, accessibilityDescription: "Visibilità striscia") {
            let tintedImg = eyeImg.copy() as! NSImage
            tintedImg.isTemplate = true
            let iconColor = isMinimized ? NSColor(calibratedWhite: 0.45, alpha: 1.0) : NSColor(calibratedWhite: 0.9, alpha: 1.0)
            iconColor.set()
            tintedImg.draw(in: eyeRect.insetBy(dx: 2, dy: 1))
        }
    }

    private func drawMinimizedIndicator(accentColor: NSColor, ctx: CGContext) {
        guard let model = selectionModel else { return }
        let clips = model.clips(for: stripType)
        let durSec = clips.reduce(0.0) { $0 + CMTimeGetSeconds($1.duration) }
        let totalW = CGFloat(durSec * pixelsPerSecond)

        if totalW > 0 {
            let barRect = CGRect(x: leftMargin, y: (bounds.height - 4) / 2, width: totalW, height: 4)
            let barPath = CGPath(roundedRect: barRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.setFillColor(accentColor.withAlphaComponent(0.6).cgColor)
            ctx.addPath(barPath)
            ctx.fillPath()
        }
    }

    private func drawClipCard(_ clip: SelectionClip, rect: CGRect, isUnderPlayhead: Bool, ctx: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)

        // Colore card specifico della striscia
        let fillColor: NSColor
        switch stripType {
        case .rejected:
            fillColor = isUnderPlayhead ? NSColor(calibratedRed: 0.65, green: 0.22, blue: 0.25, alpha: 1.0) : NSColor(calibratedRed: 0.48, green: 0.16, blue: 0.18, alpha: 1.0)
        case .analysis:
            fillColor = isUnderPlayhead ? NSColor(calibratedRed: 0.18, green: 0.50, blue: 0.88, alpha: 1.0) : NSColor(calibratedRed: 0.13, green: 0.36, blue: 0.65, alpha: 1.0)
        case .selected:
            fillColor = isUnderPlayhead ? NSColor(calibratedRed: 0.18, green: 0.68, blue: 0.32, alpha: 1.0) : NSColor(calibratedRed: 0.12, green: 0.48, blue: 0.22, alpha: 1.0)
        }

        ctx.setFillColor(fillColor.cgColor)
        ctx.addPath(path)
        ctx.fillPath()

        // Bordo di selezione / playhead
        if isUnderPlayhead {
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2.0)
            ctx.addPath(path)
            ctx.strokePath()
        } else {
            ctx.setStrokeColor(NSColor(white: 1.0, alpha: 0.25).cgColor)
            ctx.setLineWidth(1.0)
            ctx.addPath(path)
            ctx.strokePath()
        }

        // Nome della clip
        if rect.width > 24 {
            let label = clip.mediaItem.name
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            let textRect = CGRect(x: rect.minX + 5, y: rect.minY + 4, width: rect.width - 10, height: 14)
            str.draw(with: textRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        }

        // Durata della porzione
        if rect.width > 55 {
            let durSec = CMTimeGetSeconds(clip.duration)
            let durStr = String(format: "%.1fs", durSec)
            let durAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: NSColor(white: 1.0, alpha: 0.85)
            ]
            let str = NSAttributedString(string: durStr, attributes: durAttrs)
            str.draw(at: NSPoint(x: rect.minX + 5, y: rect.maxY - 16))
        }

        // Parentesi quadre [ o ] sui bordi
        let isStartHover = (hoveredClipId == clip.id && hoveredEdge == .start) || (isDraggingEdge && activeEdgeClipId == clip.id && activeEdgeIsStart)
        let isEndHover = (hoveredClipId == clip.id && hoveredEdge == .end) || (isDraggingEdge && activeEdgeClipId == clip.id && !activeEdgeIsStart)

        if isStartHover {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(calibratedRed: 0.1, green: 0.95, blue: 1.0, alpha: 1.0).cgColor)
            ctx.setLineWidth(2.5)
            let bPath = CGMutablePath()
            bPath.move(to: CGPoint(x: rect.minX + 7, y: rect.minY + 2))
            bPath.addLine(to: CGPoint(x: rect.minX + 2, y: rect.minY + 2))
            bPath.addLine(to: CGPoint(x: rect.minX + 2, y: rect.maxY - 2))
            bPath.addLine(to: CGPoint(x: rect.minX + 7, y: rect.maxY - 2))
            ctx.addPath(bPath)
            ctx.strokePath()
            ctx.restoreGState()
        }

        if isEndHover {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(calibratedRed: 0.1, green: 0.95, blue: 1.0, alpha: 1.0).cgColor)
            ctx.setLineWidth(2.5)
            let bPath = CGMutablePath()
            bPath.move(to: CGPoint(x: rect.maxX - 7, y: rect.minY + 2))
            bPath.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.minY + 2))
            bPath.addLine(to: CGPoint(x: rect.maxX - 2, y: rect.maxY - 2))
            bPath.addLine(to: CGPoint(x: rect.maxX - 7, y: rect.maxY - 2))
            ctx.addPath(bPath)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    // MARK: - Mouse Handlers
    public override func mouseMoved(with event: NSEvent) {
        if isMinimized { return }
        let localPoint = convert(event.locationInWindow, from: nil)
        guard let model = selectionModel else { return }
        let clips = model.clips(for: stripType)

        var currentX: CGFloat = leftMargin
        let clipY: CGFloat = 8
        let clipH: CGFloat = bounds.height - 16
        let edgeMargin: CGFloat = 8.0

        var foundId: UUID? = nil
        var foundEdge: ClipEdge? = nil

        for clip in clips {
            let durSec = CMTimeGetSeconds(clip.duration)
            let clipW = CGFloat(durSec * pixelsPerSecond)
            let clipRect = CGRect(x: currentX, y: clipY, width: clipW, height: clipH)

            if clipRect.contains(localPoint) {
                if localPoint.x <= clipRect.minX + edgeMargin {
                    foundId = clip.id
                    foundEdge = .start
                    break
                } else if localPoint.x >= clipRect.maxX - edgeMargin {
                    foundId = clip.id
                    foundEdge = .end
                    break
                }
            }
            currentX += clipW
        }

        if foundId != hoveredClipId || foundEdge != hoveredEdge {
            hoveredClipId = foundId
            hoveredEdge = foundEdge
            needsDisplay = true
        }

        if let edge = foundEdge {
            switch edge {
            case .start: NSCursor.resizeLeft.set()
            case .end: NSCursor.resizeRight.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredClipId = nil
        hoveredEdge = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    public override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)

        // Clic sull'icona occhio (x <= 34)
        if localPoint.x <= 34 {
            isMinimized.toggle()
            onMinimizeToggled?()
            return
        }

        if isMinimized {
            onStripClicked?()
            return
        }

        onStripClicked?()
        guard let model = selectionModel else { return }
        let clips = model.clips(for: stripType)

        var currentX: CGFloat = leftMargin
        let clipY: CGFloat = 8
        let clipH: CGFloat = bounds.height - 16
        let edgeMargin: CGFloat = 8.0

        for clip in clips {
            let durSec = CMTimeGetSeconds(clip.duration)
            let clipW = CGFloat(durSec * pixelsPerSecond)
            let clipRect = CGRect(x: currentX, y: clipY, width: clipW, height: clipH)

            if clipRect.contains(localPoint) {
                if localPoint.x <= clipRect.minX + edgeMargin {
                    isDraggingEdge = true
                    activeEdgeClipId = clip.id
                    activeEdgeIsStart = true
                    dragInitialPoint = localPoint
                    dragInitialIn = clip.sourceIn
                    dragInitialDur = clip.duration
                    return
                } else if localPoint.x >= clipRect.maxX - edgeMargin {
                    isDraggingEdge = true
                    activeEdgeClipId = clip.id
                    activeEdgeIsStart = false
                    dragInitialPoint = localPoint
                    dragInitialIn = clip.sourceIn
                    dragInitialDur = clip.duration
                    return
                }
            }
            currentX += clipW
        }

        // Click altrove sulla striscia: posiziona la testina
        let clickedSec = max(0, Double(localPoint.x - leftMargin) / pixelsPerSecond)
        let newTime = CMTime(seconds: clickedSec, preferredTimescale: 600)
        onPlayheadScrubbed?(newTime)
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        if isMinimized { return }
        let localPoint = convert(event.locationInWindow, from: nil)

        if isDraggingEdge, let clipId = activeEdgeClipId, let model = selectionModel {
            let deltaX = localPoint.x - dragInitialPoint.x
            let deltaSec = Double(deltaX) / pixelsPerSecond

            if stripType == .analysis {
                if let idx = model.analysisClips.firstIndex(where: { $0.id == clipId }) {
                    let mediaDur = CMTimeGetSeconds(model.analysisClips[idx].mediaItem.duration)
                    var clipStartSec: Double = 0
                    for i in 0..<idx {
                        clipStartSec += CMTimeGetSeconds(model.analysisClips[i].duration)
                    }

                    if activeEdgeIsStart {
                        let origIn = CMTimeGetSeconds(dragInitialIn)
                        let newIn = max(0, min(mediaDur - 0.2, origIn + deltaSec))
                        let deltaApplied = newIn - origIn
                        let newDur = max(0.2, CMTimeGetSeconds(dragInitialDur) - deltaApplied)
                        model.analysisClips[idx].sourceIn = CMTime(seconds: newIn, preferredTimescale: 600)
                        model.analysisClips[idx].duration = CMTime(seconds: newDur, preferredTimescale: 600)

                        // Durante il drag dell'inizio, visualizza il frame sul taglio nel player
                        let scrubTime = CMTime(seconds: clipStartSec + deltaApplied, preferredTimescale: 600)
                        onPlayheadScrubbed?(scrubTime)
                    } else {
                        let curIn = CMTimeGetSeconds(model.analysisClips[idx].sourceIn)
                        let origDur = CMTimeGetSeconds(dragInitialDur)
                        let maxDur = mediaDur - curIn
                        let newDur = max(0.2, min(maxDur, origDur + deltaSec))
                        model.analysisClips[idx].duration = CMTime(seconds: newDur, preferredTimescale: 600)

                        let scrubTime = CMTime(seconds: clipStartSec + newDur, preferredTimescale: 600)
                        onPlayheadScrubbed?(scrubTime)
                    }
                    model.onSelectionChanged?()
                }
            }
            needsDisplay = true
            return
        }

        // Scrubbing testina
        let scrubSec = max(0, Double(localPoint.x - leftMargin) / pixelsPerSecond)
        let newTime = CMTime(seconds: scrubSec, preferredTimescale: 600)
        onPlayheadScrubbed?(newTime)
        needsDisplay = true
    }

    public override func mouseUp(with event: NSEvent) {
        if isDraggingEdge {
            let wasStart = activeEdgeIsStart
            let clipId = activeEdgeClipId
            isDraggingEdge = false
            activeEdgeClipId = nil

            var targetTime: CMTime? = nil
            if let id = clipId, let model = selectionModel, let idx = model.analysisClips.firstIndex(where: { $0.id == id }) {
                var clipStartSec: Double = 0
                for i in 0..<idx {
                    clipStartSec += CMTimeGetSeconds(model.analysisClips[i].duration)
                }
                let curDur = CMTimeGetSeconds(model.analysisClips[idx].duration)
                let finalSec = wasStart ? clipStartSec : max(clipStartSec, clipStartSec + curDur - 0.04)
                targetTime = CMTime(seconds: finalSec, preferredTimescale: 600)
            }

            onClipMovedOrTrimmed?()
            onClipMovedOrTrimmedWithTargetTime?(targetTime)
            needsDisplay = true
        }
    }
}
