import Foundation
import CoreGraphics

public struct TimelineFormat: Identifiable, Hashable {
    public let id: String
    public let name: String
    public let size: CGSize
    public let fps: Float

    public static let fhdLandscape = TimelineFormat(
        id: "1080p_16x9",
        name: "1920 × 1080 (16:9 Orizzontale)",
        size: CGSize(width: 1920, height: 1080),
        fps: 30.0
    )
    public static let fhdVertical = TimelineFormat(
        id: "1080p_9x16",
        name: "1080 × 1920 (9:16 Verticale / Reels)",
        size: CGSize(width: 1080, height: 1920),
        fps: 30.0
    )
    public static let uhd4KLandscape = TimelineFormat(
        id: "4k_16x9",
        name: "3840 × 2160 (4K UHD)",
        size: CGSize(width: 3840, height: 2160),
        fps: 30.0
    )
    public static let square1x1 = TimelineFormat(
        id: "1080_1x1",
        name: "1080 × 1080 (1:1 Quadrato)",
        size: CGSize(width: 1080, height: 1080),
        fps: 30.0
    )
    public static let native6K = TimelineFormat(
        id: "6k_native",
        name: "5952 × 3968 (6K Open Gate Nativo)",
        size: CGSize(width: 5952, height: 3968),
        fps: 25.0
    )

    public static let presets: [TimelineFormat] = [
        .fhdLandscape,
        .fhdVertical,
        .uhd4KLandscape,
        .square1x1,
        .native6K
    ]
}
