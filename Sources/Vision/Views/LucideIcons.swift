import AppKit

public enum LucideIcon {
    case list
    case layoutGrid
    case folder
    case folderPlus
    case film
    case music
    case plus
    case trash
    case rotateCw
    case chevronRight
    case chevronDown
    case clapperboard
    case alertTriangle
}

public final class Lucide {
    public static func image(_ icon: LucideIcon, size: CGFloat = 16, color: NSColor = .labelColor) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()

            // Scale from 24x24 Lucide coordinate grid to target rect
            let scale = rect.width / 24.0
            ctx.scaleBy(x: scale, y: scale)

            color.setStroke()
            color.setFill()

            let path = NSBezierPath()
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            switch icon {
            case .list:
                // Three lines with leading dots (Lucide List)
                path.move(to: NSPoint(x: 8, y: 18))
                path.line(to: NSPoint(x: 21, y: 18))
                path.move(to: NSPoint(x: 8, y: 12))
                path.line(to: NSPoint(x: 21, y: 12))
                path.move(to: NSPoint(x: 8, y: 6))
                path.line(to: NSPoint(x: 21, y: 6))
                path.stroke()

                let dot1 = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 16.5, width: 3, height: 3))
                let dot2 = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 10.5, width: 3, height: 3))
                let dot3 = NSBezierPath(ovalIn: NSRect(x: 2.5, y: 4.5, width: 3, height: 3))
                dot1.fill()
                dot2.fill()
                dot3.fill()

            case .layoutGrid:
                // 4 squares (Lucide LayoutGrid)
                let r1 = NSBezierPath(roundedRect: NSRect(x: 3, y: 13, width: 7, height: 7), xRadius: 1.5, yRadius: 1.5)
                let r2 = NSBezierPath(roundedRect: NSRect(x: 14, y: 13, width: 7, height: 7), xRadius: 1.5, yRadius: 1.5)
                let r3 = NSBezierPath(roundedRect: NSRect(x: 14, y: 4, width: 7, height: 7), xRadius: 1.5, yRadius: 1.5)
                let r4 = NSBezierPath(roundedRect: NSRect(x: 3, y: 4, width: 7, height: 7), xRadius: 1.5, yRadius: 1.5)
                r1.lineWidth = 1.8; r1.stroke()
                r2.lineWidth = 1.8; r2.stroke()
                r3.lineWidth = 1.8; r3.stroke()
                r4.lineWidth = 1.8; r4.stroke()

            case .folder:
                // Lucide Folder
                path.move(to: NSPoint(x: 4, y: 20))
                path.line(to: NSPoint(x: 9, y: 20))
                path.line(to: NSPoint(x: 11, y: 17))
                path.line(to: NSPoint(x: 20, y: 17))
                path.curve(to: NSPoint(x: 22, y: 15), controlPoint1: NSPoint(x: 21.1, y: 17), controlPoint2: NSPoint(x: 22, y: 16.1))
                path.line(to: NSPoint(x: 22, y: 6))
                path.curve(to: NSPoint(x: 20, y: 4), controlPoint1: NSPoint(x: 22, y: 4.9), controlPoint2: NSPoint(x: 21.1, y: 4))
                path.line(to: NSPoint(x: 4, y: 4))
                path.curve(to: NSPoint(x: 2, y: 6), controlPoint1: NSPoint(x: 2.9, y: 4), controlPoint2: NSPoint(x: 2, y: 4.9))
                path.line(to: NSPoint(x: 2, y: 18))
                path.curve(to: NSPoint(x: 4, y: 20), controlPoint1: NSPoint(x: 2, y: 19.1), controlPoint2: NSPoint(x: 2.9, y: 20))
                path.close()
                path.stroke()

            case .folderPlus:
                path.move(to: NSPoint(x: 4, y: 20))
                path.line(to: NSPoint(x: 9, y: 20))
                path.line(to: NSPoint(x: 11, y: 17))
                path.line(to: NSPoint(x: 20, y: 17))
                path.curve(to: NSPoint(x: 22, y: 15), controlPoint1: NSPoint(x: 21.1, y: 17), controlPoint2: NSPoint(x: 22, y: 16.1))
                path.line(to: NSPoint(x: 22, y: 6))
                path.curve(to: NSPoint(x: 20, y: 4), controlPoint1: NSPoint(x: 22, y: 4.9), controlPoint2: NSPoint(x: 21.1, y: 4))
                path.line(to: NSPoint(x: 4, y: 4))
                path.curve(to: NSPoint(x: 2, y: 6), controlPoint1: NSPoint(x: 2.9, y: 4), controlPoint2: NSPoint(x: 2, y: 4.9))
                path.line(to: NSPoint(x: 2, y: 18))
                path.curve(to: NSPoint(x: 4, y: 20), controlPoint1: NSPoint(x: 2, y: 19.1), controlPoint2: NSPoint(x: 2.9, y: 20))
                path.close()
                path.stroke()

                let plus = NSBezierPath()
                plus.lineWidth = 1.8
                plus.lineCapStyle = .round
                plus.move(to: NSPoint(x: 12, y: 8))
                plus.line(to: NSPoint(x: 12, y: 14))
                plus.move(to: NSPoint(x: 9, y: 11))
                plus.line(to: NSPoint(x: 15, y: 11))
                plus.stroke()

            case .film:
                // Film strip
                let rect = NSBezierPath(roundedRect: NSRect(x: 3, y: 4, width: 18, height: 16), xRadius: 2, yRadius: 2)
                rect.lineWidth = 1.8
                rect.stroke()
                path.move(to: NSPoint(x: 7, y: 4))
                path.line(to: NSPoint(x: 7, y: 20))
                path.move(to: NSPoint(x: 17, y: 4))
                path.line(to: NSPoint(x: 17, y: 20))
                path.move(to: NSPoint(x: 3, y: 12))
                path.line(to: NSPoint(x: 21, y: 12))
                path.stroke()

            case .clapperboard:
                let base = NSBezierPath(roundedRect: NSRect(x: 3, y: 4, width: 18, height: 16), xRadius: 2, yRadius: 2)
                base.lineWidth = 1.8
                base.stroke()
                path.move(to: NSPoint(x: 3, y: 15))
                path.line(to: NSPoint(x: 21, y: 15))
                path.move(to: NSPoint(x: 7, y: 15))
                path.line(to: NSPoint(x: 10, y: 20))
                path.move(to: NSPoint(x: 14, y: 15))
                path.line(to: NSPoint(x: 17, y: 20))
                path.stroke()

            case .music:
                path.move(to: NSPoint(x: 9, y: 18))
                path.line(to: NSPoint(x: 9, y: 8))
                path.curve(to: NSPoint(x: 18, y: 14), controlPoint1: NSPoint(x: 12, y: 11), controlPoint2: NSPoint(x: 16, y: 13))
                path.line(to: NSPoint(x: 18, y: 6))
                path.stroke()
                let note = NSBezierPath(ovalIn: NSRect(x: 5, y: 4, width: 5, height: 4))
                note.fill()

            case .plus:
                path.move(to: NSPoint(x: 12, y: 5))
                path.line(to: NSPoint(x: 12, y: 19))
                path.move(to: NSPoint(x: 5, y: 12))
                path.line(to: NSPoint(x: 19, y: 12))
                path.stroke()

            case .trash:
                path.move(to: NSPoint(x: 3, y: 18))
                path.line(to: NSPoint(x: 21, y: 18))
                path.move(to: NSPoint(x: 19, y: 18))
                path.line(to: NSPoint(x: 18, y: 5))
                path.curve(to: NSPoint(x: 16, y: 3), controlPoint1: NSPoint(x: 18, y: 3.9), controlPoint2: NSPoint(x: 17.1, y: 3))
                path.line(to: NSPoint(x: 8, y: 3))
                path.curve(to: NSPoint(x: 6, y: 5), controlPoint1: NSPoint(x: 6.9, y: 3), controlPoint2: NSPoint(x: 6, y: 3.9))
                path.line(to: NSPoint(x: 5, y: 18))
                path.move(to: NSPoint(x: 10, y: 14))
                path.line(to: NSPoint(x: 10, y: 7))
                path.move(to: NSPoint(x: 14, y: 14))
                path.line(to: NSPoint(x: 14, y: 7))
                path.move(to: NSPoint(x: 9, y: 18))
                path.line(to: NSPoint(x: 9, y: 20))
                path.curve(to: NSPoint(x: 10, y: 21), controlPoint1: NSPoint(x: 9, y: 20.6), controlPoint2: NSPoint(x: 9.4, y: 21))
                path.line(to: NSPoint(x: 14, y: 21))
                path.curve(to: NSPoint(x: 15, y: 20), controlPoint1: NSPoint(x: 14.6, y: 21), controlPoint2: NSPoint(x: 15, y: 20.6))
                path.line(to: NSPoint(x: 15, y: 18))
                path.stroke()

            case .rotateCw:
                path.move(to: NSPoint(x: 21, y: 16))
                path.line(to: NSPoint(x: 21, y: 21))
                path.line(to: NSPoint(x: 16, y: 21))
                path.stroke()
                let arc = NSBezierPath()
                arc.lineWidth = 1.8
                arc.lineCapStyle = .round
                arc.appendArc(withCenter: NSPoint(x: 12, y: 12), radius: 8, startAngle: 45, endAngle: 330, clockwise: true)
                arc.stroke()

            case .chevronRight:
                path.move(to: NSPoint(x: 9, y: 18))
                path.line(to: NSPoint(x: 15, y: 12))
                path.line(to: NSPoint(x: 9, y: 6))
                path.stroke()

            case .chevronDown:
                path.move(to: NSPoint(x: 6, y: 15))
                path.line(to: NSPoint(x: 12, y: 9))
                path.line(to: NSPoint(x: 18, y: 15))
                path.stroke()

            case .alertTriangle:
                path.move(to: NSPoint(x: 12, y: 21))
                path.line(to: NSPoint(x: 2, y: 5))
                path.curve(to: NSPoint(x: 3.5, y: 3), controlPoint1: NSPoint(x: 1.5, y: 4.1), controlPoint2: NSPoint(x: 2.3, y: 3))
                path.line(to: NSPoint(x: 20.5, y: 3))
                path.curve(to: NSPoint(x: 22, y: 5), controlPoint1: NSPoint(x: 21.7, y: 3), controlPoint2: NSPoint(x: 22.5, y: 4.1))
                path.close()
                path.stroke()

                let ex = NSBezierPath()
                ex.lineWidth = 1.8
                ex.lineCapStyle = .round
                ex.move(to: NSPoint(x: 12, y: 14))
                ex.line(to: NSPoint(x: 12, y: 9))
                ex.stroke()

                let dot = NSBezierPath(ovalIn: NSRect(x: 11, y: 5.5, width: 2, height: 2))
                dot.fill()
            }

            ctx.restoreGState()
            return true
        }
        img.isTemplate = true
        return img
    }
}
