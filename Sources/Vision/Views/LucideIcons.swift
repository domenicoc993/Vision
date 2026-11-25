import AppKit

public enum LucideIcon {
    case list
    case layoutGrid
    case squarePlay
    case fileVideoCamera
    case galleryHorizontalEnd
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
    case palette
    case feather
    case maximize2
    case play
    case pause
    case stepBack
    case stepForward
    case link
    case magnet
    case textCursor
    case keyboard
    case sparkles
    case zap
    case slidersHorizontal
    case scissors
    case lock
    case unlock
    case eye
    case eyeOff
    case database
    case undo2
    case redo2
    case history
    case zoomIn
    case search
    case filter
    case square
    case volume2
    case volumeX
    case minimize2
    case wandSparkles
    case tally3
    case check
    case download
    case folderInput
    case pencil
    case copy
    case bookmark
    case settings2
    case fileCode2
    case arrowLeftRight
    case layers
    case scale
    case flag
    case letterM
    case mousePointer
    case caretsFromAxisDashedVertical
    case ghost
    case snail
}

public final class Lucide {
    public static func template(_ icon: LucideIcon, size: CGFloat = 16) -> NSImage {
        return buildImage(icon, size: size, colorHex: "#000000", isTemplate: true)
    }

    public static func image(_ icon: LucideIcon, size: CGFloat = 16, color: NSColor = .labelColor) -> NSImage {
        return buildImage(icon, size: size, colorHex: hexString(for: color), isTemplate: false)
    }

    private static func buildImage(_ icon: LucideIcon, size: CGFloat, colorHex: String, isTemplate: Bool) -> NSImage {
        let inner = svgInner(for: icon).replacingOccurrences(of: "currentColor", with: colorHex)
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="\(colorHex)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">\(inner)</svg>
        """
        if let data = svg.data(using: .utf8), let img = NSImage(data: data) {
            img.size = NSSize(width: size, height: size)
            img.isTemplate = isTemplate
            return img
        }
        return NSImage(size: NSSize(width: size, height: size))
    }

    private static func hexString(for color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else {
            return "#FFFFFF"
        }
        let r = Int(round(max(0, min(1, rgb.redComponent)) * 255))
        let g = Int(round(max(0, min(1, rgb.greenComponent)) * 255))
        let b = Int(round(max(0, min(1, rgb.blueComponent)) * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    private static func svgInner(for icon: LucideIcon) -> String {
        switch icon {
        case .tally3:
            return #"<path d="M4 4v16" /><path d="M9 4v16" /><path d="M14 4v16" />"#
        case .list:
            return #"<path d="M3 5h.01" /><path d="M3 12h.01" /><path d="M3 19h.01" /><path d="M8 5h13" /><path d="M8 12h13" /><path d="M8 19h13" />"#
        case .layoutGrid:
            return #"<rect width="7" height="7" x="3" y="3" rx="1" /><rect width="7" height="7" x="14" y="3" rx="1" /><rect width="7" height="7" x="14" y="14" rx="1" /><rect width="7" height="7" x="3" y="14" rx="1" />"#
        case .squarePlay:
            return #"<rect x="3" y="3" width="18" height="18" rx="2" /><path d="M9 9.003a1 1 0 0 1 1.517-.859l4.997 2.997a1 1 0 0 1 0 1.718l-4.997 2.997A1 1 0 0 1 9 14.996z" />"#
        case .fileVideoCamera:
            return #"<path d="M4 12V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.706.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2" /><path d="M14 2v5a1 1 0 0 0 1 1h5" /><path d="m10 17.843 3.033-1.755a.64.64 0 0 1 .967.56v4.704a.65.65 0 0 1-.967.56L10 20.157" /><rect width="7" height="6" x="3" y="16" rx="1" />"#
        case .galleryHorizontalEnd:
            return #"<path d="M2 7v10" /><path d="M6 5v14" /><rect width="12" height="18" x="10" y="3" rx="2" />"#
        case .folder:
            return #"<path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z" />"#
        case .folderPlus:
            return #"<path d="M12 10v6" /><path d="M9 13h6" /><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z" />"#
        case .film:
            return #"<rect width="18" height="18" x="3" y="3" rx="2" /><path d="M7 3v18" /><path d="M3 7.5h4" /><path d="M3 12h18" /><path d="M3 16.5h4" /><path d="M17 3v18" /><path d="M17 7.5h4" /><path d="M17 16.5h4" />"#
        case .clapperboard:
            return #"<path d="m12.296 3.464 3.02 3.956" /><path d="M20.2 6 3 11l-.9-2.4c-.3-1.1.3-2.2 1.3-2.5l13.5-4c1.1-.3 2.2.3 2.5 1.3z" /><path d="M3 11h18v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" /><path d="m6.18 5.276 3.1 3.899" />"#
        case .music:
            return #"<path d="M21 16V3a1 1 0 0 0-1.28-.96l-10 2.917a1 1 0 0 0-.72.96V19" /><circle cx="18" cy="16" r="3" /><circle cx="6" cy="19" r="3" />"#
        case .plus:
            return #"<path d="M5 12h14" /><path d="M12 5v14" />"#
        case .trash:
            return #"<path d="M10 11v6" /><path d="M14 11v6" /><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6" /><path d="M3 6h18" /><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2" />"#
        case .rotateCw:
            return #"<path d="M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8" /><path d="M21 3v5h-5" />"#
        case .chevronRight:
            return #"<path d="m9 18 6-6-6-6" />"#
        case .chevronDown:
            return #"<path d="m6 9 6 6 6-6" />"#
        case .alertTriangle:
            return #"<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3" /><path d="M12 9v4" /><path d="M12 17h.01" />"#
        case .palette:
            return #"<path d="M12 22a1 1 0 0 1 0-20 10 9 0 0 1 10 9 5 5 0 0 1-5 5h-2.25a1.75 1.75 0 0 0-1.4 2.8l.3.4a1.75 1.75 0 0 1-1.4 2.8z" /><circle cx="13.5" cy="6.5" r=".5" fill="currentColor" /><circle cx="17.5" cy="10.5" r=".5" fill="currentColor" /><circle cx="6.5" cy="12.5" r=".5" fill="currentColor" /><circle cx="8.5" cy="7.5" r=".5" fill="currentColor" />"#
        case .feather:
            return #"<path d="M14.086 18.412A2 2 0 0112.67 19H5v-7.672a2 2 0 01.586-1.414L11.75 3.75a6 6 0 118.49 8.49z" /><path d="M16 8 2 22" /><path d="M17.488 15H9" />"#
        case .maximize2:
            return #"<path d="M15 3h6v6" /><path d="m21 3-7 7" /><path d="m3 21 7-7" /><path d="M9 21H3v-6" />"#
        case .play:
            return #"<path d="M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z" />"#
        case .pause:
            return #"<rect x="14" y="3" width="5" height="18" rx="1" /><rect x="5" y="3" width="5" height="18" rx="1" />"#
        case .stepBack:
            return #"<path d="M13.971 4.285A2 2 0 0 1 17 6v12a2 2 0 0 1-3.029 1.715l-9.997-5.998a2 2 0 0 1-.003-3.432z" /><path d="M21 20V4" />"#
        case .stepForward:
            return #"<path d="M10.029 4.285A2 2 0 0 0 7 6v12a2 2 0 0 0 3.029 1.715l9.997-5.998a2 2 0 0 0 .003-3.432z" /><path d="M3 4v16" />"#
        case .link:
            return #"<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" /><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />"#
        case .magnet:
            return #"<path d="m12 15 4 4" /><path d="M2.352 10.648a1.205 1.205 0 0 0 0 1.704l2.296 2.296a1.205 1.205 0 0 0 1.704 0l6.029-6.029a1 1 0 1 1 3 3l-6.029 6.029a1.205 1.205 0 0 0 0 1.704l2.296 2.296a1.205 1.205 0 0 0 1.704 0l6.365-6.367A1 1 0 0 0 8.716 4.282z" /><path d="m5 8 4 4" />"#
        case .textCursor:
            return #"<path d="M17 22h-1a4 4 0 0 1-4-4V6a4 4 0 0 1 4-4h1" /><path d="M7 22h1a4 4 0 0 0 4-4" /><path d="M7 2h1a4 4 0 0 1 4 4" />"#
        case .keyboard:
            return #"<path d="M10 8h.01" /><path d="M12 12h.01" /><path d="M14 8h.01" /><path d="M16 12h.01" /><path d="M18 8h.01" /><path d="M6 8h.01" /><path d="M7 16h10" /><path d="M8 12h.01" /><rect width="20" height="16" x="2" y="4" rx="2" />"#
        case .sparkles:
            return #"<path d="M11.017 2.814a1 1 0 0 1 1.966 0l1.051 5.558a2 2 0 0 0 1.594 1.594l5.558 1.051a1 1 0 0 1 0 1.966l-5.558 1.051a2 2 0 0 0-1.594 1.594l-1.051 5.558a1 1 0 0 1-1.966 0l-1.051-5.558a2 2 0 0 0-1.594-1.594l-5.558-1.051a1 1 0 0 1 0-1.966l5.558-1.051a2 2 0 0 0 1.594-1.594z" /><path d="M20 2v4" /><path d="M22 4h-4" /><circle cx="4" cy="20" r="2" />"#
        case .zap:
            return #"<path d="M15.914 4a1.5 1.5 0 00-2.474-1.561l-9 9A1.5 1.5 0 005.5 14h4.002a.5.5 0 01.471.666L8.086 20a1.5 1.5 0 002.475 1.56l9-9A1.5 1.5 0 0018.5 10h-3.997a.5.5 0 01-.472-.667z" />"#
        case .slidersHorizontal:
            return #"<path d="M10 5H3" /><path d="M12 19H3" /><path d="M14 3v4" /><path d="M16 17v4" /><path d="M21 12h-9" /><path d="M21 19h-5" /><path d="M21 5h-7" /><path d="M8 10v4" /><path d="M8 12H3" />"#
        case .scissors:
            return #"<circle cx="6" cy="6" r="3" /><path d="M8.12 8.12 12 12" /><path d="M20 4 8.12 15.88" /><circle cx="6" cy="18" r="3" /><path d="M14.8 14.8 20 20" />"#
        case .lock:
            return #"<rect width="18" height="11" x="3" y="11" rx="2" ry="2" /><path d="M7 11V7a5 5 0 0 1 10 0v4" />"#
        case .unlock:
            return #"<rect width="18" height="11" x="3" y="11" rx="2" ry="2" /><path d="M7 11V7a5 5 0 0 1 9.9-1" />"#
        case .eye:
            return #"<path d="M2.062 12.348a1 1 0 0 1 0-.696 10.75 10.75 0 0 1 19.876 0 1 1 0 0 1 0 .696 10.75 10.75 0 0 1-19.876 0" /><circle cx="12" cy="12" r="3" />"#
        case .eyeOff:
            return #"<path d="M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49" /><path d="M14.084 14.158a3 3 0 0 1-4.242-4.242" /><path d="M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143" /><path d="m2 2 20 20" />"#
        case .database:
            return #"<ellipse cx="12" cy="5" rx="9" ry="3" /><path d="M3 5V19A9 3 0 0 0 21 19V5" /><path d="M3 12A9 3 0 0 0 21 12" />"#
        case .undo2:
            return #"<path d="M9 14 4 9l5-5" /><path d="M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11" />"#
        case .redo2:
            return #"<path d="m15 14 5-5-5-5" /><path d="M20 9H9.5A5.5 5.5 0 0 0 4 14.5A5.5 5.5 0 0 0 9.5 20H13" />"#
        case .history:
            return #"<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8" /><path d="M3 3v5h5" /><path d="M12 7v5l4 2" />"#
        case .zoomIn:
            return #"<circle cx="11" cy="11" r="8" /><line x1="21" x2="16.65" y1="21" y2="16.65" /><line x1="11" x2="11" y1="8" y2="14" /><line x1="8" x2="14" y1="11" y2="11" />"#
        case .search:
            return #"<circle cx="11" cy="11" r="8" /><path d="m21 21-4.3-4.3" />"#
        case .filter:
            return #"<polygon points="22 3 2 3 10 12.46 10 19 14 21 14 12.46 22 3" />"#
        case .square:
            return #"<rect width="18" height="18" x="3" y="3" rx="2" />"#
        case .volume2:
            return #"<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z" /><path d="M16 9a5 5 0 0 1 0 6" /><path d="M19.364 18.364a9 9 0 0 0 0-12.728" />"#
        case .volumeX:
            return #"<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z" /><line x1="22" x2="16" y1="9" y2="15" /><line x1="16" x2="22" y1="9" y2="15" />"#
        case .minimize2:
            return #"<path d="M4 14h6v6" /><path d="M20 10h-6V4" /><path d="m14 10 7-7" /><path d="m3 21 7-7" />"#
        case .wandSparkles:
            return #"<path d="m21.64 3.64-1.28-1.28a1.21 1.21 0 0 0-1.72 0L2.36 18.64a1.21 1.21 0 0 0 0 1.72l1.28 1.28a1.2 1.2 0 0 0 1.72 0L21.64 5.36a1.2 1.2 0 0 0 0-1.72" /><path d="m14 7 3 3" /><path d="M5 6v4" /><path d="M19 14v4" /><path d="M10 2v2" /><path d="M7 8H3" /><path d="M21 16h-4" /><path d="M11 3H9" />"#
        case .check:
            return #"<path d="M20 6 9 17l-5-5" />"#
        case .download:
            return #"<path d="M12 15V3" /><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" /><path d="m7 10 5 5 5-5" />"#
        case .folderInput:
            return #"<path d="M2 9V5a2 2 0 0 1 2-2h3.9a2 2 0 0 1 1.69.9l.81 1.2a2 2 0 0 0 1.67.9H20a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-1" /><path d="M2 13h10" /><path d="m9 16 3-3-3-3" />"#
        case .pencil:
            return #"<path d="M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z" /><path d="m15 5 4 4" />"#
        case .copy:
            return #"<rect width="14" height="14" x="8" y="8" rx="2" ry="2" /><path d="M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2" />"#
        case .bookmark:
            return #"<path d="M17 3a2 2 0 0 1 2 2v15a1 1 0 0 1-1.496.868l-4.512-2.578a2 2 0 0 0-1.984 0l-4.512 2.578A1 1 0 0 1 5 20V5a2 2 0 0 1 2-2z" />"#
        case .settings2:
            return #"<path d="M14 17H5" /><path d="M19 7h-9" /><circle cx="17" cy="17" r="3" /><circle cx="7" cy="7" r="3" />"#
        case .fileCode2:
            return #"<path d="M4 12.15V4a2 2 0 0 1 2-2h8a2.4 2.4 0 0 1 1.706.706l3.588 3.588A2.4 2.4 0 0 1 20 8v12a2 2 0 0 1-2 2h-3.35" /><path d="M14 2v5a1 1 0 0 0 1 1h5" /><path d="m5 16-3 3 3 3" /><path d="m9 22 3-3-3-3" />"#
        case .arrowLeftRight:
            return #"<path d="M8 3 4 7l4 4" /><path d="M4 7h16" /><path d="m16 21 4-4-4-4" /><path d="M20 17H4" />"#
        case .layers:
            return #"<path d="M12.83 2.18a2 2 0 0 0-1.66 0L2.6 6.08a1 1 0 0 0 0 1.83l8.58 3.91a2 2 0 0 0 1.66 0l8.58-3.9a1 1 0 0 0 0-1.83z" /><path d="M2 12a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 12" /><path d="M2 17a1 1 0 0 0 .58.91l8.6 3.91a2 2 0 0 0 1.65 0l8.58-3.9A1 1 0 0 0 22 17" />"#
        case .scale:
            return #"<path d="m16 16 3-8 3 8c-.87.65-1.92 1-3 1s-2.13-.35-3-1Z" /><path d="m2 16 3-8 3 8c-.87.65-1.92 1-3 1s-2.13-.35-3-1Z" /><path d="M7 21h10" /><path d="M12 3v18" /><path d="M3 7h2c2 0 5-1 7-2 2 1 5 2 7 2h2" />"#
        case .flag:
            return #"<path d="M4 22V4a1 1 0 0 1 .4-.8A6 6 0 0 1 8 2c3 0 5 2 7.333 2q2 0 3.067-.8A1 1 0 0 1 20 4v10a1 1 0 0 1-.4.8A6 6 0 0 1 16 16c-3 0-5-2-8-2a6 6 0 0 0-4 1.528" />"#
        case .letterM:
            return #"<path d="M5 19V5l7 8 7-8v14" />"#
        case .mousePointer:
            return #"<path d="M4.037 4.688a.495.495 0 0 1 .651-.651l16 6.5a.5.5 0 0 1-.063.947l-6.124 1.58a2 2 0 0 0-1.438 1.435l-1.579 6.126a.5.5 0 0 1-.947.063z" />"#
        case .caretsFromAxisDashedVertical:
            return #"<path d="M12 14v2" /><path d="M12 20v2" /><path d="M12 2v2" /><path d="M12 8v2" /><path d="M17.712 16.703 A1 1 0 0 1 15.999 16 V8 a1 1 0 0 1 1.713 -.703 l3.99 3.991 a1 1 0 0 1 .001 1.424 z" /><path d="M6.288 16.703 A1 1 0 0 0 8.001 16 V8 a1 1 0 0 0 -1.713 -.703 l-3.99 3.991 a1 1 0 0 0 -.001 1.424 z" />"#
        case .ghost:
            return #"<path d="M15 10v1" /><path d="M7.528 20.472 a1.6 1.6 0 0 1 2.277 0 l1.057 1.056 a1.6 1.6 0 0 0 2.276 0 l1.057 -1.056 a1.6 1.6 0 0 1 2.277 0 l1.114 1.114 a1.4 1.4 0 0 0 2.414 -1 V10 a8 8 0 0 0 -16 0 v10.586 a1.4 1.4 0 0 0 2.414 1 z" /><path d="M9 10v1" />"#
        case .snail:
            return #"<path d="M2 13 a6 6 0 1 0 12 0 a4 4 0 1 0 -8 0 a2 2 0 0 0 4 0" /><circle cx="10" cy="13" r="8" /><path d="M2 21 h12 c4.4 0 8 -3.6 8 -8 V7 a2 2 0 1 0 -4 0 v6" /><path d="M18 3 l1.1 2.2" />"#
        }
    }
}
