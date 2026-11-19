import AppKit

// MARK: - Speed Editor SVG Data Structures & Parser

private struct SpeedEditorSVGText {
    let text: String
    let position: CGPoint
    let fontSize: CGFloat
    let fontWeight: NSFont.Weight
    let fill: NSColor
    let anchor: String // "start", "middle", "end"
}

private struct SpeedEditorSVGShape {
    let path: CGPath
    let fill: NSColor?
    let stroke: NSColor?
    let strokeWidth: CGFloat
}

private struct SpeedEditorSVGElement {
    let id: String
    let hitPath: CGPath
    let bounds: CGRect
    let shapes: [SpeedEditorSVGShape] // shape[0] = main keycap / outer wheel; shape[1] on keys = optional LED bar
    let texts: [SpeedEditorSVGText]
}

private struct SpeedEditorSVGDocument {
    let viewBox: CGRect
    let chassis: SpeedEditorSVGShape?
    let trays: [SpeedEditorSVGShape]
    let chromeShapes: [SpeedEditorSVGShape]
    let chromeTexts: [SpeedEditorSVGText]
    let elements: [SpeedEditorSVGElement] // 43 buttons + se-jog-wheel
}

private final class SpeedEditorSVGParser: NSObject, XMLParserDelegate {
    private var viewBox = CGRect(x: 0, y: 0, width: 996, height: 646)
    private var chassis: SpeedEditorSVGShape?
    private var trays: [SpeedEditorSVGShape] = []
    private var chromeShapes: [SpeedEditorSVGShape] = []
    private var chromeTexts: [SpeedEditorSVGText] = []
    private var elements: [SpeedEditorSVGElement] = []

    private var groupDepth = 0
    private var activeGroupId: String?
    private var activeGroupDepth = 0
    private var activeShapes: [SpeedEditorSVGShape] = []
    private var activeTexts: [SpeedEditorSVGText] = []

    private var activeTextMeta: (
        pos: CGPoint,
        fontSize: CGFloat,
        weight: NSFont.Weight,
        fill: NSColor,
        anchor: String,
        buffer: String
    )?

    static func parseBundledSVG() -> SpeedEditorSVGDocument? {
        guard let url = resolveSVGURL(), let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parse(data: data)
    }

    static func resolveSVGURL() -> URL? {
        if let resURL = Bundle.main.url(forResource: "speed_editor", withExtension: "svg") {
            return resURL
        }
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/speed_editor.svg"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("speed_editor.svg"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/speed_editor.svg")
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    static func parse(data: Data) -> SpeedEditorSVGDocument? {
        let handler = SpeedEditorSVGParser()
        let xml = XMLParser(data: data)
        xml.delegate = handler
        guard xml.parse(), !handler.elements.isEmpty else { return nil }
        return SpeedEditorSVGDocument(
            viewBox: handler.viewBox,
            chassis: handler.chassis,
            trays: handler.trays,
            chromeShapes: handler.chromeShapes,
            chromeTexts: handler.chromeTexts,
            elements: handler.elements
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "svg":
            if let vb = attributeDict["viewBox"] {
                let nums = Self.parseNumbers(vb)
                if nums.count == 4 {
                    viewBox = CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
                }
            }

        case "g":
            groupDepth += 1
            if activeGroupId == nil, let gid = attributeDict["id"], gid.hasPrefix("se-") {
                activeGroupId = gid
                activeGroupDepth = groupDepth
                activeShapes = []
                activeTexts = []
            }

        case "rect":
            let x = CGFloat(Double(attributeDict["x"] ?? "0") ?? 0)
            let y = CGFloat(Double(attributeDict["y"] ?? "0") ?? 0)
            let w = CGFloat(Double(attributeDict["width"] ?? "0") ?? 0)
            let h = CGFloat(Double(attributeDict["height"] ?? "0") ?? 0)
            let rx = CGFloat(Double(attributeDict["rx"] ?? attributeDict["ry"] ?? "0") ?? 0)
            let ry = CGFloat(Double(attributeDict["ry"] ?? attributeDict["rx"] ?? "0") ?? 0)
            let path = CGPath(
                roundedRect: CGRect(x: x, y: y, width: w, height: h),
                cornerWidth: min(rx, w * 0.5),
                cornerHeight: min(ry, h * 0.5),
                transform: nil
            )
            let shape = SpeedEditorSVGShape(
                path: path,
                fill: Self.parseColor(attributeDict["fill"]),
                stroke: Self.parseColor(attributeDict["stroke"]),
                strokeWidth: CGFloat(Double(attributeDict["stroke-width"] ?? "1.5") ?? 1.5)
            )
            let rid = attributeDict["id"] ?? ""
            if rid == "speed-editor-chassis" {
                chassis = shape
            } else if rid.hasPrefix("tray-") {
                trays.append(shape)
            } else if activeGroupId != nil {
                activeShapes.append(shape)
            } else {
                chromeShapes.append(shape)
            }

        case "circle":
            let cx = CGFloat(Double(attributeDict["cx"] ?? "0") ?? 0)
            let cy = CGFloat(Double(attributeDict["cy"] ?? "0") ?? 0)
            let r = CGFloat(Double(attributeDict["r"] ?? "0") ?? 0)
            let path = CGPath(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2), transform: nil)
            let shape = SpeedEditorSVGShape(
                path: path,
                fill: Self.parseColor(attributeDict["fill"]),
                stroke: Self.parseColor(attributeDict["stroke"]),
                strokeWidth: CGFloat(Double(attributeDict["stroke-width"] ?? "1.5") ?? 1.5)
            )
            if activeGroupId != nil {
                activeShapes.append(shape)
            } else {
                chromeShapes.append(shape)
            }

        case "text":
            let x = CGFloat(Double(attributeDict["x"] ?? "0") ?? 0)
            let y = CGFloat(Double(attributeDict["y"] ?? "0") ?? 0)
            let fsize = CGFloat(Double(attributeDict["font-size"] ?? "11") ?? 11)
            let weightNum = Double(attributeDict["font-weight"] ?? "500") ?? 500
            let weight: NSFont.Weight = weightNum >= 600 ? .semibold : (weightNum >= 500 ? .medium : .regular)
            let fill = Self.parseColor(attributeDict["fill"]) ?? NSColor(calibratedWhite: 0.9, alpha: 1.0)
            let anchor = attributeDict["text-anchor"] ?? "start"
            activeTextMeta = (CGPoint(x: x, y: y), fsize, weight, fill, anchor, "")

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeTextMeta != nil {
            activeTextMeta?.buffer.append(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "text":
            if let meta = activeTextMeta {
                let cleaned = meta.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    let elem = SpeedEditorSVGText(
                        text: cleaned,
                        position: meta.pos,
                        fontSize: meta.fontSize,
                        fontWeight: meta.weight,
                        fill: meta.fill,
                        anchor: meta.anchor
                    )
                    if activeGroupId != nil {
                        activeTexts.append(elem)
                    } else {
                        chromeTexts.append(elem)
                    }
                }
                activeTextMeta = nil
            }

        case "g":
            if let gid = activeGroupId, groupDepth == activeGroupDepth {
                if let primaryShape = activeShapes.first {
                    elements.append(SpeedEditorSVGElement(
                        id: gid,
                        hitPath: primaryShape.path,
                        bounds: primaryShape.path.boundingBoxOfPath,
                        shapes: activeShapes,
                        texts: activeTexts
                    ))
                }
                activeGroupId = nil
                activeGroupDepth = 0
                activeShapes = []
                activeTexts = []
            }
            groupDepth -= 1

        default:
            break
        }
    }

    private static func parseNumbers(_ raw: String) -> [CGFloat] {
        let seps = CharacterSet(charactersIn: ", \t\r\n")
        return raw.components(separatedBy: seps).compactMap { tok in
            let s = tok.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, let v = Double(s) else { return nil }
            return CGFloat(v)
        }
    }

    private static func parseColor(_ raw: String?) -> NSColor? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty, raw != "none" else { return nil }
        if raw.hasPrefix("#") {
            let hex = String(raw.dropFirst())
            guard hex.count == 6, let val = UInt32(hex, radix: 16) else { return nil }
            return NSColor(
                srgbRed: CGFloat((val >> 16) & 0xFF) / 255.0,
                green: CGFloat((val >> 8) & 0xFF) / 255.0,
                blue: CGFloat(val & 0xFF) / 255.0,
                alpha: 1.0
            )
        }
        return nil
    }
}

// MARK: - Interactive Speed Editor Vector View

/// Vista vettoriale interattiva basata su `speed_editor.svg`: click sui tasti o Search Dial, LED hardware e indicatori Tap / Double Tap.
public final class InteractiveSpeedEditorView: NSView {
    public static let searchDialSVGId = "se-jog-wheel"

    private let document: SpeedEditorSVGDocument?

    public var selectedElementId: String? {
        didSet { needsDisplay = true }
    }
    public var highlightedButton: SpeedEditorButton? {
        didSet { needsDisplay = true }
    }
    public var searchQuery: String = "" {
        didSet { needsDisplay = true }
    }

    public var onElementSelected: ((String) -> Void)?

    private var hoveredElementId: String? {
        didSet {
            if oldValue != hoveredElementId {
                needsDisplay = true
                updateTooltipAndCursor()
            }
        }
    }
    private var trackingAreaRef: NSTrackingArea?

    public override var isFlipped: Bool { true }

    public var svgAspectRatio: CGFloat {
        guard let vb = document?.viewBox, vb.height > 0 else { return 996.0 / 646.0 }
        return vb.width / vb.height
    }

    public var hasLoadedSVG: Bool {
        guard let doc = document else { return false }
        return !doc.elements.isEmpty
    }

    public var parsedElementCount: Int {
        document?.elements.count ?? 0
    }

    public func containsElement(id: String) -> Bool {
        document?.elements.contains(where: { $0.id == id }) ?? false
    }

    public init() {
        self.document = SpeedEditorSVGParser.parseBundledSVG()
        super.init(frame: .zero)
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    private func computeSVGTransform() -> (transform: CGAffineTransform, scale: CGFloat) {
        let vb = document?.viewBox ?? CGRect(x: 0, y: 0, width: 996, height: 646)
        let insetBounds = bounds.insetBy(dx: 2, dy: 2)
        guard insetBounds.width > 10, insetBounds.height > 10, vb.width > 0, vb.height > 0 else {
            return (.identity, 1.0)
        }
        let scale = min(insetBounds.width / vb.width, insetBounds.height / vb.height)
        let drawnW = vb.width * scale
        let drawnH = vb.height * scale
        let offsetX = insetBounds.minX + (insetBounds.width - drawnW) * 0.5 - vb.minX * scale
        let offsetY = insetBounds.minY + (insetBounds.height - drawnH) * 0.5 - vb.minY * scale
        let t = CGAffineTransform(translationX: offsetX, y: offsetY).scaledBy(x: scale, y: scale)
        return (t, scale)
    }

    private func hitElementId(at viewPoint: CGPoint) -> String? {
        guard let doc = document else { return nil }
        let (svgToView, _) = computeSVGTransform()
        let svgPt = viewPoint.applying(svgToView.inverted())
        for elem in doc.elements.reversed() {
            if elem.hitPath.contains(svgPt) {
                return elem.id
            }
        }
        return nil
    }

    private func updateTooltipAndCursor() {
        guard let elemId = hoveredElementId else {
            toolTip = nil
            NSCursor.arrow.set()
            return
        }
        NSCursor.pointingHand.set()
        if elemId == Self.searchDialSVGId {
            let mgr = SpeedEditorManager.shared
            toolTip = "Search Dial — Modalità: \(mgr.currentWheelMode.rawValue) (Sensibilità \(String(format: "%.1fx", mgr.wheelSensitivity)))\nClicca per regolare rotella"
            return
        }
        guard let btn = SpeedEditorButton.fromSVGId(elemId) else {
            toolTip = elemId
            return
        }
        let mgr = SpeedEditorManager.shared
        let tapTitle = mgr.action(for: btn).displayTitle
        let dtTitle = mgr.doubleTapAction(for: btn).displayTitle
        var header = btn.label
        if let sec = btn.secondaryHardwareLabel {
            header += " (\(sec))"
        }
        toolTip = "\(header)\nTap singolo: \(tapTitle)\nDouble Tap: \(dtTitle)"
    }

    public override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoveredElementId = hitElementId(at: pt)
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredElementId = nil
    }

    public override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let elemId = hitElementId(at: pt) else { return }
        selectedElementId = elemId
        onElementSelected?(elemId)
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext, let doc = document else { return }

        let (svgToView, scale) = computeSVGTransform()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. Chassis & trays
        if let chassis = doc.chassis {
            drawShape(chassis, in: ctx, transform: svgToView, scale: scale)
        }
        for tray in doc.trays {
            drawShape(tray, in: ctx, transform: svgToView, scale: scale)
        }
        for chrome in doc.chromeShapes {
            drawShape(chrome, in: ctx, transform: svgToView, scale: scale)
        }
        for txt in doc.chromeTexts {
            drawSVGText(txt, in: svgToView, scale: scale, overrideColor: nil, baselineAdjusted: true)
        }

        // 2. Interactive Elements (43 buttons + Search Dial)
        for elem in doc.elements {
            if elem.id == Self.searchDialSVGId {
                drawSearchDial(elem, in: ctx, transform: svgToView, scale: scale, query: query)
            } else {
                drawButtonElement(elem, in: ctx, transform: svgToView, scale: scale, query: query)
            }
        }
    }

    private func drawShape(
        _ shape: SpeedEditorSVGShape,
        in ctx: CGContext,
        transform: CGAffineTransform,
        scale: CGFloat
    ) {
        var t = transform
        guard let path = shape.path.copy(using: &t) else { return }
        ctx.saveGState()
        if let fill = shape.fill {
            ctx.addPath(path)
            ctx.setFillColor(fill.cgColor)
            ctx.fillPath()
        }
        if let stroke = shape.stroke {
            ctx.addPath(path)
            ctx.setStrokeColor(stroke.cgColor)
            ctx.setLineWidth(max(1.0, shape.strokeWidth * scale))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private func drawSearchDial(
        _ elem: SpeedEditorSVGElement,
        in ctx: CGContext,
        transform: CGAffineTransform,
        scale: CGFloat,
        query: String
    ) {
        let isSelected = (selectedElementId == elem.id)
        let isHovered = (hoveredElementId == elem.id)
        let matchesSearch = !query.isEmpty && (
            "search dial jog wheel shuttle scroll rotella".contains(query)
        )

        let opacity: CGFloat = (!query.isEmpty && !matchesSearch && !isSelected) ? 0.48 : 1.0
        ctx.saveGState()
        ctx.setAlpha(opacity)

        for (idx, shape) in elem.shapes.enumerated() {
            var modified = shape
            if idx == 1 { // Machined dial face
                if isSelected {
                    modified = SpeedEditorSVGShape(
                        path: shape.path,
                        fill: shape.fill?.blended(withFraction: 0.14, of: .systemCyan) ?? shape.fill,
                        stroke: NSColor.systemCyan,
                        strokeWidth: 2.6
                    )
                } else if isHovered || matchesSearch {
                    modified = SpeedEditorSVGShape(
                        path: shape.path,
                        fill: shape.fill?.blended(withFraction: 0.10, of: .white) ?? shape.fill,
                        stroke: matchesSearch ? NSColor.systemCyan : NSColor(calibratedWhite: 0.60, alpha: 1.0),
                        strokeWidth: 2.2
                    )
                }
            }
            drawShape(modified, in: ctx, transform: transform, scale: scale)
        }
        ctx.restoreGState()
    }

    private func drawButtonElement(
        _ elem: SpeedEditorSVGElement,
        in ctx: CGContext,
        transform: CGAffineTransform,
        scale: CGFloat,
        query: String
    ) {
        guard let body = elem.shapes.first else { return }
        var t = transform
        guard let bodyPath = body.path.copy(using: &t) else { return }

        let mgr = SpeedEditorManager.shared
        let btn = SpeedEditorButton.fromSVGId(elem.id)
        let singleAct: VisionCommandAction = btn.map { mgr.action(for: $0) } ?? .none
        let dtAct: VisionCommandAction = btn.map { mgr.doubleTapAction(for: $0) } ?? .none

        let hasSingle = (singleAct != .none)
        let hasDouble = (dtAct != .none)
        let isSelected = (selectedElementId == elem.id)
        let isHovered = (hoveredElementId == elem.id)
        let isPhysicalLit = (btn != nil && highlightedButton == btn)

        var matchesQuery = true
        if !query.isEmpty, let btn = btn {
            matchesQuery = btn.label.lowercased().contains(query)
                || (btn.secondaryHardwareLabel?.lowercased().contains(query) ?? false)
                || singleAct.displayTitle.lowercased().contains(query)
                || dtAct.displayTitle.lowercased().contains(query)
                || btn.groupTitle.lowercased().contains(query)
        }

        let opacity: CGFloat = (!query.isEmpty && !matchesQuery && !isSelected && !isPhysicalLit) ? 0.40 : 1.0

        var fillColor = body.fill ?? NSColor(calibratedWhite: 0.18, alpha: 1.0)
        var strokeColor = body.stroke ?? NSColor(calibratedWhite: 0.30, alpha: 1.0)
        var strokeWidth = max(1.0, body.strokeWidth * scale)

        if isSelected {
            fillColor = fillColor.blended(withFraction: 0.22, of: .systemCyan) ?? fillColor
            strokeColor = NSColor.systemCyan
            strokeWidth = max(2.0, 2.6 * scale)
        } else if isPhysicalLit {
            fillColor = NSColor.systemCyan.withAlphaComponent(0.38)
            strokeColor = NSColor.systemCyan
            strokeWidth = max(2.0, 2.5 * scale)
        } else if !query.isEmpty && matchesQuery {
            fillColor = fillColor.blended(withFraction: 0.16, of: .systemCyan) ?? fillColor
            strokeColor = NSColor.systemCyan
            strokeWidth = max(1.6, 2.0 * scale)
        } else if isHovered {
            fillColor = fillColor.blended(withFraction: 0.12, of: .white) ?? fillColor
            strokeColor = NSColor(calibratedWhite: 0.62, alpha: 1.0)
            strokeWidth = max(1.4, 1.9 * scale)
        }

        ctx.saveGState()
        ctx.setAlpha(opacity)

        // Button cap body
        ctx.addPath(bodyPath)
        ctx.setFillColor(fillColor.cgColor)
        ctx.fillPath()

        ctx.addPath(bodyPath)
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.strokePath()

        // Optional LED indicator pill (shape[1])
        if elem.shapes.count > 1 {
            let ledShape = elem.shapes[1]
            let isActiveWheelLED: Bool
            switch btn {
            case .jog: isActiveWheelLED = (mgr.currentWheelMode == .jog)
            case .shtl: isActiveWheelLED = (mgr.currentWheelMode == .shuttle)
            case .scrl: isActiveWheelLED = (mgr.currentWheelMode == .scroll)
            default: isActiveWheelLED = isPhysicalLit
            }
            let effectiveLED = SpeedEditorSVGShape(
                path: ledShape.path,
                fill: isActiveWheelLED ? NSColor(srgbRed: 0.92, green: 0.28, blue: 0.30, alpha: 1.0) : ledShape.fill,
                stroke: isActiveWheelLED ? NSColor(srgbRed: 1.0, green: 0.45, blue: 0.47, alpha: 1.0) : ledShape.stroke,
                strokeWidth: ledShape.strokeWidth
            )
            drawShape(effectiveLED, in: ctx, transform: transform, scale: scale)
        }

        // Labels inside button
        for txt in elem.texts {
            drawSVGText(txt, in: transform, scale: scale, overrideColor: nil, baselineAdjusted: false)
        }

        // Status indicator dots (cyan = Tap assigned, orange = Double Tap assigned)
        let viewRect = elem.bounds.applying(transform)
        let dotSize = max(3.5, 4.8 * scale)
        let inset = max(3.0, 5.2 * scale)
        if hasDouble {
            let dtDotRect = CGRect(
                x: viewRect.maxX - inset - dotSize,
                y: viewRect.minY + inset,
                width: dotSize,
                height: dotSize
            )
            ctx.setFillColor(NSColor.systemOrange.cgColor)
            ctx.fillEllipse(in: dtDotRect)
        }
        if hasSingle {
            let rightShift = hasDouble ? (dotSize + max(2.0, 2.8 * scale)) : 0
            let tapDotRect = CGRect(
                x: viewRect.maxX - inset - dotSize - rightShift,
                y: viewRect.minY + inset,
                width: dotSize,
                height: dotSize
            )
            ctx.setFillColor(NSColor.systemCyan.cgColor)
            ctx.fillEllipse(in: tapDotRect)
        }

        ctx.restoreGState()
    }

    private func drawSVGText(
        _ txt: SpeedEditorSVGText,
        in transform: CGAffineTransform,
        scale: CGFloat,
        overrideColor: NSColor?,
        baselineAdjusted: Bool
    ) {
        let pt = txt.position.applying(transform)
        let font = NSFont.systemFont(ofSize: max(5.5, txt.fontSize * scale), weight: txt.fontWeight)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: overrideColor ?? txt.fill
        ]
        let attrStr = NSAttributedString(string: txt.text, attributes: attrs)
        let size = attrStr.size()
        let drawX: CGFloat
        switch txt.anchor {
        case "middle": drawX = pt.x - size.width * 0.5
        case "end": drawX = pt.x - size.width
        default: drawX = pt.x
        }
        let drawY = baselineAdjusted ? (pt.y - size.height * 0.78) : (pt.y - size.height * 0.5)
        attrStr.draw(at: NSPoint(x: drawX, y: drawY))
    }
}
