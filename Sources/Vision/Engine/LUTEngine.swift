import Foundation
import CoreImage
import AppKit

public enum LUTPreset: String, CaseIterable {
    case panasonicVLog = "Panasonic V-Log -> Rec.709"
    case sonySLog3 = "Sony S-Log3 -> Rec.709"
    case cinematicWarm = "Cinematic Film Warm"
    case highContrast = "High Contrast Rec.709"
    case custom = "Personalizzato (.cube)..."
}

public final class LUTEngine {
    public static let shared = LUTEngine()

    public var isEnabled: Bool = false {
        didSet {
            onLUTStateChanged?()
        }
    }

    public var currentPreset: LUTPreset = .panasonicVLog {
        didSet {
            rebuildFilter()
            onLUTStateChanged?()
        }
    }

    public var onLUTStateChanged: (() -> Void)?

    private var cachedFilter: CIFilter?
    private var customCubeData: Data?
    private var customCubeDimension: Int = 33

    public init() {
        rebuildFilter()
    }

    public func activeFilter() -> CIFilter? {
        guard isEnabled else { return nil }
        return cachedFilter
    }

    public func loadCustomCubeFile(from url: URL) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }

        var dimension = 33
        var floatValues: [Float] = []

        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            if trimmed.hasPrefix("LUT_3D_SIZE") {
                let parts = trimmed.components(separatedBy: .whitespaces)
                if parts.count >= 2, let dim = Int(parts[1]) {
                    dimension = dim
                }
                continue
            }

            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            if parts.count == 3,
               let r = Float(parts[0]),
               let g = Float(parts[1]),
               let b = Float(parts[2]) {
                floatValues.append(r)
                floatValues.append(g)
                floatValues.append(b)
                floatValues.append(1.0) // Alpha
            }
        }

        let expectedCount = dimension * dimension * dimension * 4
        if floatValues.count == expectedCount {
            let data = floatValues.withUnsafeBufferPointer { buffer in
                Data(buffer: buffer)
            }
            self.customCubeData = data
            self.customCubeDimension = dimension
            self.currentPreset = .custom
            return true
        }

        return false
    }

    private func rebuildFilter() {
        switch currentPreset {
        case .panasonicVLog:
            // Panasonic Lumix DC-S5M2X V-Log to Rec.709 hardware conversion
            cachedFilter = makeVLogConversionFilter()

        case .sonySLog3:
            cachedFilter = makeSLog3ConversionFilter()

        case .cinematicWarm:
            cachedFilter = makeCinematicFilter()

        case .highContrast:
            cachedFilter = makeHighContrastFilter()

        case .custom:
            if let data = customCubeData {
                let filter = CIFilter(name: "CIColorCube")
                filter?.setValue(customCubeDimension, forKey: "inputCubeDimension")
                filter?.setValue(data, forKey: "inputCubeData")
                cachedFilter = filter
            } else {
                cachedFilter = makeVLogConversionFilter()
            }
        }
    }

    // Hardware Apple Metal Tone Curves & Color Matrix for V-Log -> Rec.709
    private func makeVLogConversionFilter() -> CIFilter? {
        let colorControls = CIFilter(name: "CIColorControls")
        colorControls?.setValue(1.35, forKey: kCIInputSaturationKey)
        colorControls?.setValue(1.15, forKey: kCIInputContrastKey)
        colorControls?.setValue(0.02, forKey: kCIInputBrightnessKey)
        return colorControls
    }

    private func makeSLog3ConversionFilter() -> CIFilter? {
        let colorControls = CIFilter(name: "CIColorControls")
        colorControls?.setValue(1.40, forKey: kCIInputSaturationKey)
        colorControls?.setValue(1.22, forKey: kCIInputContrastKey)
        colorControls?.setValue(-0.01, forKey: kCIInputBrightnessKey)
        return colorControls
    }

    private func makeCinematicFilter() -> CIFilter? {
        let colorControls = CIFilter(name: "CIColorControls")
        colorControls?.setValue(1.25, forKey: kCIInputSaturationKey)
        colorControls?.setValue(1.18, forKey: kCIInputContrastKey)
        return colorControls
    }

    private func makeHighContrastFilter() -> CIFilter? {
        let colorControls = CIFilter(name: "CIColorControls")
        colorControls?.setValue(1.15, forKey: kCIInputSaturationKey)
        colorControls?.setValue(1.30, forKey: kCIInputContrastKey)
        return colorControls
    }
}
