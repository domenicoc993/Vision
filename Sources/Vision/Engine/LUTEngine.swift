import Foundation
import CoreImage
import AppKit

public enum LUTPreset: String, CaseIterable, Sendable {
    case panasonicVLog = "Panasonic V-Log -> Rec.709"
    case sonySLog3 = "Sony S-Log3 -> Rec.709"
    case cinematicWarm = "Cinematic Film Warm"
    case highContrast = "High Contrast Rec.709"
    case custom = "Personalizzato (.cube)..."
}

public struct SavedCustomLUT: Codable, Hashable, Sendable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public enum LUTParameters: Sendable, Equatable {
    case colorControls(saturation: Double, contrast: Double, brightness: Double)
    case cube(dimension: Int, data: Data)
}

public final class LUTEngine: @unchecked Sendable {
    public static let shared = LUTEngine()
    public static let stateChangedNotification = Notification.Name("LUTEngine.stateChanged")

    private static let customLUTsDefaultsKey = "com.vision.customLUTLinks.v1"
    private static let lutStateDefaultsKey = "com.vision.lutState.v1"

    private struct PersistedLUTState: Codable {
        var isEnabled: Bool
        var presetRaw: String
        var customPath: String?
    }

    private let stateLock = NSLock()
    private var suppressNotifications = false

    public var isEnabled: Bool = false {
        didSet {
            if !suppressNotifications {
                persistStateToDefaults()
                notifyStateChanged()
            }
        }
    }

    public var currentPreset: LUTPreset = .panasonicVLog {
        didSet {
            rebuildFilter()
            if !suppressNotifications {
                if currentPreset != .custom {
                    activeCustomLUTPath = nil
                }
                persistStateToDefaults()
                notifyStateChanged()
            }
        }
    }

    public private(set) var customLUTs: [SavedCustomLUT] = []
    public private(set) var activeCustomLUTPath: String? = nil

    public var onLUTStateChanged: (() -> Void)?

    private var cachedFilter: CIFilter?
    private var customCubeData: Data?
    private var customCubeDimension: Int = 33

    public init() {
        validateAndRestoreSavedState()
    }

    private func notifyStateChanged() {
        onLUTStateChanged?()
        let post = {
            NotificationCenter.default.post(name: Self.stateChangedNotification, object: nil)
        }
        if Thread.isMainThread {
            post()
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }

    // MARK: - Persistence & Missing-Link Validation

    private func persistCustomLUTList() {
        stateLock.lock()
        let snapshot = customLUTs
        stateLock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: Self.customLUTsDefaultsKey)
        }
    }

    private func persistStateToDefaults() {
        let st = PersistedLUTState(
            isEnabled: isEnabled,
            presetRaw: currentPreset.rawValue,
            customPath: activeCustomLUTPath
        )
        if let data = try? JSONEncoder().encode(st) {
            UserDefaults.standard.set(data, forKey: Self.lutStateDefaultsKey)
        }
    }

    /// Carica i link alle LUT personalizzate salvate, rimuove eventuali file non più presenti su disco
    /// e ripristina stato ON/OFF e preset (tornando a OFF se la LUT custom attiva è mancante).
    public func validateAndRestoreSavedState() {
        suppressNotifications = true
        defer { suppressNotifications = false }

        let fm = FileManager.default
        var loadedList: [SavedCustomLUT] = []
        if let raw = UserDefaults.standard.data(forKey: Self.customLUTsDefaultsKey),
           let decoded = try? JSONDecoder().decode([SavedCustomLUT].self, from: raw) {
            loadedList = decoded
        }

        let validList = loadedList.filter { fm.fileExists(atPath: $0.path) }
        let prunedAny = validList.count != loadedList.count
        stateLock.lock()
        self.customLUTs = validList
        stateLock.unlock()
        if prunedAny {
            persistCustomLUTList()
        }

        if let rawState = UserDefaults.standard.data(forKey: Self.lutStateDefaultsKey),
           let st = try? JSONDecoder().decode(PersistedLUTState.self, from: rawState) {
            let preset = LUTPreset(rawValue: st.presetRaw) ?? .panasonicVLog
            if preset == .custom || st.customPath != nil {
                if let path = st.customPath, fm.fileExists(atPath: path),
                   parseCubeFile(at: URL(fileURLWithPath: path)) {
                    self.activeCustomLUTPath = path
                    self.currentPreset = .custom
                    self.isEnabled = st.isEnabled
                } else {
                    if let missingPath = st.customPath {
                        removeCustomLUT(path: missingPath, notify: false)
                        DebugLogger.shared.log("LUT personalizzata mancante su disco ('\(URL(fileURLWithPath: missingPath).lastPathComponent)'): rimossa dalla lista e LUT disattivata.", level: .warning)
                    }
                    self.activeCustomLUTPath = nil
                    self.currentPreset = .panasonicVLog
                    self.isEnabled = false
                    persistStateToDefaults()
                }
            } else {
                self.activeCustomLUTPath = nil
                self.currentPreset = preset
                self.isEnabled = st.isEnabled
            }
        } else {
            rebuildFilter()
        }
    }

    /// Ripristina lo stato LUT salvato nel documento del progetto, verificando l'esistenza del file `.cube` su disco.
    public func applySavedProjectState(enabled: Bool?, presetRaw: String?, customPath: String?) {
        // Re-prune list on disk whenever switching/opening projects
        let fm = FileManager.default
        stateLock.lock()
        let beforeCount = customLUTs.count
        customLUTs = customLUTs.filter { fm.fileExists(atPath: $0.path) }
        let didPrune = customLUTs.count != beforeCount
        stateLock.unlock()
        if didPrune {
            persistCustomLUTList()
        }

        guard let enabled = enabled, let presetRaw = presetRaw else {
            return
        }

        suppressNotifications = true
        let preset = LUTPreset(rawValue: presetRaw) ?? .panasonicVLog
        if preset == .custom || customPath != nil {
            if let path = customPath, fm.fileExists(atPath: path),
               parseCubeFile(at: URL(fileURLWithPath: path)) {
                registerCustomLUTLink(url: URL(fileURLWithPath: path))
                self.activeCustomLUTPath = path
                self.currentPreset = .custom
                self.isEnabled = enabled
            } else {
                if let missingPath = customPath {
                    removeCustomLUT(path: missingPath, notify: false)
                    DebugLogger.shared.log("LUT del progetto non trovata su disco ('\(URL(fileURLWithPath: missingPath).lastPathComponent)'): rimossa dalla lista e impostata su OFF.", level: .warning)
                }
                self.activeCustomLUTPath = nil
                self.currentPreset = .panasonicVLog
                self.isEnabled = false
            }
        } else {
            self.activeCustomLUTPath = nil
            self.currentPreset = preset
            self.isEnabled = enabled
        }
        suppressNotifications = false
        persistStateToDefaults()
        notifyStateChanged()
    }

    private func registerCustomLUTLink(url: URL) {
        let cleanName = url.deletingPathExtension().lastPathComponent
        let path = url.path
        stateLock.lock()
        if !customLUTs.contains(where: { $0.path == path }) {
            customLUTs.append(SavedCustomLUT(name: cleanName, path: path))
        }
        stateLock.unlock()
        persistCustomLUTList()
    }

    @discardableResult
    public func selectCustomLUT(path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            removeCustomLUT(path: path, notify: false)
            suppressNotifications = true
            activeCustomLUTPath = nil
            currentPreset = .panasonicVLog
            isEnabled = false
            suppressNotifications = false
            persistStateToDefaults()
            notifyStateChanged()
            return false
        }
        let url = URL(fileURLWithPath: path)
        return loadCustomCubeFile(from: url)
    }

    public func removeCustomLUT(path: String, notify: Bool = true) {
        stateLock.lock()
        customLUTs.removeAll(where: { $0.path == path })
        stateLock.unlock()
        persistCustomLUTList()

        if activeCustomLUTPath == path {
            suppressNotifications = true
            activeCustomLUTPath = nil
            customCubeData = nil
            currentPreset = .panasonicVLog
            isEnabled = false
            suppressNotifications = false
            persistStateToDefaults()
        }
        if notify {
            notifyStateChanged()
        }
    }

    public func activeFilter() -> CIFilter? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isEnabled else { return nil }
        return cachedFilter
    }

    /// Chiave univoca per la cache miniature quando una LUT è attiva (`"off"` se disattivata).
    public var cacheSignature: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isEnabled else { return "off" }
        return "\(currentPreset.rawValue)|\(activeCustomLUTPath ?? "")"
    }

    /// Snapshot thread-safe e immutabile dei parametri LUT per l'esecuzione hardware Metal su `AVVideoCompositing`.
    public func currentLUTParameters() -> LUTParameters? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isEnabled else { return nil }
        switch currentPreset {
        case .panasonicVLog:
            return .colorControls(saturation: 1.35, contrast: 1.15, brightness: 0.02)
        case .sonySLog3:
            return .colorControls(saturation: 1.40, contrast: 1.22, brightness: -0.01)
        case .cinematicWarm:
            return .colorControls(saturation: 1.25, contrast: 1.18, brightness: 0.0)
        case .highContrast:
            return .colorControls(saturation: 1.15, contrast: 1.30, brightness: 0.0)
        case .custom:
            if let data = customCubeData {
                return .cube(dimension: customCubeDimension, data: data)
            }
            return .colorControls(saturation: 1.35, contrast: 1.15, brightness: 0.02)
        }
    }

    public static func apply(_ params: LUTParameters, to image: CIImage) -> CIImage {
        switch params {
        case .colorControls(let sat, let contrast, let brightness):
            return image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: sat,
                kCIInputContrastKey: contrast,
                kCIInputBrightnessKey: brightness
            ])
        case .cube(let dimension, let data):
            return image.applyingFilter("CIColorCube", parameters: [
                "inputCubeDimension": dimension,
                "inputCubeData": data
            ])
        }
    }

    public func loadCustomCubeFile(from url: URL) -> Bool {
        guard parseCubeFile(at: url) else {
            return false
        }
        registerCustomLUTLink(url: url)
        suppressNotifications = true
        self.activeCustomLUTPath = url.path
        self.currentPreset = .custom
        suppressNotifications = false
        persistStateToDefaults()
        notifyStateChanged()
        return true
    }

    private func parseCubeFile(at url: URL) -> Bool {
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
            stateLock.lock()
            self.customCubeData = data
            self.customCubeDimension = dimension
            stateLock.unlock()
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
