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
    public var onOpenBeatFinderForClip: ((TimelineClip) -> Void)?
    public var onSlipDualPreviewUpdate: ((_ url: URL, _ inSeconds: Double, _ outSeconds: Double, _ fps: Double, _ clipName: String) -> Void)?
    public var onSlipDualPreviewEnd: (() -> Void)?
    public var onUserPlayheadScrubbed: (() -> Void)?
    public var onShowWarningToast: ((String) -> Void)?
    public var onImportDroppedURLsToTimeline: ((_ urls: [URL], _ atTime: CMTime, _ targetTrackIndex: Int, _ isTargetVideo: Bool) -> Void)?
    public var onClipDoubleClicked: ((TimelineClip) -> Void)?
    public var onRelinkMediaItemRequested: ((MediaItem) -> Void)?

    public let headerWidth: CGFloat = 104
    public let rulerHeight: CGFloat = 26
    public let defaultVideoRowHeight: CGFloat = 46
    public let defaultAudioRowHeight: CGFloat = 40
    public let minVideoRowHeight: CGFloat = 23
    public let maxVideoRowHeight: CGFloat = 92
    public let minAudioRowHeight: CGFloat = 20
    public let maxAudioRowHeight: CGFloat = 120

    private struct TrackResizeTarget: Equatable {
        let trackId: Int
        let isVideo: Bool
    }
    private var resizingTrack: TrackResizeTarget? = nil
    private var trackResizeInitialScreenY: CGFloat = 0
    private var trackResizeInitialHeight: CGFloat = 0

    // Movable Center Divider between Video & Audio (nil = exact 50% viewport center)
    private var customSeparatorOffsetY: CGFloat? = nil
    private var isDraggingCenterDivider = false
    private var centerDividerInitialScreenY: CGFloat = 0
    private var centerDividerInitialOffsetY: CGFloat = 0

    // Internal Clip Dragging state
    private struct DraggedClipInitialState {
        let id: UUID
        let isVideo: Bool
        let initialStartTime: CMTime
        let initialTrackIndex: Int
    }
    private var draggedClipId: UUID?
    private var draggedClipIsVideo: Bool = true
    private var dragInitialPoint: CGPoint = .zero
    private var dragInitialStartTime: CMTime = .zero
    private var dragInitialTrackIndex: Int = 0
    private var currentDragTime: CMTime = .zero
    private var currentDragTrackIndex: Int = 0
    private var lastValidDragTime: CMTime = .zero
    private var lastValidDragTrackIndex: Int = 0
    private var isDraggingClip = false
    private var activeSnapLineTime: CMTime? = nil
    private var preDragVideoTrackCount: Int = 1
    private var preDragAudioTrackCount: Int = 1
    private var multiDragInitialStates: [DraggedClipInitialState] = []
    private var multiDragMinStartSeconds: Double = 0.0
    private var currentMultiDragMoves: [(id: UUID, toTrack: Int, isVideo: Bool, newStartTime: CMTime)] = []
    private var lastValidMultiDragMoves: [(id: UUID, toTrack: Int, isVideo: Bool, newStartTime: CMTime)] = []

    // Linked Companion dragging state
    private var linkedCompanionId: UUID? = nil
    private var linkedCompanionInitialStart: CMTime = .zero
    private var linkedCompanionInitialTrack: Int = 0

    // Ruler scrub & Hand pan state
    private var isScrubbingRuler = false
    private var isHandPanning = false
    private var handPanInitialScreenPoint: CGPoint = .zero
    private var handPanInitialOrigin: CGPoint = .zero

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
    private var preDropVideoTrackCount: Int = 1
    private var preDropAudioTrackCount: Int = 1

    // Clip Edge Trimming Gesture state
    private var trackingArea: NSTrackingArea?
    private var hoveredClipId: UUID? = nil
    private var hoveredClipEdge: ClipEdge? = nil
    private var isTrimmingEdge: Bool = false
    private var didTrimCurrentEdge: Bool = false
    private var activeTrimClipId: UUID? = nil
    private var activeTrimIsStart: Bool = false
    private var activeTrimIsVideo: Bool = true
    private var trimStartAnchorX: CGFloat = 0
    private var trimInitialEdgeTimeSec: Double = 0

    // Interactive Marker & Bar Drag/Delete state
    fileprivate struct MarkerTarget: Equatable {
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

    // Modalità Gabbie: Reorder & Tab+Drag Floating Slip Bar state
    public var isTabKeyHeld: Bool = false
    private var isCageReorderDrag: Bool = false
    private var cageReorderTargetIndex: Int? = nil
    private var cageReorderTargetBlocked: Bool = false

    private var isFloatingSlipActive: Bool = false
    private var isSlipDragging: Bool = false
    private var slipClipId: UUID? = nil
    private var slipInitialSourceIn: Double = 0.0
    private var slipDragAnchorSourceIn: Double = 0.0
    private var slipCurrentSourceIn: Double = 0.0
    private var slipSourceDur: Double = 0.0
    private var slipBoundsMin: Double = 0.0
    private var slipBoundsMax: Double = 0.0
    private var slipMarkers: [Double] = []
    private var slipDragInitialX: CGFloat = 0.0
    private var slipClipTimelineStartSec: Double = 0.0
    private var slipClipFrame: CGRect = .zero
    private var slipLastHudRect: CGRect = .zero
    private var slipIsExtract: Bool = false
    private var lastLiveSlipPreviewTime: CFAbsoluteTime = 0.0

    public var widthConstraint: NSLayoutConstraint?

    private let playheadContainerLayer = CALayer()
    private let playheadLineLayer = CALayer()
    private let playheadHandleLayer = CALayer()

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private static let cachedLockBadgeImage: NSImage = Lucide.image(.lock, size: 9, color: .black)
    private static let cachedCheckBadgeImage: NSImage = Lucide.image(.check, size: 9, color: .black)
    private static let cachedSnailBadgeImage: NSImage = Lucide.image(.snail, size: 10, color: .black)

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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onApplicationDidResignActive(_:)),
            name: NSApplication.didResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onModelSelectionChanged(_:)),
            name: TimelineModel.selectionChangedNotification,
            object: nil
        )
    }

    @objc private func onModelSelectionChanged(_ notification: Notification) {
        guard (notification.object as AnyObject?) === self.model else { return }
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func onApplicationDidResignActive(_ note: Notification) {
        isHandPanning = false
        isScrubbingRuler = false
        isDraggingClip = false
        isCageReorderDrag = false
        cageReorderTargetIndex = nil
        isMarqueeSelecting = false
        draggingMarker = nil
        activeSnapLineTime = nil
        resizingTrack = nil
        isTabKeyHeld = false
        if isFloatingSlipActive {
            finishFloatingSlipIfActive()
        }
    }

    public func handleTabKeyStateChanged(isDown: Bool) {
        isTabKeyHeld = isDown
        if isDown {
            if !isFloatingSlipActive, let target = resolveSlipTargetClipAndFrame() {
                beginFloatingSlip(
                    for: target.clip,
                    displayStart: target.displayStart,
                    clipFrame: target.frame,
                    startDragging: false,
                    dragX: target.frame.midX
                )
            }
        } else if isFloatingSlipActive {
            finishFloatingSlipIfActive()
        }
    }

    private func slipHUDWidth() -> CGFloat {
        let totalRange = max(0.05, slipBoundsMax - slipBoundsMin)
        return max(190.0, min(460.0, max(slipClipFrame.width + 60.0, 160.0 + CGFloat(totalRange) * 7.0)))
    }

    private func resolveSlipTargetClipAndFrame() -> (clip: TimelineClip, displayStart: CMTime, frame: CGRect)? {
        let sepY = separatorY
        let phSec = CMTimeGetSeconds(playbackController.currentTime)

        func frameFor(_ dStart: CMTime, _ clip: TimelineClip, _ trackY: CGFloat, _ trackH: CGFloat) -> CGRect {
            let clipX = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
            let clipW = max(4.0, CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond))
            return CGRect(x: clipX, y: trackY + 2, width: clipW, height: trackH - 4)
        }

        // 1. Priorità a clip selezionata (prima video, poi audio)
        if !model.selectedClipIds.isEmpty {
            for track in model.videoTracks where !track.isLocked {
                let trackH = heightForVideoTrack(track.id)
                let trackY = yForVideoTrack(track.id, sepY: sepY)
                for (clip, dStart) in model.displayedClips(isVideo: true, trackIndex: track.id)
                where model.selectedClipIds.contains(clip.id) && !clip.isEffectivelyLocked {
                    return (clip, dStart, frameFor(dStart, clip, trackY, trackH))
                }
            }
            for track in model.audioTracks where !track.isLocked {
                let trackH = heightForAudioTrack(track.id)
                let trackY = yForAudioTrack(track.id, sepY: sepY)
                for (clip, dStart) in model.displayedClips(isVideo: false, trackIndex: track.id)
                where model.selectedClipIds.contains(clip.id) && !clip.isEffectivelyLocked {
                    return (clip, dStart, frameFor(dStart, clip, trackY, trackH))
                }
            }
        }

        // 2. Fallback alla clip sotto la testina (dalla traccia video superiore verso il basso)
        for track in model.videoTracks.reversed() where !track.isLocked {
            let trackH = heightForVideoTrack(track.id)
            let trackY = yForVideoTrack(track.id, sepY: sepY)
            for (clip, dStart) in model.displayedClips(isVideo: true, trackIndex: track.id) where !clip.isEffectivelyLocked {
                let s = CMTimeGetSeconds(dStart)
                let e = s + CMTimeGetSeconds(clip.duration)
                if phSec >= s - 0.005 && phSec <= e + 0.005 {
                    return (clip, dStart, frameFor(dStart, clip, trackY, trackH))
                }
            }
        }
        for track in model.audioTracks where !track.isLocked {
            let trackH = heightForAudioTrack(track.id)
            let trackY = yForAudioTrack(track.id, sepY: sepY)
            for (clip, dStart) in model.displayedClips(isVideo: false, trackIndex: track.id) where !clip.isEffectivelyLocked {
                let s = CMTimeGetSeconds(dStart)
                let e = s + CMTimeGetSeconds(clip.duration)
                if phSec >= s - 0.005 && phSec <= e + 0.005 {
                    return (clip, dStart, frameFor(dStart, clip, trackY, trackH))
                }
            }
        }
        return nil
    }

    @discardableResult
    private func beginFloatingSlip(
        for clip: TimelineClip,
        displayStart: CMTime,
        clipFrame: CGRect,
        startDragging: Bool,
        dragX: CGFloat
    ) -> Bool {
        guard !clip.isEffectivelyLocked,
              let slipInfo = model.slipClipSelectionBounds(clipId: clip.id) else {
            return false
        }
        isFloatingSlipActive = true
        isSlipDragging = startDragging
        slipClipId = clip.id
        slipInitialSourceIn = slipInfo.sourceIn
        slipDragAnchorSourceIn = slipInfo.sourceIn
        slipCurrentSourceIn = slipInfo.sourceIn
        slipSourceDur = slipInfo.sourceDur
        slipBoundsMin = slipInfo.boundsMin
        slipBoundsMax = slipInfo.boundsMax
        slipMarkers = slipInfo.markers
        slipIsExtract = slipInfo.isExtract
        slipDragInitialX = dragX
        slipClipTimelineStartSec = CMTimeGetSeconds(displayStart)
        slipClipFrame = clipFrame
        emitSlipDualPreview(forClipId: clip.id, currentSourceIn: slipInfo.sourceIn, sourceDur: slipInfo.sourceDur)
        needsDisplay = true
        return true
    }

    private func emitSlipDualPreview(forClipId clipId: UUID, currentSourceIn: Double, sourceDur: Double) {
        let outSec = currentSourceIn + sourceDur
        var targetClip: TimelineClip? = model.videoTracks.lazy.flatMap(\.clips).first(where: { $0.id == clipId })
        if targetClip == nil, let aClip = model.audioTracks.lazy.flatMap(\.clips).first(where: { $0.id == clipId }) {
            if let lId = aClip.linkGroupId {
                targetClip = model.videoTracks.lazy.flatMap(\.clips).first(where: { $0.linkGroupId == lId })
            }
            if targetClip == nil {
                let paired = model.resolveSelectionCompanionClipIds(for: [clipId])
                targetClip = model.videoTracks.lazy.flatMap(\.clips).first(where: { paired.contains($0.id) })
            }
            if targetClip == nil && aClip.mediaItem.hasVideo {
                targetClip = aClip
            }
        }
        guard let vClip = targetClip, vClip.mediaItem.hasVideo else { return }
        let fps = vClip.mediaItem.frameRate > 0 ? Double(vClip.mediaItem.frameRate) : Double(model.format.fps)
        onSlipDualPreviewUpdate?(vClip.mediaItem.effectiveURL, currentSourceIn, outSec, fps, vClip.mediaItem.name)
    }

    public func refreshFloatingSlipBoundsIfActive() {
        guard isFloatingSlipActive, let clipId = slipClipId,
              let slipInfo = model.slipClipSelectionBounds(clipId: clipId) else { return }
        slipCurrentSourceIn = slipInfo.sourceIn
        slipSourceDur = slipInfo.sourceDur
        slipBoundsMin = slipInfo.boundsMin
        slipBoundsMax = slipInfo.boundsMax
        slipMarkers = slipInfo.markers
        slipIsExtract = slipInfo.isExtract
        emitSlipDualPreview(forClipId: clipId, currentSourceIn: slipInfo.sourceIn, sourceDur: slipInfo.sourceDur)
        needsDisplay = true
    }

    private func finishFloatingSlipIfActive() {
        guard isFloatingSlipActive else { return }
        let changed = abs(slipCurrentSourceIn - slipInitialSourceIn) > 0.002
        isFloatingSlipActive = false
        isSlipDragging = false
        slipClipId = nil
        slipLastHudRect = .zero
        onSlipDualPreviewEnd?()
        updateWidth()
        needsDisplay = true
        if changed {
            notifyModified(slipIsExtract ? "Slip Estratto Selezione (Tab+Drag)" : "Slip Clip (Tab+Drag)")
        }
    }

    public func heightForVideoTrack(_ trackId: Int) -> CGFloat {
        let raw = CGFloat(model.videoTrackHeights[trackId] ?? Double(defaultVideoRowHeight))
        return max(minVideoRowHeight, min(maxVideoRowHeight, raw))
    }

    public func heightForAudioTrack(_ trackId: Int) -> CGFloat {
        let raw = CGFloat(model.audioTrackHeights[trackId] ?? Double(defaultAudioRowHeight))
        return max(minAudioRowHeight, min(maxAudioRowHeight, raw))
    }

    private func yForVideoTrack(_ trackId: Int, sepY: CGFloat) -> CGFloat {
        var top = sepY
        for id in 0...max(0, trackId) {
            top -= heightForVideoTrack(id)
        }
        return top
    }

    private func yForAudioTrack(_ trackId: Int, sepY: CGFloat) -> CGFloat {
        var top = sepY + 4
        for id in 0..<max(0, trackId) {
            top += heightForAudioTrack(id)
        }
        return top
    }

    private func videoTrackIndex(atY y: CGFloat, sepY: CGFloat, maxTrackIndex: Int) -> Int {
        var bottom = sepY
        for id in 0...max(0, maxTrackIndex) {
            let h = heightForVideoTrack(id)
            let top = bottom - h
            if y >= top {
                return id
            }
            bottom = top
        }
        return max(0, maxTrackIndex)
    }

    private func audioTrackIndex(atY y: CGFloat, sepY: CGFloat, maxTrackIndex: Int) -> Int {
        var top = sepY + 4
        for id in 0...max(0, maxTrackIndex) {
            let h = heightForAudioTrack(id)
            let bottom = top + h
            if y <= bottom {
                return id
            }
            top = bottom
        }
        return max(0, maxTrackIndex)
    }

    private var stickyRulerTopY: CGFloat {
        max(0.0, visibleRect.minY)
    }

    private func centerDividerHitTest(at localPoint: CGPoint, sepY: CGFloat) -> Bool {
        guard localPoint.y > stickyRulerTopY + rulerHeight else { return false }
        return abs(localPoint.y - sepY) <= 4.5
    }

    private func trackResizeHitTest(at localPoint: CGPoint, sepY: CGFloat) -> TrackResizeTarget? {
        guard localPoint.y > stickyRulerTopY + rulerHeight else { return nil }
        for track in model.videoTracks {
            let borderY = yForVideoTrack(track.id, sepY: sepY)
            if abs(localPoint.y - borderY) <= 3.5 {
                return TrackResizeTarget(trackId: track.id, isVideo: true)
            }
        }
        for track in model.audioTracks {
            let borderY = yForAudioTrack(track.id, sepY: sepY) + heightForAudioTrack(track.id)
            if abs(localPoint.y - borderY) <= 3.5 {
                return TrackResizeTarget(trackId: track.id, isVideo: false)
            }
        }
        return nil
    }

    private var waveformRedrawWorkItem: DispatchWorkItem?

    @objc private func onWaveformReady(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.waveformRedrawWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.needsDisplay = true
            }
            self.waveformRedrawWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
        }
    }

    private var visibleViewportHeight: CGFloat {
        let h = enclosingScrollView?.contentView.bounds.height ?? bounds.height
        return max(180, h)
    }

    private var totalVideoTracksHeight: CGFloat {
        model.videoTracks.reduce(0) { $0 + heightForVideoTrack($1.id) }
    }

    private var totalAudioTracksHeight: CGFloat {
        model.audioTracks.reduce(0) { $0 + heightForAudioTrack($1.id) }
    }

    private func clampedSeparatorOffsetY(forViewportHeight viewportH: CGFloat) -> CGFloat {
        let usableH = max(80, viewportH - rulerHeight)
        let minOff = min(24.0, usableH * 0.25)
        let maxOff = max(minOff, usableH - 28.0)
        let raw = customSeparatorOffsetY ?? (usableH * 0.5)
        return max(minOff, min(maxOff, raw))
    }

    private func topVideoOverflow(forViewportHeight viewportH: CGFloat) -> CGFloat {
        let desiredOffset = clampedSeparatorOffsetY(forViewportHeight: viewportH)
        return max(0.0, totalVideoTracksHeight - desiredOffset)
    }

    // Center divider between Video & Audio (default: exact 50% between ruler and bottom of viewport; shifts down on top overflow)
    public func separatorY(forViewportHeight viewportH: CGFloat) -> CGFloat {
        let desiredOffset = clampedSeparatorOffsetY(forViewportHeight: viewportH)
        let topOverflow = max(0.0, totalVideoTracksHeight - desiredOffset)
        return rulerHeight + desiredOffset + topOverflow
    }

    public var separatorY: CGFloat {
        separatorY(forViewportHeight: visibleViewportHeight)
    }

    public func calculatedTotalHeight(forViewportHeight viewportH: CGFloat) -> CGFloat {
        let desiredOffset = clampedSeparatorOffsetY(forViewportHeight: viewportH)
        let topOverflow = max(0.0, totalVideoTracksHeight - desiredOffset)
        let sepY = rulerHeight + desiredOffset + topOverflow
        let audioBottom = sepY + 4.0 + totalAudioTracksHeight + 8.0
        return max(viewportH + topOverflow, audioBottom)
    }

    public var totalContentSeconds: Double {
        let rawDur = max(0.0, CMTimeGetSeconds(model.displayedTotalDuration))
        let pad = rawDur > 0 ? min(10.0, max(2.0, rawDur * 0.02)) : 30.0
        return max(30.0, rawDur + pad)
    }

    public var calculatedTotalWidth: CGFloat {
        return headerWidth + CGFloat(totalContentSeconds * pixelsPerSecond)
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
        let visTopY = stickyRulerTopY

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playheadContainerLayer.isHidden = (playheadX < stickyHeaderRight)
        playheadContainerLayer.frame = CGRect(x: playheadX - 5, y: visTopY, width: 10, height: max(0, totalHeight - visTopY))
        playheadLineLayer.frame = CGRect(x: 4.25, y: 0, width: 1.5, height: max(0, totalHeight - visTopY))
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
        DebugLogger.shared.measure("TimelineCanvasView.draw", thresholdMs: 25.0) {
        drawCanvasContent(dirtyRect: dirtyRect, ctx: ctx)
        }
    }

    private func drawCanvasContent(dirtyRect: NSRect, ctx: CGContext) {

        let bounds = self.bounds
        let sepY = separatorY
        let drawMinX = max(headerWidth, dirtyRect.minX)
        let drawMaxX = min(bounds.width, dirtyRect.maxX)
        let drawRowW = max(0, drawMaxX - drawMinX)
        let clipVisMinX = visibleRect.minX - 24
        let clipVisMaxX = visibleRect.maxX + 24

        // 1. Background (clamped to dirtyRect)
        ctx.setFillColor(NSColor(calibratedWhite: 0.075, alpha: 1.0).cgColor)
        ctx.fill(dirtyRect)

        // Clip tracks & center divider below the sticky ruler so scrolled tracks never bleed above it
        let tracksTopY = stickyRulerTopY + rulerHeight
        ctx.saveGState()
        ctx.clip(to: CGRect(x: 0, y: tracksTopY, width: bounds.width, height: max(0, bounds.height - tracksTopY)))

        // 2. Video Tracks stack UPWARDS from separatorY
        for track in model.videoTracks {
            let trackH = heightForVideoTrack(track.id)
            let trackY = yForVideoTrack(track.id, sepY: sepY)
            if drawRowW > 0 {
                let rowRect = CGRect(x: drawMinX, y: trackY, width: drawRowW, height: trackH)
                let isEven = (track.id % 2 == 0)

                if track.isLocked {
                    ctx.setFillColor(NSColor(calibratedRed: 0.11, green: 0.08, blue: 0.08, alpha: 1.0).cgColor)
                } else {
                    ctx.setFillColor(isEven ? NSColor(calibratedWhite: 0.11, alpha: 1.0).cgColor : NSColor(calibratedWhite: 0.095, alpha: 1.0).cgColor)
                }
                ctx.fill(rowRect)

                ctx.setStrokeColor(NSColor(calibratedWhite: 0.17, alpha: 1.0).cgColor)
                ctx.setLineWidth(1.0)
                ctx.strokeLineSegments(between: [
                    CGPoint(x: drawMinX, y: trackY),
                    CGPoint(x: drawMaxX, y: trackY)
                ])
            }

            for (clip, dStart) in model.displayedClips(isVideo: true, trackIndex: track.id) {
                let cx = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
                let cw = max(3.0, CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond))
                if cx + cw < clipVisMinX || cx > clipVisMaxX { continue }
                drawClip(clip: clip, displayStart: dStart, y: trackY + 2, height: trackH - 4, trackHeight: trackH, isVideo: true, isTrackLocked: track.isLocked, isTrackEnabled: track.isEnabled, ctx: ctx)
            }
        }

        // Center Separator between Video and Audio (Exact 50% Middle, clamped horizontally)
        let fullDrawMinX = max(0, dirtyRect.minX)
        let fullDrawMaxX = min(bounds.width, dirtyRect.maxX)
        let fullDrawW = max(0, fullDrawMaxX - fullDrawMinX)
        if fullDrawW > 0 {
            let sepRect = CGRect(x: fullDrawMinX, y: sepY - 2, width: fullDrawW, height: 4)
            ctx.setFillColor(NSColor(calibratedWhite: 0.04, alpha: 1.0).cgColor)
            ctx.fill(sepRect)

            ctx.setStrokeColor(NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeLineSegments(between: [
                CGPoint(x: fullDrawMinX, y: sepY),
                CGPoint(x: fullDrawMaxX, y: sepY)
            ])
        }

        // Audio Tracks stack DOWNWARDS from separatorY
        for track in model.audioTracks {
            let trackH = heightForAudioTrack(track.id)
            let trackY = yForAudioTrack(track.id, sepY: sepY)
            if drawRowW > 0 {
                let rowRect = CGRect(x: drawMinX, y: trackY, width: drawRowW, height: trackH)
                let isEven = (track.id % 2 == 0)

                if track.isLocked {
                    ctx.setFillColor(NSColor(calibratedRed: 0.11, green: 0.08, blue: 0.08, alpha: 1.0).cgColor)
                } else {
                    ctx.setFillColor(isEven ? NSColor(calibratedWhite: 0.105, alpha: 1.0).cgColor : NSColor(calibratedWhite: 0.09, alpha: 1.0).cgColor)
                }
                ctx.fill(rowRect)

                ctx.setStrokeColor(NSColor(calibratedWhite: 0.17, alpha: 1.0).cgColor)
                ctx.setLineWidth(1.0)
                ctx.strokeLineSegments(between: [
                    CGPoint(x: drawMinX, y: trackY + trackH),
                    CGPoint(x: drawMaxX, y: trackY + trackH)
                ])
            }

            for (clip, dStart) in model.displayedClips(isVideo: false, trackIndex: track.id) {
                let cx = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
                let cw = max(3.0, CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond))
                if cx + cw < clipVisMinX || cx > clipVisMaxX { continue }
                drawClip(clip: clip, displayStart: dStart, y: trackY + 2, height: trackH - 4, trackHeight: trackH, isVideo: false, isTrackLocked: track.isLocked, isTrackEnabled: track.isEnabled, ctx: ctx)
            }
        }

        // 2b. Selected clip borders always rendered on top of adjacent clips (both before and after)
        drawSelectedClipBorders(sepY: sepY, visibleRect: visibleRect, ctx: ctx)
        ctx.restoreGState()

        // 2c. Evidenziazione Ghost delle zone completamente vuote (rettangolo rosso dall'alto al basso)
        if model.isEmptyGapsHighlighted {
            drawEmptyTimelineGaps(bounds: bounds, drawMinX: drawMinX, drawMaxX: drawMaxX, ctx: ctx)
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
                CGPoint(x: snapX, y: stickyRulerTopY + rulerHeight),
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

        // 9. Modalità Gabbie Reorder Target Cage Highlight
        if isCageReorderDrag, let targetIdx = cageReorderTargetIndex {
            let cages = model.activeCageIntervals()
            if targetIdx >= 0 && targetIdx < cages.count {
                let cage = cages[targetIdx]
                let trackH = heightForVideoTrack(dragInitialTrackIndex)
                let trackY = yForVideoTrack(dragInitialTrackIndex, sepY: sepY)
                let x = headerWidth + CGFloat(cage.startSeconds * pixelsPerSecond)
                let w = max(6.0, CGFloat(cage.durationSeconds * pixelsPerSecond))
                let targetRect = CGRect(x: x, y: trackY + 1, width: w, height: trackH - 2)
                let color: NSColor = cageReorderTargetBlocked ? .systemRed : .systemCyan
                ctx.saveGState()
                ctx.setFillColor(color.withAlphaComponent(0.24).cgColor)
                let path = CGPath(roundedRect: targetRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.setStrokeColor(color.cgColor)
                ctx.setLineWidth(2.2)
                ctx.addPath(path)
                ctx.strokePath()
                ctx.restoreGState()
            }
        }

        // 10. Floating Slip Range Bar (Tab + Click & Drag sopra la clip)
        if isFloatingSlipActive {
            drawFloatingSlipHUD(in: bounds, ctx: ctx)
        }
    }

    private func drawFloatingSlipHUD(in bounds: CGRect, ctx: CGContext) {
        let totalRange = max(0.05, slipBoundsMax - slipBoundsMin)
        let hudW = slipHUDWidth()
        let hudH: CGFloat = 42.0
        var hudX = slipClipFrame.midX - hudW * 0.5
        let minVisX = max(headerWidth + 8.0, visibleRect.minX + headerWidth + 8.0)
        let maxVisX = max(minVisX, visibleRect.maxX - hudW - 8.0)
        hudX = max(minVisX, min(maxVisX, hudX))
        var hudY = slipClipFrame.minY - hudH - 6.0
        if hudY < rulerHeight + 4.0 {
            hudY = slipClipFrame.maxY + 6.0
        }
        let hudRect = CGRect(x: hudX, y: hudY, width: hudW, height: hudH)
        slipLastHudRect = hudRect

        ctx.saveGState()
        let bgPath = CGPath(roundedRect: hudRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.setFillColor(NSColor(calibratedWhite: 0.11, alpha: 0.96).cgColor)
        ctx.addPath(bgPath)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(0.85).cgColor)
        ctx.setLineWidth(1.3)
        ctx.addPath(bgPath)
        ctx.strokePath()

        // Inner track bar representing [slipBoundsMin .. slipBoundsMax]
        let trackRect = CGRect(x: hudRect.minX + 10, y: hudRect.minY + 19, width: hudW - 20, height: 14)
        let trackPath = CGPath(roundedRect: trackRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.setFillColor(NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor)
        ctx.addPath(trackPath)
        ctx.fillPath()

        // Highlighted window [slipCurrentSourceIn .. slipCurrentSourceIn + slipSourceDur], proporzionale al range
        let normStart = max(0.0, min(1.0, (slipCurrentSourceIn - slipBoundsMin) / totalRange))
        let normDur = max(0.0, min(1.0 - normStart, slipSourceDur / totalRange))
        let winX = trackRect.minX + CGFloat(normStart) * trackRect.width
        let winW = max(8.0, min(trackRect.width, CGFloat(normDur) * trackRect.width))
        let clampedWinX = min(trackRect.maxX - winW, max(trackRect.minX, winX))
        let winRect = CGRect(x: clampedWinX, y: trackRect.minY, width: winW, height: trackRect.height)
        let winPath = CGPath(roundedRect: winRect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.55).cgColor)
        ctx.addPath(winPath)
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.systemYellow.cgColor)
        ctx.setLineWidth(1.6)
        ctx.addPath(winPath)
        ctx.strokePath()

        // Draw any Selection markers (M) inside the extract
        for m in slipMarkers {
            let normM = max(0.0, min(1.0, (m - slipBoundsMin) / totalRange))
            let mx = trackRect.minX + CGFloat(normM) * trackRect.width
            ctx.setStrokeColor(NSColor.systemOrange.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeLineSegments(between: [
                CGPoint(x: mx, y: trackRect.minY - 1),
                CGPoint(x: mx, y: trackRect.maxY + 1)
            ])
        }

        let startRel = max(0.0, slipCurrentSourceIn - slipBoundsMin)
        let endRel = min(totalRange, startRel + slipSourceDur)
        let prefix = slipIsExtract ? "SLIP SELEZIONE" : "SLIP ORIGINALE"
        let infoStr = String(format: "%@  •  %.1fs – %.1fs / %.1fs", prefix, startRel, endRel, totalRange)
        let infoAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        (infoStr as NSString).draw(at: CGPoint(x: hudRect.minX + 10, y: hudRect.minY + 4), withAttributes: infoAttrs)
        ctx.restoreGState()
    }

    private func drawEmptyTimelineGaps(bounds: CGRect, drawMinX: CGFloat, drawMaxX: CGFloat, ctx: CGContext) {
        let gaps = model.emptyTimelineGapIntervals()
        guard !gaps.isEmpty, drawMaxX > drawMinX else { return }
        let topY = stickyRulerTopY + rulerHeight
        let height = max(0, bounds.height - topY)
        guard height > 0 else { return }

        ctx.saveGState()
        for gap in gaps {
            let rawStartX = headerWidth + CGFloat(gap.start * pixelsPerSecond)
            let rawEndX = headerWidth + CGFloat(gap.end * pixelsPerSecond)
            let clampedStartX = max(drawMinX, rawStartX)
            let clampedEndX = min(drawMaxX, max(clampedStartX, rawEndX))
            let rectW = rawEndX - rawStartX
            guard rawEndX >= drawMinX - 2, rawStartX <= drawMaxX + 2 else { continue }

            let visW = max(min(2.0, max(0.0, drawMaxX - clampedStartX)), clampedEndX - clampedStartX)
            guard visW > 0 else { continue }

            let gapRect = CGRect(x: clampedStartX, y: topY, width: visW, height: height)
            ctx.setFillColor(NSColor.systemRed.withAlphaComponent(0.28).cgColor)
            ctx.fill(gapRect)

            ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.82).cgColor)
            ctx.setLineWidth(1.25)
            var edgeLines: [CGPoint] = []
            if rawStartX >= drawMinX && rawStartX <= drawMaxX {
                edgeLines.append(CGPoint(x: rawStartX, y: topY))
                edgeLines.append(CGPoint(x: rawStartX, y: bounds.height))
            }
            if rectW >= 3.0 && rawEndX >= drawMinX && rawEndX <= drawMaxX {
                edgeLines.append(CGPoint(x: rawEndX, y: topY))
                edgeLines.append(CGPoint(x: rawEndX, y: bounds.height))
            }
            if !edgeLines.isEmpty {
                ctx.strokeLineSegments(between: edgeLines)
            }
        }
        ctx.restoreGState()
    }

    private func drawSelectedClipBorders(sepY: CGFloat, visibleRect: CGRect, ctx: CGContext) {
        guard !model.selectedClipIds.isEmpty else { return }

        let drawTrackBorders: ([TimelineTrack], Bool) -> Void = { tracks, isVideo in
            for track in tracks {
                let trackH = isVideo ? self.heightForVideoTrack(track.id) : self.heightForAudioTrack(track.id)
                let trackY = isVideo ? self.yForVideoTrack(track.id, sepY: sepY) : self.yForAudioTrack(track.id, sepY: sepY)
                for (clip, dStart) in self.model.displayedClips(isVideo: isVideo, trackIndex: track.id) {
                    guard self.model.selectedClipIds.contains(clip.id) else { continue }
                    let cx = self.headerWidth + CGFloat(CMTimeGetSeconds(dStart) * self.pixelsPerSecond)
                    let cw = max(3.0, CGFloat(CMTimeGetSeconds(clip.duration) * self.pixelsPerSecond))
                    if cx + cw < visibleRect.minX - 24 || cx > visibleRect.maxX + 24 { continue }
                    let rect = CGRect(x: cx, y: trackY + 2, width: cw, height: trackH - 4)
                    let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                    ctx.setStrokeColor(NSColor.systemRed.cgColor)
                    ctx.setLineWidth(clip.isOrphan ? 2.5 : 2.0)
                    ctx.addPath(path)
                    ctx.strokePath()
                }
            }
        }

        drawTrackBorders(model.videoTracks, true)
        drawTrackBorders(model.audioTracks, false)
    }

    private static let clipLabelAttrsActive: [NSAttributedString.Key: Any] = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white, .paragraphStyle: p]
    }()
    private static let clipLabelAttrsMuted: [NSAttributedString.Key: Any] = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.lightGray, .paragraphStyle: p]
    }()
    private static let clipLabelAttrsOrphan: [NSAttributedString.Key: Any] = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.85, alpha: 1.0), .paragraphStyle: p]
    }()
    private static let badgeDarkAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
        .foregroundColor: NSColor.black
    ]
    private static let badgeWhiteAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 8.5, weight: .bold),
        .foregroundColor: NSColor.white
    ]
    private static let badgeCageAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.9, alpha: 1.0)
    ]
    private static let trackHeaderNameAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.boldSystemFont(ofSize: 11),
        .foregroundColor: NSColor.white
    ]
    private static let rulerTimeAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1.0)
    ]
    private static let rulerCageIndexAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 7.5, weight: .bold),
        .foregroundColor: NSColor.systemCyan
    ]
    private static let rulerBpmTagAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .bold),
        .foregroundColor: NSColor.systemCyan
    ]

    private func drawClip(
        clip: TimelineClip,
        displayStart: CMTime,
        y: CGFloat,
        height: CGFloat,
        trackHeight: CGFloat,
        isVideo: Bool,
        isTrackLocked: Bool,
        isTrackEnabled: Bool,
        ctx: CGContext
    ) {
        let startSec = CMTimeGetSeconds(displayStart)
        let durSec = CMTimeGetSeconds(clip.duration)
        let x = headerWidth + CGFloat(startSec * pixelsPerSecond)
        let w = max(3.0, CGFloat(durSec * pixelsPerSecond))
        let rect = CGRect(x: x, y: y, width: w, height: height)

        let isSelected = model.selectedClipIds.contains(clip.id)

        // Clip background (selection does NOT alter fill color; custom colorTag overrides priority/default)
        let baseColor: NSColor
        if clip.isOrphan {
            baseColor = NSColor(calibratedRed: 0.65, green: 0.15, blue: 0.15, alpha: 1.0)
        } else if !isTrackEnabled {
            baseColor = NSColor.darkGray.withAlphaComponent(0.4)
        } else if isTrackLocked {
            baseColor = isVideo ? NSColor(calibratedRed: 0.28, green: 0.18, blue: 0.22, alpha: 1.0) : NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.28, alpha: 1.0)
        } else if clip.isApproved {
            baseColor = NSColor(calibratedRed: 0.13, green: 0.49, blue: 0.27, alpha: 1.0)
        } else if let customColor = clip.colorTag?.nsColor {
            baseColor = customColor
        } else if let p = clip.priority, let pColor = priorityColor(for: p) {
            baseColor = pColor
        } else if isVideo {
            baseColor = NSColor(calibratedRed: 0.18, green: 0.35, blue: 0.58, alpha: 1.0)
        } else {
            baseColor = NSColor(calibratedRed: 0.22, green: 0.48, blue: 0.38, alpha: 1.0)
        }

        ctx.setFillColor(baseColor.cgColor)
        let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        // Audio Waveform rendering ONLY when track height >= defaultAudioRowHeight (hides below current default height)
        if !isVideo && isTrackEnabled && !clip.isOrphan && trackHeight >= defaultAudioRowHeight - 0.5 {
            drawWaveform(for: clip, displayStart: displayStart, in: rect, ctx: ctx)
        }

        // Beat markers / gabbie segnate direttamente sul brano audio
        if !isVideo && !clip.beatMarkers.isEmpty && w > 8 {
            drawClipBeatMarkers(for: clip, in: rect, ctx: ctx)
        }

        // Marcatori manuali (M) su clip video e audio
        if !clip.markers.isEmpty && w > 6 {
            drawClipManualMarkers(for: clip, displayStart: displayStart, in: rect, ctx: ctx)
        }

        // Unselected clip borders (selected red borders are drawn in a dedicated top overlay pass)
        if !isSelected {
            if clip.isOrphan {
                ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.75).cgColor)
                ctx.setLineWidth(1.5)
                ctx.addPath(path)
                ctx.strokePath()
            } else if clip.isApproved {
                ctx.setStrokeColor(NSColor(calibratedRed: 0.30, green: 0.90, blue: 0.52, alpha: 1.0).cgColor)
                ctx.setLineWidth(1.8)
                ctx.addPath(path)
                ctx.strokePath()
            } else if clip.isLocked {
                ctx.setStrokeColor(NSColor.systemOrange.cgColor)
                ctx.setLineWidth(1.6)
                ctx.addPath(path)
                ctx.strokePath()
            } else {
                ctx.setStrokeColor(NSColor(calibratedWhite: 0.5, alpha: 0.4).cgColor)
                ctx.setLineWidth(0.8)
                ctx.addPath(path)
                ctx.strokePath()
            }
        }

        // Clip label
        if w > 34 {
            let label = clip.mediaItem.name as NSString
            let attrs = clip.isOrphan
                ? Self.clipLabelAttrsOrphan
                : (isTrackEnabled ? Self.clipLabelAttrsActive : Self.clipLabelAttrsMuted)
            let textRect = CGRect(x: x + 4, y: y + 2, width: max(10, w - 8), height: 14)
            label.draw(in: textRect, withAttributes: attrs)
        }

        // Badges: BeatMarkers (♪), Speed (Snail), Span (2x/3x), Approved (✓), Lock, Priority (1/2/3/4), Cage (G1, G2...)
        var badgeX = x + w - 4

        if !isVideo && !clip.beatMarkers.isEmpty && w > 48 {
            let beatText = clip.beatBPM.map { "♪ \(Int($0.rounded()))" } ?? "♪ \(clip.beatMarkers.count)"
            let bSize = (beatText as NSString).size(withAttributes: Self.badgeDarkAttrs)
            badgeX -= (bSize.width + 6)
            let badgeRect = CGRect(x: badgeX, y: y + 2, width: bSize.width + 6, height: 12)
            ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.92).cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            (beatText as NSString).draw(at: CGPoint(x: badgeX + 3, y: y + 2), withAttributes: Self.badgeDarkAttrs)
            badgeX -= 3
        }

        if clip.speed < 0.99 && w > 24 {
            badgeX -= 16
            let snailPill = CGRect(x: badgeX, y: y + 2, width: 14, height: 12)
            ctx.setFillColor(NSColor.systemYellow.cgColor)
            ctx.addPath(CGPath(roundedRect: snailPill, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            Self.cachedSnailBadgeImage.draw(in: CGRect(x: badgeX + 2.0, y: y + 3.0, width: 10, height: 10))
            badgeX -= 3
        } else if clip.speed > 1.01 && w > 42 {
            let speedText = "\(Int(clip.speed * 100))%"
            let sSize = (speedText as NSString).size(withAttributes: Self.badgeDarkAttrs)
            badgeX -= (sSize.width + 6)
            let badgeRect = CGRect(x: badgeX, y: y + 2, width: sSize.width + 6, height: 12)
            ctx.setFillColor(NSColor.systemYellow.cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            (speedText as NSString).draw(at: CGPoint(x: badgeX + 3, y: y + 2), withAttributes: Self.badgeDarkAttrs)
            badgeX -= 3
        }

        // Badge temporaneo Xx solo durante il drag / trim in Modalità Gabbie ON
        if model.isCageLockActive {
            let isActivelyTrimmingThis = (isTrimmingEdge && activeTrimClipId == clip.id)
            let isActivelyDraggingThis = (isDraggingClip && (draggedClipId == clip.id || multiDragInitialStates.contains(where: { $0.id == clip.id })))
            if isActivelyTrimmingThis || isActivelyDraggingThis {
                let cages = model.activeCageIntervals()
                let sSec = CMTimeGetSeconds(displayStart)
                let eSec = sSec + CMTimeGetSeconds(clip.duration)
                let overlapCages = cages.filter { min(eSec, $0.endSeconds) - max(sSec, $0.startSeconds) > 0.02 }.count
                let liveSpan = max(clip.span, overlapCages)
                if (isActivelyTrimmingThis && liveSpan >= 1) || liveSpan >= 2 {
                    let spanText = "\(max(1, liveSpan))x"
                    let spSize = (spanText as NSString).size(withAttributes: Self.badgeWhiteAttrs)
                    let pillW = spSize.width + 6
                    if badgeX - pillW > x + 4 {
                        badgeX -= pillW
                        let badgeRect = CGRect(x: badgeX, y: y + 2, width: pillW, height: 12)
                        ctx.setFillColor(NSColor.systemCyan.cgColor)
                        ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
                        ctx.fillPath()
                        (spanText as NSString).draw(at: CGPoint(x: badgeX + 3, y: y + 2), withAttributes: Self.badgeWhiteAttrs)
                        badgeX -= 3
                    }
                }
            }
        }

        if clip.isApproved && w > 22 {
            badgeX -= 16
            let okPill = CGRect(x: badgeX, y: y + 2, width: 14, height: 12)
            ctx.setFillColor(NSColor(calibratedRed: 0.35, green: 0.92, blue: 0.54, alpha: 0.96).cgColor)
            ctx.addPath(CGPath(roundedRect: okPill, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            Self.cachedCheckBadgeImage.draw(in: CGRect(x: badgeX + 2.5, y: y + 3.5, width: 9, height: 9))
            badgeX -= 3
        }

        if clip.isLocked && w > 22 {
            badgeX -= 16
            let lockPill = CGRect(x: badgeX, y: y + 2, width: 14, height: 12)
            ctx.setFillColor(NSColor.systemOrange.withAlphaComponent(0.95).cgColor)
            ctx.addPath(CGPath(roundedRect: lockPill, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            Self.cachedLockBadgeImage.draw(in: CGRect(x: badgeX + 2.5, y: y + 3.5, width: 9, height: 9))
            badgeX -= 3
        }

        if let p = clip.priority, let pColor = priorityColor(for: p), w > 24 {
            let pText = "\(p)"
            let pSize = (pText as NSString).size(withAttributes: Self.badgeWhiteAttrs)
            let pillW = max(14.0, pSize.width + 6)
            badgeX -= pillW
            let badgeRect = CGRect(x: badgeX, y: y + 2, width: pillW, height: 12)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.38).cgColor)
            let bPath = CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            ctx.addPath(bPath)
            ctx.fillPath()
            ctx.setStrokeColor(pColor.cgColor)
            ctx.setLineWidth(0.8)
            ctx.addPath(bPath)
            ctx.strokePath()
            (pText as NSString).draw(at: CGPoint(x: badgeX + (pillW - pSize.width) * 0.5, y: y + 2), withAttributes: Self.badgeWhiteAttrs)
            badgeX -= 3
        }

        if let cIdx = clip.cageIndex, w > 74 {
            let cText = "G\(cIdx + 1)"
            let cSize = (cText as NSString).size(withAttributes: Self.badgeCageAttrs)
            badgeX -= (cSize.width + 6)
            let badgeRect = CGRect(x: badgeX, y: y + 2, width: cSize.width + 6, height: 12)
            ctx.setFillColor(NSColor(calibratedWhite: 0.2, alpha: 0.85).cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
            (cText as NSString).draw(at: CGPoint(x: badgeX + 3, y: y + 2), withAttributes: Self.badgeCageAttrs)
            badgeX -= 3
        }

        if isVideo && !model.isClipFrameRateCompatible(clip) && w > 44 {
            let fpsText = "⚠ \(TimelineModel.formatFPSLabel(clip.mediaItem.frameRate))fps"
            let fSize = (fpsText as NSString).size(withAttributes: Self.badgeDarkAttrs)
            if badgeX - (fSize.width + 6) > x + 4 {
                badgeX -= (fSize.width + 6)
                let badgeRect = CGRect(x: badgeX, y: y + 2, width: fSize.width + 6, height: 12)
                ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.95).cgColor)
                ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
                ctx.fillPath()
                (fpsText as NSString).draw(at: CGPoint(x: badgeX + 3, y: y + 2), withAttributes: Self.badgeDarkAttrs)
            }
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
        case 1: return NSColor(calibratedRed: 0.36, green: 0.72, blue: 0.98, alpha: 1.0) // 1 — Blu chiaro
        case 2: return NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.85, alpha: 1.0) // 2 — Blu medio
        case 3: return NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.48, alpha: 1.0) // 3 — Blu scuro
        case 4: return NSColor(calibratedRed: 0.56, green: 0.24, blue: 0.74, alpha: 1.0) // 4 — Dialogo / Intera (Viola)
        default: return nil
        }
    }

    private func drawWaveform(for clip: TimelineClip, displayStart: CMTime, in rect: CGRect, ctx: CGContext) {
        guard rect.width > 4 else { return }

        let waveformHeight = max(8.0, rect.height - 10)
        let maxHalfH = waveformHeight * 0.5
        let centerY = rect.midY + 4

        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: 1, dy: 1))

        if let wf = AudioWaveformCache.shared.waveformData(for: clip.mediaItem.url), !wf.peaks.isEmpty {
            let clipStartSec = CMTimeGetSeconds(displayStart)
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

            let stepPx = (rect.width < 48 || pixelsPerSecond < 18.0) ? 2 : 1
            let cap = (colCount / stepPx) + 2
            var xs = [CGFloat]()
            var topPeakY = [CGFloat]()
            var botPeakY = [CGFloat]()
            var topRmsY = [CGFloat]()
            var botRmsY = [CGFloat]()
            xs.reserveCapacity(cap)
            topPeakY.reserveCapacity(cap)
            botPeakY.reserveCapacity(cap)
            topRmsY.reserveCapacity(cap)
            botRmsY.reserveCapacity(cap)

            let invPPS = 1.0 / pixelsPerSecond
            let stepSec = Double(stepPx) * invPPS
            var px = startPx
            while px < endPx {
                let x = CGFloat(px) + 0.5
                let t0 = Double(CGFloat(px) - headerWidth) * invPPS
                let src0 = sourceInSec + (t0 - clipStartSec) * speed
                let src1 = src0 + stepSec * speed

                let env = wf.displayEnvelope(from: src0, to: src1)
                let pAmp = max(0.8, CGFloat(env.peak) * maxHalfH)
                let rAmp = max(0.5, CGFloat(env.rms) * maxHalfH)

                xs.append(x)
                topPeakY.append(centerY - pAmp)
                botPeakY.append(centerY + pAmp)
                topRmsY.append(centerY - rAmp)
                botRmsY.append(centerY + rAmp)
                px += stepPx
            }

            guard !xs.isEmpty else {
                ctx.restoreGState()
                return
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

            // 2. Nucleo RMS interno luminoso
            if rect.height >= 36 {
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
            }

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

    private func drawClipManualMarkers(for clip: TimelineClip, displayStart: CMTime, in rect: CGRect, ctx: CGContext) {
        let sIn = CMTimeGetSeconds(clip.sourceIn)
        let sOut = CMTimeGetSeconds(clip.sourceOut)
        let dStart = CMTimeGetSeconds(displayStart)
        let spd = clip.speed > 0 ? clip.speed : 1.0
        let markerTimes = clip.markers
            .filter { $0 >= sIn - 0.005 && $0 <= sOut + 0.005 }
            .map { dStart + ($0 - sIn) / spd }
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
                let trackH = heightForVideoTrack(targetTrack)
                let trackY = yForVideoTrack(targetTrack, sepY: sepY)
                let rect = CGRect(x: x, y: trackY + 2, width: w, height: trackH - 4)

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
                let trackH = heightForAudioTrack(aTrackIdx)
                let trackY = yForAudioTrack(aTrackIdx, sepY: sepY)
                let rect = CGRect(x: x, y: trackY + 2, width: w, height: trackH - 4)

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
        let rulerTop = stickyRulerTopY
        let rulerBottom = rulerTop + rulerHeight
        // Left Column background (sticky al bordo sinistro visibile)
        let headerRect = CGRect(x: originX, y: rulerBottom, width: headerWidth, height: max(0, bounds.height - rulerBottom))
        ctx.setFillColor(NSColor(calibratedWhite: 0.095, alpha: 1.0).cgColor)
        ctx.fill(headerRect)

        ctx.saveGState()
        ctx.clip(to: CGRect(x: originX, y: rulerBottom, width: headerWidth + 1, height: max(0, bounds.height - rulerBottom)))

        ctx.setStrokeColor(NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokeLineSegments(between: [
            CGPoint(x: originX + headerWidth, y: rulerBottom),
            CGPoint(x: originX + headerWidth, y: bounds.height)
        ])

        // Video headers
        for track in model.videoTracks {
            let trackH = heightForVideoTrack(track.id)
            let trackY = yForVideoTrack(track.id, sepY: sepY)
            drawTrackHeaderItem(name: track.name, isVideo: true, isLocked: track.isLocked, isEnabled: track.isEnabled, originX: originX, y: trackY, height: trackH, ctx: ctx)
        }

        // Audio headers
        for track in model.audioTracks {
            let trackH = heightForAudioTrack(track.id)
            let trackY = yForAudioTrack(track.id, sepY: sepY)
            drawTrackHeaderItem(name: track.name, isVideo: false, isLocked: track.isLocked, isEnabled: track.isEnabled, originX: originX, y: trackY, height: trackH, ctx: ctx)
        }

        // Divisore centrale visibile anche nella colonna header (tra Video e Audio)
        let headerSepRect = CGRect(x: originX, y: sepY - 2, width: headerWidth, height: 4)
        ctx.setFillColor(NSColor(calibratedWhite: 0.04, alpha: 1.0).cgColor)
        ctx.fill(headerSepRect)
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.24, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeLineSegments(between: [
            CGPoint(x: originX, y: sepY),
            CGPoint(x: originX + headerWidth, y: sepY)
        ])
        ctx.restoreGState()
    }

    private static let lockActiveIcon = Lucide.image(.lock, size: 13, color: .systemOrange)
    private static let lockInactiveIcon = Lucide.image(.unlock, size: 13, color: NSColor(calibratedWhite: 0.45, alpha: 1.0))
    private static let eyeActiveIcon = Lucide.image(.eye, size: 14, color: NSColor(calibratedWhite: 0.88, alpha: 1.0))
    private static let eyeInactiveIcon = Lucide.image(.eyeOff, size: 14, color: NSColor(calibratedWhite: 0.42, alpha: 1.0))
    private static let muteActiveIcon = Lucide.image(.letterM, size: 13, color: .systemRed)
    private static let muteInactiveIcon = Lucide.image(.letterM, size: 13, color: NSColor(calibratedWhite: 0.45, alpha: 1.0))

    private func drawTrackHeaderItem(name: String, isVideo: Bool, isLocked: Bool, isEnabled: Bool, originX: CGFloat, y: CGFloat, height: CGFloat, ctx: CGContext) {
        let borderY = isVideo ? y : (y + height)
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokeLineSegments(between: [
            CGPoint(x: originX, y: borderY),
            CGPoint(x: originX + headerWidth, y: borderY)
        ])

        (name as NSString).draw(at: CGPoint(x: originX + 8, y: y + (height - 14) / 2), withAttributes: Self.trackHeaderNameAttrs)

        if !model.isSelection {
            let lockImg = isLocked ? Self.lockActiveIcon : Self.lockInactiveIcon
            let lockRect = NSRect(x: originX + 42, y: y + (height - 13) / 2, width: 13, height: 13)
            lockImg.draw(in: lockRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        }

        if isVideo {
            let eyeImg = isEnabled ? Self.eyeActiveIcon : Self.eyeInactiveIcon
            let eyeRect = NSRect(x: originX + 74, y: y + (height - 14) / 2, width: 14, height: 14)
            eyeImg.draw(in: eyeRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        } else {
            // Audio track: M letter icon — red when muted (!isEnabled), greyed out otherwise
            let muteImg = isEnabled ? Self.muteInactiveIcon : Self.muteActiveIcon
            let muteRect = NSRect(x: originX + 74, y: y + (height - 13) / 2, width: 13, height: 13)
            muteImg.draw(in: muteRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)
        }
    }

    private func drawRuler(ctx: CGContext, bounds: CGRect, visibleMinX: CGFloat) {
        let rulerTop = stickyRulerTopY
        let rulerBottom = rulerTop + rulerHeight
        let rulerStartX = visibleMinX + headerWidth
        let rulerEndX = min(bounds.width, visibleRect.maxX + 4)
        let rulerW = max(0, rulerEndX - rulerStartX)
        let rulerRect = CGRect(x: rulerStartX, y: rulerTop, width: rulerW, height: rulerHeight)
        ctx.setFillColor(NSColor(calibratedWhite: 0.115, alpha: 1.0).cgColor)
        ctx.fill(rulerRect)

        ctx.setStrokeColor(NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokeLineSegments(between: [
            CGPoint(x: rulerStartX, y: rulerBottom),
            CGPoint(x: rulerEndX, y: rulerBottom)
        ])

        let fps: Double = max(1.0, Double(model.format.fps))
        let frameSec: Double = 1.0 / fps
        let rawCandidates: [Double] = [frameSec, frameSec * 2.0, frameSec * 5.0, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        var candidateSteps: [Double] = []
        for s in rawCandidates where (candidateSteps.last.map { s > $0 + 0.0001 } ?? true) {
            candidateSteps.append(s)
        }
        let stepSec: Double = candidateSteps.first(where: { $0 * pixelsPerSecond >= 78.0 }) ?? 3600.0
        let subStepSec: Double = stepSec < 0.99
            ? (stepSec <= frameSec * 1.05 ? stepSec : frameSec)
            : (stepSec == 1.0 && frameSec * pixelsPerSecond >= 8.0 ? frameSec : stepSec / 5.0)
        let totalSeconds = totalContentSeconds
        let visStartSec = max(0.0, Double(visibleMinX) / pixelsPerSecond)
        let visEndSec = min(totalSeconds, Double(max(rulerStartX, visibleRect.maxX) - headerWidth) / pixelsPerSecond + stepSec)

        // Sotto-tacche secondarie (o singoli frame a zoom elevato)
        if subStepSec < stepSec - 0.0001 && subStepSec * pixelsPerSecond >= 6.0 {
            var st = max(0.0, floor(visStartSec / subStepSec) * subStepSec)
            var subSegments: [CGPoint] = []
            while st <= visEndSec {
                let sx = headerWidth + CGFloat(st * pixelsPerSecond)
                if sx >= rulerStartX && sx <= rulerEndX {
                    subSegments.append(CGPoint(x: sx, y: rulerBottom - 4))
                    subSegments.append(CGPoint(x: sx, y: rulerBottom))
                }
                st += subStepSec
            }
            if !subSegments.isEmpty {
                ctx.setStrokeColor(NSColor(calibratedWhite: 0.34, alpha: 0.85).cgColor)
                ctx.setLineWidth(0.75)
                ctx.strokeLineSegments(between: subSegments)
            }
        }

        // Tacche principali ed etichette tempo (con frame :FF a zoom profondo)
        var t = max(0.0, floor(visStartSec / stepSec) * stepSec)
        let showFrameTC = stepSec < 0.99
        let fpsInt = max(1, Int(fps.rounded()))
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.55, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.0)
        while t <= visEndSec {
            let x = headerWidth + CGFloat(t * pixelsPerSecond)
            if x >= rulerStartX && x <= rulerEndX {
                ctx.strokeLineSegments(between: [
                    CGPoint(x: x, y: rulerBottom - 8),
                    CGPoint(x: x, y: rulerBottom)
                ])

                let label: String
                if showFrameTC {
                    let frameIndex = max(0, Int((t * fps).rounded()))
                    let ff = frameIndex % fpsInt
                    let totalSecInt = frameIndex / fpsInt
                    let hrs = totalSecInt / 3600
                    let mins = (totalSecInt % 3600) / 60
                    let secs = totalSecInt % 60
                    label = hrs > 0
                        ? String(format: "%d:%02d:%02d:%02d", hrs, mins, secs, ff)
                        : String(format: "%02d:%02d:%02d", mins, secs, ff)
                } else {
                    let totalSecInt = Int(t.rounded())
                    let hrs = totalSecInt / 3600
                    let mins = (totalSecInt % 3600) / 60
                    let secs = totalSecInt % 60
                    label = hrs > 0
                        ? String(format: "%d:%02d:%02d", hrs, mins, secs)
                        : String(format: "%02d:%02d", mins, secs)
                }
                (label as NSString).draw(at: CGPoint(x: x + 2, y: rulerTop + 2), withAttributes: Self.rulerTimeAttrs)
            }
            t += stepSec
        }

        // Visualizzazione Gabbie Ritmate (Rhythmic Grid dinamica su tracce audio + timeline)
        let liveCages = model.activeCageIntervals()
        if model.isRhythmicGridVisible && !liveCages.isEmpty {
            let cageVisMinX = max(headerWidth, visibleRect.minX - 16)
            let cageVisMaxX = visibleRect.maxX + 16
            var dashedLines: [CGPoint] = []
            for cage in liveCages {
                let startX = headerWidth + CGFloat(cage.startSeconds * pixelsPerSecond)
                let endX = headerWidth + CGFloat(cage.endSeconds * pixelsPerSecond)
                let w = endX - startX

                if endX >= cageVisMinX && startX <= cageVisMaxX {
                    if startX >= headerWidth && startX <= cageVisMaxX {
                        dashedLines.append(CGPoint(x: startX, y: rulerBottom))
                        dashedLines.append(CGPoint(x: startX, y: bounds.height))
                    }

                    // Badge numerico gabbia nel righello (visibile solo a modalità gabbia attiva)
                    if model.isCageLockActive && w >= 16 && startX >= rulerStartX - 24 {
                        let badgeRect = CGRect(x: startX + 2, y: rulerBottom - 11, width: min(w - 4, 22), height: 10)
                        ctx.setFillColor(NSColor.systemCyan.withAlphaComponent(0.25).cgColor)
                        ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 2, cornerHeight: 2, transform: nil))
                        ctx.fillPath()

                        let cLabel = "\(cage.index + 1)"
                        (cLabel as NSString).draw(at: CGPoint(x: startX + 4, y: rulerBottom - 11.5), withAttributes: Self.rulerCageIndexAttrs)
                    }
                }
            }

            if let lastCage = liveCages.last {
                let endX = headerWidth + CGFloat(lastCage.endSeconds * pixelsPerSecond)
                if endX >= cageVisMinX && endX <= cageVisMaxX {
                    dashedLines.append(CGPoint(x: endX, y: rulerBottom))
                    dashedLines.append(CGPoint(x: endX, y: bounds.height))
                }
            }

            if !dashedLines.isEmpty {
                ctx.saveGState()
                let lineAlpha: CGFloat = model.isCageLockActive ? 0.35 : 0.05
                ctx.setStrokeColor(NSColor.systemCyan.withAlphaComponent(lineAlpha).cgColor)
                ctx.setLineWidth(1.0)
                ctx.setLineDash(phase: 0, lengths: [4, 4])
                ctx.strokeLineSegments(between: dashedLines)
                ctx.restoreGState()
            }

            // Etichetta BPM / conteggio gabbie in alto a sinistra nel righello (solo se modalità gabbia attiva)
            if model.isCageLockActive {
                let bpmPrefix = model.effectiveDetectedBPM.map { "\(String(format: "%.1f", $0)) BPM • " } ?? ""
                let bpmTag = "🎵 \(bpmPrefix)\(liveCages.count) gabbie"
                (bpmTag as NSString).draw(at: CGPoint(x: headerWidth + 6, y: rulerTop + 2), withAttributes: Self.rulerBpmTagAttrs)
            }
        }
    }

    private func markerHitTest(at localPoint: NSPoint) -> MarkerTarget? {
        let sepY = separatorY
        let stickyHeaderRight = max(0, visibleRect.minX) + headerWidth
        guard localPoint.x >= stickyHeaderRight else { return nil }

        func findMarkerInClip(_ clip: TimelineClip, displayStart: CMTime, trackY: CGFloat, rowHeight: CGFloat, isVideo: Bool) -> MarkerTarget? {
            guard localPoint.y >= trackY && localPoint.y <= trackY + rowHeight else { return nil }
            let cStart = CMTimeGetSeconds(displayStart)
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
            let trackH = heightForVideoTrack(track.id)
            let trackY = yForVideoTrack(track.id, sepY: sepY)
            for (clip, dStart) in model.displayedClips(isVideo: true, trackIndex: track.id) {
                if let hit = findMarkerInClip(clip, displayStart: dStart, trackY: trackY, rowHeight: trackH, isVideo: true) {
                    return hit
                }
            }
        }
        for track in model.audioTracks where !track.isLocked {
            let trackH = heightForAudioTrack(track.id)
            let trackY = yForAudioTrack(track.id, sepY: sepY)
            for (clip, dStart) in model.displayedClips(isVideo: false, trackIndex: track.id) {
                if let hit = findMarkerInClip(clip, displayStart: dStart, trackY: trackY, rowHeight: trackH, isVideo: false) {
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
            let trackH = heightForVideoTrack(track.id)
            let trackY = yForVideoTrack(track.id, sepY: sepY)
            if localPoint.y >= trackY && localPoint.y <= trackY + trackH {
                for (clip, dStart) in model.displayedClips(isVideo: true, trackIndex: track.id) where !clip.isEffectivelyLocked {
                    let clipX = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
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
                let trackH = heightForAudioTrack(track.id)
                let trackY = yForAudioTrack(track.id, sepY: sepY)
                if localPoint.y >= trackY && localPoint.y <= trackY + trackH {
                    for (clip, dStart) in model.displayedClips(isVideo: false, trackIndex: track.id) where !clip.isEffectivelyLocked {
                        let clipX = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
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
        } else if centerDividerHitTest(at: localPoint, sepY: sepY) || trackResizeHitTest(at: localPoint, sepY: sepY) != nil {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    public override func cursorUpdate(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let sepY = separatorY
        if isDraggingCenterDivider || resizingTrack != nil {
            NSCursor.resizeUpDown.set()
        } else if isHandPanning {
            NSCursor.closedHand.set()
        } else if markerHitTest(at: localPoint) != nil {
            NSCursor.resizeLeftRight.set()
        } else if let edge = hoveredClipEdge {
            switch edge {
            case .start: NSCursor.resizeLeft.set()
            case .end: NSCursor.resizeRight.set()
            }
        } else if centerDividerHitTest(at: localPoint, sepY: sepY) || trackResizeHitTest(at: localPoint, sepY: sepY) != nil {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    private func prepareDragSelectionState() {
        preDragVideoTrackCount = model.videoTracks.count
        preDragAudioTrackCount = model.audioTracks.count

        var states: [DraggedClipInitialState] = []
        var addedIds: Set<UUID> = []

        func appendClipIfUnlocked(_ clip: TimelineClip, isVideo: Bool) {
            guard !clip.isEffectivelyLocked, addedIds.insert(clip.id).inserted else { return }
            states.append(DraggedClipInitialState(
                id: clip.id,
                isVideo: isVideo,
                initialStartTime: clip.timelineStart,
                initialTrackIndex: clip.trackIndex
            ))
        }

        for vTrack in model.videoTracks where !vTrack.isLocked {
            for clip in vTrack.clips where model.selectedClipIds.contains(clip.id) {
                appendClipIfUnlocked(clip, isVideo: true)
                if model.isLinkActive, let lId = clip.linkGroupId {
                    for aTrack in model.audioTracks where !aTrack.isLocked {
                        if let aClip = aTrack.clips.first(where: { $0.linkGroupId == lId }) {
                            appendClipIfUnlocked(aClip, isVideo: false)
                        }
                    }
                }
            }
        }

        for aTrack in model.audioTracks where !aTrack.isLocked {
            for clip in aTrack.clips where model.selectedClipIds.contains(clip.id) {
                appendClipIfUnlocked(clip, isVideo: false)
                if model.isLinkActive, let lId = clip.linkGroupId {
                    for vTrack in model.videoTracks where !vTrack.isLocked {
                        if let vClip = vTrack.clips.first(where: { $0.linkGroupId == lId }) {
                            appendClipIfUnlocked(vClip, isVideo: true)
                        }
                    }
                }
            }
        }

        multiDragInitialStates = states
        multiDragMinStartSeconds = states.map { CMTimeGetSeconds($0.initialStartTime) }.min() ?? 0.0
        currentMultiDragMoves = []
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
        window?.makeFirstResponder(self)
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

        // 0b. Clicking inside active Tab Slip HUD bar drags it directly
        if isTabKeyHeld && isFloatingSlipActive && !slipLastHudRect.isEmpty && slipLastHudRect.contains(localPoint) {
            isSlipDragging = true
            slipDragInitialX = localPoint.x
            slipDragAnchorSourceIn = slipCurrentSourceIn
            needsDisplay = true
            return
        }

        // 1. Clicked in Ruler: Scrub playhead
        if localPoint.y <= stickyRulerTopY + rulerHeight {
            guard localPoint.x >= stickyHeaderRight else { return }
            isScrubbingRuler = true
            onUserPlayheadScrubbed?()
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

        // 2a. Center Video/Audio Divider Drag / Double-Click Reset to exact center
        if centerDividerHitTest(at: localPoint, sepY: sepY) {
            if event.clickCount == 2 {
                customSeparatorOffsetY = nil
                onCanvasWidthChanged?()
                if let clipView = enclosingScrollView?.contentView {
                    let maxOriginY = max(0.0, frame.height - clipView.bounds.height)
                    let targetY = min(maxOriginY, topVideoOverflow(forViewportHeight: visibleViewportHeight))
                    clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
                    enclosingScrollView?.reflectScrolledClipView(clipView)
                }
                needsDisplay = true
                return
            }
            isDraggingCenterDivider = true
            centerDividerInitialScreenY = NSEvent.mouseLocation.y
            centerDividerInitialOffsetY = clampedSeparatorOffsetY(forViewportHeight: visibleViewportHeight)
            NSCursor.resizeUpDown.set()
            return
        }

        // 2b. Track Height Border Drag / Double-Click Reset (before header buttons & clips)
        if let resizeHit = trackResizeHitTest(at: localPoint, sepY: sepY) {
            if event.clickCount == 2 {
                if resizeHit.isVideo {
                    model.videoTrackHeights.removeValue(forKey: resizeHit.trackId)
                } else {
                    model.audioTrackHeights.removeValue(forKey: resizeHit.trackId)
                }
                onCanvasWidthChanged?()
                needsDisplay = true
                return
            }
            resizingTrack = resizeHit
            trackResizeInitialScreenY = NSEvent.mouseLocation.y
            trackResizeInitialHeight = resizeHit.isVideo ? heightForVideoTrack(resizeHit.trackId) : heightForAudioTrack(resizeHit.trackId)
            NSCursor.resizeUpDown.set()
            return
        }

        // 2b. Clicked in Track Header area (Left Sticky Column): Toggle Lock / Enable / Mute
        if localPoint.x < stickyHeaderRight {
            let relX = localPoint.x - stickyMinX
            // Check Video Tracks
            for track in model.videoTracks {
                let trackH = heightForVideoTrack(track.id)
                let trackY = yForVideoTrack(track.id, sepY: sepY)
                if localPoint.y >= trackY && localPoint.y <= trackY + trackH {
                    if !model.isSelection && relX >= 38 && relX <= 64 {
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
                let trackH = heightForAudioTrack(track.id)
                let trackY = yForAudioTrack(track.id, sepY: sepY)
                if localPoint.y >= trackY && localPoint.y <= trackY + trackH {
                    if !model.isSelection && relX >= 38 && relX <= 64 {
                        model.toggleTrackLock(id: track.id, isVideo: false)
                        needsDisplay = true
                        return
                    } else if relX >= 70 && relX <= 96 {
                        model.toggleTrackEnabled(id: track.id, isVideo: false)
                        needsDisplay = true
                        notifyModified("Muta/Attiva Traccia A\(track.id + 1)")
                        return
                    }
                }
            }
            return
        }

        // 3. Clicked on a Video Clip
        for track in model.videoTracks {
            let trackH = heightForVideoTrack(track.id)
            let trackY = yForVideoTrack(track.id, sepY: sepY)
            if localPoint.y >= trackY && localPoint.y <= trackY + trackH {
                for (clip, dStart) in model.displayedClips(isVideo: true, trackIndex: track.id) {
                    let clipX = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
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

                            if event.clickCount == 2 {
                                onClipDoubleClicked?(clip)
                                needsDisplay = true
                                return
                            }

                            if clip.isEffectivelyLocked {
                                let msg = clip.isApproved
                                    ? "Clip '\(clip.mediaItem.name)' approvata OK (\\ per sbloccare)."
                                    : "Clip '\(clip.mediaItem.name)' bloccata (L per sbloccare)."
                                DebugLogger.shared.log(msg, level: .info)
                                needsDisplay = true
                                return
                            }

                            // Tab + Click/Drag -> SEMPRE prioritario su edge trimming: slip interno senza mai cambiare i bordi
                            if isTabKeyHeld {
                                if isFloatingSlipActive && slipClipId == clip.id {
                                    isSlipDragging = true
                                    slipDragInitialX = localPoint.x
                                    slipDragAnchorSourceIn = slipCurrentSourceIn
                                    slipClipFrame = CGRect(x: clipX, y: trackY + 2, width: clipW, height: trackH - 4)
                                    needsDisplay = true
                                    return
                                }
                                let frame = CGRect(x: clipX, y: trackY + 2, width: clipW, height: trackH - 4)
                                if beginFloatingSlip(for: clip, displayStart: dStart, clipFrame: frame, startDragging: true, dragX: localPoint.x) {
                                    return
                                }
                            }

                            let edgeMargin: CGFloat = 8.0
                            if localPoint.x <= clipX + edgeMargin {
                                isTrimmingEdge = true
                                didTrimCurrentEdge = false
                                activeTrimClipId = clip.id
                                activeTrimIsStart = true
                                activeTrimIsVideo = true
                                trimStartAnchorX = localPoint.x
                                trimInitialEdgeTimeSec = CMTimeGetSeconds(clip.timelineStart)
                                dragInitialPoint = localPoint
                                needsDisplay = true
                                return
                            } else if localPoint.x >= clipX + clipW - edgeMargin {
                                isTrimmingEdge = true
                                didTrimCurrentEdge = false
                                activeTrimClipId = clip.id
                                activeTrimIsStart = false
                                activeTrimIsVideo = true
                                trimStartAnchorX = localPoint.x
                                trimInitialEdgeTimeSec = CMTimeGetSeconds(clip.timelineEnd)
                                dragInitialPoint = localPoint
                                needsDisplay = true
                                return
                            }

                            if model.isSmartFilterActive {
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
                            lastValidDragTime = clip.timelineStart
                            lastValidDragTrackIndex = track.id
                            prepareDragSelectionState()
                            lastValidMultiDragMoves = multiDragInitialStates.map {
                                (id: $0.id, toTrack: $0.initialTrackIndex, isVideo: $0.isVideo, newStartTime: $0.initialStartTime)
                            }
                            isCageReorderDrag = model.isCageLockActive && !model.activeCageIntervals().isEmpty && multiDragInitialStates.count <= 1
                            cageReorderTargetIndex = clip.cageIndex ?? model.cageIndex(at: clip.timelineStart)
                            cageReorderTargetBlocked = false

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
            let trackH = heightForAudioTrack(track.id)
            let trackY = yForAudioTrack(track.id, sepY: sepY)
            if localPoint.y >= trackY && localPoint.y <= trackY + trackH {
                for (clip, dStart) in model.displayedClips(isVideo: false, trackIndex: track.id) {
                    let clipX = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
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

                            if event.clickCount == 2 {
                                onClipDoubleClicked?(clip)
                                needsDisplay = true
                                return
                            }

                            if clip.isEffectivelyLocked {
                                let msg = clip.isApproved
                                    ? "Clip '\(clip.mediaItem.name)' approvata OK (\\ per sbloccare)."
                                    : "Clip '\(clip.mediaItem.name)' bloccata (L per sbloccare)."
                                DebugLogger.shared.log(msg, level: .info)
                                needsDisplay = true
                                return
                            }

                            // Tab + Click/Drag -> SEMPRE prioritario su edge trimming anche su tracce audio
                            if isTabKeyHeld {
                                if isFloatingSlipActive && slipClipId == clip.id {
                                    isSlipDragging = true
                                    slipDragInitialX = localPoint.x
                                    slipDragAnchorSourceIn = slipCurrentSourceIn
                                    slipClipFrame = CGRect(x: clipX, y: trackY + 2, width: clipW, height: trackH - 4)
                                    needsDisplay = true
                                    return
                                }
                                let frame = CGRect(x: clipX, y: trackY + 2, width: clipW, height: trackH - 4)
                                if beginFloatingSlip(for: clip, displayStart: dStart, clipFrame: frame, startDragging: true, dragX: localPoint.x) {
                                    return
                                }
                            }

                            let edgeMargin: CGFloat = 8.0
                            if localPoint.x <= clipX + edgeMargin {
                                isTrimmingEdge = true
                                didTrimCurrentEdge = false
                                activeTrimClipId = clip.id
                                activeTrimIsStart = true
                                activeTrimIsVideo = false
                                trimStartAnchorX = localPoint.x
                                trimInitialEdgeTimeSec = CMTimeGetSeconds(clip.timelineStart)
                                dragInitialPoint = localPoint
                                needsDisplay = true
                                return
                            } else if localPoint.x >= clipX + clipW - edgeMargin {
                                isTrimmingEdge = true
                                didTrimCurrentEdge = false
                                activeTrimClipId = clip.id
                                activeTrimIsStart = false
                                activeTrimIsVideo = false
                                trimStartAnchorX = localPoint.x
                                trimInitialEdgeTimeSec = CMTimeGetSeconds(clip.timelineEnd)
                                dragInitialPoint = localPoint
                                needsDisplay = true
                                return
                            }

                            if model.isSmartFilterActive {
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
                            lastValidDragTime = clip.timelineStart
                            lastValidDragTrackIndex = track.id
                            prepareDragSelectionState()
                            lastValidMultiDragMoves = multiDragInitialStates.map {
                                (id: $0.id, toTrack: $0.initialTrackIndex, isVideo: $0.isVideo, newStartTime: $0.initialStartTime)
                            }

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
        // (Timeline grabbing is triggered via middle mouse button drag)
        isMarqueeSelecting = true
        marqueeStartPoint = localPoint
        marqueeCurrentPoint = localPoint
        marqueeInitialSelectedIds = isShift ? model.selectedClipIds : []

        if !isShift {
            model.selectedClipIds.removeAll()
        }
        needsDisplay = true
    }

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        window?.makeFirstResponder(self)
        onSectionActivated?()
        guard let clipView = enclosingScrollView?.contentView else { return }
        isHandPanning = true
        handPanInitialScreenPoint = NSEvent.mouseLocation
        handPanInitialOrigin = clipView.bounds.origin
        NSCursor.closedHand.set()
    }

    public override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2, isHandPanning, let clipView = enclosingScrollView?.contentView else {
            super.otherMouseDragged(with: event)
            return
        }
        let currentScreen = NSEvent.mouseLocation
        let dx = currentScreen.x - handPanInitialScreenPoint.x
        let maxOriginX = max(0.0, frame.width - clipView.bounds.width)
        let targetX = max(0.0, min(maxOriginX, handPanInitialOrigin.x - dx))
        clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.origin.y))
        enclosingScrollView?.reflectScrolledClipView(clipView)
        NSCursor.closedHand.set()
    }

    public override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        if isHandPanning {
            isHandPanning = false
            NSCursor.arrow.set()
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let sepY = separatorY

        if isDraggingCenterDivider {
            let viewportH = visibleViewportHeight
            let prevOverflow = topVideoOverflow(forViewportHeight: viewportH)
            let dy = NSEvent.mouseLocation.y - centerDividerInitialScreenY
            let usableH = max(80, viewportH - rulerHeight)
            let minOff = min(24.0, usableH * 0.25)
            let maxOff = max(minOff, usableH - 28.0)
            customSeparatorOffsetY = max(minOff, min(maxOff, centerDividerInitialOffsetY - dy))
            let newOverflow = topVideoOverflow(forViewportHeight: viewportH)
            onCanvasWidthChanged?()
            if abs(newOverflow - prevOverflow) > 0.25, let clipView = enclosingScrollView?.contentView {
                let maxOriginY = max(0.0, frame.height - clipView.bounds.height)
                let targetY = max(0.0, min(maxOriginY, clipView.bounds.origin.y + (newOverflow - prevOverflow)))
                clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: targetY))
                enclosingScrollView?.reflectScrolledClipView(clipView)
            }
            NSCursor.resizeUpDown.set()
            needsDisplay = true
            return
        }

        if let rt = resizingTrack {
            let screenY = NSEvent.mouseLocation.y
            let dy = screenY - trackResizeInitialScreenY
            if rt.isVideo {
                let clamped = max(minVideoRowHeight, min(maxVideoRowHeight, trackResizeInitialHeight + dy))
                model.videoTrackHeights[rt.trackId] = Double(clamped)
            } else {
                let clamped = max(minAudioRowHeight, min(maxAudioRowHeight, trackResizeInitialHeight - dy))
                model.audioTrackHeights[rt.trackId] = Double(clamped)
            }
            onCanvasWidthChanged?()
            NSCursor.resizeUpDown.set()
            needsDisplay = true
            return
        }

        if isHandPanning, let clipView = enclosingScrollView?.contentView {
            let currentScreen = NSEvent.mouseLocation
            let dx = currentScreen.x - handPanInitialScreenPoint.x
            let maxOriginX = max(0.0, frame.width - clipView.bounds.width)
            let targetX = max(0.0, min(maxOriginX, handPanInitialOrigin.x - dx))
            clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.origin.y))
            enclosingScrollView?.reflectScrolledClipView(clipView)
            NSCursor.closedHand.set()
            return
        }

        if isFloatingSlipActive, isSlipDragging, let clipId = slipClipId {
            let totalRange = max(0.05, slipBoundsMax - slipBoundsMin)
            let hudW = slipHUDWidth()
            let trackW = max(120.0, hudW - 20.0)
            let dx = localPoint.x - slipDragInitialX
            let deltaSec = Double(dx / trackW) * totalRange
            let desiredIn = slipDragAnchorSourceIn + deltaSec
            if let res = model.slipClipWithinSelection(clipId: clipId, newSourceIn: desiredIn) {
                slipCurrentSourceIn = res.newIn
                emitSlipDualPreview(forClipId: clipId, currentSourceIn: res.newIn, sourceDur: slipSourceDur)
                needsDisplay = true
            }
            return
        }

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
                    let cStart = CMTimeGetSeconds(model.displayedStartTime(for: clip, isVideo: isVideo))
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
                if model.isCageLockActive {
                    if let rolled = model.rollCageBoundaryWithAdjacentClips(
                        oldSeconds: mDrag.timelineSec,
                        newSeconds: targetTimelineSec,
                        audioClipId: clipId,
                        isBeatMarker: true,
                        markerSourceSec: oldSrc
                    ), let newSrc = rolled.newMarkerSourceSec {
                        mDrag.kind = .clipBeat(clipId: clipId, sourceSec: newSrc)
                        mDrag.timelineSec = rolled.newTimelineSec
                        draggingMarker = mDrag
                        selectedMarker = mDrag
                        hoveredMarker = mDrag
                        activeSnapLineTime = CMTime(seconds: rolled.newTimelineSec, preferredTimescale: 600)
                        didMoveDraggingMarker = true
                        needsDisplay = true
                    }
                } else {
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
                }
            case .timelineCageBar(let oldSec):
                if model.isCageLockActive {
                    if let rolled = model.rollCageBoundaryWithAdjacentClips(
                        oldSeconds: oldSec,
                        newSeconds: targetTimelineSec,
                        audioClipId: nil,
                        isBeatMarker: false,
                        markerSourceSec: nil
                    ) {
                        mDrag.kind = .timelineCageBar(seconds: rolled.newTimelineSec)
                        mDrag.timelineSec = rolled.newTimelineSec
                        draggingMarker = mDrag
                        selectedMarker = mDrag
                        hoveredMarker = mDrag
                        activeSnapLineTime = CMTime(seconds: rolled.newTimelineSec, preferredTimescale: 600)
                        didMoveDraggingMarker = true
                        needsDisplay = true
                    }
                } else if let updatedSec = model.moveTimelineCageBoundary(from: oldSec, to: targetTimelineSec) {
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
            if model.isCageLockActive && model.isSnappingActive && activeTrimIsVideo && !model.activeCageIntervals().isEmpty {
                let targetX = max(headerWidth, localPoint.x)
                let cursorSec = max(0, Double(targetX - headerWidth) / pixelsPerSecond)
                let didTrim = model.trimClipEdgeInCages(
                    clipId: clipId,
                    isStart: activeTrimIsStart,
                    targetTimeSeconds: cursorSec
                )
                if didTrim {
                    didTrimCurrentEdge = true
                    dragInitialPoint = localPoint
                    updateWidth()
                    needsDisplay = true
                }
            } else if !activeTrimIsVideo && model.isSnappingActive {
                let rawEdgeSec = max(0.0, trimInitialEdgeTimeSec + Double(localPoint.x - trimStartAnchorX) / pixelsPerSecond)
                let snapThresholdSec = 10.0 / pixelsPerSecond
                var focalPts = model.timelineFocalPoints(excludingClipIds: [clipId])
                let playheadSec = CMTimeGetSeconds(playbackController.currentTime)
                if playheadSec.isFinite && playheadSec >= 0 {
                    focalPts.append(playheadSec)
                }

                var bestPt: Double? = nil
                var bestDiff = snapThresholdSec
                for pt in focalPts {
                    let diff = abs(rawEdgeSec - pt)
                    if diff < bestDiff {
                        bestDiff = diff
                        bestPt = pt
                    }
                }

                let desiredEdgeSec = bestPt ?? rawEdgeSec
                activeSnapLineTime = bestPt.map { CMTime(seconds: $0, preferredTimescale: 600) }

                var currentEdgeSec: Double? = nil
                for track in model.audioTracks {
                    if let c = track.clips.first(where: { $0.id == clipId }) {
                        currentEdgeSec = activeTrimIsStart ? CMTimeGetSeconds(c.timelineStart) : CMTimeGetSeconds(c.timelineEnd)
                        break
                    }
                }
                if let curEdge = currentEdgeSec {
                    let deltaSec = desiredEdgeSec - curEdge
                    if abs(deltaSec) >= 0.0005 {
                        let didTrim = model.trimClipEdge(
                            clipId: clipId,
                            isStart: activeTrimIsStart,
                            deltaSeconds: deltaSec,
                            isVideo: false
                        )
                        if didTrim {
                            didTrimCurrentEdge = true
                            dragInitialPoint = localPoint
                            updateWidth()
                        }
                    }
                }
                needsDisplay = true
            } else {
                activeSnapLineTime = nil
                let deltaX = localPoint.x - dragInitialPoint.x
                let deltaSec = Double(deltaX) / pixelsPerSecond
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
            return
        }

        if isScrubbingRuler {
            onUserPlayheadScrubbed?()
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
            enclosingScrollView?.contentView.autoscroll(with: event)

            if isCageReorderDrag {
                let cursorSec = max(0.0, Double(max(headerWidth, localPoint.x) - headerWidth) / pixelsPerSecond)
                let cages = model.activeCageIntervals()
                if let hoveredCage = cages.first(where: { cursorSec >= $0.startSeconds && cursorSec <= $0.endSeconds })
                    ?? model.nearestCageStart(to: cursorSec) {
                    cageReorderTargetIndex = hoveredCage.index
                    let lockedClips = (dragInitialTrackIndex < model.videoTracks.count ? model.videoTracks[dragInitialTrackIndex].clips : []).filter { $0.isEffectivelyLocked }
                    cageReorderTargetBlocked = lockedClips.contains { lc in
                        let ls = CMTimeGetSeconds(lc.timelineStart)
                        let le = CMTimeGetSeconds(lc.timelineEnd)
                        return min(le, hoveredCage.endSeconds) - max(ls, hoveredCage.startSeconds) > 0.02
                    }
                }
                needsDisplay = true
                return
            }

            let deltaX = localPoint.x - dragInitialPoint.x
            let deltaSeconds = Double(deltaX) / pixelsPerSecond
            let rawSeconds = max(0, CMTimeGetSeconds(dragInitialStartTime) + deltaSeconds)
            var newTime = CMTime(seconds: rawSeconds, preferredTimescale: 600)

            var clipDuration = CMTime(seconds: 1.0, preferredTimescale: 600)
            var draggedClipObj: TimelineClip? = nil
            if draggedClipIsVideo {
                for track in model.videoTracks {
                    if let c = track.clips.first(where: { $0.id == clipId }) { clipDuration = c.duration; draggedClipObj = c; break }
                }
            } else {
                for track in model.audioTracks {
                    if let c = track.clips.first(where: { $0.id == clipId }) { clipDuration = c.duration; draggedClipObj = c; break }
                }
            }

            // Target Track calculation (computed before snap so audio beat-snapping knows target track vs other tracks)
            var targetTrackIndex = dragInitialTrackIndex
            let maxVAllowed = min(model.maxVideoTracks - 1, preDragVideoTrackCount)
            let maxAAllowed = min(model.maxAudioTracks - 1, preDragAudioTrackCount)

            if draggedClipIsVideo {
                targetTrackIndex = videoTrackIndex(atY: localPoint.y, sepY: sepY, maxTrackIndex: maxVAllowed)
                if targetTrackIndex == model.videoTracks.count && targetTrackIndex <= maxVAllowed {
                    model.ensureVideoTrack(id: targetTrackIndex)
                    onCanvasWidthChanged?()
                }
            } else {
                targetTrackIndex = audioTrackIndex(atY: localPoint.y, sepY: sepY, maxTrackIndex: maxAAllowed)
                if targetTrackIndex == model.audioTracks.count && targetTrackIndex <= maxAAllowed {
                    model.ensureAudioTrack(id: targetTrackIndex)
                    onCanvasWidthChanged?()
                }
            }

            if (draggedClipIsVideo && model.videoTracks[targetTrackIndex].isLocked) ||
               (!draggedClipIsVideo && model.audioTracks[targetTrackIndex].isLocked) {
                targetTrackIndex = dragInitialTrackIndex
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
                let snapRes = model.snap(
                    startTime: newTime,
                    duration: clipDuration,
                    playhead: playbackController.currentTime,
                    thresholdSeconds: snapThreshold,
                    draggedClip: draggedClipObj,
                    targetTrackIndex: targetTrackIndex,
                    isVideo: draggedClipIsVideo
                )
                if snapRes.didSnap {
                    newTime = snapRes.snappedTime
                    activeSnapLineTime = snapRes.snapPoint
                } else {
                    activeSnapLineTime = nil
                }
            }

            // Clamp group horizontal delta so no selected clip goes < 0s
            let rawDeltaSec = CMTimeGetSeconds(newTime) - CMTimeGetSeconds(dragInitialStartTime)
            let clampedDeltaSec = max(-multiDragMinStartSeconds, rawDeltaSec)
            let effectiveNewTime = CMTime(seconds: max(0.0, CMTimeGetSeconds(dragInitialStartTime) + clampedDeltaSec), preferredTimescale: 600)

            // Compute vertical delta across selected same-media clips safely
            var trackDelta = targetTrackIndex - dragInitialTrackIndex
            if trackDelta != 0 && multiDragInitialStates.count > 1 {
                let maxTrackCap = draggedClipIsVideo ? maxVAllowed : maxAAllowed
                for st in multiDragInitialStates where st.isVideo == draggedClipIsVideo {
                    let candidateTrack = st.initialTrackIndex + trackDelta
                    if candidateTrack < 0 || candidateTrack > maxTrackCap {
                        trackDelta = 0
                        break
                    }
                    if draggedClipIsVideo {
                        if candidateTrack == model.videoTracks.count && candidateTrack <= maxVAllowed {
                            model.ensureVideoTrack(id: candidateTrack)
                        }
                        if candidateTrack < model.videoTracks.count && model.videoTracks[candidateTrack].isLocked {
                            trackDelta = 0
                            break
                        }
                    } else {
                        if candidateTrack == model.audioTracks.count && candidateTrack <= maxAAllowed {
                            model.ensureAudioTrack(id: candidateTrack)
                        }
                        if candidateTrack < model.audioTracks.count && model.audioTracks[candidateTrack].isLocked {
                            trackDelta = 0
                            break
                        }
                    }
                }
                if trackDelta == 0 {
                    targetTrackIndex = dragInitialTrackIndex
                }
            }

            if multiDragInitialStates.count > 1 {
                var planned: [(id: UUID, toTrack: Int, isVideo: Bool, newStartTime: CMTime)] = []
                var hasLockedCollision = false
                for st in multiDragInitialStates {
                    let destTrack = (st.isVideo == draggedClipIsVideo) ? (st.initialTrackIndex + trackDelta) : st.initialTrackIndex
                    let destTime = CMTime(seconds: max(0.0, CMTimeGetSeconds(st.initialStartTime) + clampedDeltaSec), preferredTimescale: 600)
                    let tracks = st.isVideo ? model.videoTracks : model.audioTracks
                    let dur = tracks.compactMap { $0.clips.first(where: { $0.id == st.id })?.duration }.first ?? CMTime(seconds: 0.1, preferredTimescale: 600)
                    if model.hasLockedClipOverlap(start: destTime, end: CMTimeAdd(destTime, dur), trackIndex: destTrack, isVideo: st.isVideo, excludingClipIds: [st.id]) {
                        hasLockedCollision = true
                        break
                    }
                    planned.append((id: st.id, toTrack: destTrack, isVideo: st.isVideo, newStartTime: destTime))
                }
                let finalMoves = hasLockedCollision ? lastValidMultiDragMoves : planned
                if !hasLockedCollision {
                    lastValidMultiDragMoves = finalMoves
                    lastValidDragTime = effectiveNewTime
                    lastValidDragTrackIndex = targetTrackIndex
                } else {
                    currentDragTime = lastValidDragTime
                    currentDragTrackIndex = lastValidDragTrackIndex
                }
                for mv in finalMoves {
                    model.previewMoveClip(id: mv.id, toTrack: mv.toTrack, isVideo: mv.isVideo, newStartTime: mv.newStartTime)
                }
                currentMultiDragMoves = finalMoves
            } else {
                var resolvedTrack = targetTrackIndex
                var resolvedTime = effectiveNewTime
                if let candidateTime = model.resolveNonLockedStartTime(proposedStart: effectiveNewTime, duration: clipDuration, trackIndex: targetTrackIndex, isVideo: draggedClipIsVideo, excludingClipIds: [clipId]) {
                    let deltaSec = CMTimeGetSeconds(candidateTime) - CMTimeGetSeconds(dragInitialStartTime)
                    var companionValid = true
                    if model.isLinkActive, let cId = linkedCompanionId {
                        let compStartSec = max(0, CMTimeGetSeconds(linkedCompanionInitialStart) + deltaSec)
                        let compTime = CMTime(seconds: compStartSec, preferredTimescale: 600)
                        let compTracks = !draggedClipIsVideo ? model.videoTracks : model.audioTracks
                        let compDur = compTracks.compactMap { $0.clips.first(where: { $0.id == cId })?.duration }.first ?? clipDuration
                        if model.hasLockedClipOverlap(start: compTime, end: CMTimeAdd(compTime, compDur), trackIndex: linkedCompanionInitialTrack, isVideo: !draggedClipIsVideo, excludingClipIds: [cId]) {
                            companionValid = false
                        }
                    }
                    if companionValid {
                        resolvedTime = candidateTime
                        lastValidDragTime = resolvedTime
                        lastValidDragTrackIndex = resolvedTrack
                    } else {
                        resolvedTime = lastValidDragTime
                        resolvedTrack = lastValidDragTrackIndex
                    }
                } else {
                    resolvedTime = lastValidDragTime
                    resolvedTrack = lastValidDragTrackIndex
                }

                currentDragTime = resolvedTime
                currentDragTrackIndex = resolvedTrack
                model.previewMoveClip(id: clipId, toTrack: resolvedTrack, isVideo: draggedClipIsVideo, newStartTime: resolvedTime)
                if model.isLinkActive, let cId = linkedCompanionId {
                    let resolvedDeltaSec = CMTimeGetSeconds(resolvedTime) - CMTimeGetSeconds(dragInitialStartTime)
                    let compStartSec = max(0, CMTimeGetSeconds(linkedCompanionInitialStart) + resolvedDeltaSec)
                    let compTime = CMTime(seconds: compStartSec, preferredTimescale: 600)
                    model.previewMoveClip(id: cId, toTrack: linkedCompanionInitialTrack, isVideo: !draggedClipIsVideo, newStartTime: compTime)
                }
                currentMultiDragMoves = []
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
                let trackH = heightForVideoTrack(track.id)
                let trackY = yForVideoTrack(track.id, sepY: sepY)
                for (clip, dStart) in model.displayedClips(isVideo: true, trackIndex: track.id) {
                    let clipX = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
                    let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                    let clipRect = NSRect(x: clipX, y: trackY + 2, width: clipW, height: trackH - 4)
                    if rect.intersects(clipRect) {
                        newlySelected.insert(clip.id)
                    }
                }
            }

            for track in model.audioTracks {
                let trackH = heightForAudioTrack(track.id)
                let trackY = yForAudioTrack(track.id, sepY: sepY)
                for (clip, dStart) in model.displayedClips(isVideo: false, trackIndex: track.id) {
                    let clipX = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
                    let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                    let clipRect = NSRect(x: clipX, y: trackY + 2, width: clipW, height: trackH - 4)
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

        if isDraggingCenterDivider || resizingTrack != nil {
            isDraggingCenterDivider = false
            resizingTrack = nil
            onCanvasWidthChanged?()
            NSCursor.arrow.set()
            return
        }

        if isFloatingSlipActive {
            if isSlipDragging {
                isSlipDragging = false
                slipDragAnchorSourceIn = slipCurrentSourceIn
                needsDisplay = true
            }
            if !isTabKeyHeld {
                finishFloatingSlipIfActive()
            }
            return
        }

        if isHandPanning {
            isHandPanning = false
            NSCursor.arrow.set()
            return
        }

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
            let wasCageReorder = isCageReorderDrag
            let reorderTarget = cageReorderTargetIndex
            let reorderBlocked = cageReorderTargetBlocked
            isCageReorderDrag = false
            cageReorderTargetIndex = nil
            cageReorderTargetBlocked = false

            if wasCageReorder {
                draggedClipId = nil
                linkedCompanionId = nil
                multiDragInitialStates.removeAll()
                currentMultiDragMoves.removeAll()
                if !reorderBlocked, let targetIdx = reorderTarget,
                   model.reorderClipInCages(clipId: clipId, toCageIndex: targetIdx) {
                    model.trimEmptyTracksCreatedSince(videoCount: preDragVideoTrackCount, audioCount: preDragAudioTrackCount)
                    updateWidth()
                    notifyModified("Riordina Clip in Gabbie")
                }
                needsDisplay = true
                return
            }

            let savedCompanionId = model.isLinkActive ? linkedCompanionId : nil
            let movesToCommit = currentMultiDragMoves
            draggedClipId = nil
            linkedCompanionId = nil
            multiDragInitialStates.removeAll()
            currentMultiDragMoves.removeAll()

            if movesToCommit.count > 1 {
                model.commitMoveClips(movesToCommit)
            } else {
                model.commitMoveClip(
                    id: clipId,
                    toTrack: currentDragTrackIndex,
                    isVideo: draggedClipIsVideo,
                    newStartTime: currentDragTime,
                    companionId: savedCompanionId
                )
            }

            model.trimEmptyTracksCreatedSince(videoCount: preDragVideoTrackCount, audioCount: preDragAudioTrackCount)
            updateWidth()
            notifyModified(movesToCommit.count > 1 ? "Sposta Clip Selezionate" : "Sposta Clip in Timeline")
            needsDisplay = true
        } else {
            draggedClipId = nil
            linkedCompanionId = nil
            multiDragInitialStates.removeAll()
            currentMultiDragMoves.removeAll()
            if isMarqueeSelecting {
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
        if let clipView = enclosingScrollView?.contentView,
           frame.height <= clipView.bounds.height + 1.0,
           abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) && abs(event.scrollingDeltaX) < 0.5 {
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 14.0
            let maxX = max(0, frame.width - clipView.bounds.width)
            let targetX = max(0, min(maxX, clipView.bounds.origin.x - step))
            if abs(targetX - clipView.bounds.origin.x) > 0.01 {
                clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.origin.y))
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
        window?.makeFirstResponder(self)
        onSectionActivated?()
        let localPoint = convert(event.locationInWindow, from: nil)
        guard localPoint.y > rulerHeight else { return }

        var clickedClip: (clip: TimelineClip, displayStart: CMTime, isVideo: Bool)? = nil
        let sepY = separatorY
        let stickyHeaderRight = max(0, visibleRect.minX) + headerWidth

        if localPoint.x >= stickyHeaderRight {
            for track in model.videoTracks {
                let trackH = heightForVideoTrack(track.id)
                let trackY = yForVideoTrack(track.id, sepY: sepY)
                if localPoint.y >= trackY && localPoint.y <= trackY + trackH {
                    for (clip, dStart) in model.displayedClips(isVideo: true, trackIndex: track.id) {
                        let clipX = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
                        let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                        if localPoint.x >= clipX && localPoint.x <= clipX + clipW {
                            clickedClip = (clip, dStart, true)
                            break
                        }
                    }
                }
            }
            if clickedClip == nil {
                for track in model.audioTracks {
                    let trackH = heightForAudioTrack(track.id)
                    let trackY = yForAudioTrack(track.id, sepY: sepY)
                    if localPoint.y >= trackY && localPoint.y <= trackY + trackH {
                        for (clip, dStart) in model.displayedClips(isVideo: false, trackIndex: track.id) {
                            let clipX = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
                            let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                            if localPoint.x >= clipX && localPoint.x <= clipX + clipW {
                                clickedClip = (clip, dStart, false)
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
            presentClipContextMenu(
                for: hit.clip,
                displayStart: hit.displayStart,
                isVideo: hit.isVideo,
                clickedTimelineSeconds: CMTimeGetSeconds(hit.clip.timelineStart) + (max(0.0, Double(localPoint.x - headerWidth) / pixelsPerSecond) - CMTimeGetSeconds(hit.displayStart)),
                markerHit: markerHit,
                extraTopItems: [],
                event: event,
                in: self
            )
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

    /// Costruisce e mostra il menu contestuale completo della Timeline per una clip (riusato anche da Timeline Grid).
    fileprivate func presentClipContextMenu(
        for clip: TimelineClip,
        displayStart: CMTime? = nil,
        isVideo: Bool,
        clickedTimelineSeconds: Double? = nil,
        markerHit: MarkerTarget? = nil,
        extraTopItems: [VisionMenuItem] = [],
        event: NSEvent,
        in sourceView: NSView
    ) {
        if !model.selectedClipIds.contains(clip.id) {
            model.selectedClipIds = model.linkedSelectionIds(for: [clip.id])
        }
        let targetIds: Set<UUID> = model.selectedClipIds.contains(clip.id) && model.selectedClipIds.count > 1
            ? model.selectedClipIds
            : [clip.id]
        needsDisplay = true

        let clickedTimelineSec: Double = {
            if let explicit = clickedTimelineSeconds { return explicit }
            let realPlayhead = model.isSmartFilterActive
                ? CMTimeGetSeconds(model.realTimelineTime(forDisplayedTime: playbackController.accurateCurrentTime))
                : CMTimeGetSeconds(playbackController.accurateCurrentTime)
            let cs = CMTimeGetSeconds(clip.timelineStart)
            let ce = CMTimeGetSeconds(clip.timelineEnd)
            if realPlayhead >= cs && realPlayhead <= ce {
                return realPlayhead
            }
            return cs
        }()

        var items: [VisionMenuItem] = [
            .header(targetIds.count > 1 ? "\(targetIds.count) clip selezionate" : clip.mediaItem.name)
        ]

        if !extraTopItems.isEmpty {
            items.append(contentsOf: extraTopItems)
            items.append(.separator)
        }

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
            title: clip.isApproved ? "Rimuovi approvazione (✓)" : "Approva clip (✓)",
            icon: .check,
            iconColor: .systemGreen,
            shortcut: "\\"
        ) { [weak self] in
            guard let self else { return }
            let res = self.model.toggleClipApproved(clipId: clip.id)
            if res.toggledCount > 0 {
                self.needsDisplay = true
                self.notifyModified(res.isNowApproved ? "Approva Clip (\\)" : "Rimuovi Approvazione (\\)")
            }
        })

        items.append(.action(
            title: clip.isLocked ? "Sblocca clip (proteggi da Auto-Fill)" : "Blocca clip (proteggi da Auto-Fill)",
            icon: clip.isLocked ? .unlock : .lock,
            iconColor: .systemOrange,
            shortcut: "L",
            isEnabled: !clip.isApproved
        ) { [weak self] in
            guard let self else { return }
            let res = self.model.toggleClipLock(clipId: clip.id)
            if res.toggledCount > 0 {
                self.needsDisplay = true
                self.notifyModified(res.isNowLocked ? "Blocca Clip (L)" : "Sblocca Clip (L)")
            }
        })

        let anchorScreenPoint = sourceView.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let anchorScreenRect = NSRect(origin: anchorScreenPoint, size: NSSize(width: 2, height: 2))
        items.append(.action(
            title: "Colore clip...",
            icon: .palette,
            iconColor: clip.colorTag?.nsColor ?? .systemCyan,
            shortcut: "C"
        ) { [weak self] in
            self?.presentColorPalette(forClipIds: targetIds, anchorScreenRect: anchorScreenRect)
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
                title: "4 — Dialogo / Intera (Massima)",
                icon: .flag,
                iconColor: priorityColor(for: 4),
                shortcut: "4",
                isSelected: clip.priority == 4
            ) {
                applyPriority(4, "Priorità 4 — Dialogo / Intera")
            },
            .separator,
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

        if isVideo {
            items.append(.separator)
            let reqSlowMoFPS = TimelineModel.formatFPSLabel(model.format.fps * 2.0)
            let canSlowMo = model.canSlowMoClip(clip)
            let isAlreadySlowed = clip.speed < 0.99

            items.append(.action(
                title: isAlreadySlowed ? "Velocità 100% (in Gabbia)" : (canSlowMo ? "Slow-Mo 50% (in Gabbia)" : "Slow-Mo 50% (richiede ≥ \(reqSlowMoFPS)fps)"),
                icon: .zap,
                iconColor: .systemCyan,
                shortcut: "R",
                isEnabled: !clip.isEffectivelyLocked && (isAlreadySlowed || canSlowMo)
            ) { [weak self] in
                guard let self else { return }
                let res = self.model.toggleClipSpeedDetailed(clipId: clip.id)
                if res.newSpeed != nil {
                    self.needsDisplay = true
                    self.notifyModified("Slow Motion in Gabbia (R)")
                } else if let msg = res.errorMessage {
                    self.onShowWarningToast?(msg)
                }
            })
            let canRippleSlowMo = isAlreadySlowed || canSlowMo
            items.append(.action(
                title: isAlreadySlowed ? "Velocità 100% con scarto" : (canSlowMo ? "Slow-Mo 50% con scarto" : "Slow-Mo 50% con scarto (richiede ≥ \(reqSlowMoFPS)fps)"),
                icon: .sparkles,
                iconColor: .systemOrange,
                shortcut: "⌘R",
                isEnabled: !clip.isEffectivelyLocked && canRippleSlowMo
            ) { [weak self] in
                guard let self else { return }
                let res = self.model.toggleSlowMoMultiCage(clipId: clip.id)
                if res.didChange {
                    self.needsDisplay = true
                    self.notifyModified(res.newSpeed < 0.99 ? "Slow Motion 50% con scarto (⌘R)" : "Velocità 100% con scarto (⌘R)")
                } else if let msg = res.errorMessage {
                    self.onShowWarningToast?(msg)
                }
            })
            if !model.activeCageIntervals().isEmpty {
                items.append(.action(
                    title: "Allinea alle Gabbie (±6 frame)",
                    icon: .tally3,
                    iconColor: .systemCyan,
                    shortcut: "⌥G",
                    isEnabled: !clip.isEffectivelyLocked
                ) { [weak self] in
                    guard let self else { return }
                    let res = self.model.alignSelectedClipsToCages(at: self.playbackController.accurateCurrentTime)
                    if res.alignedCount > 0 {
                        self.needsDisplay = true
                        self.notifyModified("Allinea alle Gabbie (⌥G)")
                    } else {
                        self.onShowWarningToast?("Nessuna clip entro ±6 frame da una sbarra (o spazio insufficiente).")
                    }
                })
            }
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
        } else if !model.isSelection {
            items.append(.separator)
            items.append(.action(
                title: "Beat Finder (Analisi & Sbarre)...",
                icon: .wandSparkles,
                iconColor: .systemCyan
            ) { [weak self] in
                self?.onOpenBeatFinderForClip?(clip)
            })
        }

        if targetIds.count == 1 {
            items.append(.action(title: "Ricollega / Cambia sorgente...", icon: .link, iconColor: .systemCyan) { [weak self] in
                self?.onRelinkMediaItemRequested?(clip.mediaItem)
            })
        }

        items.append(.separator)
        items.append(.action(
            title: targetIds.count > 1 ? "Elimina clip selezionate" : "Elimina clip",
            icon: .trash,
            shortcut: "⌫",
            isDestructive: true
        ) { [weak self] in
            guard let self else { return }
            let idsToDelete = Array(targetIds)
            if targetIds.count == 1, !self.model.activeCageIntervals().isEmpty,
               self.model.slotRippleDelete(clipId: clip.id) {
                self.needsDisplay = true
                self.notifyModified("Elimina Clip Ritmica")
                return
            }
            if self.model.isRippleTrimMode || self.model.isSelection {
                self.model.removeClipsWithRipple(ids: idsToDelete)
                self.needsDisplay = true
                self.notifyModified("Elimina Clip (Ripple)")
            } else {
                self.model.removeClipsWithoutRipple(ids: idsToDelete)
                self.needsDisplay = true
                self.notifyModified("Elimina Clip")
            }
        })

        VisionMenu(items: items).show(for: event, in: sourceView)
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

    public func presentColorPalette(forClipIds targetIds: Set<UUID>, anchorScreenRect: NSRect) {
        guard !targetIds.isEmpty else { return }
        let allClips = model.videoTracks.flatMap(\.clips) + model.audioTracks.flatMap(\.clips)
        let matching = allClips.filter { targetIds.contains($0.id) }
        guard !matching.isEmpty else { return }

        let distinctColors = Set(matching.map(\.colorTag))
        let hasMixed = distinctColors.count > 1
        let currentColor = hasMixed ? nil : (distinctColors.first ?? nil)

        ClipColorPalette.show(
            currentColor: currentColor,
            hasMixedColors: hasMixed,
            targetCount: matching.count,
            nearScreenRect: anchorScreenRect,
            parentWindow: self.window
        ) { [weak self] chosenColor in
            guard let self = self else { return }
            let res = self.model.setClipColor(chosenColor, forClipIds: targetIds)
            if res.updatedCount > 0 {
                self.needsDisplay = true
                let actionTitle = chosenColor.map { "Colore Clip (\($0.displayName))" } ?? "Colore Clip (Default)"
                self.notifyModified(actionTitle)
                DebugLogger.shared.log("Colore aggiornato: \(res.summary)", level: .info)
            }
        }
    }

    public func rectInCanvas(forClipId clipId: UUID) -> CGRect? {
        let sepY = separatorY
        for track in model.videoTracks {
            let trackH = heightForVideoTrack(track.id)
            let trackY = yForVideoTrack(track.id, sepY: sepY)
            for (clip, dStart) in model.displayedClips(isVideo: true, trackIndex: track.id) where clip.id == clipId {
                let clipX = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
                let clipW = max(8.0, CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond))
                return CGRect(x: clipX, y: trackY, width: clipW, height: trackH)
            }
        }
        for track in model.audioTracks {
            let trackH = heightForAudioTrack(track.id)
            let trackY = yForAudioTrack(track.id, sepY: sepY)
            for (clip, dStart) in model.displayedClips(isVideo: false, trackIndex: track.id) where clip.id == clipId {
                let clipX = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
                let clipW = max(8.0, CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond))
                return CGRect(x: clipX, y: trackY, width: clipW, height: trackH)
            }
        }
        return nil
    }

    // MARK: - Tracking Areas & Tooltip Support
    public override func updateTrackingAreas() {
        DebugLogger.shared.setTrace("TimelineCanvasView.updateTrackingAreas")
        defer { DebugLogger.shared.setTrace("idle") }
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
            let trackH = heightForVideoTrack(track.id)
            let trackY = yForVideoTrack(track.id, sepY: sepY)
            for (clip, dStart) in model.displayedClips(isVideo: true, trackIndex: track.id) where clip.isOrphan {
                let x = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
                let w = max(3.0, CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond))
                addToolTip(NSRect(x: x, y: trackY + 2, width: w, height: trackH - 4), owner: self, userData: nil)
            }
        }
        for track in model.audioTracks {
            let trackH = heightForAudioTrack(track.id)
            let trackY = yForAudioTrack(track.id, sepY: sepY)
            for (clip, dStart) in model.displayedClips(isVideo: false, trackIndex: track.id) where clip.isOrphan {
                let x = headerWidth + CGFloat(CMTimeGetSeconds(dStart) * pixelsPerSecond)
                let w = max(3.0, CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond))
                addToolTip(NSRect(x: x, y: trackY + 2, width: w, height: trackH - 4), owner: self, userData: nil)
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
        preDropVideoTrackCount = model.videoTracks.count
        preDropAudioTrackCount = model.audioTracks.count
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
        model.trimEmptyTracksCreatedSince(videoCount: preDropVideoTrackCount, audioCount: preDropAudioTrackCount)
        updateWidth()
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
                vClip.colorTag = sClip.colorTag
                if !model.hasLockedClipOverlap(start: vClip.timelineStart, end: vClip.timelineEnd, trackIndex: 0, isVideo: true) {
                    model.overwriteAndInsert(incoming: vClip, trackIndex: 0, isVideo: true)
                }
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
                    aClip.colorTag = sClip.colorTag
                    if !model.hasLockedClipOverlap(start: aClip.timelineStart, end: aClip.timelineEnd, trackIndex: 0, isVideo: false) {
                        model.overwriteAndInsert(incoming: aClip, trackIndex: 0, isVideo: false)
                    }
                }
                currentT = CMTimeAdd(currentT, sClip.duration)
            }
            dropPreviewTime = nil
            currentDraggingItems = []
            currentDraggingExternalURLs = []
            activeSnapLineTime = nil
            model.trimEmptyTracksCreatedSince(videoCount: preDropVideoTrackCount, audioCount: preDropAudioTrackCount)
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
            model.trimEmptyTracksCreatedSince(videoCount: preDropVideoTrackCount, audioCount: preDropAudioTrackCount)
            updateWidth()
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
            model.trimEmptyTracksCreatedSince(videoCount: preDropVideoTrackCount, audioCount: preDropAudioTrackCount)
            updateWidth()
            notifyModified("Trascina Clip in Timeline")
        }

        if !externalURLs.isEmpty {
            model.trimEmptyTracksCreatedSince(videoCount: preDropVideoTrackCount, audioCount: preDropAudioTrackCount)
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

        let maxVAllowed = min(model.maxVideoTracks - 1, preDropVideoTrackCount)
        let maxAAllowed = min(model.maxAudioTracks - 1, preDropAudioTrackCount)
        let rawTargetTrack: Int
        if isVideo {
            if localPoint.y < sepY {
                rawTargetTrack = videoTrackIndex(atY: localPoint.y, sepY: sepY, maxTrackIndex: maxVAllowed)
            } else {
                rawTargetTrack = 0
            }
            if rawTargetTrack == model.videoTracks.count && rawTargetTrack <= maxVAllowed {
                model.ensureVideoTrack(id: rawTargetTrack)
            }
        } else {
            if localPoint.y >= sepY {
                rawTargetTrack = audioTrackIndex(atY: localPoint.y, sepY: sepY, maxTrackIndex: maxAAllowed)
            } else {
                rawTargetTrack = 0
            }
            if rawTargetTrack == model.audioTracks.count && rawTargetTrack <= maxAAllowed {
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

private final class TimelinePillButton: NSView {
    var onClicked: (() -> Void)?
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let chevronView = NSImageView()
    private var chevronWidthConstraint: NSLayoutConstraint!
    private var chevronLeadingConstraint: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var isSelectionStyle = false
    private var isCompareStyle = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1.0

        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.drawsBackground = false

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.isHidden = true

        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(chevronView)

        chevronLeadingConstraint = chevronView.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 0)
        chevronWidthConstraint = chevronView.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevronLeadingConstraint,
            chevronWidthConstraint,
            chevronView.heightAnchor.constraint(equalToConstant: 11),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),

            widthAnchor.constraint(lessThanOrEqualToConstant: 240)
        ])
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, isSelection: Bool, isCompare: Bool = false, showDropdownIndicator: Bool = false) {
        isSelectionStyle = isSelection
        isCompareStyle = isCompare
        titleLabel.stringValue = isCompare ? "\(name) (Temporanea)" : name
        let icon: LucideIcon = isCompare ? .scale : (isSelection ? .sparkles : .clapperboard)
        let tint: NSColor = isCompare ? .systemYellow : (isSelection ? .systemPurple : .systemCyan)
        iconView.image = Lucide.image(icon, size: 13, color: tint)
        chevronView.isHidden = !showDropdownIndicator
        chevronLeadingConstraint.constant = showDropdownIndicator ? 5 : 0
        chevronWidthConstraint.constant = showDropdownIndicator ? 11 : 0
        chevronView.image = showDropdownIndicator
            ? Lucide.image(.chevronDown, size: 11, color: NSColor(calibratedWhite: 0.78, alpha: 1.0))
            : nil
        applyColors()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyColors()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyColors()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClicked?()
    }

    private func applyColors() {
        if isCompareStyle {
            layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(isHovered ? 0.24 : 0.16).cgColor
            layer?.borderColor = NSColor.systemYellow.withAlphaComponent(isHovered ? 0.70 : 0.48).cgColor
            titleLabel.textColor = .systemYellow
        } else if isSelectionStyle {
            layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(isHovered ? 0.24 : 0.16).cgColor
            layer?.borderColor = NSColor.systemPurple.withAlphaComponent(isHovered ? 0.65 : 0.45).cgColor
            titleLabel.textColor = NSColor(calibratedWhite: 0.95, alpha: 1.0)
        } else {
            layer?.backgroundColor = NSColor.systemCyan.withAlphaComponent(isHovered ? 0.20 : 0.12).cgColor
            layer?.borderColor = NSColor.systemCyan.withAlphaComponent(isHovered ? 0.55 : 0.32).cgColor
            titleLabel.textColor = NSColor(calibratedWhite: 0.90, alpha: 1.0)
        }
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
    public var onSlipDualPreviewUpdate: ((_ url: URL, _ inSeconds: Double, _ outSeconds: Double, _ fps: Double, _ clipName: String) -> Void)?
    public var onSlipDualPreviewEnd: (() -> Void)?
    public var onUserPlayheadScrubbed: (() -> Void)?
    public var onShowWarningToast: ((String) -> Void)?
    public var onImportDroppedURLsToTimeline: ((_ urls: [URL], _ atTime: CMTime, _ targetTrackIndex: Int, _ isTargetVideo: Bool) -> Void)?
    public var onSmartFilterChanged: (() -> Void)?
    public var onEnterCompareTimeline: ((TimelineModel) -> Void)?
    public var onExitCompareTimeline: (() -> Void)?
    public var onClipDoubleClicked: ((TimelineClip) -> Void)?
    public var onRelinkMediaItemRequested: ((MediaItem) -> Void)?

    private var canvasView: TimelineCanvasView!
    private let scrollView = NSScrollView()
    private let timelineScrollbar = TimelineHorizontalScrollbarView()
    private let timelineIndicatorBtn = TimelinePillButton()
    private let timecodeLabel = NSTextField(labelWithString: "00:00:00:00")

    // Pro NLE Toolbar Controls
    private let editModeSwitchButton = FlatButton(title: "Con scarto")
    private let linkButton = IconActionButton(toolTip: "Link A/V (⌘L / ⌥L)")
    private let magnetButton = IconActionButton(toolTip: "Magnet / Snapping (N)")
    private let selectionFollowsPlayheadButton = IconActionButton(toolTip: "Seleziona clip sotto la testina (⌥P)")
    private let cageLockButton = IconActionButton(toolTip: "Modalità Gabbie (G): Riordina, Tab+Drag Slip, Roll Sbarre")
    private let sourceBoundsSwitchButton = IconActionButton(toolTip: "Sorgente come Selezione (U)")
    private let rhythmicStudioButton = IconActionButton(toolTip: "Auto-Fill Ritmico da Selezione", isToggleMode: false)
    private let compareButton = IconActionButton(toolTip: "Modalità Confronta: mostra in una timeline temporanea il materiale non in comune")
    private let ghostGapsButton = IconActionButton(toolTip: "Evidenzia vuoti video in rosso (ignora tracce audio)")
    private let compareExitButton = FlatButton(title: "✕ Esci Confronto")
    private let zoomSlider = VisionSlider(value: 0.5, minValue: 0.0, maxValue: 1.0, defaultValue: 0.5)
    private let fpsWarningButton = FlatButton(title: "⚠ FPS")
    private let filterButton = IconActionButton(toolTip: "Filtro Smart Selezione", isToggleMode: true)
    private var filterPopover: NSPopover?
    private var comparePopover: NSPopover?
    private let warningToastBox = NSView()
    private let warningToastLabel = NSTextField(labelWithString: "")
    private var warningToastDismissWork: DispatchWorkItem?

    private var lastObservedPlayheadTime: CMTime = .invalid
    private var suppressPlayheadSelectionUntil: CFAbsoluteTime = 0
    private let maxZoomPPS: Double = 1800.0
    private let maxAdaptiveFitSeconds: Double = 7200.0 // 2 ore visibili max senza overflow

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
        canvasView.onOpenBeatFinderForClip = { [weak self] clip in
            self?.openBeatFinder(for: clip)
        }
        canvasView.onSlipDualPreviewUpdate = { [weak self] url, inSec, outSec, fps, name in
            self?.onSlipDualPreviewUpdate?(url, inSec, outSec, fps, name)
        }
        canvasView.onSlipDualPreviewEnd = { [weak self] in
            self?.onSlipDualPreviewEnd?()
        }
        canvasView.onUserPlayheadScrubbed = { [weak self] in
            self?.onUserPlayheadScrubbed?()
        }
        canvasView.onShowWarningToast = { [weak self] msg in
            self?.showWarningToast(msg)
        }
        canvasView.onImportDroppedURLsToTimeline = { [weak self] urls, atTime, trackIdx, isVideo in
            self?.onImportDroppedURLsToTimeline?(urls, atTime, trackIdx, isVideo)
        }
        canvasView.onClipDoubleClicked = { [weak self] clip in
            self?.onClipDoubleClicked?(clip)
        }
        canvasView.onRelinkMediaItemRequested = { [weak self] item in
            self?.onRelinkMediaItemRequested?(item)
        }
        canvasView.onCanvasWidthChanged = { [weak self] in
            self?.syncCanvasFrame()
        }
        canvasView.onRequestZoom = { [weak self] factor, viewportAnchorX in
            self?.zoomByFactor(factor, anchorViewportX: viewportAnchorX)
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = canvasView
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
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

        timelineScrollbar.translatesAutoresizingMaskIntoConstraints = false
        timelineScrollbar.isHidden = true
        timelineScrollbar.onScrollFractionChanged = { [weak self] fraction in
            guard let self = self else { return }
            let clipView = self.scrollView.contentView
            let maxOriginX = max(0.0, self.canvasView.frame.width - clipView.bounds.width)
            guard maxOriginX > 0 else { return }
            let targetX = max(0.0, min(maxOriginX, maxOriginX * fraction))
            clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.origin.y))
            self.scrollView.reflectScrolledClipView(clipView)
            self.canvasView.updatePlayheadLayer()
            self.canvasView.needsDisplay = true
            self.updateTimelineScrollbar()
        }
        timelineScrollbar.onScrollDeltaX = { [weak self] deltaX in
            self?.scrollHorizontally(by: deltaX)
        }
        root.addSubview(timelineScrollbar)

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

        warningToastBox.translatesAutoresizingMaskIntoConstraints = false
        warningToastBox.wantsLayer = true
        warningToastBox.layer?.backgroundColor = NSColor(calibratedRed: 0.22, green: 0.16, blue: 0.04, alpha: 0.94).cgColor
        warningToastBox.layer?.borderColor = NSColor.systemYellow.withAlphaComponent(0.75).cgColor
        warningToastBox.layer?.borderWidth = 1.0
        warningToastBox.layer?.cornerRadius = 6.0
        warningToastBox.isHidden = true

        warningToastLabel.translatesAutoresizingMaskIntoConstraints = false
        warningToastLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        warningToastLabel.textColor = .systemYellow
        warningToastLabel.lineBreakMode = .byTruncatingTail
        warningToastBox.addSubview(warningToastLabel)
        root.addSubview(warningToastBox)

        NSLayoutConstraint.activate([
            warningToastLabel.topAnchor.constraint(equalTo: warningToastBox.topAnchor, constant: 6),
            warningToastLabel.bottomAnchor.constraint(equalTo: warningToastBox.bottomAnchor, constant: -6),
            warningToastLabel.leadingAnchor.constraint(equalTo: warningToastBox.leadingAnchor, constant: 12),
            warningToastLabel.trailingAnchor.constraint(equalTo: warningToastBox.trailingAnchor, constant: -12),
            warningToastBox.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8),
            warningToastBox.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            warningToastBox.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -40),
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 42),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            timelineScrollbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: canvasView.headerWidth),
            timelineScrollbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            timelineScrollbar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            timelineScrollbar.heightAnchor.constraint(equalToConstant: 14),

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
            let timeMoved = !self.lastObservedPlayheadTime.isValid || CMTimeCompare(time, self.lastObservedPlayheadTime) != 0
            self.lastObservedPlayheadTime = time
            // Attiva "selezione sotto testina" SOLO quando la testina si sposta realmente,
            // preservando la selezione singola/multipla mentre spostiamo le clip a testina ferma o selezioniamo da Grid.
            if self.model.isSelectionFollowsPlayhead && timeMoved && CFAbsoluteTimeGetCurrent() >= self.suppressPlayheadSelectionUntil {
                let prevSelected = self.model.selectedClipIds
                self.model.updateSelectionAtPlayhead(time: time)
                if self.model.selectedClipIds != prevSelected {
                    self.canvasView.needsDisplay = true
                }
            }
            if self.playbackController.isPlaying || timeMoved {
                self.autoScrollToKeepPlayheadVisible(at: time)
            }
            self.canvasView.updatePlayheadLayer()
            let formatted = self.playbackController.formattedCurrentTime
            if self.timecodeLabel.stringValue != formatted {
                self.timecodeLabel.stringValue = formatted
            }
        }

        playbackController.addPlayStateObserver(self) { [weak self] isPlaying in
            guard let self = self, isPlaying else { return }
            self.centerViewportOnPlayheadIfOutsideVisibleArea()
        }

        self.view = root
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        syncAdaptiveZoomBounds()
        syncCanvasFrame()
        updateTimelineScrollbar()
    }

    @objc private func onScrollViewBoundsChanged(_ note: Notification) {
        canvasView.updatePlayheadLayer()
        canvasView.needsDisplay = true
        updateTimelineScrollbar()
    }

    private func syncCanvasFrame() {
        let clipSize = scrollView.contentView.bounds.size
        guard clipSize.width > 0 else { return }
        let viewportH = max(180, clipSize.height)
        let targetW = max(clipSize.width, canvasView.calculatedTotalWidth)
        let targetH = max(viewportH, canvasView.calculatedTotalHeight(forViewportHeight: viewportH))
        let needsVScroll = targetH > viewportH + 1.0
        if scrollView.hasVerticalScroller != needsVScroll {
            scrollView.hasVerticalScroller = needsVScroll
            if needsVScroll {
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = false
            }
        }
        if abs(canvasView.frame.width - targetW) > 0.5 || abs(canvasView.frame.height - targetH) > 0.5 || canvasView.frame.origin != .zero {
            canvasView.frame = NSRect(x: 0, y: 0, width: targetW, height: targetH)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            canvasView.needsDisplay = true
        }
        updateTimelineScrollbar()
    }

    private func updateTimelineScrollbar() {
        let clipBounds = scrollView.contentView.bounds
        let totalW = canvasView.frame.width
        let headerW = canvasView.headerWidth
        let maxOriginX = max(0.0, totalW - clipBounds.width)
        let overflows = maxOriginX > 0.5
        timelineScrollbar.isHidden = !overflows
        guard overflows else { return }

        let scrollableContentW = max(1.0, totalW - headerW)
        let visibleTimelineW = max(1.0, clipBounds.width - headerW)
        let proportion = min(1.0, visibleTimelineW / scrollableContentW)
        let fraction = max(0.0, min(1.0, clipBounds.origin.x / maxOriginX))
        timelineScrollbar.updateState(thumbProportion: proportion, scrollFraction: fraction)
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
                clipView.scroll(to: NSPoint(x: targetOriginX, y: clipBounds.origin.y))
                scrollView.reflectScrolledClipView(clipView)
            }
        } else if playheadX < clipBounds.minX + headerW + 16.0 {
            let targetOriginX = max(0.0, playheadX - headerW - min(48.0, tracksVisibleW * 0.14))
            if abs(targetOriginX - clipBounds.origin.x) > 0.5 {
                clipView.scroll(to: NSPoint(x: targetOriginX, y: clipBounds.origin.y))
                scrollView.reflectScrolledClipView(clipView)
            }
        }
    }

    public func centerViewportOnPlayheadIfOutsideVisibleArea() {
        let clipView = scrollView.contentView
        let clipBounds = clipView.bounds
        let headerW = canvasView.headerWidth
        let tracksVisibleW = max(80.0, clipBounds.width - headerW)

        let sec = max(0.0, CMTimeGetSeconds(playbackController.currentTime))
        let playheadX = headerW + CGFloat(sec * canvasView.pixelsPerSecond)
        let maxOriginX = max(0.0, canvasView.frame.width - clipBounds.width)
        guard maxOriginX > 0 else { return }

        let isOutsideLeft = playheadX < (clipBounds.minX + headerW + 4.0)
        let isOutsideRight = playheadX > (clipBounds.maxX - 4.0)
        guard isOutsideLeft || isOutsideRight else { return }

        let targetOriginX = max(0.0, min(maxOriginX, playheadX - (headerW + tracksVisibleW * 0.5)))
        if abs(targetOriginX - clipBounds.origin.x) > 0.5 {
            clipView.scroll(to: NSPoint(x: targetOriginX, y: clipBounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
            canvasView.updatePlayheadLayer()
        }
    }

    private func setupToolbar(_ toolbar: NSView) {
        let leftStack = NSStackView()
        leftStack.translatesAutoresizingMaskIntoConstraints = false
        leftStack.orientation = .horizontal
        leftStack.spacing = 6
        leftStack.alignment = .centerY
        toolbar.addSubview(leftStack)

        let centerStack = NSStackView()
        centerStack.translatesAutoresizingMaskIntoConstraints = false
        centerStack.orientation = .horizontal
        centerStack.spacing = 6
        centerStack.alignment = .centerY
        toolbar.addSubview(centerStack)

        let rightStack = NSStackView()
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.orientation = .horizontal
        rightStack.spacing = 8
        rightStack.alignment = .centerY
        toolbar.addSubview(rightStack)

        let centerXConstraint = centerStack.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor)
        centerXConstraint.priority = .defaultHigh

        NSLayoutConstraint.activate([
            leftStack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            leftStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            leftStack.trailingAnchor.constraint(lessThanOrEqualTo: centerStack.leadingAnchor, constant: -10),

            centerXConstraint,
            centerStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            centerStack.trailingAnchor.constraint(lessThanOrEqualTo: rightStack.leadingAnchor, constant: -10),

            rightStack.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            rightStack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])

        // LEFT: Selettore Timeline / Selezione (con ▾ solo se esiste più di una scelta) + Exit Compare + FPS Warning
        timelineIndicatorBtn.translatesAutoresizingMaskIntoConstraints = false
        timelineIndicatorBtn.configure(
            name: model.name,
            isSelection: model.isSelection,
            isCompare: model.isTemporaryCompare,
            showDropdownIndicator: EditorProject.shared.timelines.count > 1
        )
        timelineIndicatorBtn.toolTip = "Timeline o Selezione attiva (Clicca per cambiare)"
        timelineIndicatorBtn.onClicked = { [weak self] in
            self?.onTimelineIndicatorClicked()
        }
        leftStack.addArrangedSubview(timelineIndicatorBtn)

        compareExitButton.toolTip = "Chiudi timeline di confronto temporanea"
        compareExitButton.target = self
        compareExitButton.action = #selector(onExitCompareClicked)
        compareExitButton.isAccentActive = true
        compareExitButton.translatesAutoresizingMaskIntoConstraints = false
        compareExitButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        compareExitButton.isHidden = !model.isTemporaryCompare
        leftStack.addArrangedSubview(compareExitButton)

        fpsWarningButton.translatesAutoresizingMaskIntoConstraints = false
        fpsWarningButton.target = self
        fpsWarningButton.action = #selector(onFPSWarningClicked)
        fpsWarningButton.isAccentActive = true
        fpsWarningButton.heightAnchor.constraint(equalToConstant: 22).isActive = true
        fpsWarningButton.isHidden = true
        leftStack.addArrangedSubview(fpsWarningButton)

        // CENTER: Switch [Con scarto] / [Senza scarto] + tutti i button di editing
        editModeSwitchButton.translatesAutoresizingMaskIntoConstraints = false
        editModeSwitchButton.target = self
        editModeSwitchButton.action = #selector(onToggleEditModeClicked)
        editModeSwitchButton.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        editModeSwitchButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true
        editModeSwitchButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        centerStack.addArrangedSubview(editModeSwitchButton)
        updateEditModeButtons()

        func makeCenterDivider() -> NSBox {
            let div = NSBox()
            div.boxType = .separator
            div.translatesAutoresizingMaskIntoConstraints = false
            div.widthAnchor.constraint(equalToConstant: 1).isActive = true
            div.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return div
        }

        let editModeDivider = makeCenterDivider()
        centerStack.addArrangedSubview(editModeDivider)

        // Boxless icon toggles: Link, Magnet, Under-playhead | Gabbia | Sorgente Selezione/Clip
        linkButton.image = Lucide.template(.link, size: 16)
        linkButton.activeTintColor = .systemCyan
        linkButton.target = self
        linkButton.action = #selector(onLinkToggleClicked)
        linkButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        linkButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        updateLinkButtonTitle()
        centerStack.addArrangedSubview(linkButton)

        magnetButton.image = Lucide.template(.magnet, size: 16)
        magnetButton.activeTintColor = .systemCyan
        magnetButton.target = self
        magnetButton.action = #selector(onMagnetToggleClicked)
        magnetButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        magnetButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        updateMagnetButtonTitle()
        centerStack.addArrangedSubview(magnetButton)

        selectionFollowsPlayheadButton.image = Lucide.template(.textCursor, size: 16)
        selectionFollowsPlayheadButton.activeTintColor = .systemCyan
        selectionFollowsPlayheadButton.target = self
        selectionFollowsPlayheadButton.action = #selector(onSelectionFollowsPlayheadClicked)
        selectionFollowsPlayheadButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        selectionFollowsPlayheadButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        updateSelectionFollowsPlayheadButtonTitle()
        centerStack.addArrangedSubview(selectionFollowsPlayheadButton)

        centerStack.addArrangedSubview(makeCenterDivider())

        cageLockButton.image = Lucide.template(.tally3, size: 16)
        cageLockButton.activeTintColor = .systemCyan
        cageLockButton.target = self
        cageLockButton.action = #selector(onCageLockToggleClicked)
        cageLockButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        cageLockButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        updateCageLockButtonTitle()
        centerStack.addArrangedSubview(cageLockButton)

        centerStack.addArrangedSubview(makeCenterDivider())

        sourceBoundsSwitchButton.image = Lucide.template(.caretsFromAxisDashedVertical, size: 16)
        sourceBoundsSwitchButton.activeTintColor = .systemCyan
        sourceBoundsSwitchButton.target = self
        sourceBoundsSwitchButton.action = #selector(onSourceBoundsToggleClicked)
        sourceBoundsSwitchButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        sourceBoundsSwitchButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        updateSourceBoundsButtonTitle()
        centerStack.addArrangedSubview(sourceBoundsSwitchButton)

        let rhythmDivider = makeCenterDivider()
        centerStack.addArrangedSubview(rhythmDivider)

        rhythmicStudioButton.image = Lucide.template(.sparkles, size: 16)
        rhythmicStudioButton.toolTip = "Auto-Fill Ritmico"
        rhythmicStudioButton.target = self
        rhythmicStudioButton.action = #selector(onRhythmicStudioClicked)
        rhythmicStudioButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        rhythmicStudioButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        centerStack.addArrangedSubview(rhythmicStudioButton)

        compareButton.image = Lucide.template(.scale, size: 16)
        compareButton.activeTintColor = .systemYellow
        compareButton.isToggleMode = true
        compareButton.isToggleActive = model.isTemporaryCompare
        compareButton.target = self
        compareButton.action = #selector(onCompareClicked)
        compareButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        compareButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        centerStack.addArrangedSubview(compareButton)

        ghostGapsButton.image = Lucide.template(.ghost, size: 16)
        ghostGapsButton.activeTintColor = .systemRed
        ghostGapsButton.target = self
        ghostGapsButton.action = #selector(onGhostGapsToggleClicked)
        ghostGapsButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        ghostGapsButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        updateGhostGapsButtonTitle()
        centerStack.addArrangedSubview(ghostGapsButton)

        // RIGHT (lato opposto al selettore timeline): Filtro Selezione + Zoom Slider
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        filterButton.image = Lucide.template(.filter, size: 16)
        filterButton.activeTintColor = .systemPurple
        filterButton.target = self
        filterButton.action = #selector(onFilterButtonClicked)
        filterButton.isHidden = !model.isSelection
        filterButton.isToggleActive = model.isSmartFilterActive
        filterButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        filterButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        rightStack.addArrangedSubview(filterButton)

        let zoomIconView = NSImageView()
        zoomIconView.translatesAutoresizingMaskIntoConstraints = false
        zoomIconView.image = Lucide.template(.zoomIn, size: 15)
        zoomIconView.contentTintColor = .secondaryLabelColor
        zoomIconView.toolTip = "Zoom Timeline"
        zoomIconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        zoomIconView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        rightStack.addArrangedSubview(zoomIconView)

        zoomSlider.minValue = 0.0
        zoomSlider.maxValue = 1.0
        zoomSlider.doubleValue = 0.5
        zoomSlider.isContinuous = true
        zoomSlider.controlSize = .small
        zoomSlider.target = self
        zoomSlider.action = #selector(onZoomChanged)
        zoomSlider.widthAnchor.constraint(equalToConstant: 86).isActive = true
        rightStack.addArrangedSubview(zoomSlider)

        compareExitButton.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        fpsWarningButton.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        updateFPSWarningButton()
    }

    private func updateEditModeButtons() {
        let isTrim = model.isRippleTrimMode || model.isSelection
        editModeSwitchButton.title = isTrim ? "Senza scarto" : "Con scarto"
        editModeSwitchButton.isAccentActive = isTrim
        editModeSwitchButton.isEnabled = !model.isSelection
        editModeSwitchButton.toolTip = isTrim
            ? "Modalità Senza scarto / Ripple (T) — Clicca o premi A per Con scarto"
            : "Modalità Con scarto (A) — Clicca o premi T per Senza scarto"
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

    private func updateSourceBoundsButtonTitle() {
        sourceBoundsSwitchButton.isToggleActive = model.isSelectionSourceConstrained
        sourceBoundsSwitchButton.toolTip = model.isSelectionSourceConstrained
            ? "Sorgente come Selezione (U) — Attivo: usa solo l'estratto ereditato dalla Selezione"
            : "Sorgente come Clip Originale (U) — Disattivo: sblocca l'intera durata originale della clip"
    }

    private func updateGhostGapsButtonTitle() {
        ghostGapsButton.isToggleActive = model.isEmptyGapsHighlighted
    }

    public func updateTimelineIndicator() {
        timelineIndicatorBtn.configure(
            name: model.name,
            isSelection: model.isSelection,
            isCompare: model.isTemporaryCompare,
            showDropdownIndicator: EditorProject.shared.timelines.count > 1
        )
    }

    public func presentClipContextMenu(
        for clip: TimelineClip,
        isVideo: Bool,
        extraTopItems: [VisionMenuItem] = [],
        event: NSEvent,
        in sourceView: NSView
    ) {
        canvasView.presentClipContextMenu(
            for: clip,
            displayStart: nil,
            isVideo: isVideo,
            clickedTimelineSeconds: nil,
            markerHit: nil,
            extraTopItems: extraTopItems,
            event: event,
            in: sourceView
        )
    }

    public func reloadTimelineUI() {
        timelineIndicatorBtn.configure(
            name: model.name,
            isSelection: model.isSelection,
            isCompare: model.isTemporaryCompare,
            showDropdownIndicator: EditorProject.shared.timelines.count > 1
        )
        filterButton.isHidden = !model.isSelection
        filterButton.isToggleActive = model.isSmartFilterActive
        compareButton.isToggleActive = model.isTemporaryCompare
        compareExitButton.isHidden = !model.isTemporaryCompare
        updateEditModeButtons()
        updateLinkButtonTitle()
        updateMagnetButtonTitle()
        updateSelectionFollowsPlayheadButtonTitle()
        updateCageLockButtonTitle()
        updateSourceBoundsButtonTitle()
        updateGhostGapsButtonTitle()
        updateFPSWarningButton()
        syncAdaptiveZoomBounds()
        canvasView.updateWidth()
        canvasView.needsDisplay = true
    }

    public func updateFPSWarningButton() {
        let badClips = model.nonConformantFrameRateClips()
        guard !badClips.isEmpty else {
            fpsWarningButton.isHidden = true
            return
        }
        let tlFpsStr = TimelineModel.formatFPSLabel(model.format.fps)
        fpsWarningButton.title = "⚠ \(badClips.count) clip ≠ \(tlFpsStr)fps"
        let uniqueNames = Array(Set(badClips.map { "\($0.mediaItem.name) (\(TimelineModel.formatFPSLabel($0.mediaItem.frameRate))fps)" })).sorted()
        fpsWarningButton.toolTip = "Clip con framerate non conforme a \(tlFpsStr)fps (sono ammessi solo multipli interi come \(tlFpsStr), \(TimelineModel.formatFPSLabel(model.format.fps * 2)), \(TimelineModel.formatFPSLabel(model.format.fps * 4))fps):\n• " + uniqueNames.joined(separator: "\n• ")
        fpsWarningButton.isHidden = false
    }

    @objc private func onFPSWarningClicked() {
        let badClips = model.nonConformantFrameRateClips()
        guard !badClips.isEmpty else { return }
        let tlFpsStr = TimelineModel.formatFPSLabel(model.format.fps)
        model.selectedClipIds = Set(badClips.map(\.id))
        canvasView.needsDisplay = true
        let uniqueSummary = Array(Set(badClips.map { "\($0.mediaItem.name) (\(TimelineModel.formatFPSLabel($0.mediaItem.frameRate))fps)" })).sorted().joined(separator: ", ")
        let msg = "⚠ Clip non conformi a \(tlFpsStr)fps: \(uniqueSummary)"
        DebugLogger.shared.log(msg, level: .warning)
        showWarningToast("\(badClips.count) clip selezionate non conformi a \(tlFpsStr)fps")
    }

    public func showWarningToast(_ message: String) {
        warningToastDismissWork?.cancel()
        warningToastLabel.stringValue = "⚠ \(message)"
        warningToastBox.isHidden = false
        let work = DispatchWorkItem { [weak self] in
            self?.warningToastBox.isHidden = true
        }
        warningToastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4, execute: work)
    }

    public func preserveSelectionForNextSeek(duration: TimeInterval = 0.25) {
        suppressPlayheadSelectionUntil = CFAbsoluteTimeGetCurrent() + duration
    }

    public func switchModel(_ newModel: TimelineModel) {
        self.model = newModel
        self.canvasView.model = newModel
        self.lastObservedPlayheadTime = .invalid
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

    @objc private func onToggleEditModeClicked() {
        let isTrim = model.isRippleTrimMode || model.isSelection
        setRippleTrimMode(!isTrim)
    }

    public func setRippleTrimMode(_ enabled: Bool) {
        if model.isSelection && !enabled {
            updateEditModeButtons()
            DebugLogger.shared.log("In Selezione le clip restano sempre contigue (modalità T attiva).", level: .info)
            return
        }
        guard model.isRippleTrimMode != enabled else {
            updateEditModeButtons()
            return
        }
        model.isRippleTrimMode = enabled
        updateEditModeButtons()
        notifyVCModified(enabled ? "Modalità Trim / Senza Scarto (T)" : "Modalità Selezione / Con Scarto (A)")
        DebugLogger.shared.log(
            enabled
            ? "Modalità Montaggio: TRIM / SENZA SCARTO (T) — Q, W e taglio bordi spostano le clip chiudendo gli spazi."
            : "Modalità Montaggio: SELEZIONE / CON SCARTO (A) — Q, W e taglio bordi lasciano lo spazio vuoto senza spostare la timeline.",
            level: .info
        )
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
        canvasView.needsDisplay = true
        notifyVCModified(model.isCageLockActive ? "Blocco Gabbia Attivo" : "Montaggio Libero")
        DebugLogger.shared.log("Blocco Gabbia impostato su: \(model.isCageLockActive ? "ATTIVO (aggancia alle sbarre)" : "DISATTIVATO (montaggio libero)")", level: .info)
    }

    @objc public func onSourceBoundsToggleClicked() {
        model.isSelectionSourceConstrained.toggle()
        updateSourceBoundsButtonTitle()
        canvasView.refreshFloatingSlipBoundsIfActive()
        canvasView.needsDisplay = true
        let title = model.isSelectionSourceConstrained
            ? "Sorgente come Selezione (U)"
            : "Sorgente come Clip Originale (U)"
        notifyVCModified(title)
        DebugLogger.shared.log(
            model.isSelectionSourceConstrained
            ? "Sorgente come Selezione (U): Slip, drag e span rispettano i limiti ereditati dalla Selezione."
            : "Sorgente come Clip Originale (U): Slip, drag e span possono usare l'intera clip sorgente.",
            level: .info
        )
    }

    @objc public func onGhostGapsToggleClicked() {
        model.isEmptyGapsHighlighted.toggle()
        updateGhostGapsButtonTitle()
        canvasView.needsDisplay = true
        let gapCount = model.emptyTimelineGapIntervals().count
        if model.isEmptyGapsHighlighted {
            DebugLogger.shared.log("Evidenziazione Ghost vuoti video ATTIVA (\(gapCount) vuoti video rilevati).", level: .info)
        } else {
            DebugLogger.shared.log("Evidenziazione Ghost vuoti video DISATTIVATA.", level: .info)
        }
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

    @objc private func onFilterButtonClicked() {
        guard model.isSelection else { return }
        if let existing = filterPopover, existing.isShown {
            existing.performClose(nil)
            return
        }
        let vc = SelectionFilterPopoverController(initialFilter: model.smartFilter) { [weak self] updatedFilter in
            guard let self = self else { return }
            let curDisplayTime = self.playbackController.currentTime
            let realAnchorTime = self.model.isSmartFilterActive
                ? self.model.realTimelineTime(forDisplayedTime: curDisplayTime)
                : curDisplayTime

            self.model.smartFilter = updatedFilter
            let newPlayheadTime = self.model.isSmartFilterActive
                ? self.model.displayedTime(forRealTime: realAnchorTime)
                : realAnchorTime
            self.playbackController.setPlayheadForPendingReload(newPlayheadTime)

            self.filterButton.isToggleActive = self.model.isSmartFilterActive
            self.reloadTimelineUI()
            self.onSmartFilterChanged?()
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 245, height: 225)
        popover.show(relativeTo: filterButton.bounds, of: filterButton, preferredEdge: .maxY)
        self.filterPopover = popover
    }

    @objc private func onCompareClicked() {
        if let existing = comparePopover, existing.isShown {
            existing.performClose(nil)
            return
        }
        let vc = ComparePopoverController(
            timelines: EditorProject.shared.timelines,
            activeSavedTimeline: EditorProject.shared.activeTimeline,
            isCurrentlyComparing: model.isTemporaryCompare,
            onOpenCompare: { [weak self] compareTL in
                self?.comparePopover?.performClose(nil)
                self?.onEnterCompareTimeline?(compareTL)
            },
            onExitCompare: { [weak self] in
                self?.comparePopover?.performClose(nil)
                self?.onExitCompareTimeline?()
            }
        )
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.contentViewController = vc
        popover.contentSize = NSSize(width: 344, height: 224)
        popover.show(relativeTo: compareButton.bounds, of: compareButton, preferredEdge: .maxY)
        self.comparePopover = popover
    }

    @objc private func onExitCompareClicked() {
        comparePopover?.performClose(nil)
        onExitCompareTimeline?()
    }

    public func presentColorPaletteForCurrentTarget() {
        var targetIds = model.selectedClipIds
        if targetIds.isEmpty {
            let t = playbackController.accurateCurrentTime
            let queryTime = model.isSmartFilterActive ? model.realTimelineTime(forDisplayedTime: t) : t
            let sec = CMTimeGetSeconds(queryTime)
            for track in model.videoTracks {
                if let c = track.clips.first(where: { sec >= CMTimeGetSeconds($0.timelineStart) - 0.001 && sec < CMTimeGetSeconds($0.timelineEnd) }) {
                    targetIds.insert(c.id)
                    break
                }
            }
            if targetIds.isEmpty {
                for track in model.audioTracks {
                    if let c = track.clips.first(where: { sec >= CMTimeGetSeconds($0.timelineStart) - 0.001 && sec < CMTimeGetSeconds($0.timelineEnd) }) {
                        targetIds.insert(c.id)
                        break
                    }
                }
            }
        }
        guard !targetIds.isEmpty else {
            DebugLogger.shared.log("Seleziona una o più clip o posiziona la testina su una clip per cambiare colore (C).", level: .warning)
            return
        }

        let anchorScreenRect: NSRect
        if let win = view.window {
            let clipRectInCanvas = targetIds.compactMap { canvasView.rectInCanvas(forClipId: $0) }.first
            if let r = clipRectInCanvas, r.intersects(canvasView.visibleRect) {
                let winRect = canvasView.convert(NSRect(x: r.midX, y: r.maxY, width: 2, height: 2), to: nil)
                anchorScreenRect = win.convertToScreen(winRect)
            } else {
                let centerInScroll = NSRect(x: scrollView.bounds.midX - 94, y: scrollView.bounds.midY + 60, width: 2, height: 2)
                let winRect = scrollView.convert(centerInScroll, to: nil)
                anchorScreenRect = win.convertToScreen(winRect)
            }
        } else {
            let mouse = NSEvent.mouseLocation
            anchorScreenRect = NSRect(origin: mouse, size: NSSize(width: 2, height: 2))
        }
        canvasView.presentColorPalette(forClipIds: targetIds, anchorScreenRect: anchorScreenRect)
    }

    // MARK: - Rhythmic Auto-Fill & Beat Finder Action Handlers

    @objc public func onRhythmicStudioClicked() {
        let ph = max(0.0, CMTimeGetSeconds(playbackController.accurateCurrentTime))
        BeatAnalysisDialog.showAutoFillModal(for: model, playheadSeconds: ph, relativeTo: view.window) { [weak self] in
            self?.reloadTimelineUI()
            self?.notifyVCModified("Auto-Fill Ritmico")
        }
    }

    public func handleTabKeyStateChanged(isDown: Bool) {
        canvasView?.handleTabKeyStateChanged(isDown: isDown)
    }

    public func openBeatFinder(for audioClip: TimelineClip) {
        guard !model.isSelection else { return }
        BeatAnalysisDialog.showBeatFinderModal(for: model, audioClip: audioClip, relativeTo: view.window) { [weak self] in
            self?.reloadTimelineUI()
            self?.notifyVCModified("Beat Finder")
        }
    }

    /// Scorrimento orizzontale fluido della timeline (usato dalla modalità SCRL della rotella Speed Editor).
    public func scrollHorizontally(by deltaPoints: CGFloat) {
        let clipView = scrollView.contentView
        let maxX = max(0, canvasView.bounds.width - clipView.bounds.width)
        let targetX = max(0, min(maxX, clipView.bounds.origin.x + deltaPoints))
        clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
        canvasView.updatePlayheadLayer()
        canvasView.needsDisplay = true
    }

    @objc public func onExportXMLClicked() {
        onExportFCPXML?()
    }

    @objc public func onSpanClicked() {
        guard let id = model.resolvedVideoClipId() ?? model.selectedClipId else { return }
        for track in model.videoTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                let currentSpan = max(1, clip.span)
                let growRes = model.setClipSpanDetailed(clipId: id, newSpan: currentSpan + 1)
                if growRes.didChange {
                    reloadTimelineUI()
                    notifyVCModified("Espandi in Gabbia (⌥+)")
                } else if currentSpan > 1 {
                    if model.setClipSpanDetailed(clipId: id, newSpan: 1).didChange {
                        reloadTimelineUI()
                        notifyVCModified("Riduci a 1 Gabbia (⌥+)")
                    }
                } else if let msg = growRes.errorMessage {
                    showWarningToast(msg)
                }
                break
            }
        }
    }

    @objc public func onDecreaseSpanClicked() {
        guard let id = model.resolvedVideoClipId() ?? model.selectedClipId else { return }
        for track in model.videoTracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                guard clip.span > 1 else { break }
                let res = model.setClipSpanDetailed(clipId: id, newSpan: clip.span - 1)
                if res.didChange {
                    reloadTimelineUI()
                    notifyVCModified("Riduci Span Gabbia (⌥-)")
                } else if let msg = res.errorMessage {
                    showWarningToast(msg)
                }
                break
            }
        }
    }

    @objc public func onToggleSpeedClicked() {
        guard let id = model.resolvedVideoClipId() ?? model.selectedClipId else { return }
        let res = model.toggleClipSpeedDetailed(clipId: id)
        if res.newSpeed != nil {
            reloadTimelineUI()
            notifyVCModified("Slow Motion in Gabbia (R)")
        } else if let err = res.errorMessage {
            showWarningToast(err)
        }
    }

    @objc public func onToggleSlowMoMultiCageClicked() {
        guard let id = model.resolvedVideoClipId() ?? model.selectedClipId else { return }
        let res = model.toggleSlowMoMultiCage(clipId: id)
        if res.didChange {
            reloadTimelineUI()
            notifyVCModified(res.newSpeed < 0.99 ? "Slow Motion 50% con scarto (⌘R)" : "Velocità 100% con scarto (⌘R)")
        } else if let err = res.errorMessage {
            DebugLogger.shared.log(err, level: .warning)
            showWarningToast(err)
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

    public func adaptiveMinPixelsPerSecond() -> Double {
        let viewportW = Double(max(240.0, scrollView.contentView.bounds.width - canvasView.headerWidth))
        let contentSec = canvasView.totalContentSeconds
        let rawDur = max(0.0, CMTimeGetSeconds(model.displayedTotalDuration))
        let pad = rawDur > 0 ? min(10.0, max(2.0, rawDur * 0.02)) : 0.0
        let fitSec = min(maxAdaptiveFitSeconds + pad, contentSec)
        let computed = viewportW / max(30.0, fitSec)
        return max(0.05, min(maxZoomPPS * 0.5, computed))
    }

    private func pixelsPerSecond(forSliderValue t: Double) -> Double {
        let minPPS = adaptiveMinPixelsPerSecond()
        let clampedT = max(0.0, min(1.0, t))
        return minPPS * pow(maxZoomPPS / minPPS, clampedT)
    }

    private func sliderValue(forPixelsPerSecond pps: Double) -> Double {
        let minPPS = adaptiveMinPixelsPerSecond()
        let clampedPPS = max(minPPS, min(maxZoomPPS, pps))
        guard maxZoomPPS > minPPS else { return 0.5 }
        return log(clampedPPS / minPPS) / log(maxZoomPPS / minPPS)
    }

    private func syncAdaptiveZoomBounds() {
        let minPPS = adaptiveMinPixelsPerSecond()
        if canvasView.pixelsPerSecond < minPPS || canvasView.pixelsPerSecond > maxZoomPPS {
            canvasView.pixelsPerSecond = max(minPPS, min(maxZoomPPS, canvasView.pixelsPerSecond))
        }
        zoomSlider.doubleValue = sliderValue(forPixelsPerSecond: canvasView.pixelsPerSecond)
    }

    @objc private func onZoomChanged() {
        let oldPPS = canvasView.pixelsPerSecond
        let newPPS = pixelsPerSecond(forSliderValue: zoomSlider.doubleValue)
        applyZoom(newPixelsPerSecond: newPPS, oldPixelsPerSecond: oldPPS, anchorViewportX: nil)
    }

    private func zoomByFactor(_ factor: Double, anchorViewportX: CGFloat) {
        let minPPS = adaptiveMinPixelsPerSecond()
        let oldPPS = canvasView.pixelsPerSecond
        let newPPS = max(minPPS, min(maxZoomPPS, oldPPS * factor))
        zoomSlider.doubleValue = sliderValue(forPixelsPerSecond: newPPS)
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
        clipView.scroll(to: NSPoint(x: targetOriginX, y: clipBounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
        canvasView.updatePlayheadLayer()
        canvasView.needsDisplay = true
    }
}

private final class SelectionFilterPopoverController: NSViewController {
    private var filter: SelectionSmartFilter
    private let onFilterChanged: (SelectionSmartFilter) -> Void

    private let p4Check = NSButton(checkboxWithTitle: "4 — Dialogo / Intera", target: nil, action: nil)
    private let p1Check = NSButton(checkboxWithTitle: "1 — Blu chiaro", target: nil, action: nil)
    private let p2Check = NSButton(checkboxWithTitle: "2 — Blu medio", target: nil, action: nil)
    private let p3Check = NSButton(checkboxWithTitle: "3 — Blu scuro", target: nil, action: nil)
    private let noPrioCheck = NSButton(checkboxWithTitle: "Senza priorità", target: nil, action: nil)
    private let withMarkersCheck = NSButton(checkboxWithTitle: "Con marcatori", target: nil, action: nil)
    private let withoutMarkersCheck = NSButton(checkboxWithTitle: "Senza marcatori", target: nil, action: nil)

    init(initialFilter: SelectionSmartFilter, onFilterChanged: @escaping (SelectionSmartFilter) -> Void) {
        self.filter = initialFilter
        self.onFilterChanged = onFilterChanged
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 245, height: 248))
        root.wantsLayer = true

        let headerRow = NSStackView()
        headerRow.orientation = .horizontal
        headerRow.distribution = .equalSpacing
        headerRow.alignment = .centerY
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        let titleLbl = NSTextField(labelWithString: "Filtro Smart Selezione")
        titleLbl.font = NSFont.systemFont(ofSize: 12, weight: .bold)
        titleLbl.textColor = .white

        let clearBtn = FlatButton(title: "Azzera", target: self, action: #selector(onClearClicked))
        clearBtn.isBoxless = true
        clearBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        clearBtn.isAccentActive = true

        headerRow.addArrangedSubview(titleLbl)
        headerRow.addArrangedSubview(clearBtn)
        root.addSubview(headerRow)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        let prioHeader = NSTextField(labelWithString: "PRIORITÀ")
        prioHeader.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        prioHeader.textColor = .secondaryLabelColor
        stack.addArrangedSubview(prioHeader)

        func makeColorRow(check: NSButton, dotColor: NSColor?) -> NSView {
            check.target = self
            check.action = #selector(onCheckboxToggled)
            check.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
            guard let dotColor = dotColor else { return check }

            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY

            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.backgroundColor = dotColor.cgColor
            dot.layer?.cornerRadius = 4.5
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 9).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 9).isActive = true

            row.addArrangedSubview(dot)
            row.addArrangedSubview(check)
            return row
        }

        stack.addArrangedSubview(makeColorRow(check: p4Check, dotColor: NSColor(calibratedRed: 0.56, green: 0.24, blue: 0.74, alpha: 1.0)))
        stack.addArrangedSubview(makeColorRow(check: p1Check, dotColor: NSColor(calibratedRed: 0.36, green: 0.72, blue: 0.98, alpha: 1.0)))
        stack.addArrangedSubview(makeColorRow(check: p2Check, dotColor: NSColor(calibratedRed: 0.16, green: 0.45, blue: 0.85, alpha: 1.0)))
        stack.addArrangedSubview(makeColorRow(check: p3Check, dotColor: NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.48, alpha: 1.0)))
        stack.addArrangedSubview(makeColorRow(check: noPrioCheck, dotColor: nil))

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 215).isActive = true
        stack.addArrangedSubview(divider)

        let markHeader = NSTextField(labelWithString: "MARCATORI")
        markHeader.font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        markHeader.textColor = .secondaryLabelColor
        stack.addArrangedSubview(markHeader)

        stack.addArrangedSubview(makeColorRow(check: withMarkersCheck, dotColor: nil))
        stack.addArrangedSubview(makeColorRow(check: withoutMarkersCheck, dotColor: nil))

        root.addSubview(stack)

        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            headerRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            headerRow.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            stack.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14)
        ])

        syncCheckboxesFromFilter()
        self.view = root
    }

    private func syncCheckboxesFromFilter() {
        p4Check.state = filter.includePriority4 ? .on : .off
        p1Check.state = filter.includePriority1 ? .on : .off
        p2Check.state = filter.includePriority2 ? .on : .off
        p3Check.state = filter.includePriority3 ? .on : .off
        noPrioCheck.state = filter.includeNoPriority ? .on : .off
        withMarkersCheck.state = filter.includeWithMarkers ? .on : .off
        withoutMarkersCheck.state = filter.includeWithoutMarkers ? .on : .off
    }

    @objc private func onCheckboxToggled() {
        filter.includePriority4 = (p4Check.state == .on)
        filter.includePriority1 = (p1Check.state == .on)
        filter.includePriority2 = (p2Check.state == .on)
        filter.includePriority3 = (p3Check.state == .on)
        filter.includeNoPriority = (noPrioCheck.state == .on)
        filter.includeWithMarkers = (withMarkersCheck.state == .on)
        filter.includeWithoutMarkers = (withoutMarkersCheck.state == .on)
        onFilterChanged(filter)
    }

    @objc private func onClearClicked() {
        filter = SelectionSmartFilter()
        syncCheckboxesFromFilter()
        onFilterChanged(filter)
    }
}

private final class TimelineHorizontalScrollbarView: NSView {
    var onScrollFractionChanged: ((CGFloat) -> Void)?
    var onScrollDeltaX: ((CGFloat) -> Void)?

    private var thumbProportion: CGFloat = 1.0
    private var scrollFraction: CGFloat = 0.0
    private var isDraggingThumb: Bool = false
    private var isHovered: Bool = false
    private var dragStartX: CGFloat = 0.0
    private var dragStartFraction: CGFloat = 0.0
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func updateState(thumbProportion: CGFloat, scrollFraction: CGFloat) {
        let clampedProp = max(0.02, min(1.0, thumbProportion))
        let clampedFrac = max(0.0, min(1.0, scrollFraction))
        if abs(self.thumbProportion - clampedProp) > 0.0005 || abs(self.scrollFraction - clampedFrac) > 0.0005 {
            self.thumbProportion = clampedProp
            self.scrollFraction = clampedFrac
            needsDisplay = true
        }
    }

    private func computeThumbRect() -> CGRect {
        let hPad: CGFloat = 4.0
        let vPad: CGFloat = 2.5
        let trackW = max(1.0, bounds.width - hPad * 2.0)
        let thumbW = max(28.0, min(trackW, trackW * thumbProportion))
        let maxTravel = max(0.0, trackW - thumbW)
        let thumbX = hPad + maxTravel * scrollFraction
        return CGRect(x: thumbX, y: vPad, width: thumbW, height: max(4.0, bounds.height - vPad * 2.0))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Track background (strictly confined to the timeline area right of track headers)
        ctx.setFillColor(NSColor(calibratedWhite: 0.09, alpha: 0.92).cgColor)
        ctx.fill(bounds)

        // Subtle top border
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokeLineSegments(between: [
            CGPoint(x: 0, y: 0.5),
            CGPoint(x: bounds.width, y: 0.5)
        ])

        // Thumb pill
        let thumbRect = computeThumbRect()
        let thumbColor: NSColor
        if isDraggingThumb {
            thumbColor = NSColor.systemCyan.withAlphaComponent(0.85)
        } else if isHovered {
            thumbColor = NSColor(calibratedWhite: 0.58, alpha: 0.95)
        } else {
            thumbColor = NSColor(calibratedWhite: 0.42, alpha: 0.88)
        }
        let radius = thumbRect.height * 0.5
        let path = CGPath(roundedRect: thumbRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.setFillColor(thumbColor.cgColor)
        ctx.addPath(path)
        ctx.fillPath()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        let thumbRect = computeThumbRect()
        let hPad: CGFloat = 4.0
        let trackW = max(1.0, bounds.width - hPad * 2.0)
        let maxTravel = max(1.0, trackW - thumbRect.width)

        if thumbRect.contains(pt) {
            isDraggingThumb = true
            dragStartX = pt.x
            dragStartFraction = scrollFraction
            needsDisplay = true
        } else {
            let targetFraction = max(0.0, min(1.0, (pt.x - hPad - thumbRect.width * 0.5) / maxTravel))
            isDraggingThumb = true
            dragStartX = pt.x
            dragStartFraction = targetFraction
            scrollFraction = targetFraction
            needsDisplay = true
            onScrollFractionChanged?(targetFraction)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDraggingThumb else { return }
        let pt = convert(event.locationInWindow, from: nil)
        let thumbRect = computeThumbRect()
        let hPad: CGFloat = 4.0
        let trackW = max(1.0, bounds.width - hPad * 2.0)
        let maxTravel = max(1.0, trackW - thumbRect.width)
        let deltaFraction = (pt.x - dragStartX) / maxTravel
        let targetFraction = max(0.0, min(1.0, dragStartFraction + deltaFraction))
        scrollFraction = targetFraction
        needsDisplay = true
        onScrollFractionChanged?(targetFraction)
    }

    override func mouseUp(with event: NSEvent) {
        if isDraggingThumb {
            isDraggingThumb = false
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY) ? -event.scrollingDeltaX : -event.scrollingDeltaY
        let step = event.hasPreciseScrollingDeltas ? delta : delta * 14.0
        if abs(step) > 0.01 {
            onScrollDeltaX?(step)
        }
    }
}

private final class ComparePopoverController: NSViewController {
    private let timelines: [TimelineModel]
    private let activeSavedTimeline: TimelineModel
    private let isCurrentlyComparing: Bool
    private let onOpenCompare: (TimelineModel) -> Void
    private let onExitCompare: () -> Void

    private let sourcePopUp = VisionDropdownButton()
    private let referencePopUp = VisionDropdownButton()
    private let swapBtn = FlatButton(title: "⇄ Scambia")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private let openBtn = FlatButton(title: "Apri Confronto")
    private let exitBtn = FlatButton(title: "Esci Confronto")

    private var cachedCompareResult: (timeline: TimelineModel, segmentCount: Int, totalSeconds: Double)?

    init(
        timelines: [TimelineModel],
        activeSavedTimeline: TimelineModel,
        isCurrentlyComparing: Bool,
        onOpenCompare: @escaping (TimelineModel) -> Void,
        onExitCompare: @escaping () -> Void
    ) {
        self.timelines = timelines
        self.activeSavedTimeline = activeSavedTimeline
        self.isCurrentlyComparing = isCurrentlyComparing
        self.onOpenCompare = onOpenCompare
        self.onExitCompare = onExitCompare
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 344, height: 224))
        root.wantsLayer = true

        let titleLbl = NSTextField(labelWithString: "Modalità Confronta (Temporanea)")
        titleLbl.font = NSFont.systemFont(ofSize: 12.5, weight: .bold)
        titleLbl.textColor = .white
        titleLbl.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(titleLbl)

        let subLbl = NSTextField(labelWithString: "Mostra in timeline il girato non usato (non salvato)")
        subLbl.font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        subLbl.textColor = NSColor(calibratedWhite: 0.62, alpha: 1.0)
        subLbl.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(subLbl)

        let srcLbl = NSTextField(labelWithString: "Mostra girato di:")
        srcLbl.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        srcLbl.textColor = NSColor(calibratedWhite: 0.78, alpha: 1.0)
        srcLbl.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(srcLbl)

        sourcePopUp.translatesAutoresizingMaskIntoConstraints = false
        sourcePopUp.onSelectionChanged = { [weak self] _, _ in
            self?.recomputePreview()
        }
        root.addSubview(sourcePopUp)

        let refLbl = NSTextField(labelWithString: "Escludi già in:")
        refLbl.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        refLbl.textColor = NSColor(calibratedWhite: 0.78, alpha: 1.0)
        refLbl.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(refLbl)

        referencePopUp.translatesAutoresizingMaskIntoConstraints = false
        referencePopUp.onSelectionChanged = { [weak self] _, _ in
            self?.recomputePreview()
        }
        root.addSubview(referencePopUp)

        swapBtn.translatesAutoresizingMaskIntoConstraints = false
        swapBtn.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        swapBtn.target = self
        swapBtn.action = #selector(onSwapClicked)
        root.addSubview(swapBtn)

        previewLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        previewLabel.textColor = .systemCyan
        previewLabel.maximumNumberOfLines = 2
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(previewLabel)

        openBtn.translatesAutoresizingMaskIntoConstraints = false
        openBtn.isAccentActive = true
        openBtn.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        openBtn.target = self
        openBtn.action = #selector(onOpenClicked)
        root.addSubview(openBtn)

        exitBtn.translatesAutoresizingMaskIntoConstraints = false
        exitBtn.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        exitBtn.target = self
        exitBtn.action = #selector(onExitClicked)
        exitBtn.isHidden = !isCurrentlyComparing
        root.addSubview(exitBtn)

        NSLayoutConstraint.activate([
            titleLbl.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            titleLbl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            titleLbl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),

            subLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 2),
            subLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
            subLbl.trailingAnchor.constraint(equalTo: titleLbl.trailingAnchor),

            srcLbl.topAnchor.constraint(equalTo: subLbl.bottomAnchor, constant: 12),
            srcLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
            srcLbl.widthAnchor.constraint(equalToConstant: 96),

            sourcePopUp.centerYAnchor.constraint(equalTo: srcLbl.centerYAnchor),
            sourcePopUp.leadingAnchor.constraint(equalTo: srcLbl.trailingAnchor, constant: 8),
            sourcePopUp.trailingAnchor.constraint(equalTo: titleLbl.trailingAnchor),
            sourcePopUp.heightAnchor.constraint(equalToConstant: 24),

            refLbl.topAnchor.constraint(equalTo: sourcePopUp.bottomAnchor, constant: 10),
            refLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
            refLbl.widthAnchor.constraint(equalToConstant: 96),

            referencePopUp.centerYAnchor.constraint(equalTo: refLbl.centerYAnchor),
            referencePopUp.leadingAnchor.constraint(equalTo: refLbl.trailingAnchor, constant: 8),
            referencePopUp.trailingAnchor.constraint(equalTo: titleLbl.trailingAnchor),
            referencePopUp.heightAnchor.constraint(equalToConstant: 24),

            swapBtn.topAnchor.constraint(equalTo: referencePopUp.bottomAnchor, constant: 8),
            swapBtn.trailingAnchor.constraint(equalTo: titleLbl.trailingAnchor),
            swapBtn.widthAnchor.constraint(equalToConstant: 82),
            swapBtn.heightAnchor.constraint(equalToConstant: 22),

            previewLabel.centerYAnchor.constraint(equalTo: swapBtn.centerYAnchor),
            previewLabel.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: swapBtn.leadingAnchor, constant: -8),

            openBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            openBtn.trailingAnchor.constraint(equalTo: titleLbl.trailingAnchor),
            openBtn.widthAnchor.constraint(equalToConstant: 124),
            openBtn.heightAnchor.constraint(equalToConstant: 26),

            exitBtn.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            exitBtn.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
            exitBtn.widthAnchor.constraint(equalToConstant: 108),
            exitBtn.heightAnchor.constraint(equalToConstant: 26)
        ])

        self.view = root
        populatePopUps()
        recomputePreview()
    }

    private func populatePopUps() {
        sourcePopUp.removeAllItems()
        referencePopUp.removeAllItems()

        for tl in timelines {
            let tag = tl.isSelection ? " [Selezione]" : ""
            sourcePopUp.addItem(withTitle: "\(tl.name)\(tag)")
            referencePopUp.addItem(withTitle: "\(tl.name)\(tag)")
        }

        guard !timelines.isEmpty else {
            sourcePopUp.isEnabled = false
            referencePopUp.isEnabled = false
            swapBtn.isEnabled = false
            openBtn.isEnabled = false
            return
        }

        let activeIdx = timelines.firstIndex(where: { $0.id == activeSavedTimeline.id }) ?? 0
        referencePopUp.selectItem(at: activeIdx)

        // Default Sorgente: prima Selezione diversa dalla timeline attiva, altrimenti altro elemento
        if let selIdx = timelines.firstIndex(where: { $0.isSelection && $0.id != activeSavedTimeline.id }) {
            sourcePopUp.selectItem(at: selIdx)
        } else if let otherIdx = timelines.firstIndex(where: { $0.id != activeSavedTimeline.id }) {
            sourcePopUp.selectItem(at: otherIdx)
        } else {
            sourcePopUp.selectItem(at: activeIdx)
        }
    }

    private func recomputePreview() {
        guard timelines.count >= 2 else {
            previewLabel.stringValue = "Servono almeno 2 timeline o selezioni."
            previewLabel.textColor = .systemOrange
            openBtn.isEnabled = false
            openBtn.isAccentActive = false
            cachedCompareResult = nil
            return
        }
        let sIdx = max(0, min(timelines.count - 1, sourcePopUp.selectedIndex))
        let rIdx = max(0, min(timelines.count - 1, referencePopUp.selectedIndex))
        let src = timelines[sIdx]
        let ref = timelines[rIdx]

        if src.id == ref.id {
            previewLabel.stringValue = "Scegli due timeline o selezioni diverse."
            previewLabel.textColor = .systemOrange
            openBtn.isEnabled = false
            openBtn.isAccentActive = false
            cachedCompareResult = nil
            return
        }

        let res = TimelineModel.buildDifferenceCompareTimeline(source: src, excludingReference: ref)
        cachedCompareResult = res
        if res.segmentCount == 0 {
            previewLabel.stringValue = "Nessuna differenza: tutto il girato è già incluso."
            previewLabel.textColor = .systemGreen
            openBtn.isEnabled = false
            openBtn.isAccentActive = false
        } else {
            let mins = Int(res.totalSeconds) / 60
            let secs = Int(res.totalSeconds) % 60
            let durStr = String(format: "%02d:%02d", mins, secs)
            previewLabel.stringValue = "\(res.segmentCount) spezzoni non inclusi (\(durStr))."
            previewLabel.textColor = .systemCyan
            openBtn.isEnabled = true
            openBtn.isAccentActive = true
        }
    }

    @objc private func onSwapClicked() {
        let sIdx = sourcePopUp.selectedIndex
        let rIdx = referencePopUp.selectedIndex
        guard sIdx >= 0, rIdx >= 0 else { return }
        sourcePopUp.selectItem(at: rIdx)
        referencePopUp.selectItem(at: sIdx)
        recomputePreview()
    }

    @objc private func onOpenClicked() {
        guard let res = cachedCompareResult, res.segmentCount > 0 else { return }
        onOpenCompare(res.timeline)
    }

    @objc private func onExitClicked() {
        onExitCompare()
    }
}
