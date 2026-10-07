import AppKit
import AVFoundation

public final class TimelineCanvasView: NSView, NSViewToolTipOwner {
    public var model: TimelineModel
    public var playbackController: PlaybackController
    public var pixelsPerSecond: Double = 40.0 {
        didSet {
            updateWidth()
            needsDisplay = true
        }
    }
    public var onTimelineModified: (() -> Void)?
    public var onResolveMediaItem: ((UUID?, URL?) -> MediaItem?)?
    public var onSectionActivated: (() -> Void)?

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

    public var widthConstraint: NSLayoutConstraint?

    public override var isFlipped: Bool { true }

    public init(model: TimelineModel, playbackController: PlaybackController) {
        self.model = model
        self.playbackController = playbackController
        super.init(frame: .zero)
        self.wantsLayer = true
        registerForDraggedTypes([kMediaItemPasteboardType, .fileURL])

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

    public func updateWidth() {
        let w = calculatedTotalWidth
        widthConstraint?.constant = w
        invalidateIntrinsicContentSize()
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
        ctx.setFillColor(NSColor(calibratedWhite: 0.125, alpha: 1.0).cgColor)
        ctx.fill(bounds)

        // 2. Video Tracks stack UPWARDS from separatorY
        for track in model.videoTracks {
            let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
            let rowRect = CGRect(x: headerWidth, y: trackY, width: bounds.width - headerWidth, height: videoRowHeight)
            let isEven = (track.id % 2 == 0)

            if track.isLocked {
                ctx.setFillColor(NSColor(calibratedRed: 0.14, green: 0.11, blue: 0.11, alpha: 1.0).cgColor)
            } else {
                ctx.setFillColor(isEven ? NSColor(calibratedWhite: 0.175, alpha: 1.0).cgColor : NSColor(calibratedWhite: 0.155, alpha: 1.0).cgColor)
            }
            ctx.fill(rowRect)

            for clip in track.clips {
                drawClip(clip: clip, y: trackY + 2, height: videoRowHeight - 4, isVideo: true, isTrackLocked: track.isLocked, isTrackEnabled: track.isEnabled, ctx: ctx)
            }
        }

        // Center Separator between Video and Audio (Exact 50% Middle)
        let sepRect = CGRect(x: 0, y: sepY - 2, width: bounds.width, height: 4)
        ctx.setFillColor(NSColor(calibratedWhite: 0.07, alpha: 1.0).cgColor)
        ctx.fill(sepRect)

        ctx.setStrokeColor(NSColor(calibratedWhite: 0.32, alpha: 1.0).cgColor)
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
                ctx.setFillColor(NSColor(calibratedRed: 0.14, green: 0.11, blue: 0.11, alpha: 1.0).cgColor)
            } else {
                ctx.setFillColor(isEven ? NSColor(calibratedWhite: 0.165, alpha: 1.0).cgColor : NSColor(calibratedWhite: 0.145, alpha: 1.0).cgColor)
            }
            ctx.fill(rowRect)

            for clip in track.clips {
                drawClip(clip: clip, y: trackY + 2, height: audioRowHeight - 4, isVideo: false, isTrackLocked: track.isLocked, isTrackEnabled: track.isEnabled, ctx: ctx)
            }
        }

        // 3. Track Headers on the left
        drawHeaders(ctx: ctx, bounds: bounds, sepY: sepY)

        // 4. Time Ruler on top
        drawRuler(ctx: ctx, bounds: bounds)

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

        // 7. Playhead
        let playheadSec = CMTimeGetSeconds(playbackController.currentTime)
        let playheadX = headerWidth + CGFloat(playheadSec * pixelsPerSecond)

        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeLineSegments(between: [
            CGPoint(x: playheadX, y: 0),
            CGPoint(x: playheadX, y: bounds.height)
        ])

        // Playhead handle
        let handleRect = CGRect(x: playheadX - 5, y: 0, width: 10, height: rulerHeight - 2)
        ctx.setFillColor(NSColor.systemRed.cgColor)
        ctx.fill(handleRect)

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

        // DaVinci Resolve Style Audio Waveform rendering on audio clips
        if !isVideo && isTrackEnabled && !clip.isOrphan {
            drawWaveform(for: clip, in: rect, ctx: ctx)
        }

        // Selection border
        if clip.isOrphan {
            ctx.setStrokeColor(NSColor.systemRed.cgColor)
            ctx.setLineWidth(isSelected ? 2.5 : 1.5)
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
            let textRect = CGRect(x: x + 4, y: y + 2, width: w - 8, height: 14)
            str.draw(with: textRect, options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin])
        }
    }

    private func drawWaveform(for clip: TimelineClip, in rect: CGRect, ctx: CGContext) {
        guard rect.width > 6 else { return }

        let samples = AudioWaveformCache.shared.samples(for: clip.mediaItem.url)
        let waveformHeight = rect.height - 10
        let centerY = rect.midY + 4

        ctx.saveGState()
        ctx.clip(to: rect.insetBy(dx: 2, dy: 2))

        if let samples = samples, !samples.isEmpty {
            ctx.setStrokeColor(NSColor(calibratedRed: 0.45, green: 0.88, blue: 0.60, alpha: 0.85).cgColor)
            ctx.setLineWidth(1.2)

            let totalMediaSec = max(0.1, CMTimeGetSeconds(clip.mediaItem.duration))
            let sourceInSec = CMTimeGetSeconds(clip.sourceIn)
            let sourceDurSec = CMTimeGetSeconds(clip.duration)

            let sampleCount = samples.count
            let startIdx = max(0, min(sampleCount - 1, Int((sourceInSec / totalMediaSec) * Double(sampleCount))))
            let endIdx = max(startIdx, min(sampleCount - 1, Int(((sourceInSec + sourceDurSec) / totalMediaSec) * Double(sampleCount))))
            let rangeCount = max(1, endIdx - startIdx)

            let step = max(1.2, rect.width / CGFloat(rangeCount))
            var xPos = rect.minX + 2

            for i in startIdx...endIdx {
                let amp = CGFloat(samples[i]) * (waveformHeight / 2.0)
                ctx.strokeLineSegments(between: [
                    CGPoint(x: xPos, y: centerY - amp),
                    CGPoint(x: xPos, y: centerY + amp)
                ])
                xPos += step
                if xPos > rect.maxX - 2 { break }
            }
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
                let aTrackIdx = min(targetTrack, model.maxTracks - 1)
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

    private func drawHeaders(ctx: CGContext, bounds: CGRect, sepY: CGFloat) {
        // Left Column background
        let headerRect = CGRect(x: 0, y: 0, width: headerWidth, height: bounds.height)
        ctx.setFillColor(NSColor(calibratedWhite: 0.14, alpha: 1.0).cgColor)
        ctx.fill(headerRect)

        ctx.setStrokeColor(NSColor(calibratedWhite: 0.28, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokeLineSegments(between: [
            CGPoint(x: headerWidth, y: 0),
            CGPoint(x: headerWidth, y: bounds.height)
        ])

        // Video headers
        for track in model.videoTracks {
            let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
            drawTrackHeaderItem(name: track.name, isLocked: track.isLocked, isEnabled: track.isEnabled, y: trackY, height: videoRowHeight)
        }

        // Audio headers
        for track in model.audioTracks {
            let trackY = sepY + 4 + CGFloat(track.id) * audioRowHeight
            drawTrackHeaderItem(name: track.name, isLocked: track.isLocked, isEnabled: track.isEnabled, y: trackY, height: audioRowHeight)
        }
    }

    private func drawTrackHeaderItem(name: String, isLocked: Bool, isEnabled: Bool, y: CGFloat, height: CGFloat) {
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 11),
            .foregroundColor: NSColor.white
        ]
        NSAttributedString(string: name, attributes: nameAttrs).draw(at: CGPoint(x: 8, y: y + (height - 14) / 2))

        let lockIcon = isLocked ? "🔒" : "🔓"
        let lockAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11)
        ]
        NSAttributedString(string: lockIcon, attributes: lockAttrs).draw(at: CGPoint(x: 42, y: y + (height - 14) / 2))

        let eyeIcon = isEnabled ? "👁️" : "🚫"
        NSAttributedString(string: eyeIcon, attributes: lockAttrs).draw(at: CGPoint(x: 74, y: y + (height - 14) / 2))
    }

    private func drawRuler(ctx: CGContext, bounds: CGRect) {
        let rulerRect = CGRect(x: 0, y: 0, width: bounds.width, height: rulerHeight)
        ctx.setFillColor(NSColor(calibratedWhite: 0.18, alpha: 1.0).cgColor)
        ctx.fill(rulerRect)

        ctx.setStrokeColor(NSColor(calibratedWhite: 0.35, alpha: 1.0).cgColor)
        ctx.setLineWidth(1.0)
        ctx.strokeLineSegments(between: [
            CGPoint(x: 0, y: rulerHeight),
            CGPoint(x: bounds.width, y: rulerHeight)
        ])

        let stepSec: Double = pixelsPerSecond >= 80 ? 1.0 : (pixelsPerSecond >= 30 ? 5.0 : 10.0)
        let totalSeconds = max(30.0, CMTimeGetSeconds(model.totalDuration) + 10.0)

        var t: Double = 0.0
        while t <= totalSeconds {
            let x = headerWidth + CGFloat(t * pixelsPerSecond)
            if x >= headerWidth && x <= bounds.width {
                ctx.setStrokeColor(NSColor(calibratedWhite: 0.5, alpha: 1.0).cgColor)
                ctx.strokeLineSegments(between: [
                    CGPoint(x: x, y: rulerHeight - 8),
                    CGPoint(x: x, y: rulerHeight)
                ])

                let mins = Int(t) / 60
                let secs = Int(t) % 60
                let label = String(format: "%02d:%02d", mins, secs)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                    .foregroundColor: NSColor(calibratedWhite: 0.7, alpha: 1.0)
                ]
                NSAttributedString(string: label, attributes: attrs).draw(at: CGPoint(x: x + 2, y: 2))
            }
            t += stepSec
        }
    }

    // MARK: - Mouse & Drag Handlers
    public override func mouseDown(with event: NSEvent) {
        onSectionActivated?()
        let localPoint = convert(event.locationInWindow, from: nil)
        let isShift = event.modifierFlags.contains(.shift)
        let sepY = separatorY

        // 1. Clicked in Ruler: Scrub playhead
        if localPoint.y <= rulerHeight {
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

        // 2. Clicked in Track Header area (Left Column): Toggle Lock / Enable
        if localPoint.x < headerWidth {
            // Check Video Tracks
            for track in model.videoTracks {
                let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
                if localPoint.y >= trackY && localPoint.y <= trackY + videoRowHeight {
                    if localPoint.x >= 38 && localPoint.x <= 64 {
                        model.toggleTrackLock(id: track.id, isVideo: true)
                        needsDisplay = true
                        return
                    } else if localPoint.x >= 70 && localPoint.x <= 96 {
                        model.toggleTrackEnabled(id: track.id, isVideo: true)
                        needsDisplay = true
                        onTimelineModified?()
                        return
                    }
                }
            }
            // Check Audio Tracks
            for track in model.audioTracks {
                let trackY = sepY + 4 + CGFloat(track.id) * audioRowHeight
                if localPoint.y >= trackY && localPoint.y <= trackY + audioRowHeight {
                    if localPoint.x >= 38 && localPoint.x <= 64 {
                        model.toggleTrackLock(id: track.id, isVideo: false)
                        needsDisplay = true
                        return
                    } else if localPoint.x >= 70 && localPoint.x <= 96 {
                        model.toggleTrackEnabled(id: track.id, isVideo: false)
                        needsDisplay = true
                        onTimelineModified?()
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
                            draggedClipId = clip.id
                            draggedClipIsVideo = true
                            dragInitialPoint = localPoint
                            dragInitialStartTime = clip.timelineStart
                            dragInitialTrackIndex = track.id
                            currentDragTime = clip.timelineStart
                            currentDragTrackIndex = track.id

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
                            draggedClipId = clip.id
                            draggedClipIsVideo = false
                            dragInitialPoint = localPoint
                            dragInitialStartTime = clip.timelineStart
                            dragInitialTrackIndex = track.id
                            currentDragTime = clip.timelineStart
                            currentDragTrackIndex = track.id

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

            // Snapping calculation
            let snapThreshold = 10.0 / pixelsPerSecond
            let snapRes = model.snap(startTime: newTime, duration: clipDuration, playhead: playbackController.currentTime, thresholdSeconds: snapThreshold)
            if snapRes.didSnap {
                newTime = snapRes.snappedTime
                activeSnapLineTime = snapRes.snapPoint
            } else {
                activeSnapLineTime = nil
            }

            // Target Track calculation
            var targetTrackIndex = dragInitialTrackIndex
            if draggedClipIsVideo {
                let trackFloat = (sepY - localPoint.y) / videoRowHeight
                let calculatedTrack = max(0, min(model.maxTracks - 1, Int(trackFloat)))
                targetTrackIndex = calculatedTrack
                if targetTrackIndex >= model.videoTracks.count && targetTrackIndex < model.maxTracks {
                    model.ensureVideoTrack(id: targetTrackIndex)
                }
            } else {
                let trackFloat = (localPoint.y - sepY - 4) / audioRowHeight
                let calculatedTrack = max(0, min(model.maxTracks - 1, Int(trackFloat)))
                targetTrackIndex = calculatedTrack
                if targetTrackIndex >= model.audioTracks.count && targetTrackIndex < model.maxTracks {
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
            onTimelineModified?()
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
                playbackController.scrub(to: targetTime)
                if model.isSelectionFollowsPlayhead {
                    model.updateSelectionAtPlayhead(time: targetTime)
                }
            }

            isMarqueeSelecting = false
            needsDisplay = true
        }
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let localPoint = convert(event.locationInWindow, from: nil)
        var clickedClip: TimelineClip? = nil
        let sepY = separatorY

        for track in model.videoTracks {
            let trackY = sepY - CGFloat(track.id + 1) * videoRowHeight
            if localPoint.y >= trackY && localPoint.y <= trackY + videoRowHeight {
                for clip in track.clips {
                    let clipX = headerWidth + CGFloat(CMTimeGetSeconds(clip.timelineStart) * pixelsPerSecond)
                    let clipW = CGFloat(CMTimeGetSeconds(clip.duration) * pixelsPerSecond)
                    if localPoint.x >= clipX && localPoint.x <= clipX + clipW {
                        clickedClip = clip
                        break
                    }
                }
            }
        }

        guard let clip = clickedClip else { return nil }
        model.selectedClipId = clip.id
        needsDisplay = true

        let menu = NSMenu(title: "Opzioni Clip")
        menu.addItem(withTitle: "Clip: \(clip.mediaItem.name)", action: nil, keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        let orientationMenu = NSMenu(title: "Orientamento")
        for orient in ClipOrientation.allCases {
            let item = NSMenuItem(title: orient.rawValue, action: #selector(onSelectOrientation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = (clip.id, orient)
            if clip.orientation == orient {
                item.state = .on
            }
            orientationMenu.addItem(item)
        }

        let orientItem = NSMenuItem(title: "Imposta Orientamento", action: nil, keyEquivalent: "")
        orientItem.submenu = orientationMenu
        menu.addItem(orientItem)

        return menu
    }

    @objc private func onSelectOrientation(_ sender: NSMenuItem) {
        guard let (clipId, orient) = sender.representedObject as? (UUID, ClipOrientation) else { return }
        model.setClipOrientation(id: clipId, orientation: orient)
        DebugLogger.shared.log("Orientamento clip aggiornato a: \(orient.rawValue)", level: .info)
        needsDisplay = true
        onTimelineModified?()
    }

    // MARK: - Tooltip Support (Media Offline)
    public override func updateTrackingAreas() {
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
        currentDraggingItems = extractMediaItems(from: sender)
        guard !currentDraggingItems.isEmpty else { return [] }
        updateDropPreview(with: sender)
        needsDisplay = true
        return .copy
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !currentDraggingItems.isEmpty else { return [] }
        updateDropPreview(with: sender)
        needsDisplay = true
        return .copy
    }

    public override func draggingExited(_ sender: NSDraggingInfo?) {
        dropPreviewTime = nil
        currentDraggingItems = []
        activeSnapLineTime = nil
        needsDisplay = true
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let items = extractMediaItems(from: sender)
        guard !items.isEmpty, let dropTime = dropPreviewTime else {
            dropPreviewTime = nil
            currentDraggingItems = []
            needsDisplay = true
            return false
        }

        let isVideo = dropPreviewIsVideo
        let targetTrack = dropPreviewTrackIndex

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

        dropPreviewTime = nil
        currentDraggingItems = []
        activeSnapLineTime = nil
        updateWidth()
        onTimelineModified?()
        needsDisplay = true
        return true
    }

    private func updateDropPreview(with sender: NSDraggingInfo) {
        let localPoint = convert(sender.draggingLocation, from: nil)
        let sepY = separatorY

        let isVideo = localPoint.y < sepY
        dropPreviewIsVideo = isVideo

        let rawTargetTrack: Int
        if isVideo {
            let trackFloat = (sepY - localPoint.y) / videoRowHeight
            rawTargetTrack = max(0, min(model.maxTracks - 1, Int(trackFloat)))
            if rawTargetTrack >= model.videoTracks.count && rawTargetTrack < model.maxTracks {
                model.ensureVideoTrack(id: rawTargetTrack)
            }
        } else {
            let trackFloat = (localPoint.y - sepY - 4) / audioRowHeight
            rawTargetTrack = max(0, min(model.maxTracks - 1, Int(trackFloat)))
            if rawTargetTrack >= model.audioTracks.count && rawTargetTrack < model.maxTracks {
                model.ensureAudioTrack(id: rawTargetTrack)
            }
        }
        dropPreviewTrackIndex = rawTargetTrack

        let targetX = max(headerWidth, localPoint.x)
        let rawSeconds = max(0, Double(targetX - headerWidth) / pixelsPerSecond)
        var proposedTime = CMTime(seconds: rawSeconds, preferredTimescale: 600)

        if model.isSnappingActive {
            let totalDur = currentDraggingItems.reduce(CMTime.zero) { CMTimeAdd($0, $1.duration) }
            let snapThreshold = 10.0 / pixelsPerSecond
            let snapRes = model.snap(startTime: proposedTime, duration: totalDur, playhead: playbackController.currentTime, thresholdSeconds: snapThreshold)
            if snapRes.didSnap {
                proposedTime = snapRes.snappedTime
                activeSnapLineTime = snapRes.snapPoint
            } else {
                activeSnapLineTime = nil
            }
        } else {
            activeSnapLineTime = nil
        }

        dropPreviewTime = proposedTime
    }

    private func extractMediaItems(from sender: NSDraggingInfo) -> [MediaItem] {
        var result: [MediaItem] = []
        let pboard = sender.draggingPasteboard
        if let pbItems = pboard.pasteboardItems {
            for pbItem in pbItems {
                let idStr = pbItem.string(forType: kMediaItemPasteboardType)
                let uuid = idStr != nil ? UUID(uuidString: idStr!) : nil
                var fileURL: URL? = nil
                if let urlOrPath = pbItem.string(forType: .fileURL) {
                    if urlOrPath.hasPrefix("file://") {
                        fileURL = URL(string: urlOrPath)
                    } else {
                        fileURL = URL(fileURLWithPath: urlOrPath)
                    }
                } else if let pathStr = pbItem.string(forType: .string), pathStr.hasPrefix("/") {
                    fileURL = URL(fileURLWithPath: pathStr)
                }
                if let mediaItem = onResolveMediaItem?(uuid, fileURL) {
                    if !result.contains(where: { $0.id == mediaItem.id }) {
                        result.append(mediaItem)
                    }
                }
            }
        }
        if result.isEmpty {
            if let urls = pboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
                for u in urls {
                    if let mediaItem = onResolveMediaItem?(nil, u) {
                        if !result.contains(where: { $0.id == mediaItem.id }) {
                            result.append(mediaItem)
                        }
                    }
                }
            }
        }
        return result
    }
}

public final class TimelineViewController: NSViewController {
    public var model: TimelineModel
    public let playbackController: PlaybackController
    public var onTimelineModified: (() -> Void)?
    public var onFormatChangedCallback: ((TimelineFormat) -> Void)?
    public var onResolveMediaItem: ((UUID?, URL?) -> MediaItem?)?
    public var onSectionActivated: (() -> Void)?
    public var onSwitchTimeline: ((TimelineModel) -> Void)?

    private var canvasView: TimelineCanvasView!
    private let scrollView = NSScrollView()
    private let timelineIndicatorBtn = FlatButton()
    private let timecodeLabel = NSTextField(labelWithString: "00:00:00:00")
    private let formatPopUp = NSPopUpButton()

    // Pro NLE Toolbar Controls
    private let linkButton = NSButton()
    private let magnetButton = NSButton()
    private let selectionFollowsPlayheadButton = NSButton()
    private let cleanTracksButton = NSButton()
    private let closeGapsButton = NSButton()

    private let trimStartButton = NSButton()
    private let trimEndButton = NSButton()
    private let splitButton = NSButton()
    private let deleteButton = NSButton()
    private let addVideoTrackButton = NSButton()
    private let addAudioTrackButton = NSButton()
    private let zoomSlider = NSSlider()

    public init(model: TimelineModel, playbackController: PlaybackController) {
        self.model = model
        self.playbackController = playbackController
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        root.addSubview(toolbar)

        setupToolbar(toolbar)

        canvasView = TimelineCanvasView(model: model, playbackController: playbackController)
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        canvasView.onTimelineModified = { [weak self] in
            self?.onTimelineModified?()
        }
        canvasView.onResolveMediaItem = { [weak self] id, url in
            self?.onResolveMediaItem?(id, url)
        }
        canvasView.onSectionActivated = { [weak self] in
            self?.onSectionActivated?()
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = canvasView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        root.addSubview(scrollView)

        let widthC = canvasView.widthAnchor.constraint(greaterThanOrEqualToConstant: canvasView.calculatedTotalWidth)
        canvasView.widthConstraint = widthC

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 42),

            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            canvasView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            canvasView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
            canvasView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.widthAnchor),
            widthC
        ])

        let oldCallback = playbackController.onTimeChanged
        playbackController.onTimeChanged = { [weak self] time in
            oldCallback?(time)
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.model.isSelectionFollowsPlayhead {
                    self.model.updateSelectionAtPlayhead(time: time)
                }
                self.canvasView.needsDisplay = true
                self.timecodeLabel.stringValue = self.playbackController.formattedCurrentTime
            }
        }

        self.view = root
    }

    private func setupToolbar(_ toolbar: NSView) {
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.alignment = .centerY
        toolbar.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: toolbar.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])

        timelineIndicatorBtn.title = "  \(model.name)"
        timelineIndicatorBtn.image = Lucide.image(.clapperboard, size: 14, color: .systemCyan)
        timelineIndicatorBtn.toolTip = "Timeline attiva (Clicca per cambiare)"
        timelineIndicatorBtn.target = self
        timelineIndicatorBtn.action = #selector(onTimelineIndicatorClicked)
        stack.addArrangedSubview(timelineIndicatorBtn)

        timecodeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        stack.addArrangedSubview(timecodeLabel)

        formatPopUp.bezelStyle = .rounded
        formatPopUp.target = self
        formatPopUp.action = #selector(onFormatChanged)
        for preset in TimelineFormat.presets {
            formatPopUp.addItem(withTitle: preset.name)
        }
        formatPopUp.selectItem(withTitle: model.format.name)
        stack.addArrangedSubview(formatPopUp)

        updateLinkButtonTitle()
        linkButton.bezelStyle = .rounded
        linkButton.target = self
        linkButton.action = #selector(onLinkToggleClicked)
        stack.addArrangedSubview(linkButton)

        updateMagnetButtonTitle()
        magnetButton.bezelStyle = .rounded
        magnetButton.target = self
        magnetButton.action = #selector(onMagnetToggleClicked)
        stack.addArrangedSubview(magnetButton)

        updateSelectionFollowsPlayheadButtonTitle()
        selectionFollowsPlayheadButton.bezelStyle = .rounded
        selectionFollowsPlayheadButton.target = self
        selectionFollowsPlayheadButton.action = #selector(onSelectionFollowsPlayheadClicked)
        selectionFollowsPlayheadButton.toolTip = "Seleziona clip sotto la testina durante lo scorrimento (Resolve style)"
        stack.addArrangedSubview(selectionFollowsPlayheadButton)

        cleanTracksButton.title = "🧹 Pulisci"
        cleanTracksButton.bezelStyle = .rounded
        cleanTracksButton.target = self
        cleanTracksButton.action = #selector(onCleanTracksClicked)
        stack.addArrangedSubview(cleanTracksButton)

        closeGapsButton.title = "Chiudi Spazi (⌥⌘W)"
        closeGapsButton.bezelStyle = .rounded
        closeGapsButton.target = self
        closeGapsButton.action = #selector(onCloseGapsClicked)
        stack.addArrangedSubview(closeGapsButton)

        trimStartButton.title = "Trim Inizio (Q)"
        trimStartButton.bezelStyle = .rounded
        trimStartButton.target = self
        trimStartButton.action = #selector(onTrimStartClicked)
        stack.addArrangedSubview(trimStartButton)

        trimEndButton.title = "Trim Fine (W)"
        trimEndButton.bezelStyle = .rounded
        trimEndButton.target = self
        trimEndButton.action = #selector(onTrimEndClicked)
        stack.addArrangedSubview(trimEndButton)

        splitButton.title = "Spezza (S)"
        splitButton.bezelStyle = .rounded
        splitButton.target = self
        splitButton.action = #selector(onSplitClicked)
        stack.addArrangedSubview(splitButton)

        addVideoTrackButton.title = "+ V"
        addVideoTrackButton.bezelStyle = .rounded
        addVideoTrackButton.target = self
        addVideoTrackButton.action = #selector(onAddVideoTrackClicked)
        stack.addArrangedSubview(addVideoTrackButton)

        addAudioTrackButton.title = "+ A"
        addAudioTrackButton.bezelStyle = .rounded
        addAudioTrackButton.target = self
        addAudioTrackButton.action = #selector(onAddAudioTrackClicked)
        stack.addArrangedSubview(addAudioTrackButton)

        deleteButton.title = "Elimina (Scarto)"
        deleteButton.toolTip = "Elimina le clip selezionate chiudendo subito lo spazio vuoto"
        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(onDeleteClicked)
        stack.addArrangedSubview(deleteButton)

        zoomSlider.minValue = 10.0
        zoomSlider.maxValue = 150.0
        zoomSlider.doubleValue = 40.0
        zoomSlider.target = self
        zoomSlider.action = #selector(onZoomChanged)
        zoomSlider.widthAnchor.constraint(equalToConstant: 70).isActive = true

        let zoomLabel = NSTextField(labelWithString: "Zoom:")
        zoomLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(zoomLabel)
        stack.addArrangedSubview(zoomSlider)
    }

    private func updateLinkButtonTitle() {
        linkButton.title = model.isLinkActive ? "🔗 Link: ON" : "⛓️ Link: OFF"
    }

    private func updateMagnetButtonTitle() {
        magnetButton.title = model.isSnappingActive ? "🧲 Magnet: ON" : "🧲 Magnet: OFF"
    }

    private func updateSelectionFollowsPlayheadButtonTitle() {
        selectionFollowsPlayheadButton.title = model.isSelectionFollowsPlayhead ? "🎯 Sotto Testina: ON" : "🎯 Sotto Testina: OFF"
    }

    public func reloadTimelineUI() {
        timelineIndicatorBtn.title = "  \(model.name)"
        updateLinkButtonTitle()
        updateMagnetButtonTitle()
        updateSelectionFollowsPlayheadButtonTitle()
        formatPopUp.selectItem(withTitle: model.format.name)
        canvasView.updateWidth()
        canvasView.needsDisplay = true
    }

    public func switchModel(_ newModel: TimelineModel) {
        self.model = newModel
        self.canvasView.model = newModel
        timelineIndicatorBtn.title = "  \(newModel.name)"
        reloadTimelineUI()
    }

    @objc private func onTimelineIndicatorClicked() {
        let menu = NSMenu(title: "Seleziona Timeline")
        for (idx, tl) in EditorProject.shared.timelines.enumerated() {
            let item = NSMenuItem(title: "🎞️ \(tl.name)", action: #selector(onSelectTimelineFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = idx
            if tl.id == model.id {
                item.state = .on
            }
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: timelineIndicatorBtn.bounds.height + 4), in: timelineIndicatorBtn)
    }

    @objc private func onSelectTimelineFromMenu(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int, idx < EditorProject.shared.timelines.count else { return }
        EditorProject.shared.activeTimelineIndex = idx
        let targetTL = EditorProject.shared.timelines[idx]
        onSwitchTimeline?(targetTL)
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

    @objc public func onCleanTracksClicked() {
        model.cleanEmptyTracks()
        reloadTimelineUI()
        onTimelineModified?()
    }

    @objc public func onCloseGapsClicked() {
        model.closeGapsBetweenSelectedClips()
        reloadTimelineUI()
        onTimelineModified?()
    }

    @objc private func onFormatChanged() {
        let index = formatPopUp.indexOfSelectedItem
        if index >= 0 && index < TimelineFormat.presets.count {
            model.format = TimelineFormat.presets[index]
            DebugLogger.shared.log("Formato Timeline: \(model.format.name)", level: .info)
            onFormatChangedCallback?(model.format)
            onTimelineModified?()
        }
    }

    @objc private func onTrimStartClicked() {
        model.trimClipStart(at: playbackController.currentTime)
        reloadTimelineUI()
        onTimelineModified?()
    }

    @objc private func onTrimEndClicked() {
        model.trimClipEnd(at: playbackController.currentTime)
        reloadTimelineUI()
        onTimelineModified?()
    }

    @objc private func onSplitClicked() {
        model.splitClip(at: playbackController.currentTime)
        reloadTimelineUI()
        onTimelineModified?()
    }

    @objc private func onAddVideoTrackClicked() {
        if model.videoTracks.count < model.maxTracks {
            model.ensureVideoTrack(id: model.videoTracks.count)
            DebugLogger.shared.log("Aggiunta traccia video V\(model.videoTracks.count)", level: .info)
            reloadTimelineUI()
            onTimelineModified?()
        }
    }

    @objc private func onAddAudioTrackClicked() {
        if model.audioTracks.count < model.maxTracks {
            model.ensureAudioTrack(id: model.audioTracks.count)
            DebugLogger.shared.log("Aggiunta traccia audio A\(model.audioTracks.count)", level: .info)
            reloadTimelineUI()
            onTimelineModified?()
        }
    }

    @objc private func onDeleteClicked() {
        if model.selectedClipIds.isEmpty && model.isSelectionFollowsPlayhead {
            model.updateSelectionAtPlayhead(time: playbackController.currentTime)
        }
        if !model.selectedClipIds.isEmpty {
            model.removeSelectedClips()
            reloadTimelineUI()
            onTimelineModified?()
        }
    }

    @objc private func onZoomChanged() {
        canvasView.pixelsPerSecond = zoomSlider.doubleValue
    }
}
