import Foundation
import IOKit.hid

/// Azioni mappabili di Vision eseguibili sia da tastiera che da Blackmagic DaVinci Resolve Speed Editor.
public enum VisionCommandAction: String, CaseIterable, Codable, Sendable {
    case none = "none"
    case playPause = "play_pause"
    case stepBack = "step_back"
    case stepForward = "step_forward"
    case trimStart = "trim_start"
    case trimEnd = "trim_end"
    case splitClip = "split_clip"
    case rippleDelete = "ripple_delete"
    case closeGaps = "close_gaps"
    case toggleMarker = "toggle_marker"
    case clearMarkers = "clear_markers"
    case toggleSlowMotion = "toggle_slow_motion"
    case toggleLock = "toggle_lock"
    case toggleLink = "toggle_link"
    case toggleSnap = "toggle_snap"
    case toggleSelectionFollowsPlayhead = "toggle_selection_playhead"
    case priority1 = "priority_1"
    case priority2 = "priority_2"
    case priority3 = "priority_3"
    case priorityClear = "priority_clear"
    case slipLeft = "slip_left"
    case slipRight = "slip_right"
    case spanUp = "span_up"
    case spanDown = "span_down"
    case swapLeft = "swap_left"
    case swapRight = "swap_right"
    case moveClipUp = "move_clip_up"
    case moveClipDown = "move_clip_down"
    case toggleFullScreen = "toggle_fullscreen"
    case undo = "undo"
    case redo = "redo"
    case openRhythmicStudio = "open_rhythmic_studio"
    case wheelModeJog = "wheel_mode_jog"
    case wheelModeShuttle = "wheel_mode_shuttle"
    case wheelModeScroll = "wheel_mode_scroll"

    public var displayTitle: String {
        switch self {
        case .none: return "— Nessun comando —"
        case .playPause: return "Play / Pausa (Spazio)"
        case .stepBack: return "Passo indietro 1 frame (←)"
        case .stepForward: return "Passo avanti 1 frame (→)"
        case .trimStart: return "Trim inizio alla testina (Q)"
        case .trimEnd: return "Trim fine alla testina (W)"
        case .splitClip: return "Spezza clip alla testina (S)"
        case .rippleDelete: return "Elimina con scarto (⌫ / E)"
        case .closeGaps: return "Chiudi spazi tra clip (⌥⌘W)"
        case .toggleMarker: return "Aggiungi / rimuovi Marcatore (M)"
        case .clearMarkers: return "Pulisci marcatori clip (⌥M)"
        case .toggleSlowMotion: return "Alterna Slow Motion 50% (⌥S)"
        case .toggleLock: return "Blocca / Sblocca clip (L)"
        case .toggleLink: return "Alterna Link A/V (⌥L)"
        case .toggleSnap: return "Alterna Magnet Snapping (N)"
        case .toggleSelectionFollowsPlayhead: return "Alterna Seleziona sotto testina (⌥P)"
        case .priority1: return "Priorità 1 — Hero (1)"
        case .priority2: return "Priorità 2 — Buona (2)"
        case .priority3: return "Priorità 3 — Filler (3)"
        case .priorityClear: return "Rimuovi Priorità (0)"
        case .slipLeft: return "Slip contenuto indietro −0.25s (⌥←)"
        case .slipRight: return "Slip contenuto avanti +0.25s (⌥→)"
        case .spanUp: return "Aumenta Span gabbia (⌥+)"
        case .spanDown: return "Riduci Span gabbia (⌥−)"
        case .swapLeft: return "Scambia gabbia a sinistra (⌘←)"
        case .swapRight: return "Scambia gabbia a destra (⌘→)"
        case .moveClipUp: return "Sposta clip su traccia sopra (⌥↑)"
        case .moveClipDown: return "Sposta clip su traccia sotto (⌥↓)"
        case .toggleFullScreen: return "Viewer Schermo Intero (⌘F)"
        case .undo: return "Annulla — Undo (⌘Z)"
        case .redo: return "Ripeti — Redo (⇧⌘Z)"
        case .openRhythmicStudio: return "Apri Auto-Fill Ritmico"
        case .wheelModeJog: return "Rotella: Modalità JOG (Frame)"
        case .wheelModeShuttle: return "Rotella: Modalità SHTL (Shuttle)"
        case .wheelModeScroll: return "Rotella: Modalità SCRL (Scroll Timeline)"
        }
    }
}

/// Tasti fisici del Blackmagic Design DaVinci Resolve Speed Editor (`bmd.py` HID keycodes).
public enum SpeedEditorButton: UInt16, CaseIterable, Codable, Sendable {
    case stopPlay = 0x3c
    case cut = 0x0f
    case split = 0x2f
    case riplDel = 0x2b
    case inKey = 0x07
    case outKey = 0x08
    case trimIn = 0x09
    case trimOut = 0x0a
    case roll = 0x0b
    case slipSrc = 0x0c
    case slipDest = 0x0d
    case shtl = 0x1c
    case jog = 0x1d
    case scrl = 0x1e
    case snap = 0x2e
    case fullView = 0x2d
    case source = 0x1a
    case timeline = 0x1b
    case smartInsrt = 0x01
    case appnd = 0x02
    case riplOwr = 0x03
    case closeUp = 0x04
    case placeOnTop = 0x05
    case srcOwr = 0x06
    case liveOwr = 0x30
    case dis = 0x10
    case smthCut = 0x11
    case trans = 0x22
    case transDur = 0x0e
    case syncBin = 0x1f
    case videoOnly = 0x25
    case audioOnly = 0x26
    case audioLevel = 0x2c
    case esc = 0x31
    case cam1 = 0x33
    case cam2 = 0x34
    case cam3 = 0x35
    case cam4 = 0x36
    case cam5 = 0x37
    case cam6 = 0x38
    case cam7 = 0x39
    case cam8 = 0x3a
    case cam9 = 0x3b

    public var label: String {
        switch self {
        case .stopPlay: return "STOP / PLAY"
        case .cut: return "CUT"
        case .split: return "SPLIT"
        case .riplDel: return "RIPL DEL"
        case .inKey: return "IN"
        case .outKey: return "OUT"
        case .trimIn: return "TRIM IN"
        case .trimOut: return "TRIM OUT"
        case .roll: return "ROLL"
        case .slipSrc: return "SLIP SRC"
        case .slipDest: return "SLIP DEST"
        case .shtl: return "SHTL"
        case .jog: return "JOG"
        case .scrl: return "SCRL"
        case .snap: return "SNAP"
        case .fullView: return "FULL VIEW"
        case .source: return "SOURCE"
        case .timeline: return "TIMELINE"
        case .smartInsrt: return "SMART INSRT"
        case .appnd: return "APPND"
        case .riplOwr: return "RIPL O/WR"
        case .closeUp: return "CLOSE UP"
        case .placeOnTop: return "PLACE ON TOP"
        case .srcOwr: return "SRC O/WR"
        case .liveOwr: return "LIVE O/WR"
        case .dis: return "DIS"
        case .smthCut: return "SMTH CUT"
        case .trans: return "TRANS"
        case .transDur: return "TRANS DUR"
        case .syncBin: return "SYNC BIN"
        case .videoOnly: return "VIDEO ONLY"
        case .audioOnly: return "AUDIO ONLY"
        case .audioLevel: return "AUDIO LEVEL"
        case .esc: return "ESC"
        case .cam1: return "CAM 1"
        case .cam2: return "CAM 2"
        case .cam3: return "CAM 3"
        case .cam4: return "CAM 4"
        case .cam5: return "CAM 5"
        case .cam6: return "CAM 6"
        case .cam7: return "CAM 7"
        case .cam8: return "CAM 8"
        case .cam9: return "CAM 9"
        }
    }

    public var groupTitle: String {
        switch self {
        case .stopPlay, .shtl, .jog, .scrl, .source, .timeline:
            return "Trasporto & Search Dial"
        case .inKey, .outKey, .trimIn, .trimOut, .roll, .slipSrc, .slipDest, .cut, .split, .riplDel:
            return "Taglio, Trim & Slip"
        case .smartInsrt, .appnd, .riplOwr, .closeUp, .placeOnTop, .srcOwr, .liveOwr, .dis, .smthCut, .trans, .transDur:
            return "Inserimento & Transizioni"
        case .snap, .fullView, .syncBin, .videoOnly, .audioOnly, .audioLevel, .esc, .cam1, .cam2, .cam3, .cam4, .cam5, .cam6, .cam7, .cam8, .cam9:
            return "Camera, Modalità & Controlli"
        }
    }

    public var defaultAction: VisionCommandAction {
        switch self {
        case .stopPlay: return .playPause
        case .cut, .split: return .splitClip
        case .riplDel: return .rippleDelete
        case .inKey, .trimIn: return .trimStart
        case .outKey, .trimOut: return .trimEnd
        case .roll: return .closeGaps
        case .slipSrc: return .slipLeft
        case .slipDest: return .slipRight
        case .shtl: return .wheelModeShuttle
        case .jog: return .wheelModeJog
        case .scrl: return .wheelModeScroll
        case .snap: return .toggleSnap
        case .fullView: return .toggleFullScreen
        case .source: return .toggleSlowMotion
        case .timeline: return .toggleSelectionFollowsPlayhead
        case .smartInsrt: return .stepBack
        case .appnd: return .openRhythmicStudio
        case .riplOwr: return .stepForward
        case .closeUp: return .spanUp
        case .placeOnTop: return .moveClipUp
        case .srcOwr: return .moveClipDown
        case .liveOwr: return .toggleMarker
        case .dis: return .clearMarkers
        case .smthCut: return .toggleLock
        case .trans: return .swapRight
        case .transDur: return .swapLeft
        case .syncBin: return .undo
        case .videoOnly: return .spanDown
        case .audioOnly: return .redo
        case .audioLevel: return .toggleLink
        case .esc: return .priorityClear
        case .cam1: return .priority1
        case .cam2: return .priority2
        case .cam3: return .priority3
        case .cam4, .cam5, .cam6, .cam7, .cam8, .cam9: return .none
        }
    }

    public var svgId: String {
        switch self {
        case .stopPlay: return "se-stop-play"
        case .cut: return "se-cut"
        case .split: return "se-split"
        case .riplDel: return "se-ripl-del"
        case .inKey: return "se-in"
        case .outKey: return "se-out"
        case .trimIn: return "se-trim-in"
        case .trimOut: return "se-trim-out"
        case .roll: return "se-roll"
        case .slipSrc: return "se-slip-src"
        case .slipDest: return "se-slip-dest"
        case .shtl: return "se-shtl"
        case .jog: return "se-jog"
        case .scrl: return "se-scrl"
        case .snap: return "se-snap"
        case .fullView: return "se-full-view"
        case .source: return "se-source"
        case .timeline: return "se-timeline"
        case .smartInsrt: return "se-smart-insrt"
        case .appnd: return "se-appnd"
        case .riplOwr: return "se-ripl-owr"
        case .closeUp: return "se-close-up"
        case .placeOnTop: return "se-place-on-top"
        case .srcOwr: return "se-src-owr"
        case .liveOwr: return "se-live-owr"
        case .dis: return "se-dis"
        case .smthCut: return "se-smth-cut"
        case .trans: return "se-trans"
        case .transDur: return "se-trans-dur"
        case .syncBin: return "se-sync-bin"
        case .videoOnly: return "se-video-only"
        case .audioOnly: return "se-audio-only"
        case .audioLevel: return "se-audio-level"
        case .esc: return "se-esc"
        case .cam1: return "se-cam-1"
        case .cam2: return "se-cam-2"
        case .cam3: return "se-cam-3"
        case .cam4: return "se-cam-4"
        case .cam5: return "se-cam-5"
        case .cam6: return "se-cam-6"
        case .cam7: return "se-cam-7"
        case .cam8: return "se-cam-8"
        case .cam9: return "se-cam-9"
        }
    }

    public static func fromSVGId(_ id: String) -> SpeedEditorButton? {
        allCases.first { $0.svgId == id }
    }

    public var secondaryHardwareLabel: String? {
        switch self {
        case .smartInsrt, .appnd: return "CLIP"
        case .closeUp: return "YPOS"
        case .esc: return "UNDO"
        case .audioLevel: return "MARK"
        case .fullView: return "RVW"
        case .trans: return "TITLE"
        case .split: return "MOVE"
        case .inKey, .outKey: return "CLR"
        case .roll: return "SLIDE"
        case .transDur: return "SET"
        case .liveOwr: return "RND"
        default: return nil
        }
    }

    public var defaultDoubleTapAction: VisionCommandAction {
        .none
    }
}

public enum SpeedEditorWheelMode: String, Codable, Sendable {
    case jog = "JOG"
    case shuttle = "SHTL"
    case scroll = "SCRL"

    var hardwareModeByte: UInt8 {
        switch self {
        case .jog: return 0     // RELATIVE_0: delta relativi continui infiniti (nessun limite a 4096)
        case .shuttle: return 3 // ABSOLUTE_DEADZERO: [-4096 .. +4096] con deadzone centrale
        case .scroll: return 0  // RELATIVE_0: delta relativi continui infiniti per timeline
        }
    }

    var jogLedMask: UInt8 {
        switch self {
        case .jog: return 1 << 0
        case .shuttle: return 1 << 1
        case .scroll: return 1 << 2
        }
    }
}

/// Gestore nativo IOKit HID per Blackmagic Design DaVinci Resolve Speed Editor (USB-C / Bluetooth).
/// Gestisce handshake crittografico Report 0x06, lettura tasti Report 0x04, Search Dial Report 0x03 e rimappatura comandi.
public final class SpeedEditorManager: @unchecked Sendable {
    public static let shared = SpeedEditorManager()
    public static let stateChangedNotification = Notification.Name("SpeedEditorManager.stateChanged")

    public static let usbVendorID: Int = 0x1EDB
    public static let usbProductID: Int = 0xDA0E

    private static let mappingDefaultsKey = "com.vision.speedEditorMappings.v1"
    private static let doubleTapDefaultsKey = "com.vision.speedEditorDoubleTapMappings.v1"
    private static let wheelSensDefaultsKey = "com.vision.speedEditorWheelSensitivity.v1"
    private static let doubleTapWindowSeconds: TimeInterval = 0.26

    public private(set) var isConnected: Bool = false
    public private(set) var isAuthenticated: Bool = false
    public private(set) var connectionStatusText: String = "Non connesso — collega via USB-C o Bluetooth"
    public private(set) var currentWheelMode: SpeedEditorWheelMode = .jog
    public private(set) var lastPressedButton: SpeedEditorButton? = nil
    public private(set) var lastPressWasDoubleTap: Bool = false

    public var wheelSensitivity: Double {
        didSet {
            let clamped = max(0.1, min(4.0, wheelSensitivity))
            if clamped != wheelSensitivity {
                wheelSensitivity = clamped
                return
            }
            UserDefaults.standard.set(clamped, forKey: Self.wheelSensDefaultsKey)
            if abs(oldValue - clamped) > 0.001 {
                DebugLogger.shared.log("[SPEED] wheelSensitivity -> \(String(format: "%.2fx", clamped))", level: .info)
            }
        }
    }

    /// Moltiplicatore percettivo unificato della ghiera (lineare sotto 1.0x per micro-precisione, progressivo fino a 4.0x).
    public static func effectiveWheelScale(for sensitivity: Double) -> Double {
        let clamped = max(0.1, min(4.0, sensitivity))
        return clamped <= 1.0 ? clamped : pow(clamped, 1.3)
    }

    /// Unità hardware base per singolo scatto del Search Dial in modalità relativa (`repMode=0`: 360 tick/scatto).
    public static let rawTicksPerWheelStep: Double = 360.0

    /// Converte il delta grezzo della ghiera in frame da spostare in JOG applicando la curva di sensibilità.
    public static func computeJogFrames(
        delta: Int32,
        sensitivity: Double,
        accumulator: inout Double,
        lastEventTime: inout CFAbsoluteTime,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> Int {
        guard delta != 0 else { return 0 }
        if lastEventTime > 0, (now - lastEventTime) > 1.2 {
            accumulator = 0
        }
        lastEventTime = now
        if (delta > 0 && accumulator < 0) || (delta < 0 && accumulator > 0) {
            accumulator = 0
        }

        let steps = Double(delta) / rawTicksPerWheelStep
        let sensScale = effectiveWheelScale(for: sensitivity)
        accumulator += steps * sensScale

        let rawFrames = Int(accumulator.rounded(.towardZero))
        guard rawFrames != 0 else { return 0 }
        let clampedFrames = max(-1800, min(1800, rawFrames))
        accumulator -= Double(clampedFrames)
        return clampedFrames
    }

    /// Converte il delta grezzo della ghiera in punti di scorrimento orizzontale per SCRL.
    public static func computeScrollDelta(delta: Int32, sensitivity: Double) -> CGFloat {
        let steps = Double(delta) / rawTicksPerWheelStep
        let sensScale = effectiveWheelScale(for: sensitivity)
        return CGFloat(steps * 12.0 * sensScale)
    }

    /// Callback sul main thread quando viene invocata un'azione mappata.
    public var onCommandAction: ((VisionCommandAction) -> Void)?
    /// Callback sul main thread quando gira la rotella: `(mode, rawDeltaTicks)`.
    public var onWheelDelta: ((SpeedEditorWheelMode, Int32) -> Void)?
    /// Callback opzionale per il modale tastiera/mappatura (evidenziazione live del tasto fisico premuto).
    public var onPhysicalButtonEvent: ((SpeedEditorButton) -> Void)?

    private var mappings: [SpeedEditorButton: VisionCommandAction] = [:]
    private var doubleTapMappings: [SpeedEditorButton: VisionCommandAction] = [:]
    private var pendingTapTimers: [SpeedEditorButton: DispatchWorkItem] = [:]
    private let stateLock = NSLock()

    private var hidManager: IOHIDManager?
    private var activeDevice: IOHIDDevice?
    private var inputReportBuffer = [UInt8](repeating: 0, count: 64)
    private var pressedKeyCodes: Set<UInt16> = []
    private var lastJogValue: Int32?
    private var lastShuttleValue: Int32?
    private var pendingWheelMode: SpeedEditorWheelMode?
    private var pendingRelativeDelta: Int64 = 0
    private var pendingAbsoluteValue: Int32?
    private var pendingReportMode: UInt8 = 0
    private var pendingPacketCount: Int = 0
    private var isWheelFlushScheduled: Bool = false
    private var reauthTimer: Timer?
    private var isStarted = false

    private init() {
        let savedSens = UserDefaults.standard.double(forKey: Self.wheelSensDefaultsKey)
        self.wheelSensitivity = savedSens > 0 ? max(0.1, min(4.0, savedSens)) : 1.0
        loadMappings()
    }

    // MARK: - Mappings Persistence

    private func loadMappings() {
        var result: [SpeedEditorButton: VisionCommandAction] = [:]
        var dtResult: [SpeedEditorButton: VisionCommandAction] = [:]
        for btn in SpeedEditorButton.allCases {
            result[btn] = btn.defaultAction
            dtResult[btn] = btn.defaultDoubleTapAction
        }
        if let rawDict = UserDefaults.standard.dictionary(forKey: Self.mappingDefaultsKey) as? [String: String] {
            for (kStr, vStr) in rawDict {
                if let rawCode = UInt16(kStr),
                   let btn = SpeedEditorButton(rawValue: rawCode),
                   let act = VisionCommandAction(rawValue: vStr) {
                    result[btn] = act
                }
            }
        }
        if let rawDtDict = UserDefaults.standard.dictionary(forKey: Self.doubleTapDefaultsKey) as? [String: String] {
            for (kStr, vStr) in rawDtDict {
                if let rawCode = UInt16(kStr),
                   let btn = SpeedEditorButton(rawValue: rawCode),
                   let act = VisionCommandAction(rawValue: vStr) {
                    dtResult[btn] = act
                }
            }
        }
        stateLock.lock()
        self.mappings = result
        self.doubleTapMappings = dtResult
        stateLock.unlock()
    }

    private func saveMappings() {
        stateLock.lock()
        var dict: [String: String] = [:]
        for (btn, act) in mappings {
            dict[String(btn.rawValue)] = act.rawValue
        }
        var dtDict: [String: String] = [:]
        for (btn, act) in doubleTapMappings where act != .none {
            dtDict[String(btn.rawValue)] = act.rawValue
        }
        stateLock.unlock()
        UserDefaults.standard.set(dict, forKey: Self.mappingDefaultsKey)
        UserDefaults.standard.set(dtDict, forKey: Self.doubleTapDefaultsKey)
    }

    public func action(for button: SpeedEditorButton) -> VisionCommandAction {
        stateLock.lock()
        defer { stateLock.unlock() }
        return mappings[button] ?? button.defaultAction
    }

    public func setAction(_ action: VisionCommandAction, for button: SpeedEditorButton) {
        stateLock.lock()
        mappings[button] = action
        stateLock.unlock()
        saveMappings()
        notifyUIStateChanged()
    }

    public func doubleTapAction(for button: SpeedEditorButton) -> VisionCommandAction {
        stateLock.lock()
        defer { stateLock.unlock() }
        return doubleTapMappings[button] ?? button.defaultDoubleTapAction
    }

    public func setDoubleTapAction(_ action: VisionCommandAction, for button: SpeedEditorButton) {
        stateLock.lock()
        doubleTapMappings[button] = action
        stateLock.unlock()
        saveMappings()
        notifyUIStateChanged()
    }

    public func resetMappingsToDefaults() {
        stateLock.lock()
        for btn in SpeedEditorButton.allCases {
            mappings[btn] = btn.defaultAction
            doubleTapMappings[btn] = btn.defaultDoubleTapAction
        }
        stateLock.unlock()
        UserDefaults.standard.removeObject(forKey: Self.mappingDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.doubleTapDefaultsKey)
        notifyUIStateChanged()
    }

    public func setWheelMode(_ mode: SpeedEditorWheelMode) {
        stateLock.lock()
        currentWheelMode = mode
        lastJogValue = nil
        lastShuttleValue = nil
        pendingWheelMode = nil
        pendingRelativeDelta = 0
        pendingAbsoluteValue = nil
        stateLock.unlock()
        applyHardwareWheelMode(mode)
        DebugLogger.shared.log("[SPEED] Modalità ghiera -> \(mode.rawValue) (hwByte=\(mode.hardwareModeByte) sens=\(String(format: "%.2fx", wheelSensitivity)))", level: .info)
        notifyUIStateChanged()
    }

    /// Consente di testare un tasto fisico / mappatura anche senza hardware collegato.
    public func simulateButtonPress(_ button: SpeedEditorButton, isDoubleTap: Bool = false) {
        let exec = { [weak self] in
            guard let self = self else { return }
            self.lastPressedButton = button
            self.lastPressWasDoubleTap = isDoubleTap
            let action = isDoubleTap ? self.doubleTapAction(for: button) : self.action(for: button)
            self.onPhysicalButtonEvent?(button)
            self.dispatchCommandAction(action)
            self.notifyUIStateChanged()
        }
        if Thread.isMainThread { exec() } else { DispatchQueue.main.async(execute: exec) }
    }

    // MARK: - IOKit HID Lifecycle

    public func start() {
        guard !isStarted else { return }
        isStarted = true

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey: Self.usbVendorID,
            kIOHIDProductIDKey: Self.usbProductID
        ]
        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let ctx = context else { return }
            let mgr = Unmanaged<SpeedEditorManager>.fromOpaque(ctx).takeUnretainedValue()
            mgr.deviceAttached(device)
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let ctx = context else { return }
            let mgr = Unmanaged<SpeedEditorManager>.fromOpaque(ctx).takeUnretainedValue()
            mgr.deviceDetached(device)
        }, ctx)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let openRes = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.hidManager = manager

        if openRes != kIOReturnSuccess {
            connectionStatusText = "HID in attesa permessi / driver (\(openRes))"
            DebugLogger.shared.log("Speed Editor IOHIDManagerOpen codice \(openRes)", level: .warning)
        }
    }

    public func stop() {
        reauthTimer?.invalidate()
        reauthTimer = nil
        if let mgr = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil
        activeDevice = nil
        isConnected = false
        isAuthenticated = false
    }

    private func deviceAttached(_ device: IOHIDDevice) {
        let openRes = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openRes == kIOReturnSuccess else {
            connectionStatusText = "Rilevato Speed Editor ma impossibile aprire interfaccia (\(openRes))"
            notifyUIStateChanged()
            return
        }

        activeDevice = device
        isConnected = true
        stateLock.lock()
        lastJogValue = nil
        lastShuttleValue = nil
        pendingWheelMode = nil
        pendingRelativeDelta = 0
        pendingAbsoluteValue = nil
        stateLock.unlock()
        pressedKeyCodes.removeAll()

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        inputReportBuffer.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            IOHIDDeviceRegisterInputReportCallback(
                device,
                base,
                buf.count,
                { context, _, _, _, reportID, report, reportLength in
                    guard let ctx = context else { return }
                    let mgr = Unmanaged<SpeedEditorManager>.fromOpaque(ctx).takeUnretainedValue()
                    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
                    mgr.handleInputReport(reportID: reportID, bytes: bytes)
                },
                ctx
            )
        }

        let authOK = performAuthentication(on: device)
        isAuthenticated = authOK
        if authOK {
            connectionStatusText = "Connesso e autenticato (Blackmagic Speed Editor)"
            applyHardwareWheelMode(currentWheelMode)
            scheduleReauthenticationTimer()
            DebugLogger.shared.log("Blackmagic Speed Editor connesso e autenticato ✓", level: .info)
        } else {
            connectionStatusText = "Connesso (handshake in corso / modalità sola lettura)"
            DebugLogger.shared.log("Speed Editor rilevato ma autenticazione Feature Report 0x06 non confermata.", level: .warning)
        }
        notifyUIStateChanged()
    }

    private func deviceDetached(_ device: IOHIDDevice) {
        guard activeDevice === device else { return }
        reauthTimer?.invalidate()
        reauthTimer = nil
        activeDevice = nil
        isConnected = false
        isAuthenticated = false
        pressedKeyCodes.removeAll()
        stateLock.lock()
        lastJogValue = nil
        lastShuttleValue = nil
        pendingWheelMode = nil
        pendingRelativeDelta = 0
        pendingAbsoluteValue = nil
        stateLock.unlock()
        connectionStatusText = "Non connesso — collega via USB-C o Bluetooth"
        DebugLogger.shared.log("Blackmagic Speed Editor scollegato.", level: .info)
        notifyUIStateChanged()
    }

    private func scheduleReauthenticationTimer() {
        reauthTimer?.invalidate()
        reauthTimer = Timer.scheduledTimer(withTimeInterval: 480.0, repeats: true) { [weak self] _ in
            guard let self = self, let dev = self.activeDevice else { return }
            _ = self.performAuthentication(on: dev)
        }
    }

    // MARK: - Feature Report 0x06 Challenge-Response Authentication (`bmd.py`)

    private static func rol8(_ v: UInt64) -> UInt64 {
        (v << 56) | (v >> 8)
    }

    private static func rol8n(_ v: UInt64, count n: Int) -> UInt64 {
        var x = v
        for _ in 0..<n { x = rol8(x) }
        return x
    }

    public static func computeAuthResponse(challenge: UInt64) -> UInt64 {
        let evenTbl: [UInt64] = [
            0x3ae1206f97c10bc8, 0x2a9ab32bebf244c6, 0x20a6f8b8df9adf0a, 0xaf80ece52cfc1719,
            0xec2ee2f7414fd151, 0xb055adfd73344a15, 0xa63d2e3059001187, 0x751bf623f42e0dde
        ]
        let oddTbl: [UInt64] = [
            0x3e22b34f502e7fde, 0x24656b981875ab1c, 0xa17f3456df7bf8c3, 0x6df72e1941aef698,
            0x72226f011e66ab94, 0x3831a3c606296b42, 0xfd7ff81881332c89, 0x61a3f6474ff236c6
        ]
        let mask: UInt64 = 0xa79a63f585d37bf0
        let n = Int(challenge & 7)
        var v = rol8n(challenge, count: n)
        let k: UInt64
        if (v & 1) == ((UInt64(0x78) >> n) & 1) {
            k = evenTbl[n]
        } else {
            v = v ^ rol8(v)
            k = oddTbl[n]
        }
        return v ^ (rol8(v) & mask) ^ k
    }

    private func performAuthentication(on device: IOHIDDevice) -> Bool {
        var resetPacket: [UInt8] = [0x06, 0x00, 0, 0, 0, 0, 0, 0, 0, 0]
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 6, &resetPacket, resetPacket.count) == kIOReturnSuccess else {
            return false
        }

        var challengeBuf = [UInt8](repeating: 0, count: 10)
        var challengeLen: CFIndex = challengeBuf.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 6, &challengeBuf, &challengeLen) == kIOReturnSuccess,
              challengeLen >= 10, challengeBuf[0] == 0x06, challengeBuf[1] == 0x00 else {
            return false
        }

        let kbdChallenge = decodeLE64(challengeBuf, offset: 2)
        var hostChallengePacket: [UInt8] = [0x06, 0x01, 0, 0, 0, 0, 0, 0, 0, 0]
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 6, &hostChallengePacket, hostChallengePacket.count) == kIOReturnSuccess else {
            return false
        }

        var kbdRespBuf = [UInt8](repeating: 0, count: 10)
        var kbdRespLen: CFIndex = kbdRespBuf.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 6, &kbdRespBuf, &kbdRespLen) == kIOReturnSuccess,
              kbdRespLen >= 10, kbdRespBuf[0] == 0x06, kbdRespBuf[1] == 0x02 else {
            return false
        }

        let responseVal = Self.computeAuthResponse(challenge: kbdChallenge)
        var responsePacket = [UInt8](repeating: 0, count: 10)
        responsePacket[0] = 0x06
        responsePacket[1] = 0x03
        encodeLE64(responseVal, into: &responsePacket, offset: 2)
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 6, &responsePacket, responsePacket.count) == kIOReturnSuccess else {
            return false
        }

        var statusBuf = [UInt8](repeating: 0, count: 10)
        var statusLen: CFIndex = statusBuf.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 6, &statusBuf, &statusLen) == kIOReturnSuccess,
              statusLen >= 4, statusBuf[0] == 0x06, statusBuf[1] == 0x04 else {
            return false
        }

        return true
    }

    private func applyHardwareWheelMode(_ mode: SpeedEditorWheelMode) {
        guard let dev = activeDevice else { return }
        var ledPacket: [UInt8] = [0x04, mode.jogLedMask]
        _ = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 4, &ledPacket, ledPacket.count)

        var modePacket: [UInt8] = [0x03, mode.hardwareModeByte, 0, 0, 0, 0, 0xFF]
        _ = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 3, &modePacket, modePacket.count)
    }

    // MARK: - HID Input Parsing

    private func handleInputReport(reportID: UInt32, bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        let effectiveId = (reportID != 0) ? Int(reportID) : Int(bytes[0])
        let payloadStart = (bytes[0] == UInt8(truncatingIfNeeded: effectiveId)) ? 1 : 0

        switch effectiveId {
        case 4: // Keys report (up to 6 x UInt16 LE active keycodes)
            var currentCodes: Set<UInt16> = []
            var idx = payloadStart
            while idx + 1 < bytes.count {
                let code = UInt16(bytes[idx]) | (UInt16(bytes[idx + 1]) << 8)
                if code != 0 {
                    currentCodes.insert(code)
                }
                idx += 2
            }
            let newlyPressed = currentCodes.subtracting(pressedKeyCodes)
            pressedKeyCodes = currentCodes
            for code in newlyPressed {
                if let btn = SpeedEditorButton(rawValue: code) {
                    handlePressedButton(btn)
                }
            }

        case 3: // Jog / Shuttle wheel report: [mode: u8, value: i32 LE, ...]
            guard bytes.count >= payloadStart + 5 else { return }
            let reportMode = bytes[payloadStart]
            let rawUnsigned =
                UInt32(bytes[payloadStart + 1]) |
                (UInt32(bytes[payloadStart + 2]) << 8) |
                (UInt32(bytes[payloadStart + 3]) << 16) |
                (UInt32(bytes[payloadStart + 4]) << 24)
            let rawValue = Int32(bitPattern: rawUnsigned)
            processWheelInput(reportMode: reportMode, rawValue: rawValue)

        default:
            break
        }
    }

    /// Elabora e accorpa un report HID della ghiera (testabile anche senza hardware fisico).
    /// - `reportMode`: `0`/`2` = relativo continuo, `1`/`3` = assoluto `[-4096 .. +4096]`.
    public func processWheelInput(reportMode: UInt8, rawValue: Int32, emitSynchronouslyForTesting: Bool = false) {
        let mode = currentWheelMode
        let isRelativePacket = (reportMode == 0 || reportMode == 2)

        stateLock.lock()
        var shouldScheduleFlush = false
        var immediateEmit: (SpeedEditorWheelMode, Int32)? = nil

        switch mode {
        case .jog, .scroll:
            let stepDelta: Int32
            if isRelativePacket {
                lastJogValue = nil
                stepDelta = rawValue
            } else {
                // Fallback sicuro se arrivano pacchetti assoluti (±4096) durante il cambio mode hardware
                if let prev = lastJogValue {
                    let diff = rawValue &- prev
                    stepDelta = abs(diff) <= 2048 ? diff : 0
                } else {
                    stepDelta = 0
                }
                lastJogValue = rawValue
            }

            if stepDelta != 0 {
                if emitSynchronouslyForTesting {
                    immediateEmit = (mode, stepDelta)
                } else {
                    if pendingWheelMode != mode {
                        pendingWheelMode = mode
                        pendingRelativeDelta = 0
                        pendingAbsoluteValue = nil
                        pendingPacketCount = 0
                    }
                    pendingReportMode = reportMode
                    pendingPacketCount += 1
                    pendingRelativeDelta += Int64(stepDelta)
                    if !isWheelFlushScheduled {
                        isWheelFlushScheduled = true
                        shouldScheduleFlush = true
                    }
                }
            }

        case .shuttle:
            // In Shuttle la posizione assoluta [-4096 .. +4096] controlla la velocità (0 = fermo nella deadzone)
            let targetVal = isRelativePacket ? (lastShuttleValue ?? 0) &+ rawValue : rawValue
            let clamped = max(-4096, min(4096, targetVal))
            let prev = lastShuttleValue
            lastShuttleValue = clamped
            if prev != clamped {
                if emitSynchronouslyForTesting {
                    immediateEmit = (.shuttle, clamped)
                } else {
                    pendingWheelMode = .shuttle
                    pendingReportMode = reportMode
                    pendingPacketCount += 1
                    pendingAbsoluteValue = clamped
                    pendingRelativeDelta = 0
                    if !isWheelFlushScheduled {
                        isWheelFlushScheduled = true
                        shouldScheduleFlush = true
                    }
                }
            }
        }
        stateLock.unlock()

        if let (emittedMode, emittedVal) = immediateEmit {
            onWheelDelta?(emittedMode, emittedVal)
            return
        }

        if shouldScheduleFlush {
            DispatchQueue.main.async { [weak self] in
                self?.flushPendingWheelInput()
            }
        }
    }

    private func flushPendingWheelInput() {
        stateLock.lock()
        isWheelFlushScheduled = false
        guard let mode = pendingWheelMode else {
            stateLock.unlock()
            return
        }
        let repMode = pendingReportMode
        let pktCount = pendingPacketCount
        pendingPacketCount = 0
        let valueToEmit: Int32?
        switch mode {
        case .jog, .scroll:
            let clamped = max(Int64(Int32.min), min(Int64(Int32.max), pendingRelativeDelta))
            pendingRelativeDelta = 0
            pendingWheelMode = nil
            valueToEmit = (clamped != 0) ? Int32(clamped) : nil
        case .shuttle:
            valueToEmit = pendingAbsoluteValue
            pendingAbsoluteValue = nil
            pendingWheelMode = nil
        }
        stateLock.unlock()

        if let val = valueToEmit {
            DebugLogger.shared.log(
                "[SPEED-HID] mode=\(mode.rawValue) repMode=\(repMode) pkts=\(pktCount) rawDelta=\(val) sens=\(String(format: "%.2fx", wheelSensitivity))",
                level: .perf
            )
            onWheelDelta?(mode, val)
        }
    }

    private func handlePressedButton(_ button: SpeedEditorButton) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let dtAction = self.doubleTapAction(for: button)
            let singleAction = self.action(for: button)

            if dtAction == .none {
                self.pendingTapTimers.removeValue(forKey: button)?.cancel()
                self.lastPressedButton = button
                self.lastPressWasDoubleTap = false
                self.onPhysicalButtonEvent?(button)
                self.dispatchCommandAction(singleAction)
                self.notifyUIStateChanged()
                return
            }

            if let pending = self.pendingTapTimers.removeValue(forKey: button) {
                pending.cancel()
                self.lastPressedButton = button
                self.lastPressWasDoubleTap = true
                self.onPhysicalButtonEvent?(button)
                self.dispatchCommandAction(dtAction)
                self.notifyUIStateChanged()
                return
            }

            self.lastPressedButton = button
            self.lastPressWasDoubleTap = false
            self.onPhysicalButtonEvent?(button)
            self.notifyUIStateChanged()

            let work = DispatchWorkItem { [weak self] in
                guard let self = self else { return }
                self.pendingTapTimers.removeValue(forKey: button)
                self.dispatchCommandAction(singleAction)
            }
            self.pendingTapTimers[button] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindowSeconds, execute: work)
        }
    }

    private func dispatchCommandAction(_ action: VisionCommandAction) {
        switch action {
        case .wheelModeJog:
            setWheelMode(.jog)
        case .wheelModeShuttle:
            setWheelMode(.shuttle)
        case .wheelModeScroll:
            setWheelMode(.scroll)
        case .none:
            break
        default:
            onCommandAction?(action)
        }
    }

    private func notifyUIStateChanged() {
        let post = {
            NotificationCenter.default.post(name: Self.stateChangedNotification, object: nil)
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    private func decodeLE64(_ buf: [UInt8], offset: Int) -> UInt64 {
        var val: UInt64 = 0
        for i in 0..<8 {
            val |= UInt64(buf[offset + i]) << (i * 8)
        }
        return val
    }

    private func encodeLE64(_ value: UInt64, into buf: inout [UInt8], offset: Int) {
        for i in 0..<8 {
            buf[offset + i] = UInt8((value >> (i * 8)) & 0xFF)
        }
    }
}
