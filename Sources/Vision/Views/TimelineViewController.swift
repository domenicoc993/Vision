import AppKit
import AVFoundation

public final class TimelineCanvasView: NSView, NSViewToolTipOwner {
    public var model: TimelineModel
    public var playbackController: PlaybackController
    public var pixelsPerSecond: Double = 40.0 {
        didSet {
            updateWidth()
            needsDisplay = true
            updatePlayheadLayer()
        }
    }
    public var onTimelineModified: (() -> Void)?
    public var onTimelineAction: ((String) -> Void)?
    public var onResolveMediaItem: ((UUID?, URL?) -> MediaItem?)?
    public var onSectionActivated: (() -> Void)?
    public var onRequestZoom: ((_ factor: Double, _ viewportAnchorX: CGFloat) -> Void)?
    public var onCanvasWidthChanged: (() -> Void)?
    public var onExportTimelineRequested: (() -> Void)?
    public var onImportDroppedURLsToTimeline: ((_ urls: [URL], _ atTime: CMTime, _ targetTrackIndex: Int, _ isTargetVideo: Bool) -> Void)?

    public let headerWidth: CGFloat = 104
    public let rulerHeight: CGFloat = 26
    public let videoRowHeight: CGFloat = 46
    public let audioRowHeight: CGFloat = 40

    // Internal Clip Dragging state
    private var draggedClipId: UUID?
    private var draggedClipIsVideo: Bool = true
    private var dragInitialPoint: CGPoint = .zero
    private var dragInitialStartTime: CMTime = .zero
    private var dragInitialTrackIndex: Int = 0
    private var currentDragTime: CMTime = .zero
    private var currentDragTrackIndex: Int = 0
    private var isDraggingClip = false
    private var activeSnapLineTime: CMTime? = nil

    // Linked Companion dragging state
    private var linkedCompanionId: UUID? = nil
    private var linkedCompanionInitialStart: CMTime = .zero
    private var linkedCompanionInitialTrack: Int = 0

    // Ruler scrub state
    private var isScrubbingRuler = false

    // Rubber-Band Marquee Selection state
    private var isMarqueeSelecting = false
    private var marqueeStartPoint: CGPoint = .zero
    private var marqueeCurrentPoint: CGPoint = .zero
    private var marqueeInitialSelectedIds: Set<UUID> = []

    // External Drag & Drop from Media Pool / Finder state
    private var dropPreviewTime: CMTime? = nil
    private var dropPreviewTrackIndex: Int = 0
    private var dropPreviewIsVideo: Bool = true
    private var currentDraggingItems: [MediaItem] = []
    private var currentDraggingExternalURLs: [URL] = []

    // Clip Edge Trimming Gesture state
    private var trackingArea: NSTrackingArea?
    private var hoveredClipId: UUID? = nil
    private var hoveredClipEdge: ClipEdge? = nil
    private var isTrimmingEdge: Bool = false
    private var didTrimCurrentEdge: Bool = false
    private var activeTrimClipId: UUID? = nil
    private var activeTrimIsStart: Bool = false
    private var activeTrimIsVideo: Bool = true

    // Interactive Marker & Bar Drag/Delete state
    private struct MarkerTarget: Equatable {
        enum Kind: Equatable {
            case clipManual(clipId: UUID, isVideo: Bool, sourceSec: Double)
            case clipBeat(clipId: UUID, sourceSec: Double)
            case timelineCageBar(seconds: Double)
        }
        var kind: Kind
        var timelineSec: Double
    }
    private var hoveredMarker: MarkerTarget? = nil
    private var selectedMarker: MarkerTarget? = nil
    private var draggingMarker: MarkerTarget? = nil
    private var didMoveDraggingMarker: Bool = false

    public var widthConstraint: NSLayoutConstraint?

    private let playheadContainerLayer = CALayer()
    private let playheadLineLayer = CALayer()
    private let playheadHandleLayer = CALayer()

    public override var isFlipped: Bool { true }

    public init(model: TimelineModel, playbackController: PlaybackController) {
        self.model = model
        self.playbackController = playbackController
        super.init(frame: .zero)
        self.wantsLayer = true
        setupPlayheadLayers()
        registerForDraggedTypes([kMediaItemPasteboardType, kSelectionPasteboardType, .fileURL, .URL, NSPasteboard.PasteboardType("NSFilenamesPboardType")])

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onWaveformReady(_:)),
            name: .waveformReadyNotification,
            object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onWaveformReady(_ note: Notification) {
        DispatchQueue.main.async {
            self.needsDisplay = true
        }
    }

    // Centered Divider coordinate: exactly at 50% between ruler and bottom of the panel
    public var separatorY: CGFloat {
        let availableHeight = max(180, bounds.height)
        return rulerHeight + (availableHeight - rulerHeight) / 2.0
    }

    public var calculatedTotalWidth: CGFloat {
        let totalSeconds = max(30.0, CMTimeGetSeconds(model.totalDuration) + 10.0)
        return headerWidth + CGFloat(totalSeconds * pixelsPerSecond)
    }

    private func setupPlayheadLayers() {
        playheadContainerLayer.zPosition = 100
        playheadLineLayer.backgroundColor = NSColor.systemRed.cgColor
        playheadHandleLayer.backgroundColor = NSColor.systemRed.cgColor
        playheadHandleLayer.cornerRadius = 2
        playheadContainerLayer.addSublayer(playheadLineLayer)
        playheadContainerLayer.addSublayer(playheadHandleLayer)
    }

    public override func layout() {
        super.layout()
        updatePlayheadLayer()
    }

    public func updatePlayheadLayer() {
        guard let rootLayer = self.layer else { return }
        if playheadContainerLayer.superlayer !== rootLayer {
            rootLayer.addSublayer(playheadContainerLayer)
        }
        let sec = CMTimeGetSeconds(playbackController.currentTime)
        let safeSec = (sec.isFinite && sec >= 0) ? sec : 0
        let playheadX = headerWidth + CGFloat(safeSec * pixelsPerSecond)
        let totalHeight = max(bounds.height, rulerHeight)
        let stickyHeaderRight = max(0, visibleRect.minX) + headerWidth

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadContainerLayer.isHidden = (playheadX < stickyHeaderRight)
        playheadContainerLayer.frame = CGRect(x: playheadX - 5, y: 0, width: 10, height: totalHeight)
        playheadLineLayer.frame = CGRect(x: 4.25, y: 0, width: 1.5, height: totalHeight)
        playheadHandleLayer.frame = CGRect(x: 0, y: 0, width: 10, height: rulerHeight - 2)
        CATransaction.commit()
    }

    public func updateWidth() {
        onCanvasWidthChanged?()
        updatePlayheadLayer()
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: calculatedTotalWidth, height: NSView.noIntrinsicMetric)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds
        let sepY = separatorY

        // 1. Background
        ctx.setFillColor(NSColor(calibratedWhite: 0.075, alpha: 1.0).cgColor)
        ctx.fill(bounds)

        // 2. Video Tracks stack UPWARDS from separatorY
        for track in model.videoTracks {
            let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
            let rowRect = CGRect(x: headerWidth, y: trackY, width: bounds.width - headerWidth, height: videoRowHeight)
            let isEven = (track.id % 2 == 0)

            if track.isLocked {
                ctx.setFillColor(NSColor(calibratedRed: 0.11, green: 0.08, blue: 0.08, alpha: 1.0).cgColor)
            } else {
                ctx.setFillColor(isEven ? NSColor(calibratedWhite: 0.11, alpha: 1.0).cgColor : NSColor(calibratedWhite: 0.095, alpha: 1.0).cgColor)
            }
            ctx.fill(rowRect)

            for clip in track.clips {
                drawClip(clip: clip, y: trackY + 2, height: videoRowHeight - 4, isVideo: true, isTrackLocked: track.isLocked, isTrackEnabled: track.isEnabled, ctx: ctx)
            }
        }

        // Center Separator between Video and Audio (Exact 50% Middle)
        let sepRect = CGRect(x: 0, y: sepY - 2, width: bounds.width, height: 4)
        ctx.setFillColor(NSColor(calibratedWhite: 0.04, alpha: 1.0).cgColor)
        ctx.fill(sepRect)

        ctx.setStrokeColor(NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeLineSegments(between: [
            CGPoint(x: 0, y: sepY),
            CGPoint(x: bounds.width, y: sepY)
        ])

        // Audio Tracks stack DOWNWARDS from separatorY
        for track in model.audioTracks {
            let trackY = sepY + 4 + CGFloat(track.id) * audioRowHeight
            let rowRect = CGRect(x: headerWidth, y: trackY, width: bounds.width - headerWidth, height: audioRowHeight)
            let isEven = (track.id % 2 == 0)

            if track.isLocked {
                ctx.setFillColor(NSColor(calibratedRed: 0.11, green: 0.08, blue: 0.08, alpha: 1.0).cgColor)
            } else {
                ctx.setFillColor(isEven ? NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor : NSColor(calibratedWhite: 0.09, alpha: 1.0).cgColor)
            }
            ctx.fill(rowRect)

            for clip in track.clips {
                drawClip(clip: clip, y: trackY + 2, height: audioRowHeight - 4, isVideo: false, isTrackLocked: track.isLocked, isTrackEnabled: track.isEnabled, ctx: ctx)
            }
        }

        // 3. Time Ruler on top + Rhythmic Grid
        let stickyHeaderX = max(0, visibleRect.minX)
        drawRuler(ctx: ctx, bounds: bounds, visibleMinX: stickyHeaderX)

        // 4. Sticky Track Headers on the left (sopra clip e griglia ritmica)
        drawHeaders(ctx: ctx, bounds: bounds, sepY: sepY, originX: stickyHeaderX)

        // 5. External Drag & Drop Multi-Clip Ghost Preview
        if let previewT = dropPreviewTime, !currentDraggingItems.isEmpty {
            drawGhostPreviews(startTime: previewT, targetTrack: dropPreviewTrackIndex, isVideo: dropPreviewIsVideo, items: currentDraggingItems, sepY: sepY, ctx: ctx)
        }

        // 6. Snapping magnetic indicator line
        if let snapT = activeSnapLineTime {
            let snapX = headerWidth + CGFloat(CMTimeGetSeconds(snapT) * pixelsPerSecond)
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeLineSegments(between: [
                CGPoint(x: snapX, y: rulerHeight),
                CGPoint(x: snapX, y: bounds.height)
            ])
        }

        // 7. Playhead (GPU CALayer position update, avoids full CPU timeline redraw at 60Hz)
        updatePlayheadLayer()

        // 8. Rubber-Band Marquee Selection Box
        if isMarqueeSelecting {
            let rect = NSRect(
                x: min(marqueeStartPoint.x, marqueeCurrentPoint.x),
                y: min(marqueeStartPoint.y, marqueeCurrentPoint.y),
                width: abs(marqueeCurrentPoint.x - marqueeStartPoint.x),
                height: abs(marqueeCurrentPoint.y - marqueeStartPoint.y)
            )
            ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.18).cgColor)
            ctx.fill(rect)
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(1.0)
            ctx.stroke(rect)
        }
    }

    private func drawClip(
        clip: TimelineClip,
        y: CGFloat,
        height: CGFloat,
        isVideo: Bool,
        isTrackLocked: Bool,
        isTrackEnabled: Bool,
        ctx: CGContext
    ) {
        let startSec = CMTimeGetSeconds(clip.timelineStart)
        let durSec = CMTimeGetSeconds(clip.duration)
        let x = headerWidth + CGFloat(startSec * pixelsPerSecond)
        let w = max(3.0, CGFloat(durSec * pixelsPerSecond))
        let rect = CGRect(x: x, y: y, width: w, height: height)

        let isSelected = model.selectedClipIds.contains(clip.id)

        // Clip background
        let baseColor: NSColor
        if clip.isOrphan {
            baseColor = NSColor(calibratedRed: 0.65, green: 0.15, blue: 0.15, alpha: 1.0)
        } else if !isTrackEnabled {
            baseColor = NSColor.darkGray.withAlphaComponent(0.4)
        } else if isTrackLocked {
            baseColor = isVideo ? NSColor(calibratedRed: 0.28, green: 0.18, blue: 0.22, alpha: 1.0) : NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.28, alpha: 1.0)
        } else if isVideo {
            baseColor = isSelected ? NSColor.systemIndigo : NSColor(calibratedRed: 0.18, green: 0.35, blue: 0.58, alpha: 1.0)
        } else {
            baseColor = isSelected ? NSColor.systemTeal : NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.38, alpha: 1.0)
        }

        ctx.setFillColor(baseColor.cgColor)
        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        if let p = clip.priority, let pColor = priorityColor(for: p) {
            ctx.setFillColor(pColor.cgColor)
            let stripeRect = CGRect(x: x, y: y, width: min(4.0, w), height: height)
            ctx.fill(stripeRect)
        }

        // DaVinci Resolve Style Audio Waveform rendering on audio clips
        if !isVideo && isTrackEnabled && !clip.isOrphan {
            drawWaveform(for: clip, in: rect, ctx: ctx)
        }

        // Beat markers / gabbie segnate direttamente sul brano audio
        if !isVideo && !clip.beatMarkers.isEmpty && w > 8 {
            drawClipBeatMarkers(for: clip, in: rect, ctx: ctx)
        }

        // Marcatori manuali (M) su clip video e audio
        if !clip.markers.isEmpty && w > 6 {
            drawClipManualMarkers(for: clip, in: rect, ctx: ctx)
        }

        // Selection border
        if clip.isOrphan {
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(isSelected ? 2.5 : 1.5)
            ctx.addPath(path)
            ctx.strokePath()
        } else if clip.isLocked {
            ctx.setStrokeColor(NSColor.systemOrange.cgColor)
            ctx.setLineWidth(isSelected ? 2.2 : 1.6)
            ctx.addPath(path)
            ctx.strokePath()
        } else if isSelected {
            ctx.setStrokeColor(NSColor.systemCyan.cgColor)
            ctx.setLineWidth(2.0)
            ctx.addPath(path)
            ctx.strokePath()
        } else {
            ctx.setStrokeColor(NSColor(calibratedWhite: 0.5, alpha: 0.4).cgColor)
            ctx.setLineWidth(0.8)
            ctx.addPath(path)
            ctx.strokePath()
        }

        // Clip label
        if w > 24 {
            let label = clip.mediaItem.name
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                .foregroundColor: clip.isOrphan ? NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.85, alpha: 1.0) : (isTrackEnabled ? NSColor.white : NSColor.lightGray)
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            let textRect = CGRect(x: x + 4, y: y + 2, width: max(10, w - 8), height: 14)
            str.draw(with: textRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        }

        // Badges: Manual Markers (◆), BeatMarkers (♪), Speed (50%), Span (2x/3x), Cage (G1, G2...)
        var badgeX = x + w - 4
        if !clip.markers.isEmpty && w > 42 {
            let markerText = "◆ \(clip.markers.count)"
            let mAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let mSize = (markerText as NSString).size(withAttributes: mAttrs)
            badgeX -= (mSize.width + 6)
            let badgeRect = CGRect(x: badgeX, y: y + 2, width: mSize.width + 6, height: 12)
            ctx.setFillColor(NSColor(calibratedRed: 0.92, green: 0.22, blue: 0.56, alpha: 0.95).cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            (markerText as NSString).draw(at: CGPoint(x: badgeX + 3, y: y + 2), withAttributes: mAttrs)
            badgeX -= 3
        }

        if !isVideo && !clip.beatMarkers.isEmpty && w > 48 {
            let beatText = clip.beatBPM.map { "♪ \(Int($0.rounded()))" } ?? "♪ \(clip.beatMarkers.count)"
            let bAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            let bSize = (beatText as NSString).size(withAttributes: bAttrs)
            badgeX -= (bSize.width + 6)
            let badgeRect = CGRect(x: badgeX, y: y + 2, width: bSize.width + 6, height: 12)
            ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.92).cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            (beatText as NSString).draw(at: CGPoint(x: badgeX + 3, y: y + 2), withAttributes: bAttrs)
            badgeX -= 3
        }

        if clip.speed != 1.0 && w > 42 {
            let speedText = "\(Int(clip.speed * 100))%"
            let sAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            let sSize = (speedText as NSString).size(withAttributes: sAttrs)
            badgeX -= (sSize.width + 6)
            let badgeRect = CGRect(x: badgeX, y: y + 2, width: sSize.width + 6, height: 12)
            ctx.setFillColor(NSColor.systemYellow.cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            (speedText as NSString).draw(at: CGPoint(x: badgeX + 3, y: y + 2), withAttributes: sAttrs)
            badgeX -= 3
        }

        if clip.span > 1 && w > 58 {
            let spanText = "\(clip.span)x"
            let spAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let spSize = (spanText as NSString).size(withAttributes: spAttrs)
            badgeX -= (spSize.width + 6)
            let badgeRect = CGRect(x: badgeX, y: y + 2, width: spSize.width + 6, height: 12)
            ctx.setFillColor(NSColor.systemCyan.cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            (spanText as NSString).draw(at: CGPoint(x: badgeX + 3, y: y + 2), withAttributes: spAttrs)
            badgeX -= 3
        }

        if clip.isLocked && w > 22 {
            badgeX -= 16
            let lockPill = CGRect(x: badgeX, y: y + 2, width: 14, height: 12)
            ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.95).cgColor)
            ctx.addPath(CGPath(roundedRect: lockPill, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            let lockImg = Lucide.image(.lock, size: 9, color: .black)
            lockImg.draw(in: CGRect(x: badgeX + 2.5, y: y + 3.5, width: 9, height: 9))
            badgeX -= 3
        }

        if let p = clip.priority, let pColor = priorityColor(for: p), w > 24 {
            let pText = "P\(p)"
            let pAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
                .foregroundColor: NSColor.black
            ]
            let pSize = (pText as NSString).size(withAttributes: pAttrs)
            badgeX -= (pSize.width + 6)
            let badgeRect = CGRect(x: badgeX, y: y + 2, width: pSize.width + 6, height: 12)
            ctx.setFillColor(pColor.cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            (pText as NSString).draw(at: CGPoint(x: badgeX + 3, y: y + 2), withAttributes: pAttrs)
            badgeX -= 3
        }

        if let cIdx = clip.cageIndex, w > 74 {
            let cText = "G\(cIdx + 1)"
            let cAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold),
                .foregroundColor: NSColor(calibratedWhite: 0.9, alpha: 1.0)
            ]
            let cSize = (cText as NSString).size(withAttributes: cAttrs)
            badgeX -= (cSize.width + 6)
            let badgeRect = CGRect(x: badgeX, y: y + 2, width: cSize.width + 6, height: 12)
            ctx.setFillColor(NSColor(calibratedWhite: 0.2, alpha: 0.85).cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            (cText as NSString).draw(at: CGPoint(x: badgeX + 3, y: y + 2), withAttributes: cAttrs)
        }

        // Draw [ or ] edge brackets on hover or active edge trimming
        let isStartHover = (hoveredClipId == clip.id && hoveredClipEdge == .start) || (isTrimmingEdge && activeTrimClipId == clip.id && activeTrimIsStart)
        let isEndHover = (hoveredClipId == clip.id && hoveredClipEdge == .end) || (isTrimmingEdge && activeTrimClipId == clip.id && !activeTrimIsStart)

        if isStartHover {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(calibratedRed: 0.1, green: 0.95, blue: 1.0, alpha: 1.0).cgColor)
            ctx.setLineWidth(2.5)
            let bPath = CGMutablePath()
            bPath.move(to: CGPoint(x: x + 8, y: y + 2))
            bPath.addLine(to: CGPoint(x: x + 2, y: y + 2))
            bPath.addLine(to: CGPoint(x: x + 2, y: y + height - 2))
            bPath.addLine(to: CGPoint(x: x + 8, y: y + height - 2))
            ctx.addPath(bPath)
            ctx.strokePath()
            ctx.restoreGState()
        }

        if isEndHover {
            ctx.saveGState()
            ctx.setStrokeColor(NSColor(calibratedRed: 0.1, green: 0.95, blue: 1.0, alpha: 1.0).cgColor)
            ctx.setLineWidth(2.5)
            let bPath = CGMutablePath()
            bPath.move(to: CGPoint(x: x + w - 8, y: y + 2))
            bPath.addLine(to: CGPoint(x: x + w - 2, y: y + 2))
            bPath.addLine(to: CGPoint(x: x + w - 2, y: y + height - 2))
            bPath.addLine(to: CGPoint(x: x + w - 8, y: y + height - 2))
            ctx.addPath(bPath)
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    private func priorityColor(for priority: Int) -> NSColor? {
        switch priority {
        case 1: return NSColor(calibratedRed: 0.96, green: 0.62, blue: 0.04, alpha: 1.0) // Hero (Amber/Gold)
        case 2: return NSColor(calibratedRed: 0.06, green: 0.72, blue: 0.51, alpha: 1.0) // Buona (Emerald)
        case 3: return NSColor(calibratedRed: 0.55, green: 0.36, blue: 0.96, alpha: 1.0) // Filler (Violet)
        default: return nil
        }
    }

    private func drawWaveform(for clip: TimelineClip, in rect: CGRect, ctx: CGContext) {
        guard rect.width > 4 else { return }

        let waveformHeight = max(8.0, rect.height - 10)
        let maxHalfH = waveformHeight * 0.5
        let centerY = rect.midY + 4

        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: 1, dy: 1))

        if let wf = AudioWaveformCache.shared.waveformData(for: clip.mediaItem.url), !wf.peaks.isEmpty {
            let clipStartSec = CMTimeGetSeconds(clip.timelineStart)
            let sourceInSec = CMTimeGetSeconds(clip.sourceIn)
            let speed = clip.speed > 0 ? clip.speed : 1.0

            // Renderizza esclusivamente le colonne pixel visibili: 1 colonna per ogni 1pt orizzontale, zero aliasing / zero drift allo zoom!
            let visMinX = max(rect.minX, visibleRect.minX)
            let visMaxX = min(rect.maxX, visibleRect.maxX)
            guard visMaxX > visMinX else {
                ctx.restoreGState()
                return
            }

            let startPx = Int(floor(visMinX))
            let endPx = Int(ceil(visMaxX))
            let colCount = endPx - startPx
            guard colCount > 0 else {
                ctx.restoreGState()
                return
            }

            var xs = [CGFloat]()
            var topPeakY = [CGFloat]()
            var botPeakY = [CGFloat]()
            var topRmsY = [CGFloat]()
            var botRmsY = [CGFloat]()
            xs.reserveCapacity(colCount)
            topPeakY.reserveCapacity(colCount)
            botPeakY.reserveCapacity(colCount)
            topRmsY.reserveCapacity(colCount)
            botRmsY.reserveCapacity(colCount)

            for px in startPx..<endPx {
                let x = CGFloat(px) + 0.5
                let t0 = Double(CGFloat(px) - headerWidth) / pixelsPerSecond
                let t1 = Double(CGFloat(px) + 1.0 - headerWidth) / pixelsPerSecond
                let src0 = sourceInSec + (t0 - clipStartSec) * speed
                let src1 = sourceInSec + (t1 - clipStartSec) * speed

                let env = wf.envelope(from: src0, to: src1)
                // Curva percettiva Resolve-style: mantiene picchi netti senza appiattire la dinamica
                let pAmp = max(0.8, CGFloat(pow(Double(env.peak), 0.72)) * maxHalfH)
                let rAmp = max(0.5, CGFloat(pow(Double(env.rms), 0.78)) * maxHalfH)

                xs.append(x)
                topPeakY.append(centerY - pAmp)
                botPeakY.append(centerY + pAmp)
                topRmsY.append(centerY - rAmp)
                botRmsY.append(centerY + rAmp)
            }

            // 1. Silhouette continua esterna (Peak Envelope - Verde/Smeraldo Resolve)
            let peakPath = CGMutablePath()
            peakPath.move(to: CGPoint(x: xs[0], y: topPeakY[0]))
            for i in 1..<xs.count {
                peakPath.addLine(to: CGPoint(x: xs[i], y: topPeakY[i]))
            }
            for i in stride(from: xs.count - 1, through: 0, by: -1) {
                peakPath.addLine(to: CGPoint(x: xs[i], y: botPeakY[i]))
            }
            peakPath.closeSubpath()

            ctx.setFillColor(NSColor(calibratedRed: 0.36, green: 0.88, blue: 0.58, alpha: 0.65).cgColor)
            ctx.addPath(peakPath)
            ctx.fillPath()

            // Bordo nitido superiore/inferiore del picco
            let topEdge = CGMutablePath()
            topEdge.move(to: CGPoint(x: xs[0], y: topPeakY[0]))
            for i in 1..<xs.count { topEdge.addLine(to: CGPoint(x: xs[i], y: topPeakY[i])) }
            let botEdge = CGMutablePath()
            botEdge.move(to: CGPoint(x: xs[0], y: botPeakY[0]))
            for i in 1..<xs.count { botEdge.addLine(to: CGPoint(x: xs[i], y: botPeakY[i])) }
            ctx.setStrokeColor(NSColor(calibratedRed: 0.62, green: 0.98, blue: 0.76, alpha: 0.9).cgColor)
            ctx.setLineWidth(0.75)
            ctx.addPath(topEdge)
            ctx.addPath(botEdge)
            ctx.strokePath()

            // 2. Nucleo RMS interno luminoso (corpo energia reale)
            let rmsPath = CGMutablePath()
            rmsPath.move(to: CGPoint(x: xs[0], y: topRmsY[0]))
            for i in 1..<xs.count {
                rmsPath.addLine(to: CGPoint(x: xs[i], y: topRmsY[i]))
            }
            for i in stride(from: xs.count - 1, through: 0, by: -1) {
                rmsPath.addLine(to: CGPoint(x: xs[i], y: botRmsY[i]))
            }
            rmsPath.closeSubpath()

            ctx.setFillColor(NSColor(calibratedRed: 0.60, green: 0.96, blue: 0.72, alpha: 0.85).cgColor)
            ctx.addPath(rmsPath)
            ctx.fillPath()

            // Asse 0 dB centrale sottile
            ctx.setStrokeColor(NSColor(calibratedRed: 0.85, green: 1.0, blue: 0.9, alpha: 0.25).cgColor)
            ctx.setLineWidth(0.5)
            ctx.strokeLineSegments(between: [
                CGPoint(x: visMinX, y: centerY),
                CGPoint(x: visMaxX, y: centerY)
            ])
        } else {
            // Trigger real background waveform analysis
            AudioWaveformCache.shared.loadWaveform(for: clip.mediaItem)

            // Clean subtle baseline while loading
            ctx.setStrokeColor(NSColor(calibratedRed: 0.35, green: 0.65, blue: 0.45, alpha: 0.3).cgColor)
            ctx.setLineWidth(1.0)
            ctx.strokeLineSegments(between: [
                CGPoint(x: rect.minX + 2, y: centerY),
                CGPoint(x: rect.maxX - 2, y: centerY)
            ])
        }

        ctx.restoreGState()
    }

    private func isMarkerHighlighted(clipId: UUID, isBeat: Bool, timelineSec: Double) -> Bool {
        for target in [hoveredMarker, selectedMarker, draggingMarker].compactMap({ $0 }) {
            switch target.kind {
            case .clipBeat(let cid, _) where isBeat && cid == clipId && abs(target.timelineSec - timelineSec) < 0.02:
                return true
            case .clipManual(let cid, _, _) where !isBeat && cid == clipId && abs(target.timelineSec - timelineSec) < 0.02:
                return true
            default:
                break
            }
        }
        return false
    }

    private func drawClipBeatMarkers(for clip: TimelineClip, in rect: CGRect, ctx: CGContext) {
        let markerTimes = clip.visibleBeatTimelineTimes()
        guard !markerTimes.isEmpty else { return }

        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: 1, dy: 1))

        let lineColor = NSColor.systemOrange.withAlphaComponent(0.85).cgColor
        let capColor = NSColor.systemYellow.withAlphaComponent(0.95).cgColor

        for tSec in markerTimes {
            let mx = headerWidth + CGFloat(tSec * pixelsPerSecond)
            if mx < rect.minX || mx > rect.maxX { continue }
            let hi = isMarkerHighlighted(clipId: clip.id, isBeat: true, timelineSec: tSec)

            ctx.setStrokeColor(hi ? NSColor.white.cgColor : lineColor)
            ctx.setLineWidth(hi ? 2.4 : 1.2)
            ctx.strokeLineSegments(between: [
                CGPoint(x: mx, y: rect.minY + 1),
                CGPoint(x: mx, y: rect.maxY - 1)
            ])

            let capW: CGFloat = hi ? 6.0 : 4.0
            let capH: CGFloat = hi ? 5.0 : 3.5
            let capRect = CGRect(x: mx - capW * 0.5, y: rect.minY + 1, width: capW, height: capH)
            ctx.setFillColor(hi ? NSColor.white.cgColor : capColor)
            ctx.fill(capRect)
        }

        ctx.restoreGState()
    }

    private func drawClipManualMarkers(for clip: TimelineClip, in rect: CGRect, ctx: CGContext) {
        let markerTimes = clip.visibleMarkersTimelineTimes()
        guard !markerTimes.isEmpty else { return }

        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: 1, dy: 1))

        let lineColor = NSColor(calibratedRed: 0.98, green: 0.30, blue: 0.64, alpha: 0.92).cgColor
        let pinColor = NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.72, alpha: 1.0).cgColor

        for tSec in markerTimes {
            let mx = headerWidth + CGFloat(tSec * pixelsPerSecond)
            if mx < rect.minX || mx > rect.maxX { continue }
            let hi = isMarkerHighlighted(clipId: clip.id, isBeat: false, timelineSec: tSec)

            ctx.setStrokeColor(hi ? NSColor.white.cgColor : lineColor)
            ctx.setLineWidth(hi ? 2.5 : 1.5)
            ctx.strokeLineSegments(between: [
                CGPoint(x: mx, y: rect.minY + 1),
                CGPoint(x: mx, y: rect.maxY - 1)
            ])

            let topY = rect.minY + 1
            let rad: CGFloat = hi ? 5.0 : 4.0
            let diamond = CGMutablePath()
            diamond.move(to: CGPoint(x: mx, y: topY))
            diamond.addLine(to: CGPoint(x: mx + rad, y: topY + rad))
            diamond.addLine(to: CGPoint(x: mx, y: topY + rad * 2.0))
            diamond.addLine(to: CGPoint(x: mx - rad, y: topY + rad))
            diamond.closeSubpath()

            ctx.setFillColor(hi ? NSColor.white.cgColor : pinColor)
            ctx.addPath(diamond)
            ctx.fillPath()
        }

        ctx.restoreGState()
    }

    private func drawGhostPreviews(
        startTime: CMTime,
        targetTrack: Int,
        isVideo: Bool,
        items: [MediaItem],
        sepY: CGFloat,
        ctx: CGContext
    ) {
        var currentT = startTime

        for item in items {
            let startSec = CMTimeGetSeconds(currentT)
            let durSec = CMTimeGetSeconds(item.duration)
            let x = headerWidth + CGFloat(startSec * pixelsPerSecond)
            let w = max(3.0, CGFloat(durSec * pixelsPerSecond))

            if item.hasVideo {
                let trackY = sepY - CGFloat(targetTrack + 1) * videoRowHeight
                let rect = CGRect(x: x, y: trackY + 2, width: w, height: videoRowHeight - 4)

                ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.35).cgColor)
                let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()

                ctx.setStrokeColor(NSColor.systemCyan.cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(path)
                ctx.strokePath()
            }

            if item.hasAudio && (model.isLinkActive || !item.hasVideo) {
                let aTrackIdx = min(targetTrack, model.maxAudioTracks - 1)
                let trackY = sepY + 4 + CGFloat(aTrackIdx) * audioRowHeight
                let rect = CGRect(x: x, y: trackY + 2, width: w, height: audioRowHeight - 4)

                ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.35).cgColor)
                let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()

                ctx.setStrokeColor(NSColor.systemGreen.cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(path)
                ctx.strokePath()
            }

            currentT = CMTimeAdd(currentT, item.duration)
        }
    }

    private func drawHeaders(ctx: CGContext, bounds: CGRect, sepY: CGFloat, originX: CGFloat) {
        // Left Column background (sticky al bordo sinistro visibile)
        let headerRect = CGRect(x: originX, y: 0, width: headerWidth, height: bounds.height)
        ctx.setFillColor(NSColor(calibratedWhite: 0.095, alpha: 1.0).cgColor)
        ctx.fill(headerRect)

        ctx.setStrokeColor(NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokeLineSegments(between: [
            CGPoint(x: originX + headerWidth, y: 0),
            CGPoint(x: originX + headerWidth, y: bounds.height)
        ])

        // Video headers
        for track in model.videoTracks {
            let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
            drawTrackHeaderItem(name: track.name, isLocked: track.isLocked, isEnabled: track.isEnabled, originX: originX, y: trackY, height: videoRowHeight)
        }

        // Audio headers
        for track in model.audioTracks {
            let trackY = sepY + 4 + CGFloat(track.id) * audioRowHeight
            drawTrackHeaderItem(name: track.name, isLocked: track.isLocked, isEnabled: track.isEnabled, originX: originX, y: trackY, height: audioRowHeight)
        }
    }

    private static let lockActiveIcon = Lucide.image(.lock, size: 13, color: .systemOrange)
    private static let lockInactiveIcon = Lucide.image(.unlock, size: 13, color: NSColor(calibratedWhite: 0.45, alpha: 1.0))
    private static let eyeActiveIcon = Lucide.image(.eye, size: 14, color: NSColor(calibratedWhite: 0.88, alpha: 1.0))
    private static let eyeInactiveIcon = Lucide.image(.eyeOff, size: 14, color: NSColor(calibratedWhite: 0.42, alpha: 1.0))

    private func drawTrackHeaderItem(name: String, isLocked: Bool, isEnabled: Bool, originX: CGFloat, y: CGFloat, height: CGFloat) {
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.white
        ]
        NSAttributedString(string: name, attributes: nameAttrs).draw(at: CGPoint(x: originX + 8, y: y + (height - 14) / 2))

        let lockImg = isLocked ? Self.lockActiveIcon : Self.lockInactiveIcon
        let lockRect = NSRect(x: originX + 42, y: y + (height - 13) / 2, width: 13, height: 13)
        lockImg.draw(in: lockRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)

        let eyeImg = isEnabled ? Self.eyeActiveIcon : Self.eyeInactiveIcon
        let eyeRect = NSRect(x: originX + 74, y: y + (height - 14) / 2, width: 14, height: 14)
        eyeImg.draw(in: eyeRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
    }

    private func drawRuler(ctx: CGContext, bounds: CGRect, visibleMinX: CGFloat) {
        let rulerStartX = visibleMinX + headerWidth
        let rulerRect = CGRect(x: rulerStartX, y: 0, width: max(0, bounds.width - rulerStartX), height: rulerHeight)
        ctx.setFillColor(NSColor(calibratedWhite: 0.115, alpha: 1.0).cgColor)
        ctx.fill(rulerRect)

        ctx.setStrokeColor(NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokeLineSegments(between: [
            CGPoint(x: rulerStartX, y: rulerHeight),
            CGPoint(x: bounds.width, y: rulerHeight)
        ])

        let stepSec: Double = pixelsPerSecond >= 80 ? 1.0 : (pixelsPerSecond >= 30 ? 5.0 : 10.0)
        let subStepSec: Double = stepSec / 5.0
        let totalSeconds = max(30.0, CMTimeGetSeconds(model.totalDuration) + 10.0)
        let visStartSec = max(0.0, Double(visibleMinX) / pixelsPerSecond)
        let visEndSec = min(totalSeconds, Double(max(bounds.width, visibleRect.maxX) - headerWidth) / pixelsPerSecond + stepSec)

        // Sotto-tacche secondarie
        var st = max(0.0, floor(visStartSec / subStepSec) * subStepSec)
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.34, alpha: 0.85).cgColor)
        ctx.setLineWidth(0.75)
        while st <= visEndSec {
            let sx = headerWidth + CGFloat(st * pixelsPerSecond)
            if sx >= rulerStartX && sx <= visibleRect.maxX {
                ctx.strokeLineSegments(between: [
                    CGPoint(x: sx, y: rulerHeight - 4),
                    CGPoint(x: sx, y: rulerHeight)
                ])
            }
            st += subStepSec
        }

        // Tacche principali ed etichette tempo
        var t = max(0.0, floor(visStartSec / stepSec) * stepSec)
        while t <= visEndSec {
            let x = headerWidth + CGFloat(t * pixelsPerSecond)
            if x >= rulerStartX && x <= visibleRect.maxX {
                ctx.setStrokeColor(NSColor(calibratedWhite: 0.55, alpha: 1.0).cgColor)
                ctx.setLineWidth(1.0)
                ctx.strokeLineSegments(between: [
                    CGPoint(x: x, y: rulerHeight - 8),
                    CGPoint(x: x, y: rulerHeight)
                ])

                let mins = Int(t) / 60
                let secs = Int(t) % 60
                let label = String(format: "%02d:%02d", mins, secs)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1.0)
                ]
                NSAttributedString(string: label, attributes: attrs).draw(at: CGPoint(x: x + 2, y: 2))
            }
            t += stepSec
        }

        // Visualizzazione Gabbie Ritmate (Rhythmic Grid dinamica su tracce audio + timeline)
        let liveCages = model.activeCageIntervals()
        if model.isRhythmicGridVisible && !liveCages.isEmpty {
            for cage in liveCages {
                let startX = headerWidth + CGFloat(cage.startSeconds * pixelsPerSecond)
                let endX = headerWidth + CGFloat(cage.endSeconds * pixelsPerSecond)
                let w = endX - startX

                if endX >= headerWidth && startX <= bounds.width {
                    // Linea verticale tratteggiata di divisione gabbia
                    ctx.saveGState()
                    ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.35).cgColor)
                    ctx.setLineWidth(1.0)
                    ctx.setLineDash(phase: 0, lengths: [4, 4])
                    ctx.strokeLineSegments(between: [
                        CGPoint(x: startX, y: rulerHeight),
                        CGPoint(x: startX, y: bounds.height)
                    ])
                    ctx.restoreGState()

                    // Badge numerico gabbia nel righello
                    if w >= 16 {
                        let badgeRect = CGRect(x: startX + 2, y: rulerHeight - 11, width: min(w - 4, 22), height: 10)
                        ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.25).cgColor)
                        ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
                        ctx.fillPath()

                        let cLabel = "\(cage.index + 1)"
                        let cAttrs: [NSAttributedString.Key: Any] = [
                            .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .bold),
                            .foregroundColor: NSColor.systemCyan
                        ]
                        (cLabel as NSString).draw(at: CGPoint(x: startX + 4, y: rulerHeight - 11.5), withAttributes: cAttrs)
                    }
                }
            }

            if let lastCage = liveCages.last {
                let endX = headerWidth + CGFloat(lastCage.endSeconds * pixelsPerSecond)
                if endX >= headerWidth && endX <= bounds.width {
                    ctx.saveGState()
                    ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.35).cgColor)
                    ctx.setLineWidth(1.0)
                    ctx.setLineDash(phase: 0, lengths: [4, 4])
                    ctx.strokeLineSegments(between: [
                        CGPoint(x: endX, y: rulerHeight),
                        CGPoint(x: endX, y: bounds.height)
                    ])
                    ctx.restoreGState()
                }
            }

            // Etichetta BPM / conteggio gabbie in alto a sinistra nel righello
            let bpmPrefix = model.effectiveDetectedBPM.map { "\(String(format: "%.1f", $0)) BPM • " } ?? ""
            let bpmTag = "🎵 \(bpmPrefix)\(liveCages.count) gabbie"
            let bAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                .foregroundColor: NSColor.systemCyan
            ]
            (bpmTag as NSString).draw(at: CGPoint(x: headerWidth + 6, y: 2), withAttributes: bAttrs)
        }
    }

    private func markerHitTest(at localPoint: NSPoint) -> MarkerTarget? {
        let sepY = separatorY
        let stickyHeaderRight = max(0, visibleRect.minX) + headerWidth
        guard localPoint.x >= stickyHeaderRight else { return nil }

        func findMarkerInClip(_ clip: TimelineClip, trackY: CGFloat, rowHeight: CGFloat, isVideo: Bool) -> MarkerTarget? {
            guard localPoint.y >= trackY && localPoint.y <= trackY + rowHeight else { return nil }
            let cStart = CMTimeGetSeconds(clip.timelineStart)
            let dur = CMTimeGetSeconds(clip.duration)
            let clipX = headerWidth + CGFloat(cStart * pixelsPerSecond)
            let clipW = CGFloat(dur * pixelsPerSecond)
            guard localPoint.x >= clipX - 4 && localPoint.x <= clipX + clipW + 4 else { return nil }

            let nearPinHead = (localPoint.y <= trackY + 14)
            let onOuterTrimEdge = (localPoint.x <= clipX + 5.0 || localPoint.x >= clipX + clipW - 5.0)
            if onOuterTrimEdge && !nearPinHead { return nil }

            let spd = clip.speed > 0 ? clip.speed : 1.0
            let sIn = CMTimeGetSeconds(clip.sourceIn)
            let sOut = CMTimeGetSeconds(clip.sourceOut)

            var best: (target: MarkerTarget, dist: CGFloat)? = nil

            for srcM in clip.markers where srcM >= sIn - 0.001 && srcM <= sOut + 0.001 {
                let tSec = cStart + (srcM - sIn) / spd
                let mx = headerWidth + CGFloat(tSec * pixelsPerSecond)
                let dist = abs(localPoint.x - mx)
                if dist <= 5.5 {
                    let cand = MarkerTarget(kind: .clipManual(clipId: clip.id, isVideo: isVideo, sourceSec: srcM), timelineSec: tSec)
                    if best == nil || dist < best!.dist {
                        best = (cand, dist)
                    }
                }
            }

            if !isVideo {
                for srcM in clip.beatMarkers where srcM >= sIn - 0.001 && srcM <= sOut + 0.001 {
                    let tSec = cStart + (srcM - sIn) / spd
                    let mx = headerWidth + CGFloat(tSec * pixelsPerSecond)
                    let dist = abs(localPoint.x - mx)
                    if dist <= 5.0 {
                        let cand = MarkerTarget(kind: .clipBeat(clipId: clip.id, sourceSec: srcM), timelineSec: tSec)
                        // Manual markers slightly prioritized when exact tie
                        if best == nil || dist + 0.5 < best!.dist {
                            best = (cand, dist)
                        }
                    }
                }
            }

            return best?.target
        }

        for track in model.videoTracks where !track.isLocked {
            let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
            for clip in track.clips {
                if let hit = findMarkerInClip(clip, trackY: trackY, rowHeight: videoRowHeight, isVideo: true) {
                    return hit
                }
            }
        }
        for track in model.audioTracks where !track.isLocked {
            let trackY = sepY + 4 + CGFloat(track.id) * audioRowHeight
            for clip in track.clips {
                if let hit = findMarkerInClip(clip, trackY: trackY, rowHeight: audioRowHeight, isVideo: false) {
                    return hit
                }
            }
        }

        // Static timeline cages (when audio clips don't drive beats directly and user drags/deletes a static bar)
        let hasAudioBeats = model.audioTracks.filter { $0.isEnabled }.flatMap(\.clips).contains { !$0.visibleBeatTimelineTimes().isEmpty }
        if !hasAudioBeats && model.isRhythmicGridVisible && !model.rhythmicCages.isEmpty {
            let boundaries = model.activeCageBoundaries()
            for bSec in boundaries {
                let bx = headerWidth + CGFloat(bSec * pixelsPerSecond)
                if abs(localPoint.x - bx) <= 4.5 && localPoint.y > rulerHeight {
                    return MarkerTarget(kind: .timelineCageBar(seconds: bSec), timelineSec: bSec)
                }
            }
        }

        return nil
    }

    public func deleteSelectedMarker() -> Bool {
        guard let target = selectedMarker else { return false }
        var deleted = false
        switch target.kind {
        case .clipManual(let clipId, _, let sourceSec):
            deleted = model.removeClipMarker(clipId: clipId, isBeatMarker: false, nearSourceSec: sourceSec)
        case .clipBeat(let clipId, let sourceSec):
            deleted = model.removeClipMarker(clipId: clipId, isBeatMarker: true, nearSourceSec: sourceSec)
        case .timelineCageBar(let sec):
            deleted = model.removeTimelineCageBoundary(near: sec)
        }
        if deleted {
            selectedMarker = nil
            hoveredMarker = nil
            needsDisplay = true
        }
        return deleted
    }

    public override func mouseMoved(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let sepY = separatorY
        let edgeMargin: CGFloat = 8.0

        let markerHit = markerHitTest(at: localPoint)
        if markerHit != hoveredMarker {
            hoveredMarker = markerHit
            needsDisplay = true
        }
        if markerHit != nil {
            if hoveredClipEdge != nil || hoveredClipId != nil {
                hoveredClipId = nil
                hoveredClipEdge = nil
                needsDisplay = true
            }
            NSCursor.resizeLeftRight.set()
            return
        }

        var foundClipId: UUID? = nil
        var foundEdge: ClipEdge? = nil

        // Check video clips
        for track in model.videoTracks where !track.isLocked {
            let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
            if localPoint.y >= trackY && localPoint.y <= trackY + videoRowHeight {
                for clip in track.clips where !clip.isLocked {
                    let clipX = headerWidth + CGFloat(CMTimeGetSeconds(clip.timelineStart) * pixelsPerSecond)
                    let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                    if localPoint.x >= clipX - 2 && localPoint.x <= clipX + edgeMargin {
                        foundClipId = clip.id
                        foundEdge = .start
                        break
                    } else if localPoint.x >= clipX + clipW - edgeMargin && localPoint.x <= clipX + clipW + 2 {
                        foundClipId = clip.id
                        foundEdge = .end
                        break
                    }
                }
            }
            if foundClipId != nil { break }
        }

        // Check audio clips
        if foundClipId == nil {
            for track in model.audioTracks where !track.isLocked {
                let trackY = sepY + 4 + CGFloat(track.id) * audioRowHeight
                if localPoint.y >= trackY && localPoint.y <= trackY + audioRowHeight {
                    for clip in track.clips where !clip.isLocked {
                        let clipX = headerWidth + CGFloat(CMTimeGetSeconds(clip.timelineStart) * pixelsPerSecond)
                        let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                        if localPoint.x >= clipX - 2 && localPoint.x <= clipX + edgeMargin {
                            foundClipId = clip.id
                            foundEdge = .start
                            break
                        } else if localPoint.x >= clipX + clipW - edgeMargin && localPoint.x <= clipX + clipW + 2 {
                            foundClipId = clip.id
                            foundEdge = .end
                            break
                        }
                    }
                }
                if foundClipId != nil { break }
            }
        }

        if foundEdge != hoveredClipEdge || foundClipId != hoveredClipId {
            hoveredClipId = foundClipId
            hoveredClipEdge = foundEdge
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
        hoveredClipEdge = nil
        hoveredMarker = nil
        NSCursor.arrow.set()
        needsDisplay = true
    }

    // MARK: - Mouse & Drag Handlers
    public override func mouseDown(with event: NSEvent) {
        onSectionActivated?()
        let localPoint = convert(event.locationInWindow, from: nil)
        let isShift = event.modifierFlags.contains(.shift)
        let sepY = separatorY

        let stickyMinX = max(0, visibleRect.minX)
        let stickyHeaderRight = stickyMinX + headerWidth

        // 0. Clicked on a Clip Marker (M), Beat Marker, or Static Cage Bar
        if let mHit = markerHitTest(at: localPoint) {
            selectedMarker = mHit
            draggingMarker = mHit
            didMoveDraggingMarker = false
            needsDisplay = true
            return
        }
        if selectedMarker != nil {
            selectedMarker = nil
            needsDisplay = true
        }

        // 1. Clicked in Ruler: Scrub playhead
        if localPoint.y <= rulerHeight {
            guard localPoint.x >= stickyHeaderRight else { return }
            isScrubbingRuler = true
            let targetX = max(headerWidth, localPoint.x)
            let targetSeconds = max(0, Double(targetX - headerWidth) / pixelsPerSecond)
            let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
            playbackController.scrub(to: targetTime)
            if model.isSelectionFollowsPlayhead {
                model.updateSelectionAtPlayhead(time: targetTime)
            }
            needsDisplay = true
            return
        }

        // 2. Clicked in Track Header area (Left Sticky Column): Toggle Lock / Enable
        if localPoint.x < stickyHeaderRight {
            let relX = localPoint.x - stickyMinX
            // Check Video Tracks
            for track in model.videoTracks {
                let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
                if localPoint.y >= trackY && localPoint.y <= trackY + videoRowHeight {
                    if relX >= 38 && relX <= 64 {
                        model.toggleTrackLock(id: track.id, isVideo: true)
                        needsDisplay = true
                        return
                    } else if relX >= 70 && relX <= 96 {
                        model.toggleTrackEnabled(id: track.id, isVideo: true)
                        needsDisplay = true
                        notifyModified("Abilita/Disabilita Traccia V\(track.id + 1)")
                        return
                    }
                }
            }
            // Check Audio Tracks
            for track in model.audioTracks {
                let trackY = sepY + 4 + CGFloat(track.id) * audioRowHeight
                if localPoint.y >= trackY && localPoint.y <= trackY + audioRowHeight {
                    if relX >= 38 && relX <= 64 {
                        model.toggleTrackLock(id: track.id, isVideo: false)
                        needsDisplay = true
                        return
                    } else if relX >= 70 && relX <= 96 {
                        model.toggleTrackEnabled(id: track.id, isVideo: false)
                        needsDisplay = true
                        notifyModified("Abilita/Disabilita Traccia A\(track.id + 1)")
                        return
                    }
                }
            }
            return
        }

        // 3. Clicked on a Video Clip
        for track in model.videoTracks {
            let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
            if localPoint.y >= trackY && localPoint.y <= trackY + videoRowHeight {
                for clip in track.clips {
                    let clipX = headerWidth + CGFloat(CMTimeGetSeconds(clip.timelineStart) * pixelsPerSecond)
                    let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                    if localPoint.x >= clipX && localPoint.x <= clipX + clipW {
                        if !track.isLocked {
                            if isShift {
                                if model.selectedClipIds.contains(clip.id) {
                                    model.selectedClipIds.remove(clip.id)
                                } else {
                                    model.selectedClipIds.insert(clip.id)
                                }
                            } else if !model.selectedClipIds.contains(clip.id) {
                                var newSelection: Set<UUID> = [clip.id]
                                if model.isLinkActive, let lId = clip.linkGroupId {
                                    for aTrack in model.audioTracks {
                                        if let aClip = aTrack.clips.first(where: { $0.linkGroupId == lId }) {
                                            newSelection.insert(aClip.id)
                                        }
                                    }
                                }
                                model.selectedClipIds = newSelection
                            }

                            if clip.isLocked {
                                DebugLogger.shared.log("Clip '\(clip.mediaItem.name)' bloccata (L per sbloccare).", level: .info)
                                needsDisplay = true
                                return
                            }

                            let edgeMargin: CGFloat = 8.0
                            if localPoint.x <= clipX + edgeMargin {
                                isTrimmingEdge = true
                                didTrimCurrentEdge = false
                                activeTrimClipId = clip.id
                                activeTrimIsStart = true
                                activeTrimIsVideo = true
                                dragInitialPoint = localPoint
                                needsDisplay = true
                                return
                            } else if localPoint.x >= clipX + clipW - edgeMargin {
                                isTrimmingEdge = true
                                didTrimCurrentEdge = false
                                activeTrimClipId = clip.id
                                activeTrimIsStart = false
                                activeTrimIsVideo = true
                                dragInitialPoint = localPoint
                                needsDisplay = true
                                return
                            }

                            draggedClipId = clip.id
                            draggedClipIsVideo = true
                            dragInitialPoint = localPoint
                            dragInitialStartTime = clip.timelineStart
                            dragInitialTrackIndex = track.id
                            currentDragTime = clip.timelineStart
                            currentDragTrackIndex = track.id

                            if model.isLinkActive, let lId = clip.linkGroupId {
                                for aTrack in model.audioTracks {
                                    if let aClip = aTrack.clips.first(where: { $0.linkGroupId == lId }) {
                                        linkedCompanionId = aClip.id
                                        linkedCompanionInitialStart = aClip.timelineStart
                                        linkedCompanionInitialTrack = aClip.trackIndex
                                        break
                                    }
                                }
                            } else {
                                linkedCompanionId = nil
                            }
                        } else {
                            DebugLogger.shared.log("Traccia V\(track.id + 1) bloccata 🔒. Spostamento clip disabilitato.", level: .info)
                        }

                        needsDisplay = true
                        return
                    }
                }
            }
        }

        // 4. Clicked on an Audio Clip
        for track in model.audioTracks {
            let trackY = sepY + 4 + CGFloat(track.id) * audioRowHeight
            if localPoint.y >= trackY && localPoint.y <= trackY + audioRowHeight {
                for clip in track.clips {
                    let clipX = headerWidth + CGFloat(CMTimeGetSeconds(clip.timelineStart) * pixelsPerSecond)
                    let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                    if localPoint.x >= clipX && localPoint.x <= clipX + clipW {
                        if !track.isLocked {
                            if isShift {
                                if model.selectedClipIds.contains(clip.id) {
                                    model.selectedClipIds.remove(clip.id)
                                } else {
                                    model.selectedClipIds.insert(clip.id)
                                }
                            } else if !model.selectedClipIds.contains(clip.id) {
                                var newSelection: Set<UUID> = [clip.id]
                                if model.isLinkActive, let lId = clip.linkGroupId {
                                    for vTrack in model.videoTracks {
                                        if let vClip = vTrack.clips.first(where: { $0.linkGroupId == lId }) {
                                            newSelection.insert(vClip.id)
                                        }
                                    }
                                }
                                model.selectedClipIds = newSelection
                            }

                            if clip.isLocked {
                                DebugLogger.shared.log("Clip '\(clip.mediaItem.name)' bloccata (L per sbloccare).", level: .info)
                                needsDisplay = true
                                return
                            }

                            let edgeMargin: CGFloat = 8.0
                            if localPoint.x <= clipX + edgeMargin {
                                isTrimmingEdge = true
                                didTrimCurrentEdge = false
                                activeTrimClipId = clip.id
                                activeTrimIsStart = true
                                activeTrimIsVideo = false
                                dragInitialPoint = localPoint
                                needsDisplay = true
                                return
                            } else if localPoint.x >= clipX + clipW - edgeMargin {
                                isTrimmingEdge = true
                                didTrimCurrentEdge = false
                                activeTrimClipId = clip.id
                                activeTrimIsStart = false
                                activeTrimIsVideo = false
                                dragInitialPoint = localPoint
                                needsDisplay = true
                                return
                            }

                            draggedClipId = clip.id
                            draggedClipIsVideo = false
                            dragInitialPoint = localPoint
                            dragInitialStartTime = clip.timelineStart
                            dragInitialTrackIndex = track.id
                            currentDragTime = clip.timelineStart
                            currentDragTrackIndex = track.id

                            if model.isLinkActive, let lId = clip.linkGroupId {
                                for vTrack in model.videoTracks {
                                    if let vClip = vTrack.clips.first(where: { $0.linkGroupId == lId }) {
                                        linkedCompanionId = vClip.id
                                        linkedCompanionInitialStart = vClip.timelineStart
                                        linkedCompanionInitialTrack = vClip.trackIndex
                                        break
                                    }
                                }
                            } else {
                                linkedCompanionId = nil
                            }
                        } else {
                            DebugLogger.shared.log("Traccia A\(track.id + 1) bloccata 🔒. Spostamento clip disabilitato.", level: .info)
                        }

                        needsDisplay = true
                        return
                    }
                }
            }
        }

        // 5. Clicked on Empty Timeline Canvas: Start Marquee Rubber-Band Selection
        isMarqueeSelecting = true
        marqueeStartPoint = localPoint
        marqueeCurrentPoint = localPoint
        marqueeInitialSelectedIds = isShift ? model.selectedClipIds : []

        if !isShift {
            model.selectedClipIds.removeAll()
        }
        needsDisplay = true
    }

    public override func mouseDragged(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let sepY = separatorY

        if var mDrag = draggingMarker {
            var targetTimelineSec = max(0.0, Double(max(headerWidth, localPoint.x) - headerWidth) / pixelsPerSecond)
            if model.isSnappingActive {
                let phSec = CMTimeGetSeconds(playbackController.currentTime)
                if abs(targetTimelineSec - phSec) * pixelsPerSecond < 6.0 {
                    targetTimelineSec = phSec
                }
            }

            switch mDrag.kind {
            case .clipManual(let clipId, let isVideo, let oldSrc):
                let allClips = (isVideo ? model.videoTracks : model.audioTracks).flatMap(\.clips)
                if let clip = allClips.first(where: { $0.id == clipId }) {
                    let cStart = CMTimeGetSeconds(clip.timelineStart)
                    let spd = clip.speed > 0 ? clip.speed : 1.0
                    let rawNewSrc = CMTimeGetSeconds(clip.sourceIn) + (targetTimelineSec - cStart) * spd
                    if let updatedSrc = model.moveClipMarker(clipId: clipId, isBeatMarker: false, fromSourceSec: oldSrc, toSourceSec: rawNewSrc) {
                        let newTimelineSec = cStart + (updatedSrc - CMTimeGetSeconds(clip.sourceIn)) / spd
                        mDrag.kind = .clipManual(clipId: clipId, isVideo: isVideo, sourceSec: updatedSrc)
                        mDrag.timelineSec = newTimelineSec
                        draggingMarker = mDrag
                        selectedMarker = mDrag
                        hoveredMarker = mDrag
                        activeSnapLineTime = CMTime(seconds: newTimelineSec, preferredTimescale: 600)
                        didMoveDraggingMarker = true
                        needsDisplay = true
                    }
                }
            case .clipBeat(let clipId, let oldSrc):
                let allAudioClips = model.audioTracks.flatMap(\.clips)
                if let clip = allAudioClips.first(where: { $0.id == clipId }) {
                    let cStart = CMTimeGetSeconds(clip.timelineStart)
                    let spd = clip.speed > 0 ? clip.speed : 1.0
                    let rawNewSrc = CMTimeGetSeconds(clip.sourceIn) + (targetTimelineSec - cStart) * spd
                    if let updatedSrc = model.moveClipMarker(clipId: clipId, isBeatMarker: true, fromSourceSec: oldSrc, toSourceSec: rawNewSrc) {
                        let newTimelineSec = cStart + (updatedSrc - CMTimeGetSeconds(clip.sourceIn)) / spd
                        mDrag.kind = .clipBeat(clipId: clipId, sourceSec: updatedSrc)
                        mDrag.timelineSec = newTimelineSec
                        draggingMarker = mDrag
                        selectedMarker = mDrag
                        hoveredMarker = mDrag
                        activeSnapLineTime = CMTime(seconds: newTimelineSec, preferredTimescale: 600)
                        didMoveDraggingMarker = true
                        needsDisplay = true
                    }
                }
            case .timelineCageBar(let oldSec):
                if let updatedSec = model.moveTimelineCageBoundary(from: oldSec, to: targetTimelineSec) {
                    mDrag.kind = .timelineCageBar(seconds: updatedSec)
                    mDrag.timelineSec = updatedSec
                    draggingMarker = mDrag
                    selectedMarker = mDrag
                    hoveredMarker = mDrag
                    activeSnapLineTime = CMTime(seconds: updatedSec, preferredTimescale: 600)
                    didMoveDraggingMarker = true
                    needsDisplay = true
                }
            }
            return
        }

        if isTrimmingEdge, let clipId = activeTrimClipId {
            if model.isCageLockActive && activeTrimIsVideo && !model.activeCageBoundaries().isEmpty {
                let targetX = max(headerWidth, localPoint.x)
                let cursorSec = max(0, Double(targetX - headerWidth) / pixelsPerSecond)
                if let targetBoundary = model.nearestCageBoundary(to: cursorSec) {
                    var currentEdgeSec: Double?
                    for track in model.videoTracks {
                        if let c = track.clips.first(where: { $0.id == clipId }) {
                            let startSec = CMTimeGetSeconds(c.timelineStart)
                            currentEdgeSec = activeTrimIsStart ? startSec : (startSec + CMTimeGetSeconds(c.duration))
                            break
                        }
                    }
                    if let edgeSec = currentEdgeSec {
                        let deltaSec = targetBoundary - edgeSec
                        if abs(deltaSec) >= 0.001 {
                            let didTrim = model.trimClipEdge(
                                clipId: clipId,
                                isStart: activeTrimIsStart,
                                deltaSeconds: deltaSec,
                                isVideo: activeTrimIsVideo
                            )
                            if didTrim {
                                didTrimCurrentEdge = true
                                dragInitialPoint = localPoint
                                updateWidth()
                                needsDisplay = true
                            }
                        }
                    }
                }
            } else {
                let deltaX = localPoint.x - dragInitialPoint.x
                let deltaSec = Double(deltaX) / pixelsPerSecond
                if abs(deltaSec) >= 0.005 {
                    let didTrim = model.trimClipEdge(
                        clipId: clipId,
                        isStart: activeTrimIsStart,
                        deltaSeconds: deltaSec,
                        isVideo: activeTrimIsVideo
                    )
                    if didTrim {
                        didTrimCurrentEdge = true
                        dragInitialPoint = localPoint
                        updateWidth()
                        needsDisplay = true
                    }
                }
            }
            return
        }

        if isScrubbingRuler {
            let targetX = max(headerWidth, localPoint.x)
            let targetSeconds = max(0, Double(targetX - headerWidth) / pixelsPerSecond)
            let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
            playbackController.scrub(to: targetTime)
            if model.isSelectionFollowsPlayhead {
                model.updateSelectionAtPlayhead(time: targetTime)
            }
            needsDisplay = true
            return
        }

        if let clipId = draggedClipId {
            isDraggingClip = true
            let deltaX = localPoint.x - dragInitialPoint.x
            let deltaSeconds = Double(deltaX) / pixelsPerSecond
            let rawSeconds = max(0, CMTimeGetSeconds(dragInitialStartTime) + deltaSeconds)
            var newTime = CMTime(seconds: rawSeconds, preferredTimescale: 600)

            var clipDuration = CMTime(seconds: 1.0, preferredTimescale: 600)
            if draggedClipIsVideo {
                for track in model.videoTracks {
                    if let c = track.clips.first(where: { $0.id == clipId }) { clipDuration = c.duration; break }
                }
            } else {
                for track in model.audioTracks {
                    if let c = track.clips.first(where: { $0.id == clipId }) { clipDuration = c.duration; break }
                }
            }

            // Snapping / Cage Lock calculation
            if model.isCageLockActive && draggedClipIsVideo && !model.activeCageBoundaries().isEmpty {
                if let cage = model.nearestCageStart(to: rawSeconds) {
                    newTime = cage.startTime
                    activeSnapLineTime = newTime
                } else if let boundary = model.nearestCageBoundary(to: rawSeconds) {
                    newTime = CMTime(seconds: boundary, preferredTimescale: 600)
                    activeSnapLineTime = newTime
                }
            } else {
                let snapThreshold = 10.0 / pixelsPerSecond
                let snapRes = model.snap(startTime: newTime, duration: clipDuration, playhead: playbackController.currentTime, thresholdSeconds: snapThreshold)
                if snapRes.didSnap {
                    newTime = snapRes.snappedTime
                    activeSnapLineTime = snapRes.snapPoint
                } else {
                    activeSnapLineTime = nil
                }
            }

            // Target Track calculation
            var targetTrackIndex = dragInitialTrackIndex
            if draggedClipIsVideo {
                let trackFloat = (sepY - localPoint.y) / videoRowHeight
                let calculatedTrack = max(0, min(model.maxVideoTracks - 1, Int(trackFloat)))
                targetTrackIndex = calculatedTrack
                if targetTrackIndex >= model.videoTracks.count && targetTrackIndex < model.maxVideoTracks {
                    model.ensureVideoTrack(id: targetTrackIndex)
                }
            } else {
                let trackFloat = (localPoint.y - sepY - 4) / audioRowHeight
                let calculatedTrack = max(0, min(model.maxAudioTracks - 1, Int(trackFloat)))
                targetTrackIndex = calculatedTrack
                if targetTrackIndex >= model.audioTracks.count && targetTrackIndex < model.maxAudioTracks {
                    model.ensureAudioTrack(id: targetTrackIndex)
                }
            }

            if (draggedClipIsVideo && model.videoTracks[targetTrackIndex].isLocked) ||
               (!draggedClipIsVideo && model.audioTracks[targetTrackIndex].isLocked) {
                targetTrackIndex = dragInitialTrackIndex
            }

            currentDragTime = newTime
            currentDragTrackIndex = targetTrackIndex

            // Move the main clip in preview
            model.previewMoveClip(id: clipId, toTrack: targetTrackIndex, isVideo: draggedClipIsVideo, newStartTime: newTime)

            // If Link is ON, also move companion clip in preview
            if model.isLinkActive, let cId = linkedCompanionId {
                let effectiveDeltaSec = CMTimeGetSeconds(newTime) - CMTimeGetSeconds(dragInitialStartTime)
                let compStartSec = max(0, CMTimeGetSeconds(linkedCompanionInitialStart) + effectiveDeltaSec)
                let compTime = CMTime(seconds: compStartSec, preferredTimescale: 600)
                model.previewMoveClip(id: cId, toTrack: linkedCompanionInitialTrack, isVideo: !draggedClipIsVideo, newStartTime: compTime)
            }

            updateWidth()
            needsDisplay = true
        } else if isMarqueeSelecting {
            marqueeCurrentPoint = localPoint
            let rect = NSRect(
                x: min(marqueeStartPoint.x, marqueeCurrentPoint.x),
                y: min(marqueeStartPoint.y, marqueeCurrentPoint.y),
                width: abs(marqueeCurrentPoint.x - marqueeStartPoint.x),
                height: abs(marqueeCurrentPoint.y - marqueeStartPoint.y)
            )

            var newlySelected = marqueeInitialSelectedIds

            for track in model.videoTracks {
                let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
                for clip in track.clips {
                    let clipX = headerWidth + CGFloat(CMTimeGetSeconds(clip.timelineStart) * pixelsPerSecond)
                    let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                    let clipRect = NSRect(x: clipX, y: trackY + 2, width: clipW, height: videoRowHeight - 4)
                    if rect.intersects(clipRect) {
                        newlySelected.insert(clip.id)
                    }
                }
            }

            for track in model.audioTracks {
                let trackY = sepY + 4 + CGFloat(track.id) * audioRowHeight
                for clip in track.clips {
                    let clipX = headerWidth + CGFloat(CMTimeGetSeconds(clip.timelineStart) * pixelsPerSecond)
                    let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                    let clipRect = NSRect(x: clipX, y: trackY + 2, width: clipW, height: audioRowHeight - 4)
                    if rect.intersects(clipRect) {
                        newlySelected.insert(clip.id)
                    }
                }
            }

            model.selectedClipIds = newlySelected
            needsDisplay = true
        }
    }

    public override func mouseUp(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        activeSnapLineTime = nil

        if let mDrag = draggingMarker {
            draggingMarker = nil
            if didMoveDraggingMarker {
                didMoveDraggingMarker = false
                let title: String
                switch mDrag.kind {
                case .clipManual: title = "Sposta Marcatore"
                case .clipBeat: title = "Sposta Beat Marker"
                case .timelineCageBar: title = "Sposta Sbarra Ritmica"
                }
                notifyModified(title)
            }
            needsDisplay = true
            return
        }

        if isTrimmingEdge {
            isTrimmingEdge = false
            let trimmed = didTrimCurrentEdge
            didTrimCurrentEdge = false
            activeTrimClipId = nil
            updateWidth()
            if trimmed {
                notifyModified("Trim Bordo Clip")
            }
            needsDisplay = true
            return
        }

        if isScrubbingRuler {
            isScrubbingRuler = false
            playbackController.seek(to: playbackController.currentTime, frameAccurate: true)
            if model.isSelectionFollowsPlayhead {
                model.updateSelectionAtPlayhead(time: playbackController.currentTime)
            }
            needsDisplay = true
            return
        }

        if isDraggingClip, let clipId = draggedClipId {
            isDraggingClip = false
            let savedCompanionId = model.isLinkActive ? linkedCompanionId : nil
            draggedClipId = nil
            linkedCompanionId = nil

            model.commitMoveClip(
                id: clipId,
                toTrack: currentDragTrackIndex,
                isVideo: draggedClipIsVideo,
                newStartTime: currentDragTime,
                companionId: savedCompanionId
            )

            updateWidth()
            notifyModified("Sposta Clip in Timeline")
            needsDisplay = true
        } else if isMarqueeSelecting {
            let dx = abs(localPoint.x - marqueeStartPoint.x)
            let dy = abs(localPoint.y - marqueeStartPoint.y)

            if dx < 4 && dy < 4 {
                if !event.modifierFlags.contains(.shift) {
                    model.selectedClipIds.removeAll()
                }
                let targetX = max(headerWidth, localPoint.x)
                let targetSeconds = max(0, Double(targetX - headerWidth) / pixelsPerSecond)
                let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
                playbackController.seek(to: targetTime, frameAccurate: true)
                if model.isSelectionFollowsPlayhead {
                    model.updateSelectionAtPlayhead(time: targetTime)
                }
            }

            isMarqueeSelecting = false
            needsDisplay = true
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.option) || mods.contains(.command) {
            let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
            guard abs(delta) > 0.01 else { return }
            let scale = event.hasPreciseScrollingDeltas ? 0.008 : 0.06
            let factor = exp(Double(delta) * scale)
            let localPoint = convert(event.locationInWindow, from: nil)
            let anchorViewportX = localPoint.x - max(0, visibleRect.minX)
            onRequestZoom?(factor, anchorViewportX)
            return
        }

        // Convert vertical mouse wheel scrolling into smooth horizontal timeline scrolling
        if abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) && abs(event.scrollingDeltaX) < 0.5,
           let clipView = enclosingScrollView?.contentView {
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 14.0
            let maxX = max(0, frame.width - clipView.bounds.width)
            let targetX = max(0, min(maxX, clipView.bounds.origin.x - step))
            if abs(targetX - clipView.bounds.origin.x) > 0.01 {
                clipView.scroll(to: NSPoint(x: targetX, y: 0))
                enclosingScrollView?.reflectScrolledClipView(clipView)
            }
            return
        }

        super.scrollWheel(with: event)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        nil
    }

    public override func rightMouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        guard localPoint.y > rulerHeight else { return }

        var clickedClip: (clip: TimelineClip, isVideo: Bool)? = nil
        let sepY = separatorY
        let stickyHeaderRight = max(0, visibleRect.minX) + headerWidth

        if localPoint.x >= stickyHeaderRight {
            for track in model.videoTracks {
                let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
                if localPoint.y >= trackY && localPoint.y <= trackY + videoRowHeight {
                    for clip in track.clips {
                        let clipX = headerWidth + CGFloat(CMTimeGetSeconds(clip.timelineStart) * pixelsPerSecond)
                        let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                        if localPoint.x >= clipX && localPoint.x <= clipX + clipW {
                            clickedClip = (clip, true)
                            break
                        }
                    }
                }
            }
            if clickedClip == nil {
                for track in model.audioTracks {
                    let trackY = sepY + 4 + CGFloat(track.id) * audioRowHeight
                    if localPoint.y >= trackY && localPoint.y <= trackY + audioRowHeight {
                        for clip in track.clips {
                            let clipX = headerWidth + CGFloat(CMTimeGetSeconds(clip.timelineStart) * pixelsPerSecond)
                            let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                            if localPoint.x >= clipX && localPoint.x <= clipX + clipW {
                                clickedClip = (clip, false)
                                break
                            }
                        }
                    }
                }
            }
        }

        let markerHit = markerHitTest(at: localPoint)
        if let mHit = markerHit {
            selectedMarker = mHit
            needsDisplay = true
        }

        if let hit = clickedClip {
            let clip = hit.clip
            model.selectedClipId = clip.id
            needsDisplay = true

            let clickedTimelineSec = max(0.0, Double(localPoint.x - headerWidth) / pixelsPerSecond)
            var items: [VisionMenuItem] = [
                .header(clip.mediaItem.name)
            ]

            if let mHit = markerHit {
                let deleteTitle: String
                switch mHit.kind {
                case .clipBeat: deleteTitle = "Elimina questo Beat Marker"
                case .clipManual: deleteTitle = "Elimina questo marcatore"
                case .timelineCageBar: deleteTitle = "Elimina questa sbarra ritmica"
                }
                items.append(.action(
                    title: deleteTitle,
                    icon: .trash,
                    shortcut: "⌫",
                    isDestructive: true
                ) { [weak self] in
                    guard let self else { return }
                    self.selectedMarker = mHit
                    if self.deleteSelectedMarker() {
                        self.notifyModified("Elimina Marcatore")
                    }
                })
                items.append(.separator)
            }

            items.append(.action(
                title: clip.isLocked ? "Sblocca clip (proteggi da Auto-Fill)" : "Blocca clip (proteggi da Auto-Fill)",
                icon: clip.isLocked ? .unlock : .lock,
                iconColor: .systemOrange,
                shortcut: "L"
            ) { [weak self] in
                guard let self else { return }
                let res = self.model.toggleClipLock(clipId: clip.id)
                if res.toggledCount > 0 {
                    self.needsDisplay = true
                    self.notifyModified(res.isNowLocked ? "Blocca Clip (L)" : "Sblocca Clip (L)")
                }
            })
            items.append(.separator)

            let applyPriority: (Int?, String) -> Void = { [weak self] priority, label in
                guard let self else { return }
                if self.model.setClipPriority(clipId: clip.id, priority: priority).updatedCount > 0 {
                    self.needsDisplay = true
                    self.notifyModified(label)
                }
            }
            let priorityChildren: [VisionMenuItem] = [
                .action(
                    title: "1 — Hero (Priorità alta)",
                    icon: .flag,
                    iconColor: priorityColor(for: 1),
                    shortcut: "1",
                    isSelected: clip.priority == 1
                ) {
                    applyPriority(1, "Priorità Clip (Hero)")
                },
                .action(
                    title: "2 — Buona",
                    icon: .flag,
                    iconColor: priorityColor(for: 2),
                    shortcut: "2",
                    isSelected: clip.priority == 2
                ) {
                    applyPriority(2, "Priorità Clip (Buona)")
                },
                .action(
                    title: "3 — Secondaria / Filler",
                    icon: .flag,
                    iconColor: priorityColor(for: 3),
                    shortcut: "3",
                    isSelected: clip.priority == 3
                ) {
                    applyPriority(3, "Priorità Clip (Filler)")
                },
                .separator,
                .action(
                    title: "Rimuovi priorità",
                    shortcut: "0",
                    isSelected: clip.priority == nil
                ) {
                    applyPriority(nil, "Rimuovi Priorità Clip")
                }
            ]
            items.append(.submenu(title: "Priorità clip", icon: .flag, iconColor: clip.priority.flatMap { priorityColor(for: $0) }, items: priorityChildren))
            items.append(.separator)

            items.append(.action(title: "Aggiungi / Rimuovi marcatore qui", icon: .bookmark, iconColor: .systemOrange, shortcut: "M") { [weak self] in
                if self?.model.toggleMarker(clipId: clip.id, at: clickedTimelineSec) == true {
                    self?.needsDisplay = true
                    self?.notifyModified("Marcatore Clip")
                }
            })

            if !clip.markers.isEmpty {
                items.append(.action(title: "Copia timestamp marcatori (\(clip.markers.count))", icon: .copy) { [weak self] in
                    self?.copyClipMarkers(clipId: clip.id)
                })
                items.append(.action(title: "Pulisci marcatori clip (\(clip.markers.count))", icon: .trash, shortcut: "⌥M", isDestructive: true) { [weak self] in
                    if self?.model.clearMarkers(clipId: clip.id) == true {
                        self?.needsDisplay = true
                        self?.notifyModified("Rimuovi Marcatori Clip")
                        DebugLogger.shared.log("Marcatori rimossi dalla clip.", level: .info)
                    }
                })
            }

            if hit.isVideo {
                items.append(.separator)
                let orientChildren: [VisionMenuItem] = ClipOrientation.allCases.map { orient in
                    .action(title: orient.rawValue, isSelected: clip.orientation == orient) { [weak self] in
                        self?.model.setClipOrientation(id: clip.id, orientation: orient)
                        DebugLogger.shared.log("Orientamento clip aggiornato a: \(orient.rawValue)", level: .info)
                        self?.needsDisplay = true
                        self?.notifyModified("Orientamento Clip")
                    }
                }
                items.append(.submenu(title: "Orientamento clip", icon: .rotateCw, items: orientChildren))
            }

            VisionMenu(items: items).show(for: event, in: self)
            return
        }

        // Context menu for track header / empty track area (and static cage bars)
        let hasUnusedVideo = model.videoTracks.contains { $0.id > 0 && $0.clips.isEmpty }
        let hasUnusedAudio = model.audioTracks.contains { $0.id > 0 && $0.clips.isEmpty }
        var trackItems: [VisionMenuItem] = []
        if let mHit = markerHit {
            let deleteTitle: String
            switch mHit.kind {
            case .clipBeat: deleteTitle = "Elimina questo Beat Marker"
            case .clipManual: deleteTitle = "Elimina questo marcatore"
            case .timelineCageBar: deleteTitle = "Elimina questa sbarra ritmica"
            }
            trackItems.append(.action(title: deleteTitle, icon: .trash, shortcut: "⌫", isDestructive: true) { [weak self] in
                guard let self else { return }
                self.selectedMarker = mHit
                if self.deleteSelectedMarker() {
                    self.notifyModified("Elimina Sbarra Ritmica")
                }
            })
            trackItems.append(.separator)
        }
        trackItems.append(contentsOf: [
            .action(
                title: "Aggiungi traccia Video",
                icon: .plus,
                iconColor: .systemCyan,
                isEnabled: model.videoTracks.count < model.maxVideoTracks
            ) { [weak self] in
                self?.addVideoTrackFromContext()
            },
            .action(
                title: "Aggiungi traccia Audio",
                icon: .plus,
                iconColor: .systemGreen,
                isEnabled: model.audioTracks.count < model.maxAudioTracks
            ) { [weak self] in
                self?.addAudioTrackFromContext()
            },
            .separator,
            .action(
                title: "Pulisci tracce non usate",
                icon: .trash,
                isEnabled: hasUnusedVideo || hasUnusedAudio
            ) { [weak self] in
                self?.cleanUnusedTracksFromContext()
            },
            .separator,
            .action(
                title: "Esporta Final Cut XML (.fcpxmld)...",
                icon: .fileCode2,
                iconColor: .systemCyan
            ) { [weak self] in
                self?.onExportTimelineRequested?()
            }
        ])
        VisionMenu(items: trackItems).show(for: event, in: self)
    }

    private func notifyModified(_ title: String) {
        if let onAction = onTimelineAction {
            onAction(title)
        } else {
            onTimelineModified?()
        }
    }

    private func addVideoTrackFromContext() {
        guard model.videoTracks.count < model.maxVideoTracks else { return }
        model.ensureVideoTrack(id: model.videoTracks.count)
        DebugLogger.shared.log("Aggiunta traccia video V\(model.videoTracks.count)", level: .info)
        updateWidth()
        needsDisplay = true
        notifyModified("Aggiungi Traccia Video")
    }

    private func addAudioTrackFromContext() {
        guard model.audioTracks.count < model.maxAudioTracks else { return }
        model.ensureAudioTrack(id: model.audioTracks.count)
        DebugLogger.shared.log("Aggiunta traccia audio A\(model.audioTracks.count)", level: .info)
        updateWidth()
        needsDisplay = true
        notifyModified("Aggiungi Traccia Audio")
    }

    private func cleanUnusedTracksFromContext() {
        model.cleanEmptyTracks()
        updateWidth()
        needsDisplay = true
        notifyModified("Pulisci Tracce Vuote")
    }

    private func copyClipMarkers(clipId: UUID) {
        let allClips = model.videoTracks.flatMap(\.clips) + model.audioTracks.flatMap(\.clips)
        guard let clip = allClips.first(where: { $0.id == clipId }) else { return }
        let formatted = clip.visibleMarkersTimelineTimes().sorted().map { sec -> String in
            let m = Int(sec) / 60
            let s = sec - Double(m * 60)
            return String(format: "%d:%05.2f", m, s)
        }.joined(separator: ", ")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(formatted, forType: .string)
        DebugLogger.shared.log("Timestamp marcatori copiati (\(clip.markers.count)): \(formatted)", level: .info)
    }

    // MARK: - Tracking Areas & Tooltip Support
    public override func updateTrackingAreas() {
        if let ta = trackingArea {
            removeTrackingArea(ta)
        }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        self.trackingArea = ta

        super.updateTrackingAreas()
        removeAllToolTips()
        let sepY = separatorY
        for track in model.videoTracks {
            let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
            for clip in track.clips where clip.isOrphan {
                let x = headerWidth + CGFloat(CMTimeGetSeconds(clip.timelineStart) * pixelsPerSecond)
                let w = max(3.0, CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond))
                addToolTip(NSRect(x: x, y: trackY + 2, width: w, height: videoRowHeight - 4), owner: self, userData: nil)
            }
        }
        for track in model.audioTracks {
            let trackY = sepY + 4 + CGFloat(track.id) * audioRowHeight
            for clip in track.clips where clip.isOrphan {
                let x = headerWidth + CGFloat(CMTimeGetSeconds(clip.timelineStart) * pixelsPerSecond)
                let w = max(3.0, CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond))
                addToolTip(NSRect(x: x, y: trackY + 2, width: w, height: audioRowHeight - 4), owner: self, userData: nil)
            }
        }
    }

    public func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        return "Media offline"
    }

    // MARK: - NSDraggingDestination (Multi-Clip Drag from Media Pool / Finder)
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let extracted = extractDraggedContent(from: sender)
        currentDraggingItems = extracted.items
        currentDraggingExternalURLs = extracted.externalURLs
        let hasSelection = sender.draggingPasteboard.types?.contains(kSelectionPasteboardType) == true
        guard !currentDraggingItems.isEmpty || !currentDraggingExternalURLs.isEmpty || hasSelection else { return [] }
        updateDropPreview(with: sender)
        needsDisplay = true
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let hasSelection = sender.draggingPasteboard.types?.contains(kSelectionPasteboardType) == true
        guard !currentDraggingItems.isEmpty || !currentDraggingExternalURLs.isEmpty || hasSelection else { return [] }
        updateDropPreview(with: sender)
        needsDisplay = true
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        dropPreviewTime = nil
        currentDraggingItems = []
        currentDraggingExternalURLs = []
        activeSnapLineTime = nil
        needsDisplay = true
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard

        // Verifica se è stata trascinata un'intera Selezione dal Media Pool
        if let selStr = pboard.string(forType: kSelectionPasteboardType),
           let selId = UUID(uuidString: selStr),
           let sel = EditorProject.shared.selectionTimelines.first(where: { $0.id == selId }),
           let dropTime = dropPreviewTime {
            var currentT = dropTime
            let clipsToInsert = sel.videoTracks.first?.clips ?? []
            for sClip in clipsToInsert {
                let linkId = UUID()
                var vClip = TimelineClip(
                    mediaItem: sClip.mediaItem,
                    sourceIn: sClip.sourceIn,
                    sourceOut: sClip.sourceOut,
                    timelineStart: currentT,
                    trackIndex: 0,
                    mediaType: .video,
                    orientation: sClip.orientation,
                    linkGroupId: linkId
                )
                vClip.markers = sClip.markers
                vClip.priority = sClip.priority
                model.videoTracks[0].clips.append(vClip)
                if sClip.mediaItem.hasAudio {
                    var aClip = TimelineClip(
                        mediaItem: sClip.mediaItem,
                        sourceIn: sClip.sourceIn,
                        sourceOut: sClip.sourceOut,
                        timelineStart: currentT,
                        trackIndex: 0,
                        mediaType: .audio,
                        orientation: .normal,
                        linkGroupId: linkId
                    )
                    aClip.markers = sClip.markers
                    aClip.priority = sClip.priority
                    model.audioTracks[0].clips.append(aClip)
                }
                currentT = CMTimeAdd(currentT, sClip.duration)
            }
            dropPreviewTime = nil
            currentDraggingItems = []
            currentDraggingExternalURLs = []
            activeSnapLineTime = nil
            updateWidth()
            notifyModified("Inserisci Selezione in Timeline")
            needsDisplay = true
            DebugLogger.shared.log("Selezione '\(sel.name)' (\(clipsToInsert.count) clip) inserita sulla timeline.", level: .info)
            return true
        }

        let extracted = extractDraggedContent(from: sender)
        let items = extracted.items
        let externalURLs = extracted.externalURLs
        guard (!items.isEmpty || !externalURLs.isEmpty), let dropTime = dropPreviewTime else {
            dropPreviewTime = nil
            currentDraggingItems = []
            currentDraggingExternalURLs = []
            needsDisplay = true
            return false
        }

        let isVideo = dropPreviewIsVideo
        let targetTrack = dropPreviewTrackIndex

        if !items.isEmpty {
            var currentT = dropTime
            for item in items {
                model.insertClip(
                    mediaItem: item,
                    atTime: currentT,
                    targetTrackIndex: targetTrack,
                    isTargetVideo: isVideo
                )
                currentT = CMTimeAdd(currentT, item.duration)
            }
            updateWidth()
            notifyModified("Trascina Clip in Timeline")
        }

        if !externalURLs.isEmpty {
            onImportDroppedURLsToTimeline?(externalURLs, dropTime, targetTrack, isVideo)
        }

        dropPreviewTime = nil
        currentDraggingItems = []
        currentDraggingExternalURLs = []
        activeSnapLineTime = nil
        needsDisplay = true
        return true
    }

    private func updateDropPreview(with sender: NSDraggingInfo) {
        let localPoint = convert(sender.draggingLocation, from: nil)
        let sepY = separatorY

        var isVideo = localPoint.y < sepY
        let allItemsAudioOnly = !currentDraggingItems.isEmpty && currentDraggingItems.allSatisfy { !$0.hasVideo && $0.hasAudio }
        let allURLsAudioOnly = currentDraggingItems.isEmpty && !currentDraggingExternalURLs.isEmpty && currentDraggingExternalURLs.allSatisfy { MediaPoolViewController.isAudioOnlyURL($0) }
        let forceAudioTarget = allItemsAudioOnly || allURLsAudioOnly
        let allItemsVideoOnly = !currentDraggingItems.isEmpty && currentDraggingItems.allSatisfy { $0.hasVideo && !$0.hasAudio }

        if forceAudioTarget {
            isVideo = false
        } else if allItemsVideoOnly {
            isVideo = true
        }
        dropPreviewIsVideo = isVideo

        let rawTargetTrack: Int
        if isVideo {
            if localPoint.y < sepY {
                let trackFloat = (sepY - localPoint.y) / videoRowHeight
                rawTargetTrack = max(0, min(model.maxVideoTracks - 1, Int(trackFloat)))
            } else {
                rawTargetTrack = 0
            }
            if rawTargetTrack >= model.videoTracks.count && rawTargetTrack < model.maxVideoTracks {
                model.ensureVideoTrack(id: rawTargetTrack)
            }
        } else {
            if localPoint.y >= sepY {
                let trackFloat = (localPoint.y - sepY - 4) / audioRowHeight
                rawTargetTrack = max(0, min(model.maxAudioTracks - 1, Int(trackFloat)))
            } else {
                rawTargetTrack = 0
            }
            if rawTargetTrack >= model.audioTracks.count && rawTargetTrack < model.maxAudioTracks {
                model.ensureAudioTrack(id: rawTargetTrack)
            }
        }
        dropPreviewTrackIndex = rawTargetTrack

        let targetX = max(headerWidth, localPoint.x)
        let rawSeconds = max(0, Double(targetX - headerWidth) / pixelsPerSecond)
        var proposedTime = CMTime(seconds: rawSeconds, preferredTimescale: 600)

        if model.isCageLockActive && dropPreviewIsVideo && !model.activeCageBoundaries().isEmpty {
            if let cage = model.nearestCageStart(to: rawSeconds) {
                proposedTime = cage.startTime
                activeSnapLineTime = proposedTime
            } else if let boundary = model.nearestCageBoundary(to: rawSeconds) {
                proposedTime = CMTime(seconds: boundary, preferredTimescale: 600)
                activeSnapLineTime = proposedTime
            }
        } else if model.isSnappingActive {
            let totalDur = currentDraggingItems.reduce(CMTime.zero) { CMTimeAdd($0, $1.duration) }
            let snapThreshold = 10.0 / pixelsPerSecond
            let snapRes = model.snap(startTime: proposedTime, duration: totalDur, playhead: playbackController.currentTime, thresholdSeconds: snapThreshold)
            if snapRes.didSnap {
                proposedTime = snapRes.snappedTime
                activeSnapLineTime = snapRes.snapPoint
            } else {
                activeSnapLineTime = !currentDraggingExternalURLs.isEmpty ? proposedTime : nil
            }
        } else {
            activeSnapLineTime = !currentDraggingExternalURLs.isEmpty ? proposedTime : nil
        }

        dropPreviewTime = proposedTime
    }

    private func extractDraggedContent(from sender: NSDraggingInfo) -> (items: [MediaItem], externalURLs: [URL]) {
        var resolvedItems: [MediaItem] = []
        var externalURLs: [URL] = []
        var seenExternalPaths: Set<String> = []
        let pboard = sender.draggingPasteboard

        if let pbItems = pboard.pasteboardItems {
            for pbItem in pbItems {
                let idStr = pbItem.string(forType: kMediaItemPasteboardType)
                let uuid = idStr != nil ? UUID(uuidString: idStr!) : nil
                var fileURL: URL? = nil
                if let urlOrPath = pbItem.string(forType: .fileURL) ?? pbItem.string(forType: .URL) {
                    fileURL = urlOrPath.hasPrefix("file://") ? URL(string: urlOrPath) : URL(fileURLWithPath: urlOrPath)
                } else if let pathStr = pbItem.string(forType: .string), pathStr.hasPrefix("/") {
                    fileURL = URL(fileURLWithPath: pathStr)
                }
                if let mediaItem = onResolveMediaItem?(uuid, fileURL) {
                    if !resolvedItems.contains(where: { $0.id == mediaItem.id }) {
                        resolvedItems.append(mediaItem)
                    }
                } else if let u = fileURL, MediaPoolViewController.isSupportedMediaURL(u) {
                    let std = u.standardizedFileURL.path
                    if seenExternalPaths.insert(std).inserted {
                        externalURLs.append(u)
                    }
                }
            }
        }

        let pboardURLs = MediaPoolViewController.extractFileURLs(from: pboard)
        for u in pboardURLs {
            if let mediaItem = onResolveMediaItem?(nil, u) {
                if !resolvedItems.contains(where: { $0.id == mediaItem.id }) {
                    resolvedItems.append(mediaItem)
                }
            } else if MediaPoolViewController.isSupportedMediaURL(u) {
                let std = u.standardizedFileURL.path
                if seenExternalPaths.insert(std).inserted {
                    externalURLs.append(u)
                }
            }
        }
        return (resolvedItems, externalURLs)
    }
}

public final class TimelineViewController: NSViewController {
    public var model: TimelineModel
    public let playbackController: PlaybackController
    public var onTimelineModified: (() -> Void)?
    public var onTimelineAction: ((String) -> Void)?
    public var onFormatChangedCallback: ((TimelineFormat) -> Void)?
    public var onResolveMediaItem: ((UUID?, URL?) -> MediaItem?)?
    public var onSectionActivated: (() -> Void)?
    public var onSwitchTimeline: ((TimelineModel) -> Void)?
    public var onExportFCPXML: (() -> Void)?
    public var onImportDroppedURLsToTimeline: ((_ urls: [URL], _ atTime: CMTime, _ targetTrackIndex: Int, _ isTargetVideo: Bool) -> Void)?

    private var canvasView: TimelineCanvasView!
    private let scrollView = NSScrollView()
    private let timelineIndicatorBtn = FlatButton()
    private let timecodeLabel = NSTextField(labelWithString: "00:00:00:00")

    // Pro NLE Toolbar Controls
    private let linkButton = IconActionButton(toolTip: "Link A/V (⌘L / ⌥L)")
    private let magnetButton = IconActionButton(toolTip: "Magnet / Snapping (N)")
    private let selectionFollowsPlayheadButton = IconActionButton(toolTip: "Seleziona clip sotto la testina (⌥P)")
    private let cageLockButton = IconActionButton(toolTip: "Blocco Gabbia (Selezionato: aggancia alle sbarre • Deselezionato: montaggio libero)")
    private let rhythmicStudioButton = IconActionButton(toolTip: "Montaggio Ritmico (Beat, Gabbie & Auto-Fill)", isToggleMode: false)
    private let exportXMLButton = IconActionButton(toolTip: "Esporta Final Cut XML (.fcpxmld) (⌘E)", isToggleMode: false)
    private let zoomSlider = NSSlider()
    private let keyboardButton = IconActionButton(toolTip: "Scorciatoie da tastiera", isToggleMode: false)

    public init(model: TimelineModel, playbackController: PlaybackController) {
        self.model = model
        self.playbackController = playbackController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(calibratedWhite: 0.08, alpha: 1.0).cgColor

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor
        root.addSubview(toolbar)

        setupToolbar(toolbar)

        canvasView = TimelineCanvasView(model: model, playbackController: playbackController)
        canvasView.translatesAutoresizingMaskIntoConstraints = true
        canvasView.autoresizingMask = [.height]
        canvasView.onTimelineModified = { [weak self] in
            self?.onTimelineModified?()
        }
        canvasView.onTimelineAction = { [weak self] title in
            if let onAction = self?.onTimelineAction {
                onAction(title)
            } else {
                self?.onTimelineModified?()
            }
        }
        canvasView.onResolveMediaItem = { [weak self] id, url in
            self?.onResolveMediaItem?(id, url)
        }
        canvasView.onSectionActivated = { [weak self] in
            self?.onSectionActivated?()
        }
        canvasView.onExportTimelineRequested = { [weak self] in
            self?.onExportFCPXML?()
        }
        canvasView.onImportDroppedURLsToTimeline = { [weak self] urls, atTime, trackIdx, isVideo in
            self?.onImportDroppedURLsToTimeline?(urls, atTime, trackIdx, isVideo)
        }
        canvasView.onCanvasWidthChanged = { [weak self] in
            self?.syncCanvasFrame()
        }
        canvasView.onRequestZoom = { [weak self] factor, viewportAnchorX in
            self?.zoomByFactor(factor, anchorViewportX: viewportAnchorX)
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = canvasView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1.0)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onScrollViewBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        root.addSubview(scrollView)

        // Pinned top-left timecode badge inside the track headers area (104x26 above V1, left of ruler)
        let timecodeHeaderView = NSView()
        timecodeHeaderView.translatesAutoresizingMaskIntoConstraints = false
        timecodeHeaderView.wantsLayer = true
        timecodeHeaderView.layer?.backgroundColor = NSColor(calibratedWhite: 0.095, alpha: 1.0).cgColor

        let tcRightBorder = NSView()
        tcRightBorder.translatesAutoresizingMaskIntoConstraints = false
        tcRightBorder.wantsLayer = true
        tcRightBorder.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
        timecodeHeaderView.addSubview(tcRightBorder)

        let tcBottomBorder = NSView()
        tcBottomBorder.translatesAutoresizingMaskIntoConstraints = false
        tcBottomBorder.wantsLayer = true
        tcBottomBorder.layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor
        timecodeHeaderView.addSubview(tcBottomBorder)

        timecodeLabel.translatesAutoresizingMaskIntoConstraints = false
        timecodeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
        timecodeLabel.textColor = .systemCyan
        timecodeLabel.alignment = .center
        timecodeHeaderView.addSubview(timecodeLabel)
        root.addSubview(timecodeHeaderView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 42),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            timecodeHeaderView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            timecodeHeaderView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            timecodeHeaderView.widthAnchor.constraint(equalToConstant: 104),
            timecodeHeaderView.heightAnchor.constraint(equalToConstant: 26),

            tcRightBorder.topAnchor.constraint(equalTo: timecodeHeaderView.topAnchor),
            tcRightBorder.bottomAnchor.constraint(equalTo: timecodeHeaderView.bottomAnchor),
            tcRightBorder.trailingAnchor.constraint(equalTo: timecodeHeaderView.trailingAnchor),
            tcRightBorder.widthAnchor.constraint(equalToConstant: 1),

            tcBottomBorder.leadingAnchor.constraint(equalTo: timecodeHeaderView.leadingAnchor),
            tcBottomBorder.trailingAnchor.constraint(equalTo: timecodeHeaderView.trailingAnchor),
            tcBottomBorder.bottomAnchor.constraint(equalTo: timecodeHeaderView.bottomAnchor),
            tcBottomBorder.heightAnchor.constraint(equalToConstant: 1),

            timecodeLabel.centerXAnchor.constraint(equalTo: timecodeHeaderView.centerXAnchor),
            timecodeLabel.centerYAnchor.constraint(equalTo: timecodeHeaderView.centerYAnchor)
        ])

        playbackController.addTimeObserver(self) { [weak self] time in
            guard let self = self else { return }
            if self.model.isSelectionFollowsPlayhead {
                let prevSelected = self.model.selectedClipIds
                self.model.updateSelectionAtPlayhead(time: time)
                if self.model.selectedClipIds != prevSelected {
                    self.canvasView.needsDisplay = true
                }
            }
            if self.playbackController.isPlaying {
                self.autoScrollToKeepPlayheadVisible(at: time)
            }
            self.canvasView.updatePlayheadLayer()
            self.timecodeLabel.stringValue = self.playbackController.formattedCurrentTime
        }

        self.view = root
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        syncCanvasFrame()
    }

    @objc private func onScrollViewBoundsChanged(_ note: Notification) {
        canvasView.updatePlayheadLayer()
        canvasView.needsDisplay = true
    }

    private func syncCanvasFrame() {
        let clipSize = scrollView.contentView.bounds.size
        guard clipSize.width > 0 else { return }
        let targetW = max(clipSize.width, canvasView.calculatedTotalWidth)
        let targetH = max(180, clipSize.height)
        if abs(canvasView.frame.width - targetW) > 0.5 || abs(canvasView.frame.height - targetH) > 0.5 || canvasView.frame.origin != .zero {
            canvasView.frame = NSRect(x: 0, y: 0, width: targetW, height: targetH)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            canvasView.needsDisplay = true
        }
    }

    private func autoScrollToKeepPlayheadVisible(at time: CMTime) {
        let clipView = scrollView.contentView
        let clipBounds = clipView.bounds
        let headerW = canvasView.headerWidth
        let tracksVisibleW = max(80.0, clipBounds.width - headerW)

        let sec = max(0.0, CMTimeGetSeconds(time))
        let playheadX = headerW + CGFloat(sec * canvasView.pixelsPerSecond)
        let maxOriginX = max(0.0, canvasView.frame.width - clipBounds.width)
        guard maxOriginX > 0 else { return }

        let edgeMargin = min(90.0, max(24.0, tracksVisibleW * 0.16))
        if playheadX > clipBounds.maxX - edgeMargin {
            let targetOriginX = min(maxOriginX, max(0.0, playheadX - (clipBounds.width - edgeMargin)))
            if abs(targetOriginX - clipBounds.origin.x) > 0.5 {
                clipView.scroll(to: NSPoint(x: targetOriginX, y: 0))
                scrollView.reflectScrolledClipView(clipView)
            }
        } else if playheadX < clipBounds.minX + headerW {
            let targetOriginX = max(0.0, playheadX - headerW - 36.0)
            if abs(targetOriginX - clipBounds.origin.x) > 0.5 {
                clipView.scroll(to: NSPoint(x: targetOriginX, y: 0))
                scrollView.reflectScrolledClipView(clipView)
            }
        }
    }

    private func setupToolbar(_ toolbar: NSView) {
        let toolbarScroll = NSScrollView()
        toolbarScroll.translatesAutoresizingMaskIntoConstraints = false
        toolbarScroll.drawsBackground = false
        toolbarScroll.borderType = .noBorder
        toolbarScroll.hasHorizontalScroller = true
        toolbarScroll.hasVerticalScroller = false
        toolbarScroll.autohidesScrollers = true
        toolbarScroll.scrollerStyle = .overlay
        toolbarScroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let docView = NSView()
        docView.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        docView.addSubview(stack)
        toolbarScroll.documentView = docView
        toolbar.addSubview(toolbarScroll)

        keyboardButton.translatesAutoresizingMaskIntoConstraints = false
        keyboardButton.image = Lucide.template(.keyboard, size: 17)
        keyboardButton.activeTintColor = .white
        keyboardButton.target = self
        keyboardButton.action = #selector(onKeyboardShortcutsClicked)
        toolbar.addSubview(keyboardButton)

        NSLayoutConstraint.activate([
            toolbarScroll.topAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbarScroll.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor),
            toolbarScroll.trailingAnchor.constraint(equalTo: keyboardButton.leadingAnchor, constant: -8),
            toolbarScroll.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),

            keyboardButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            keyboardButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            keyboardButton.widthAnchor.constraint(equalToConstant: 26),
            keyboardButton.heightAnchor.constraint(equalToConstant: 24),

            docView.topAnchor.constraint(equalTo: toolbarScroll.contentView.topAnchor),
            docView.bottomAnchor.constraint(equalTo: toolbarScroll.contentView.bottomAnchor),
            docView.leadingAnchor.constraint(equalTo: toolbarScroll.contentView.leadingAnchor),
            docView.heightAnchor.constraint(equalTo: toolbarScroll.contentView.heightAnchor),

            stack.leadingAnchor.constraint(equalTo: docView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: docView.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: docView.centerYAnchor)
        ])

        // Timeline selector: text only, no icon, no box
        timelineIndicatorBtn.isBoxless = true
        timelineIndicatorBtn.image = nil
        timelineIndicatorBtn.imagePosition = .noImage
        timelineIndicatorBtn.title = model.name
        timelineIndicatorBtn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        timelineIndicatorBtn.toolTip = "Timeline attiva (Clicca per cambiare)"
        timelineIndicatorBtn.target = self
        timelineIndicatorBtn.action = #selector(onTimelineIndicatorClicked)
        timelineIndicatorBtn.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(timelineIndicatorBtn)

        // Boxless icon toggles: Link, Magnet, Under-playhead
        linkButton.image = Lucide.template(.link, size: 16)
        linkButton.activeTintColor = .systemCyan
        linkButton.target = self
        linkButton.action = #selector(onLinkToggleClicked)
        linkButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        linkButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        updateLinkButtonTitle()
        stack.addArrangedSubview(linkButton)

        magnetButton.image = Lucide.template(.magnet, size: 16)
        magnetButton.activeTintColor = .systemCyan
        magnetButton.target = self
        magnetButton.action = #selector(onMagnetToggleClicked)
        magnetButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        magnetButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        updateMagnetButtonTitle()
        stack.addArrangedSubview(magnetButton)

        selectionFollowsPlayheadButton.image = Lucide.template(.textCursor, size: 16)
        selectionFollowsPlayheadButton.activeTintColor = .systemCyan
        selectionFollowsPlayheadButton.target = self
        selectionFollowsPlayheadButton.action = #selector(onSelectionFollowsPlayheadClicked)
        selectionFollowsPlayheadButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        selectionFollowsPlayheadButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        updateSelectionFollowsPlayheadButtonTitle()
        stack.addArrangedSubview(selectionFollowsPlayheadButton)

        cageLockButton.image = Lucide.template(.tally3, size: 16)
        cageLockButton.activeTintColor = .systemCyan
        cageLockButton.target = self
        cageLockButton.action = #selector(onCageLockToggleClicked)
        cageLockButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        cageLockButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        updateCageLockButtonTitle()
        stack.addArrangedSubview(cageLockButton)

        let rhythmDivider = NSBox()
        rhythmDivider.boxType = .separator
        rhythmDivider.translatesAutoresizingMaskIntoConstraints = false
        rhythmDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        rhythmDivider.heightAnchor.constraint(equalToConstant: 18).isActive = true
        stack.addArrangedSubview(rhythmDivider)

        rhythmicStudioButton.image = Lucide.template(.wandSparkles, size: 16)
        rhythmicStudioButton.target = self
        rhythmicStudioButton.action = #selector(onRhythmicStudioClicked)
        rhythmicStudioButton.widthAnchor.constraint(equalToConstant: 28).isActive = true
        rhythmicStudioButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        stack.addArrangedSubview(rhythmicStudioButton)

        exportXMLButton.image = Lucide.template(.fileCode2, size: 16)
        exportXMLButton.target = self
        exportXMLButton.action = #selector(onExportXMLClicked)
        exportXMLButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        exportXMLButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        stack.addArrangedSubview(exportXMLButton)

        let rhythmDivider2 = NSBox()
        rhythmDivider2.boxType = .separator
        rhythmDivider2.translatesAutoresizingMaskIntoConstraints = false
        rhythmDivider2.widthAnchor.constraint(equalToConstant: 1).isActive = true
        rhythmDivider2.heightAnchor.constraint(equalToConstant: 18).isActive = true
        stack.addArrangedSubview(rhythmDivider2)

        zoomSlider.minValue = 10.0
        zoomSlider.maxValue = 150.0
        zoomSlider.doubleValue = 40.0
        zoomSlider.isContinuous = true
        zoomSlider.target = self
        zoomSlider.action = #selector(onZoomChanged)
        zoomSlider.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let zoomIconView = NSImageView()
        zoomIconView.translatesAutoresizingMaskIntoConstraints = false
        zoomIconView.image = Lucide.template(.zoomIn, size: 15)
        zoomIconView.contentTintColor = .secondaryLabelColor
        zoomIconView.toolTip = "Zoom Timeline"
        zoomIconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        zoomIconView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        stack.addArrangedSubview(zoomIconView)
        stack.addArrangedSubview(zoomSlider)

        for view in stack.arrangedSubviews {
            if let ctrl = view as? NSControl, !(ctrl is IconActionButton) {
                ctrl.controlSize = .small
                if ctrl !== timelineIndicatorBtn {
                    ctrl.font = NSFont.systemFont(ofSize: 11, weight: .medium)
                }
            }
        }
    }

    private func updateLinkButtonTitle() {
        linkButton.isToggleActive = model.isLinkActive
    }

    private func updateMagnetButtonTitle() {
        magnetButton.isToggleActive = model.isSnappingActive
    }

    private func updateSelectionFollowsPlayheadButtonTitle() {
        selectionFollowsPlayheadButton.isToggleActive = model.isSelectionFollowsPlayhead
    }

    private func updateCageLockButtonTitle() {
        cageLockButton.isToggleActive = model.isCageLockActive
    }

    public func reloadTimelineUI() {
        timelineIndicatorBtn.title = model.name
        updateLinkButtonTitle()
        updateMagnetButtonTitle()
        updateSelectionFollowsPlayheadButtonTitle()
        updateCageLockButtonTitle()
        canvasView.updateWidth()
        canvasView.needsDisplay = true
    }

    public func switchModel(_ newModel: TimelineModel) {
        self.model = newModel
        self.canvasView.model = newModel
        timelineIndicatorBtn.title = newModel.name
        reloadTimelineUI()
    }

    public func deleteSelectedMarker() -> Bool {
        canvasView.deleteSelectedMarker()
    }

    @objc private func onTimelineIndicatorClicked() {
        let menuItems: [VisionMenuItem] = EditorProject.shared.timelines.enumerated().map { idx, tl in
            .action(
                title: tl.isSelection ? "\(tl.name) (Selezione)" : tl.name,
                icon: tl.isSelection ? .sparkles : .clapperboard,
                iconColor: tl.isSelection ? .systemPurple : .systemCyan,
                isSelected: tl.id == model.id
            ) { [weak self] in
                guard idx < EditorProject.shared.timelines.count else { return }
                EditorProject.shared.activeTimelineIndex = idx
                let targetTL = EditorProject.shared.timelines[idx]
                self?.onSwitchTimeline?(targetTL)
            }
        }
        VisionMenu(items: menuItems).show(below: timelineIndicatorBtn)
    }

    @objc public func onSelectionFollowsPlayheadClicked() {
        model.isSelectionFollowsPlayhead.toggle()
        updateSelectionFollowsPlayheadButtonTitle()
        if model.isSelectionFollowsPlayhead {
            model.updateSelectionAtPlayhead(time: playbackController.currentTime)
        }
        canvasView.needsDisplay = true
        DebugLogger.shared.log("Selezione sotto testina (Resolve style): \(model.isSelectionFollowsPlayhead ? "ATTIVA" : "DISATTIVATA")", level: .info)
    }

    @objc public func onLinkToggleClicked() {
        model.isLinkActive.toggle()
        if model.isLinkActive {
            var newSelection = model.selectedClipIds
            for track in model.videoTracks {
                for clip in track.clips where newSelection.contains(clip.id) {
                    if let lId = clip.linkGroupId {
                        for aTrack in model.audioTracks {
                            if let aClip = aTrack.clips.first(where: { $0.linkGroupId == lId }) {
                                newSelection.insert(aClip.id)
                            }
                        }
                    }
                }
            }
            for track in model.audioTracks {
                for clip in track.clips where newSelection.contains(clip.id) {
                    if let lId = clip.linkGroupId {
                        for vTrack in model.videoTracks {
                            if let vClip = vTrack.clips.first(where: { $0.linkGroupId == lId }) {
                                newSelection.insert(vClip.id)
                            }
                        }
                    }
                }
            }
            model.selectedClipIds = newSelection
        }
        updateLinkButtonTitle()
        canvasView.needsDisplay = true
        DebugLogger.shared.log("Link A/V impostato su: \(model.isLinkActive ? "ATTIVO" : "DISATTIVATO")", level: .info)
    }

    @objc public func onMagnetToggleClicked() {
        model.isSnappingActive.toggle()
        updateMagnetButtonTitle()
        DebugLogger.shared.log("Magnet (Snapping) impostato su: \(model.isSnappingActive ? "ATTIVO" : "DISATTIVATO")", level: .info)
    }

    @objc public func onCageLockToggleClicked() {
        model.isCageLockActive.toggle()
        updateCageLockButtonTitle()
        notifyVCModified(model.isCageLockActive ? "Blocco Gabbia Attivo" : "Montaggio Libero")
        DebugLogger.shared.log("Blocco Gabbia impostato su: \(model.isCageLockActive ? "ATTIVO (aggancia alle sbarre)" : "DISATTIVATO (montaggio libero)")", level: .info)
    }

    private func notifyVCModified(_ title: String) {
        if let onAction = onTimelineAction {
            onAction(title)
        } else {
            onTimelineModified?()
        }
    }

    @objc public func onCleanTracksClicked() {
        model.cleanEmptyTracks()
        reloadTimelineUI()
        notifyVCModified("Pulisci Tracce Vuote")
    }

    @objc public func onCloseGapsClicked() {
        if model.closeGapsBetweenSelectedClips() {
            reloadTimelineUI()
            notifyVCModified("Chiudi Spazi (⌥⌘W)")
        }
    }

    @objc private func onKeyboardShortcutsClicked() {
        KeyboardShortcutsDialog.showModal(relativeTo: view.window)
    }

    // MARK: - Rhythmic Studio Action Handler

    @objc public func onRhythmicStudioClicked() {
        BeatAnalysisDialog.showModal(for: model, relativeTo: view.window) { [weak self] in
            self?.reloadTimelineUI()
            self?.notifyVCModified("Montaggio Ritmico")
        }
    }

    @objc public func onExportXMLClicked() {
        onExportFCPXML?()
    }

    @objc public func onSpanClicked() {
        guard let id = model.selectedClipId else { return }
        for track in model.videoTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                let nextSpan = (clip.span % 3) + 1
                model.setClipSpan(clipId: id, newSpan: nextSpan)
                reloadTimelineUI()
                notifyVCModified("Aumenta Span Gabbia (⌥+)")
                break
            }
        }
    }

    @objc public func onToggleSpeedClicked() {
        guard let id = model.selectedClipId else { return }
        if model.toggleClipSpeed(clipId: id) != nil {
            reloadTimelineUI()
            notifyVCModified("Slow Motion 50%/100% (⌥S)")
        }
    }

    @objc public func onSlipLeftClicked() {
        guard let id = model.selectedClipId else { return }
        if model.slipClip(clipId: id, deltaSeconds: -0.25) {
            reloadTimelineUI()
            notifyVCModified("Slip Clip (-0.25s)")
        }
    }

    @objc public func onSlipRightClicked() {
        guard let id = model.selectedClipId else { return }
        if model.slipClip(clipId: id, deltaSeconds: +0.25) {
            reloadTimelineUI()
            notifyVCModified("Slip Clip (+0.25s)")
        }
    }

    @objc private func onZoomChanged() {
        let oldPPS = canvasView.pixelsPerSecond
        let newPPS = zoomSlider.doubleValue
        applyZoom(newPixelsPerSecond: newPPS, oldPixelsPerSecond: oldPPS, anchorViewportX: nil)
    }

    private func zoomByFactor(_ factor: Double, anchorViewportX: CGFloat) {
        let oldPPS = canvasView.pixelsPerSecond
        let newPPS = max(zoomSlider.minValue, min(zoomSlider.maxValue, oldPPS * factor))
        zoomSlider.doubleValue = newPPS
        applyZoom(newPixelsPerSecond: newPPS, oldPixelsPerSecond: oldPPS, anchorViewportX: anchorViewportX)
    }

    private func applyZoom(newPixelsPerSecond: Double, oldPixelsPerSecond: Double, anchorViewportX: CGFloat?) {
        let clipView = scrollView.contentView
        let clipBounds = clipView.bounds
        let headerW = canvasView.headerWidth

        let anchorTimeSec: Double
        let viewportOffsetX: CGFloat
        if let anchorX = anchorViewportX, anchorX >= headerW {
            viewportOffsetX = anchorX
            anchorTimeSec = max(0, Double(clipBounds.origin.x + anchorX - headerW) / max(1.0, oldPixelsPerSecond))
        } else {
            // Ancora alla testina se visibile, altrimenti mantienila al ~35% dello schermo
            let playheadSec = max(0, CMTimeGetSeconds(playbackController.currentTime))
            let oldPlayheadX = headerW + CGFloat(playheadSec * oldPixelsPerSecond)
            if oldPlayheadX >= clipBounds.minX + headerW && oldPlayheadX <= clipBounds.maxX {
                viewportOffsetX = oldPlayheadX - clipBounds.minX
            } else {
                viewportOffsetX = headerW + max(0, clipBounds.width - headerW) * 0.35
            }
            anchorTimeSec = playheadSec
        }

        canvasView.pixelsPerSecond = newPixelsPerSecond
        syncCanvasFrame()

        let newAnchorCanvasX = headerW + CGFloat(anchorTimeSec * newPixelsPerSecond)
        let maxOriginX = max(0, canvasView.frame.width - clipBounds.width)
        let targetOriginX = max(0, min(maxOriginX, newAnchorCanvasX - viewportOffsetX))
        clipView.scroll(to: NSPoint(x: targetOriginX, y: 0))
        scrollView.reflectScrolledClipView(clipView)
        canvasView.updatePlayheadLayer()
        canvasView.needsDisplay = true
    }
}
