import Foundation

public enum ClipOrientation: String, CaseIterable, Identifiable {
    case normal = "0° (Predefinito)"
    case rotate90 = "90° Orario"
    case rotate180 = "180° Capovolto"
    case rotate270 = "270° Antiorario"

    public var id: String { rawValue }

    public var radians: Double {
        switch self {
        case .normal: return 0
        case .rotate90: return .pi / 2
        case .rotate180: return .pi
        case .rotate270: return -.pi / 2
        }
    }

    public var degrees: Int {
        switch self {
        case .normal: return 0
        case .rotate90: return 90
        case .rotate180: return 180
        case .rotate270: return 270
        }
    }
}
