import AppKit
import AVFoundation
import CoreImage
import CryptoKit
import ImageIO
import Metal

/// Lightweight, RAM-bounded + disk-cached thumbnail generator shared across Media Pool Grid and Timeline Grid.
public final class ThumbnailCache: @unchecked Sendable {
    public static let shared = ThumbnailCache()
    public static let thumbnailReadyNotification = Notification.Name("Vision.ThumbnailCache.Ready")

    private let ramCache = NSCache<NSString, NSImage>()
    private let lutRamCache = NSCache<NSString, NSImage>()
    private var lastLutSignature: String = "off"
    private let cacheDir: URL
    private let workQueue: OperationQueue
    private let stateLock = NSLock()
    private var inFlightKeys: Set<String> = []
    private var failedKeys: Set<String> = []
    private var lutObserver: Any?

    private static let lutCIContext: CIContext = {
        // Must match VisionLUTCompositor (CompositionEngine) working space (default Extended Linear sRGB)
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .useSoftwareRenderer: false])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    private static let renderColorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    private init() {
        ramCache.countLimit = 180
        ramCache.totalCostLimit = 24 * 1024 * 1024 // Strict ~24 MB RAM cap
        lutRamCache.countLimit = 220
        lutRamCache.totalCostLimit = 24 * 1024 * 1024

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = caches.appendingPathComponent("Vision/Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        workQueue = OperationQueue()
        workQueue.name = "com.vision.thumbnailCacheQueue"
        workQueue.maxConcurrentOperationCount = 2
        workQueue.qualityOfService = .utility

        lutObserver = NotificationCenter.default.addObserver(
            forName: LUTEngine.stateChangedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self = self else { return }
            self.stateLock.lock()
            self.lutRamCache.removeAllObjects()
            self.lastLutSignature = LUTEngine.shared.cacheSignature
            self.stateLock.unlock()
        }
    }

    deinit {
        if let obs = lutObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func applyActiveLUTIfNeeded(to image: NSImage, baseKey: String) -> NSImage {
        guard let lutParams = LUTEngine.shared.currentLUTParameters() else {
            return image
        }
        let sig = LUTEngine.shared.cacheSignature
        stateLock.lock()
        if sig != lastLutSignature {
            lutRamCache.removeAllObjects()
            lastLutSignature = sig
        }
        let lutKey = "\(baseKey)#\(sig)" as NSString
        if let cached = lutRamCache.object(forKey: lutKey) {
            stateLock.unlock()
            return cached
        }
        stateLock.unlock()

        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let ci = CIImage(cgImage: cg)
        let filtered = LUTEngine.apply(lutParams, to: ci.clampedToExtent()).cropped(to: ci.extent)
        guard let outCG = Self.lutCIContext.createCGImage(filtered, from: ci.extent, format: .RGBA8, colorSpace: Self.renderColorSpace) else {
            return image
        }
        let outImg = NSImage(cgImage: outCG, size: image.size)
        stateLock.lock()
        if sig == lastLutSignature {
            lutRamCache.setObject(outImg, forKey: lutKey, cost: estimatedByteCost(of: outImg))
        }
        stateLock.unlock()
        return outImg
    }

    public func store(_ image: NSImage, for url: URL, atSeconds seconds: Double? = nil) {
        let key = cacheKey(url: url, seconds: seconds)
        let cost = estimatedByteCost(of: image)
        ramCache.setObject(image, forKey: key as NSString, cost: cost)

        let diskURL = cacheDir.appendingPathComponent("\(key).jpg")
        if !FileManager.default.fileExists(atPath: diskURL.path) {
            workQueue.addOperation {
                Self.writeJPEG(image: image, to: diskURL)
            }
        }
    }

    /// Returns cached thumbnail synchronously if in RAM/disk, otherwise schedules async generation and returns nil.
    public func thumbnail(
        for url: URL,
        atSeconds seconds: Double? = nil,
        durationSeconds: Double? = nil,
        fallbackImage: NSImage? = nil
    ) -> NSImage? {
        let key = cacheKey(url: url, seconds: seconds)
        if let hit = ramCache.object(forKey: key as NSString) {
            return applyActiveLUTIfNeeded(to: hit, baseKey: key)
        }

        let diskURL = cacheDir.appendingPathComponent("\(key).jpg")
        if FileManager.default.fileExists(atPath: diskURL.path),
           let diskImage = NSImage(contentsOf: diskURL) {
            ramCache.setObject(diskImage, forKey: key as NSString, cost: estimatedByteCost(of: diskImage))
            return applyActiveLUTIfNeeded(to: diskImage, baseKey: key)
        }

        if let fallback = fallbackImage {
            ramCache.setObject(fallback, forKey: key as NSString, cost: estimatedByteCost(of: fallback))
            let targetDisk = diskURL
            workQueue.addOperation {
                Self.writeJPEG(image: fallback, to: targetDisk)
            }
            return applyActiveLUTIfNeeded(to: fallback, baseKey: key)
        }

        // Schedule lazy background generation (non-blocking)
        scheduleGeneration(url: url, key: key, seconds: seconds, durationSeconds: durationSeconds, diskURL: diskURL)

        // If requesting a trimmed subclip frame and it's still generating, try returning the base clip's thumbnail while it loads
        if seconds != nil {
            let baseKey = cacheKey(url: url, seconds: nil)
            if let baseHit = ramCache.object(forKey: baseKey as NSString) {
                return applyActiveLUTIfNeeded(to: baseHit, baseKey: baseKey)
            }
        }
        return nil
    }

    /// Returns cached album artwork cover synchronously if in RAM/disk, otherwise extracts embedded artwork lazily on background queue.
    public func artworkThumbnail(for url: URL) -> NSImage? {
        let key = artworkKey(url: url)
        if let hit = ramCache.object(forKey: key as NSString) {
            return hit
        }

        let diskURL = cacheDir.appendingPathComponent("\(key).jpg")
        if FileManager.default.fileExists(atPath: diskURL.path),
           let diskImage = NSImage(contentsOf: diskURL) {
            ramCache.setObject(diskImage, forKey: key as NSString, cost: estimatedByteCost(of: diskImage))
            return diskImage
        }

        scheduleArtworkExtraction(url: url, key: key, diskURL: diskURL)
        return nil
    }

    private func scheduleArtworkExtraction(url: URL, key: String, diskURL: URL) {
        stateLock.lock()
        if inFlightKeys.contains(key) || failedKeys.contains(key) {
            stateLock.unlock()
            return
        }
        inFlightKeys.insert(key)
        stateLock.unlock()

        workQueue.addOperation { [weak self] in
            guard let self = self else { return }
            defer {
                self.stateLock.lock()
                self.inFlightKeys.remove(key)
                self.stateLock.unlock()
            }

            guard FileManager.default.fileExists(atPath: url.path) else {
                self.markFailed(key)
                return
            }

            let artworkData = Self.extractEmbeddedArtworkData(from: url)
            guard let data = artworkData,
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                self.markFailed(key)
                return
            }

            let thumbOpts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 280
            ]
            guard let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOpts as CFDictionary) else {
                self.markFailed(key)
                return
            }

            let w = max(1, cgImg.width)
            let h = max(1, cgImg.height)
            let img = NSImage(cgImage: cgImg, size: NSSize(width: CGFloat(w), height: CGFloat(h)))
            self.ramCache.setObject(img, forKey: key as NSString, cost: self.estimatedByteCost(of: img))
            Self.writeJPEG(cgImage: cgImg, to: diskURL)

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.thumbnailReadyNotification,
                    object: nil,
                    userInfo: ["urlPath": url.standardizedFileURL.path, "key": key, "kind": "artwork"]
                )
            }
        }
    }

    private final class ArtworkDataBox: @unchecked Sendable {
        var data: Data?
    }

    private static func extractEmbeddedArtworkData(from url: URL) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        let box = ArtworkDataBox()
        Task.detached(priority: .utility) {
            let asset = AVURLAsset(url: url)
            if let common = try? await asset.load(.commonMetadata) {
                for item in common where item.commonKey == .commonKeyArtwork {
                    if let d = try? await item.load(.dataValue), !d.isEmpty {
                        box.data = d
                        break
                    }
                }
            }
            if box.data == nil, let meta = try? await asset.load(.metadata) {
                for item in meta {
                    let ident = item.identifier?.rawValue.lowercased() ?? ""
                    if ident.contains("artwork") || ident.contains("covr") || ident.contains("apic") {
                        if let d = try? await item.load(.dataValue), !d.isEmpty {
                            box.data = d
                            break
                        }
                    }
                }
            }
            sem.signal()
        }
        sem.wait()
        return box.data
    }

    private func artworkKey(url: URL) -> String {
        let raw = "\(url.standardizedFileURL.path)#artwork"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeJPEG(cgImage: CGImage, to url: URL) {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.78]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func scheduleGeneration(
        url: URL,
        key: String,
        seconds: Double?,
        durationSeconds: Double?,
        diskURL: URL
    ) {
        stateLock.lock()
        if inFlightKeys.contains(key) || failedKeys.contains(key) {
            stateLock.unlock()
            return
        }
        inFlightKeys.insert(key)
        stateLock.unlock()

        workQueue.addOperation { [weak self] in
            guard let self = self else { return }
            defer {
                self.stateLock.lock()
                self.inFlightKeys.remove(key)
                self.stateLock.unlock()
            }

            guard FileManager.default.fileExists(atPath: url.path) else {
                self.markFailed(key)
                return
            }

            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 280, height: 160)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.4, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.4, preferredTimescale: 600)

            let targetSec: Double
            if let s = seconds {
                targetSec = max(0.0, s)
            } else if let dur = durationSeconds, dur > 0.2 {
                targetSec = min(2.0, dur * 0.1)
            } else {
                targetSec = 0.25
            }

            let captureTime = CMTime(seconds: targetSec, preferredTimescale: 600)
            guard let cgImg = try? gen.copyCGImage(at: captureTime, actualTime: nil) else {
                self.markFailed(key)
                return
            }

            let w = max(1, cgImg.width)
            let h = max(1, cgImg.height)
            let img = NSImage(cgImage: cgImg, size: NSSize(width: CGFloat(w), height: CGFloat(h)))
            self.ramCache.setObject(img, forKey: key as NSString, cost: self.estimatedByteCost(of: img))
            Self.writeJPEG(image: img, to: diskURL)

            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Self.thumbnailReadyNotification,
                    object: nil,
                    userInfo: ["urlPath": url.standardizedFileURL.path, "key": key]
                )
            }
        }
    }

    public func invalidate(url: URL) {
        let baseKey = cacheKey(url: url, seconds: nil)
        stateLock.lock()
        failedKeys.removeAll()
        ramCache.removeObject(forKey: baseKey as NSString)
        stateLock.unlock()
    }

    private func markFailed(_ key: String) {
        stateLock.lock()
        failedKeys.insert(key)
        stateLock.unlock()
    }

    private func cacheKey(url: URL, seconds: Double?) -> String {
        let bucket = seconds.map { String(format: "%.1f", max(0, $0)) } ?? "base"
        let raw = "\(url.standardizedFileURL.path)#\(bucket)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private func estimatedByteCost(of image: NSImage) -> Int {
        let w = max(1, Int(image.size.width))
        let h = max(1, Int(image.size.height))
        return w * h * 4
    }

    private static func writeJPEG(image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) else {
            return
        }
        try? data.write(to: url, options: .atomic)
    }
}
