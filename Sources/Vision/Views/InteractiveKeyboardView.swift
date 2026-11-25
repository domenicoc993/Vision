import AppKit

/// Modificatore supportato per filtrare e visualizzare le combinazioni sulla tastiera interattiva.
public enum KeyboardModifierFilter: String, CaseIterable {
    case all = "Tutti"
    case base = "Base"
    case command = "⌘ Cmd"
    case option = "⌥ Opt"
    case control = "⌃ Ctrl"
    case shift = "⇧ Shift"

    public var modifierMask: NSEvent.ModifierFlags? {
        switch self {
        case .all: return nil
        case .base: return []
        case .command: return .command
        case .option: return .option
        case .control: return .control
        case .shift: return .shift
        }
    }
}

/// Singola scorciatoia strutturata con associazione ai tasti dell'SVG.
public struct KeyboardShortcutBinding {
    public let id: String
    public let section: String
    public let keysLabel: String
    public let description: String
    public let primaryKeyIds: [String]
    public let modifiers: NSEvent.ModifierFlags

    public init(
        id: String,
        section: String,
        keysLabel: String,
        description: String,
        primaryKeyIds: [String],
        modifiers: NSEvent.ModifierFlags = []
    ) {
        self.id = id
        self.section = section
        self.keysLabel = keysLabel
        self.description = description
        self.primaryKeyIds = primaryKeyIds
        self.modifiers = modifiers
    }

    public func matches(modifierFilter: KeyboardModifierFilter) -> Bool {
        switch modifierFilter {
        case .all:
            return true
        case .base:
            return modifiers.isEmpty
        case .command:
            return modifiers.contains(.command)
        case .option:
            return modifiers.contains(.option)
        case .control:
            return modifiers.contains(.control)
        case .shift:
            return modifiers.contains(.shift)
        }
    }

    public func matches(query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return description.lowercased().contains(query)
            || keysLabel.lowercased().contains(query)
            || section.lowercased().contains(query)
    }
}

/// Catalogo centralizzato di tutte le scorciatoie da tastiera di Vision, mappate sugli ID di `keyboard.svg`.
public enum KeyboardShortcutCatalog {
    public static let orderedSections: [String] = [
        "GENERALE",
        "RIPRODUZIONE",
        "MONTAGGIO & SELEZIONE (TIMELINE)",
        "GABBIE RITMATE"
    ]

    public static let bindings: [KeyboardShortcutBinding] = [
        // GENERALE
        KeyboardShortcutBinding(
            id: "cmd_o",
            section: "GENERALE",
            keysLabel: "⌘ O",
            description: "Apri Project Manager",
            primaryKeyIds: ["key-o"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "cmd_e",
            section: "GENERALE",
            keysLabel: "⌘ E",
            description: "Esporta timeline attiva in Final Cut XML (.fcpxmld)",
            primaryKeyIds: ["key-e"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "cmd_z",
            section: "GENERALE",
            keysLabel: "⌘ Z",
            description: "Annulla (Undo)",
            primaryKeyIds: ["key-z"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "shift_cmd_z",
            section: "GENERALE",
            keysLabel: "⇧ ⌘ Z",
            description: "Ripeti (Redo)",
            primaryKeyIds: ["key-z"],
            modifiers: [.shift, .command]
        ),
        KeyboardShortcutBinding(
            id: "cmd_y",
            section: "GENERALE",
            keysLabel: "⌘ Y",
            description: "Ripeti (Redo) / Cronologia Azioni",
            primaryKeyIds: ["key-y"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "cmd_f",
            section: "GENERALE",
            keysLabel: "⌘ F",
            description: "Schermo intero Viewer",
            primaryKeyIds: ["key-f"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "z_fit",
            section: "GENERALE",
            keysLabel: "Z",
            description: "Riporta zoom Viewer su 'Adatta'",
            primaryKeyIds: ["key-z"]
        ),
        KeyboardShortcutBinding(
            id: "cmd_a",
            section: "GENERALE",
            keysLabel: "⌘ A",
            description: "Seleziona tutto nella sezione attiva",
            primaryKeyIds: ["key-a"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "cmd_w",
            section: "GENERALE",
            keysLabel: "⌘ W",
            description: "Chiudi finestra",
            primaryKeyIds: ["key-w"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "cmd_q",
            section: "GENERALE",
            keysLabel: "⌘ Q",
            description: "Esci da Vision",
            primaryKeyIds: ["key-q"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "cmd_h",
            section: "GENERALE",
            keysLabel: "⌘ H",
            description: "Nascondi Vision",
            primaryKeyIds: ["key-h"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "cmd_m",
            section: "GENERALE",
            keysLabel: "⌘ M",
            description: "Contrai finestra",
            primaryKeyIds: ["key-m"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "cmd_x_cut",
            section: "GENERALE",
            keysLabel: "⌘ X / ⌃ X",
            description: "Taglia clip selezionate",
            primaryKeyIds: ["key-x"],
            modifiers: [.command, .control]
        ),
        KeyboardShortcutBinding(
            id: "cmd_c_copy",
            section: "GENERALE",
            keysLabel: "⌘ C / ⌃ C",
            description: "Copia clip selezionate",
            primaryKeyIds: ["key-c"],
            modifiers: [.command, .control]
        ),
        KeyboardShortcutBinding(
            id: "cmd_v_paste",
            section: "GENERALE",
            keysLabel: "⌘ V / ⌃ V",
            description: "Incolla clip alla testina",
            primaryKeyIds: ["key-v"],
            modifiers: [.command, .control]
        ),

        // RIPRODUZIONE
        KeyboardShortcutBinding(
            id: "space",
            section: "RIPRODUZIONE",
            keysLabel: "Spazio",
            description: "Play / Pausa",
            primaryKeyIds: ["key-space"]
        ),
        KeyboardShortcutBinding(
            id: "arrow_left",
            section: "RIPRODUZIONE",
            keysLabel: "←",
            description: "Passo indietro di 1 frame",
            primaryKeyIds: ["key-arrow-left"]
        ),
        KeyboardShortcutBinding(
            id: "arrow_right",
            section: "RIPRODUZIONE",
            keysLabel: "→",
            description: "Passo avanti di 1 frame",
            primaryKeyIds: ["key-arrow-right"]
        ),

        // MONTAGGIO & SELEZIONE (TIMELINE)
        KeyboardShortcutBinding(
            id: "q_trim_start",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "Q",
            description: "Trim inizio clip alla testina (Ripple)",
            primaryKeyIds: ["key-q"]
        ),
        KeyboardShortcutBinding(
            id: "w_trim_end",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "W",
            description: "Trim fine clip alla testina (Ripple)",
            primaryKeyIds: ["key-w"]
        ),
        KeyboardShortcutBinding(
            id: "s_blade",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "S",
            description: "Spezza clip alla testina (Blade)",
            primaryKeyIds: ["key-s"]
        ),
        KeyboardShortcutBinding(
            id: "b_blade",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "B",
            description: "Spezza clip alla testina (Blade)",
            primaryKeyIds: ["key-b"]
        ),
        KeyboardShortcutBinding(
            id: "prio_1",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "1",
            description: "Assegna priorità clip: 1 Hero",
            primaryKeyIds: ["key-1", "key-numpad-1"]
        ),
        KeyboardShortcutBinding(
            id: "prio_2",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "2",
            description: "Assegna priorità clip: 2 Buona",
            primaryKeyIds: ["key-2", "key-numpad-2"]
        ),
        KeyboardShortcutBinding(
            id: "prio_3",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "3",
            description: "Assegna priorità clip: 3 Filler",
            primaryKeyIds: ["key-3", "key-numpad-3"]
        ),
        KeyboardShortcutBinding(
            id: "prio_0",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "0",
            description: "Rimuovi priorità dalla clip",
            primaryKeyIds: ["key-0", "key-numpad-0"]
        ),
        KeyboardShortcutBinding(
            id: "m_marker",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "M",
            description: "Aggiungi / rimuovi marcatore (o sbarra su traccia audio)",
            primaryKeyIds: ["key-m"]
        ),
        KeyboardShortcutBinding(
            id: "opt_m_clear",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "⌥ M",
            description: "Pulisci tutti i marcatori sulla clip",
            primaryKeyIds: ["key-m"],
            modifiers: [.option]
        ),
        KeyboardShortcutBinding(
            id: "opt_cmd_w_gaps",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "⌥ ⌘ W",
            description: "Chiudi spazi (Close Gaps) tra clip selezionate",
            primaryKeyIds: ["key-w"],
            modifiers: [.option, .command]
        ),
        KeyboardShortcutBinding(
            id: "n_magnet",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "N",
            description: "Attiva / disattiva Magnet (Snapping)",
            primaryKeyIds: ["key-n"]
        ),
        KeyboardShortcutBinding(
            id: "l_lock",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "L",
            description: "Blocca / sblocca clip (protetta in Auto-Fill)",
            primaryKeyIds: ["key-l"]
        ),
        KeyboardShortcutBinding(
            id: "cmd_l_link",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "⌘ L",
            description: "Attiva / disattiva Link Audio/Video",
            primaryKeyIds: ["key-l"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "opt_l_link",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "⌥ L",
            description: "Attiva / disattiva Link Audio/Video",
            primaryKeyIds: ["key-l"],
            modifiers: [.option]
        ),
        KeyboardShortcutBinding(
            id: "opt_p_playhead_sel",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "⌥ P",
            description: "Attiva / disattiva Seleziona sotto testina",
            primaryKeyIds: ["key-p"],
            modifiers: [.option]
        ),
        KeyboardShortcutBinding(
            id: "opt_up",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "⌥ ↑",
            description: "Sposta clip su traccia video/audio superiore",
            primaryKeyIds: ["key-arrow-up"],
            modifiers: [.option]
        ),
        KeyboardShortcutBinding(
            id: "opt_down",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "⌥ ↓",
            description: "Sposta clip su traccia video/audio inferiore",
            primaryKeyIds: ["key-arrow-down"],
            modifiers: [.option]
        ),
        KeyboardShortcutBinding(
            id: "backspace_del",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "⌫ / ⌦",
            description: "Elimina clip (o Ripple Delete in Selezione / su gabbie) / Elimina marcatore",
            primaryKeyIds: ["key-backspace", "key-forward-delete"]
        ),
        KeyboardShortcutBinding(
            id: "e_selection_del",
            section: "MONTAGGIO & SELEZIONE (TIMELINE)",
            keysLabel: "E",
            description: "In Selezione / Modalità Gabbie: Elimina clip con scarto (= Backspace)",
            primaryKeyIds: ["key-e"]
        ),

        // GABBIE RITMATE
        KeyboardShortcutBinding(
            id: "r_slowmo",
            section: "GABBIE RITMATE",
            keysLabel: "R",
            description: "Alterna Slow-Mo 50% / 100% restando nella gabbia",
            primaryKeyIds: ["key-r"]
        ),
        KeyboardShortcutBinding(
            id: "cmd_r_slowmo_span",
            section: "GABBIE RITMATE",
            keysLabel: "⌘ R",
            description: "Slow-Mo 50% su 2 gabbie (o riduce a 1 gabbia) con Ripple",
            primaryKeyIds: ["key-r"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "tab_slip_bar",
            section: "GABBIE RITMATE",
            keysLabel: "Tab + Drag",
            description: "Tieni premuto Tab e trascina sulla clip per scegliere il frammento nella barra flottante",
            primaryKeyIds: ["key-tab"]
        ),
        KeyboardShortcutBinding(
            id: "opt_s_slowmo",
            section: "GABBIE RITMATE",
            keysLabel: "⌥ S",
            description: "Alterna Slow Motion 50%",
            primaryKeyIds: ["key-s"],
            modifiers: [.option]
        ),
        KeyboardShortcutBinding(
            id: "opt_plus_span",
            section: "GABBIE RITMATE",
            keysLabel: "⌥ +",
            description: "Espandi span gabbia (1x / 2x / 3x)",
            primaryKeyIds: ["key-plus", "key-numpad-plus"],
            modifiers: [.option]
        ),
        KeyboardShortcutBinding(
            id: "opt_minus_span",
            section: "GABBIE RITMATE",
            keysLabel: "⌥ −",
            description: "Riduci span gabbia (3x / 2x / 1x)",
            primaryKeyIds: ["key-minus", "key-numpad-minus"],
            modifiers: [.option]
        ),
        KeyboardShortcutBinding(
            id: "opt_left_slip",
            section: "GABBIE RITMATE",
            keysLabel: "⌥ ←",
            description: "Slip contenuto interno clip (−0.25s)",
            primaryKeyIds: ["key-arrow-left"],
            modifiers: [.option]
        ),
        KeyboardShortcutBinding(
            id: "opt_right_slip",
            section: "GABBIE RITMATE",
            keysLabel: "⌥ →",
            description: "Slip contenuto interno clip (+0.25s)",
            primaryKeyIds: ["key-arrow-right"],
            modifiers: [.option]
        ),
        KeyboardShortcutBinding(
            id: "cmd_left_swap",
            section: "GABBIE RITMATE",
            keysLabel: "⌘ ←",
            description: "Scambia clip con la gabbia precedente",
            primaryKeyIds: ["key-arrow-left"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "cmd_right_swap",
            section: "GABBIE RITMATE",
            keysLabel: "⌘ →",
            description: "Scambia clip con la gabbia successiva",
            primaryKeyIds: ["key-arrow-right"],
            modifiers: [.command]
        ),
        KeyboardShortcutBinding(
            id: "cmd_shift_left_select",
            section: "GABBIE RITMATE",
            keysLabel: "⇧ ⌘ ←",
            description: "Seleziona clip precedente",
            primaryKeyIds: ["key-arrow-left"],
            modifiers: [.command, .shift]
        ),
        KeyboardShortcutBinding(
            id: "cmd_shift_right_select",
            section: "GABBIE RITMATE",
            keysLabel: "⇧ ⌘ →",
            description: "Seleziona clip successiva",
            primaryKeyIds: ["key-arrow-right"],
            modifiers: [.command, .shift]
        )
    ]

    public static func bindings(for keyId: String, modifierFilter: KeyboardModifierFilter = .all) -> [KeyboardShortcutBinding] {
        bindings.filter { $0.primaryKeyIds.contains(keyId) && $0.matches(modifierFilter: modifierFilter) }
    }

    public static func modifierRole(for keyId: String) -> KeyboardModifierFilter? {
        switch keyId {
        case "key-cmd-left", "key-cmd-right", "key-win-left", "key-win-right":
            return .command
        case "key-opt-left", "key-opt-right", "key-alt-left", "key-altgr":
            return .option
        case "key-ctrl-left", "key-ctrl-right":
            return .control
        case "key-shift-left", "key-shift-right":
            return .shift
        default:
            return nil
        }
    }

    public static func displayName(for keyId: String) -> String {
        switch keyId {
        case "key-esc": return "Esc (⎋)"
        case "key-backspace": return "Delete / Backspace (⌫)"
        case "key-forward-delete", "key-nav-1-0": return "Canc / Forward Delete (⌦)"
        case "key-tab": return "Tab (⇥)"
        case "key-caps-lock": return "Bloc Maiusc (⇪)"
        case "key-enter-main": return "Invio / Return (↩)"
        case "key-shift-left", "key-shift-right": return "Shift (⇧)"
        case "key-ctrl-left", "key-ctrl-right": return "Control (⌃)"
        case "key-opt-left", "key-opt-right", "key-alt-left", "key-altgr": return "Option (⌥)"
        case "key-cmd-left", "key-cmd-right", "key-win-left", "key-win-right": return "Command (⌘)"
        case "key-space": return "Spazio"
        case "key-fn": return "Fn"
        case "key-home", "key-nav-0-1": return "Home (↖)"
        case "key-end", "key-nav-1-1": return "Fine (↘)"
        case "key-page-up", "key-nav-0-2": return "Pagina Su (⇞)"
        case "key-page-down", "key-nav-1-2": return "Pagina Giù (⇟)"
        case "key-nav-ins", "key-nav-0-0": return "Ins"
        case "key-arrow-up": return "Freccia Su (↑)"
        case "key-arrow-down": return "Freccia Giù (↓)"
        case "key-arrow-left": return "Freccia Sinistra (←)"
        case "key-arrow-right": return "Freccia Destra (→)"
        case "key-plus": return "+"
        case "key-minus": return "-"
        case "key-comma": return ", ;"
        case "key-period": return ". :"
        case "key-backslash": return "\\ |"
        case "key-apostrophe": return "' ?"
        case "key-i-grave": return "ì ^"
        case "key-e-grave", "key-è": return "è é"
        case "key-o-grave", "key-ò": return "ò ç"
        case "key-a-grave", "key-à": return "à °"
        case "key-u-grave", "key-ù": return "ù §"
        case "key-iso-extra": return "< >"
        case "key-numpad-clear": return "Clear Numpad (⌧)"
        case "key-numpad-div": return "/ Numpad"
        case "key-numpad-mul": return "* Numpad"
        case "key-numpad-minus": return "− Numpad"
        case "key-numpad-plus": return "+ Numpad"
        case "key-numpad-enter": return "Invio Numpad (⌤)"
        case "key-numpad-decimal": return ", Numpad"
        default:
            if keyId.hasPrefix("key-numpad-") {
                return "\(keyId.replacingOccurrences(of: "key-numpad-", with: "").uppercased()) Numpad"
            }
            if keyId.hasPrefix("key-") {
                return keyId.replacingOccurrences(of: "key-", with: "").uppercased()
            }
            return keyId
        }
    }

    public static func keyId(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 53: return "key-esc"
        case 51: return "key-backspace"
        case 117: return "key-forward-delete"
        case 48: return "key-tab"
        case 36: return "key-enter-main"
        case 76: return "key-numpad-enter"
        case 49: return "key-space"
        case 123: return "key-arrow-left"
        case 124: return "key-arrow-right"
        case 125: return "key-arrow-down"
        case 126: return "key-arrow-up"
        case 115: return "key-home"
        case 119: return "key-end"
        case 116: return "key-page-up"
        case 121: return "key-page-down"
        case 82: return "key-numpad-0"
        case 83: return "key-numpad-1"
        case 84: return "key-numpad-2"
        case 85: return "key-numpad-3"
        case 86: return "key-numpad-4"
        case 87: return "key-numpad-5"
        case 88: return "key-numpad-6"
        case 89: return "key-numpad-7"
        case 91: return "key-numpad-8"
        case 92: return "key-numpad-9"
        case 69: return "key-numpad-plus"
        case 78: return "key-numpad-minus"
        case 67: return "key-numpad-mul"
        case 75: return "key-numpad-div"
        case 65: return "key-numpad-decimal"
        case 71: return "key-numpad-clear"
        case 122: return "key-f1"
        case 120: return "key-f2"
        case 99: return "key-f3"
        case 118: return "key-f4"
        case 96: return "key-f5"
        case 97: return "key-f6"
        case 98: return "key-f7"
        case 100: return "key-f8"
        case 101: return "key-f9"
        case 109: return "key-f10"
        case 103: return "key-f11"
        case 111: return "key-f12"
        default: break
        }

        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch ch {
        case "a": return "key-a"
        case "b": return "key-b"
        case "c": return "key-c"
        case "d": return "key-d"
        case "e": return "key-e"
        case "f": return "key-f"
        case "g": return "key-g"
        case "h": return "key-h"
        case "i": return "key-i"
        case "j": return "key-j"
        case "k": return "key-k"
        case "l": return "key-l"
        case "m": return "key-m"
        case "n": return "key-n"
        case "o": return "key-o"
        case "p": return "key-p"
        case "q": return "key-q"
        case "r": return "key-r"
        case "s": return "key-s"
        case "t": return "key-t"
        case "u": return "key-u"
        case "v": return "key-v"
        case "w": return "key-w"
        case "x": return "key-x"
        case "y": return "key-y"
        case "z": return "key-z"
        case "0": return "key-0"
        case "1": return "key-1"
        case "2": return "key-2"
        case "3": return "key-3"
        case "4": return "key-4"
        case "5": return "key-5"
        case "6": return "key-6"
        case "7": return "key-7"
        case "8": return "key-8"
        case "9": return "key-9"
        case "+": return "key-plus"
        case "-", "−": return "key-minus"
        case ",": return "key-comma"
        case ".": return "key-period"
        case "\\": return "key-backslash"
        case "'": return "key-apostrophe"
        case "ì": return "key-i-grave"
        case "è": return "key-e-grave"
        case "ò": return "key-o-grave"
        case "à": return "key-a-grave"
        case "ù": return "key-u-grave"
        case "<": return "key-iso-extra"
        default: return nil
        }
    }
}

// MARK: - SVG Keyboard Parser

private struct SVGTextElement {
    let text: String
    let position: CGPoint
    let fontSize: CGFloat
    let isBold: Bool
    let fill: NSColor
    let anchorCentered: Bool
}

private struct SVGKeyElement {
    let id: String
    let path: CGPath
    let bounds: CGRect
    let fill: NSColor
    let stroke: NSColor
    let strokeWidth: CGFloat
    let texts: [SVGTextElement]
}

private struct SVGDocument {
    let viewBox: CGRect
    let chassis: SVGKeyElement?
    let trays: [SVGKeyElement]
    let keys: [SVGKeyElement]
}

private final class SVGKeyboardParser: NSObject, XMLParserDelegate {
    private var viewBox = CGRect(x: 0, y: 0, width: 1644, height: 474)
    private var chassis: SVGKeyElement?
    private var trays: [SVGKeyElement] = []
    private var keys: [SVGKeyElement] = []

    private var transformStack: [CGAffineTransform] = [.identity]
    private var currentKeyId: String?
    private var currentKeyGroupDepth: Int = 0
    private var groupDepth: Int = 0

    private var currentPath: CGPath?
    private var currentFill: NSColor = NSColor(calibratedWhite: 0.15, alpha: 1.0)
    private var currentStroke: NSColor = NSColor(calibratedWhite: 0.24, alpha: 1.0)
    private var currentStrokeWidth: CGFloat = 1.5
    private var currentTexts: [SVGTextElement] = []

    private var activeText: (
        pos: CGPoint,
        fontSize: CGFloat,
        isBold: Bool,
        fill: NSColor,
        centered: Bool,
        buffer: String
    )?

    static func parseBundledKeyboardSVG() -> SVGDocument? {
        guard let url = resolveKeyboardSVGURL(),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parse(data: data)
    }

    static func resolveKeyboardSVGURL() -> URL? {
        if let resURL = Bundle.main.url(forResource: "keyboard", withExtension: "svg") {
            return resURL
        }
        let fm = FileManager.default
        let candidates = [
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/keyboard.svg"),
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("keyboard.svg"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/keyboard.svg")
        ]
        return candidates.first { fm.fileExists(atPath: $0.path) }
    }

    static func parse(data: Data) -> SVGDocument? {
        let handler = SVGKeyboardParser()
        let xml = XMLParser(data: data)
        xml.delegate = handler
        guard xml.parse(), !handler.keys.isEmpty else { return nil }
        return SVGDocument(viewBox: handler.viewBox, chassis: handler.chassis, trays: handler.trays, keys: handler.keys)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let localTransform = Self.parseTransform(attributeDict["transform"])
        let parentTransform = transformStack.last ?? .identity
        transformStack.append(localTransform.concatenating(parentTransform))

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
            if currentKeyId == nil, let gid = attributeDict["id"], gid.hasPrefix("key-") {
                currentKeyId = gid
                currentKeyGroupDepth = groupDepth
                currentPath = nil
                currentTexts = []
            }

        case "rect":
            let x = CGFloat(Double(attributeDict["x"] ?? "0") ?? 0)
            let y = CGFloat(Double(attributeDict["y"] ?? "0") ?? 0)
            let w = CGFloat(Double(attributeDict["width"] ?? "0") ?? 0)
            let h = CGFloat(Double(attributeDict["height"] ?? "0") ?? 0)
            let rx = CGFloat(Double(attributeDict["rx"] ?? attributeDict["ry"] ?? "0") ?? 0)
            let ry = CGFloat(Double(attributeDict["ry"] ?? attributeDict["rx"] ?? "0") ?? 0)
            var t = transformStack.last ?? .identity
            let rawPath = CGPath(
                roundedRect: CGRect(x: x, y: y, width: w, height: h),
                cornerWidth: min(rx, w / 2),
                cornerHeight: min(ry, h / 2),
                transform: &t
            )
            let styles = Self.parseStyles(attributes: attributeDict)
            if attributeDict["id"] == "keyboard-chassis" {
                chassis = SVGKeyElement(
                    id: "keyboard-chassis",
                    path: rawPath,
                    bounds: rawPath.boundingBoxOfPath,
                    fill: styles.fill ?? NSColor(calibratedWhite: 0.075, alpha: 1.0),
                    stroke: styles.stroke ?? NSColor(calibratedWhite: 0.16, alpha: 1.0),
                    strokeWidth: styles.strokeWidth ?? 1.5,
                    texts: []
                )
            } else if let rid = attributeDict["id"], rid.hasPrefix("tray-") {
                trays.append(SVGKeyElement(
                    id: rid,
                    path: rawPath,
                    bounds: rawPath.boundingBoxOfPath,
                    fill: styles.fill ?? NSColor(calibratedWhite: 0.06, alpha: 1.0),
                    stroke: styles.stroke ?? NSColor(calibratedWhite: 0.16, alpha: 1.0),
                    strokeWidth: styles.strokeWidth ?? 1.5,
                    texts: []
                ))
            } else if currentKeyId != nil && currentPath == nil {
                currentPath = rawPath
                currentFill = styles.fill ?? currentFill
                currentStroke = styles.stroke ?? currentStroke
                currentStrokeWidth = styles.strokeWidth ?? 1.5
            }

        case "path":
            if currentKeyId != nil, currentPath == nil, let d = attributeDict["d"] {
                let raw = Self.parseSVGPath(d)
                var t = transformStack.last ?? .identity
                let transformed = raw.copy(using: &t) ?? raw
                let styles = Self.parseStyles(attributes: attributeDict)
                currentPath = transformed
                currentFill = styles.fill ?? currentFill
                currentStroke = styles.stroke ?? currentStroke
                currentStrokeWidth = styles.strokeWidth ?? 1.5
            }

        case "text":
            if currentKeyId != nil {
                let x = Self.parsePx(attributeDict["x"]) ?? 0
                let y = Self.parsePx(attributeDict["y"]) ?? 0
                let t = transformStack.last ?? .identity
                let pt = CGPoint(x: x, y: y).applying(t)
                let styles = Self.parseStyles(attributes: attributeDict)
                let size = styles.fontSize ?? 16
                let bold = styles.isBold
                let fill = styles.fill ?? NSColor(calibratedWhite: 0.9, alpha: 1.0)
                let centered = (attributeDict["text-anchor"] == "middle") || abs(x) > 0.5
                activeText = (pt, size, bold, fill, centered, "")
            }

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if activeText != nil {
            activeText?.buffer.append(string)
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
            if let t = activeText {
                let textStr = t.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !textStr.isEmpty {
                    currentTexts.append(SVGTextElement(
                        text: textStr,
                        position: t.pos,
                        fontSize: t.fontSize,
                        isBold: t.isBold,
                        fill: t.fill,
                        anchorCentered: t.centered
                    ))
                }
                activeText = nil
            }

        case "g":
            if let keyId = currentKeyId, groupDepth == currentKeyGroupDepth {
                if let path = currentPath {
                    keys.append(SVGKeyElement(
                        id: keyId,
                        path: path,
                        bounds: path.boundingBoxOfPath,
                        fill: currentFill,
                        stroke: currentStroke,
                        strokeWidth: currentStrokeWidth,
                        texts: currentTexts
                    ))
                }
                currentKeyId = nil
                currentKeyGroupDepth = 0
                currentPath = nil
                currentTexts = []
            }
            groupDepth -= 1

        default:
            break
        }

        if transformStack.count > 1 {
            transformStack.removeLast()
        }
    }

    // MARK: Parsing Helpers

    private static func parsePx(_ str: String?) -> CGFloat? {
        guard var s = str?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if s.hasSuffix("px") { s.removeLast(2) }
        guard let v = Double(s) else { return nil }
        return CGFloat(v)
    }

    private static func parseNumbers(_ raw: String) -> [CGFloat] {
        let separators = CharacterSet(charactersIn: ", \t\r\n")
        return raw.components(separatedBy: separators).compactMap { tok -> CGFloat? in
            let s = tok.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty, let v = Double(s) else { return nil }
            return CGFloat(v)
        }
    }

    private static func parseTransform(_ raw: String?) -> CGAffineTransform {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .identity
        }
        var result = CGAffineTransform.identity
        if let mStart = raw.range(of: "matrix("), let end = raw[mStart.upperBound...].firstIndex(of: ")") {
            let nums = parseNumbers(String(raw[mStart.upperBound..<end]))
            if nums.count == 6 {
                result = result.concatenating(
                    CGAffineTransform(a: nums[0], b: nums[1], c: nums[2], d: nums[3], tx: nums[4], ty: nums[5])
                )
            }
        }
        if let tStart = raw.range(of: "translate("), let end = raw[tStart.upperBound...].firstIndex(of: ")") {
            let nums = parseNumbers(String(raw[tStart.upperBound..<end]))
            if nums.count >= 1 {
                result = result.concatenating(
                    CGAffineTransform(translationX: nums[0], y: nums.count > 1 ? nums[1] : 0)
                )
            }
        }
        return result
    }

    private struct StyleValues {
        var fill: NSColor?
        var stroke: NSColor?
        var strokeWidth: CGFloat?
        var fontSize: CGFloat?
        var isBold: Bool = false
    }

    private static func parseStyles(attributes: [String: String]) -> StyleValues {
        var out = StyleValues()
        if let styleStr = attributes["style"] {
            for pair in styleStr.split(separator: ";") {
                let kv = pair.split(separator: ":", maxSplits: 1)
                guard kv.count == 2 else { continue }
                let k = kv[0].trimmingCharacters(in: .whitespaces)
                let v = kv[1].trimmingCharacters(in: .whitespaces)
                applyStyle(key: k, value: v, to: &out)
            }
        }
        for key in ["fill", "stroke", "stroke-width", "font-size", "font-weight"] {
            if let v = attributes[key] {
                applyStyle(key: key, value: v, to: &out)
            }
        }
        return out
    }

    private static func applyStyle(key: String, value: String, to out: inout StyleValues) {
        switch key {
        case "fill":
            if let c = parseColor(value) { out.fill = c }
        case "stroke":
            if let c = parseColor(value) { out.stroke = c }
        case "stroke-width":
            if let w = parsePx(value) { out.strokeWidth = w }
        case "font-size":
            if let f = parsePx(value) { out.fontSize = f }
        case "font-weight":
            out.isBold = (value.lowercased() == "bold" || value == "600" || value == "700")
        default:
            break
        }
    }

    private static func parseColor(_ raw: String) -> NSColor? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s == "none" { return nil }
        if s == "white" { return .white }
        if s.hasPrefix("#") {
            let hex = String(s.dropFirst())
            guard hex.count == 6, let val = UInt32(hex, radix: 16) else { return nil }
            let r = CGFloat((val >> 16) & 0xFF) / 255.0
            let g = CGFloat((val >> 8) & 0xFF) / 255.0
            let b = CGFloat(val & 0xFF) / 255.0
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
        }
        if s.hasPrefix("rgb("), s.hasSuffix(")") {
            let inner = String(s.dropFirst(4).dropLast())
            let nums = parseNumbers(inner)
            if nums.count == 3 {
                return NSColor(srgbRed: nums[0] / 255.0, green: nums[1] / 255.0, blue: nums[2] / 255.0, alpha: 1.0)
            }
        }
        return nil
    }

    private static func parseSVGPath(_ d: String) -> CGPath {
        let path = CGMutablePath()
        var tokens: [String] = []
        var buf = ""
        let chars = Array(d)
        var idx = 0
        while idx < chars.count {
            let ch = chars[idx]
            if ch.isLetter && ch != "e" && ch != "E" {
                if !buf.isEmpty { tokens.append(buf); buf = "" }
                tokens.append(String(ch))
            } else if ch == "," || ch.isWhitespace {
                if !buf.isEmpty { tokens.append(buf); buf = "" }
            } else if ch == "-" && !buf.isEmpty && buf.last != "e" && buf.last != "E" {
                tokens.append(buf)
                buf = "-"
            } else {
                buf.append(ch)
            }
            idx += 1
        }
        if !buf.isEmpty { tokens.append(buf) }

        var tIdx = 0
        var cmd: Character = "M"
        var cur = CGPoint.zero

        func nextFloat() -> CGFloat? {
            guard tIdx < tokens.count, let v = Double(tokens[tIdx]) else { return nil }
            tIdx += 1
            return CGFloat(v)
        }

        while tIdx < tokens.count {
            let tok = tokens[tIdx]
            if tok.count == 1, let first = tok.first, first.isLetter {
                cmd = first
                tIdx += 1
                if cmd == "Z" || cmd == "z" {
                    path.closeSubpath()
                    continue
                }
            }

            switch cmd {
            case "M":
                if let x = nextFloat(), let y = nextFloat() {
                    cur = CGPoint(x: x, y: y)
                    path.move(to: cur)
                    cmd = "L"
                } else { tIdx += 1 }
            case "m":
                if let dx = nextFloat(), let dy = nextFloat() {
                    cur = CGPoint(x: cur.x + dx, y: cur.y + dy)
                    path.move(to: cur)
                    cmd = "l"
                } else { tIdx += 1 }
            case "L":
                if let x = nextFloat(), let y = nextFloat() {
                    cur = CGPoint(x: x, y: y)
                    path.addLine(to: cur)
                } else { tIdx += 1 }
            case "l":
                if let dx = nextFloat(), let dy = nextFloat() {
                    cur = CGPoint(x: cur.x + dx, y: cur.y + dy)
                    path.addLine(to: cur)
                } else { tIdx += 1 }
            case "H":
                if let x = nextFloat() {
                    cur = CGPoint(x: x, y: cur.y)
                    path.addLine(to: cur)
                } else { tIdx += 1 }
            case "h":
                if let dx = nextFloat() {
                    cur = CGPoint(x: cur.x + dx, y: cur.y)
                    path.addLine(to: cur)
                } else { tIdx += 1 }
            case "V":
                if let y = nextFloat() {
                    cur = CGPoint(x: cur.x, y: y)
                    path.addLine(to: cur)
                } else { tIdx += 1 }
            case "v":
                if let dy = nextFloat() {
                    cur = CGPoint(x: cur.x, y: cur.y + dy)
                    path.addLine(to: cur)
                } else { tIdx += 1 }
            case "Q":
                if let cx = nextFloat(), let cy = nextFloat(), let x = nextFloat(), let y = nextFloat() {
                    cur = CGPoint(x: x, y: y)
                    path.addQuadCurve(to: cur, control: CGPoint(x: cx, y: cy))
                } else { tIdx += 1 }
            case "q":
                if let dcx = nextFloat(), let dcy = nextFloat(), let dx = nextFloat(), let dy = nextFloat() {
                    let cp = CGPoint(x: cur.x + dcx, y: cur.y + dcy)
                    cur = CGPoint(x: cur.x + dx, y: cur.y + dy)
                    path.addQuadCurve(to: cur, control: cp)
                } else { tIdx += 1 }
            case "C":
                if let c1x = nextFloat(), let c1y = nextFloat(),
                   let c2x = nextFloat(), let c2y = nextFloat(),
                   let x = nextFloat(), let y = nextFloat() {
                    cur = CGPoint(x: x, y: y)
                    path.addCurve(to: cur, control1: CGPoint(x: c1x, y: c1y), control2: CGPoint(x: c2x, y: c2y))
                } else { tIdx += 1 }
            case "c":
                if let dc1x = nextFloat(), let dc1y = nextFloat(),
                   let dc2x = nextFloat(), let dc2y = nextFloat(),
                   let dx = nextFloat(), let dy = nextFloat() {
                    let c1 = CGPoint(x: cur.x + dc1x, y: cur.y + dc1y)
                    let c2 = CGPoint(x: cur.x + dc2x, y: cur.y + dc2y)
                    cur = CGPoint(x: cur.x + dx, y: cur.y + dy)
                    path.addCurve(to: cur, control1: c1, control2: c2)
                } else { tIdx += 1 }
            default:
                tIdx += 1
            }
        }
        return path
    }
}

// MARK: - Interactive Vector Keyboard View

/// Vista vettoriale nativa basata su `keyboard.svg` con hover, selezione tasti, evidenziazione shortcut e modificatori live.
public final class InteractiveKeyboardView: NSView {
    private let document: SVGDocument?

    public var selectedKeyId: String? {
        didSet { needsDisplay = true }
    }
    public var modifierFilter: KeyboardModifierFilter = .all {
        didSet { needsDisplay = true }
    }
    public var searchQuery: String = "" {
        didSet { needsDisplay = true }
    }
    public var physicalPressedFlags: NSEvent.ModifierFlags = [] {
        didSet { needsDisplay = true }
    }
    public var physicalPressedKeyId: String? {
        didSet { needsDisplay = true }
    }

    /// Invocato quando l'utente clicca un tasto o un modificatore sul diagramma.
    public var onKeyClicked: ((String) -> Void)?
    public var onModifierFilterToggled: ((KeyboardModifierFilter) -> Void)?

    private var hoveredKeyId: String? {
        didSet {
            if oldValue != hoveredKeyId {
                needsDisplay = true
                updateTooltipAndCursor()
            }
        }
    }
    private var trackingAreaRef: NSTrackingArea?

    public override var isFlipped: Bool { true }

    public var svgAspectRatio: CGFloat {
        guard let vb = document?.viewBox, vb.height > 0 else { return 1644.0 / 474.0 }
        return vb.width / vb.height
    }

    public var hasLoadedSVG: Bool {
        guard let doc = document else { return false }
        return !doc.keys.isEmpty
    }

    public var parsedKeyCount: Int {
        document?.keys.count ?? 0
    }

    public func containsKey(id: String) -> Bool {
        document?.keys.contains(where: { $0.id == id }) ?? false
    }

    public init() {
        self.document = SVGKeyboardParser.parseBundledKeyboardSVG()
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
        let vb = document?.viewBox ?? CGRect(x: 0, y: 0, width: 1644, height: 474)
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

    private func hitKeyId(at viewPoint: CGPoint) -> String? {
        guard let doc = document else { return nil }
        let (svgToView, _) = computeSVGTransform()
        let svgPt = viewPoint.applying(svgToView.inverted())
        for key in doc.keys.reversed() {
            if key.path.contains(svgPt) {
                return key.id
            }
        }
        return nil
    }

    private func updateTooltipAndCursor() {
        guard let keyId = hoveredKeyId else {
            toolTip = nil
            NSCursor.arrow.set()
            return
        }
        NSCursor.pointingHand.set()
        let keyName = KeyboardShortcutCatalog.displayName(for: keyId)
        if let modRole = KeyboardShortcutCatalog.modifierRole(for: keyId) {
            toolTip = "\(keyName) — Clicca per filtrare le scorciatoie \(modRole.rawValue)"
            return
        }
        let keyBindings = KeyboardShortcutCatalog.bindings(for: keyId, modifierFilter: .all)
        if keyBindings.isEmpty {
            toolTip = "\(keyName) — Nessuna scorciatoia assegnata"
        } else {
            let summary = keyBindings.map { "\($0.keysLabel): \($0.description)" }.joined(separator: "\n")
            toolTip = "\(keyName)\n\(summary)"
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        hoveredKeyId = hitKeyId(at: pt)
    }

    public override func mouseExited(with event: NSEvent) {
        hoveredKeyId = nil
    }

    public override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard let keyId = hitKeyId(at: pt) else { return }
        if let modRole = KeyboardShortcutCatalog.modifierRole(for: keyId) {
            onModifierFilterToggled?(modRole)
        } else {
            onKeyClicked?(keyId)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext, let doc = document else { return }

        let (svgToView, scale) = computeSVGTransform()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Chassis + recessed trays
        if let chassis = doc.chassis {
            var t = svgToView
            if let path = chassis.path.copy(using: &t) {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setFillColor(chassis.fill.cgColor)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(chassis.stroke.cgColor)
                ctx.setLineWidth(max(1.0, chassis.strokeWidth * scale))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
        for tray in doc.trays {
            var t = svgToView
            if let path = tray.path.copy(using: &t) {
                ctx.saveGState()
                ctx.addPath(path)
                ctx.setFillColor(tray.fill.cgColor)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(tray.stroke.cgColor)
                ctx.setLineWidth(max(1.0, tray.strokeWidth * scale))
                ctx.strokePath()
                ctx.restoreGState()
            }
        }

        for key in doc.keys {
            drawKey(key, in: ctx, transform: svgToView, scale: scale, query: query)
        }
    }

    private func isPhysicalModifierActive(for keyId: String) -> Bool {
        guard let role = KeyboardShortcutCatalog.modifierRole(for: keyId),
              let mask = role.modifierMask else { return false }
        return physicalPressedFlags.contains(mask)
    }

    private func drawKey(
        _ key: SVGKeyElement,
        in ctx: CGContext,
        transform: CGAffineTransform,
        scale: CGFloat,
        query: String
    ) {
        var t = transform
        guard let viewPath = key.path.copy(using: &t) else { return }

        let allBindings = KeyboardShortcutCatalog.bindings(for: key.id, modifierFilter: .all)
        let filteredBindings = KeyboardShortcutCatalog.bindings(for: key.id, modifierFilter: modifierFilter)
        let hasQuery = !query.isEmpty
        let matchingSearchBindings = hasQuery ? allBindings.filter { $0.matches(query: query) } : filteredBindings

        let isSelected = (selectedKeyId == key.id)
        let isHovered = (hoveredKeyId == key.id)
        let isPhysical = (physicalPressedKeyId == key.id) || isPhysicalModifierActive(for: key.id)
        let modRole = KeyboardShortcutCatalog.modifierRole(for: key.id)
        let isActiveModFilter = (modRole != nil && modRole == modifierFilter)

        let hasDirectShortcut = filteredBindings.contains { $0.modifiers.isEmpty }
        let hasModifierShortcut = filteredBindings.contains { !$0.modifiers.isEmpty }
        let hasAnyRelevant = !matchingSearchBindings.isEmpty

        var fillColor = key.fill
        var strokeColor = key.stroke
        var strokeWidth = max(1.0, key.strokeWidth * scale)
        var opacity: CGFloat = 1.0

        if hasQuery && !hasAnyRelevant && !isSelected && !isPhysical {
            opacity = 0.42
        } else if modifierFilter != .all && !hasAnyRelevant && !isActiveModFilter && !isSelected && !isPhysical {
            opacity = 0.48
        }

        if isActiveModFilter {
            fillColor = NSColor.systemCyan.withAlphaComponent(0.28)
            strokeColor = NSColor.systemCyan
            strokeWidth = max(1.8, 2.2 * scale)
        } else if isSelected {
            fillColor = NSColor(srgbRed: 0.09, green: 0.29, blue: 0.38, alpha: 1.0)
            strokeColor = NSColor.systemCyan
            strokeWidth = max(2.0, 2.5 * scale)
        } else if isPhysical {
            fillColor = NSColor.systemCyan.withAlphaComponent(0.36)
            strokeColor = NSColor.systemCyan
            strokeWidth = max(1.8, 2.2 * scale)
        } else if hasQuery && hasAnyRelevant {
            fillColor = NSColor(srgbRed: 0.11, green: 0.24, blue: 0.31, alpha: 1.0)
            strokeColor = NSColor.systemCyan
            strokeWidth = max(1.6, 2.0 * scale)
        } else if isHovered {
            fillColor = fillColor.blended(withFraction: 0.14, of: .white) ?? fillColor
            strokeColor = NSColor(calibratedWhite: 0.56, alpha: 1.0)
            strokeWidth = max(1.4, 1.8 * scale)
        } else if hasDirectShortcut {
            fillColor = NSColor(srgbRed: 0.13, green: 0.21, blue: 0.26, alpha: 1.0)
            strokeColor = NSColor(srgbRed: 0.23, green: 0.54, blue: 0.67, alpha: 1.0)
        } else if hasModifierShortcut && modifierFilter != .base {
            fillColor = NSColor(srgbRed: 0.19, green: 0.18, blue: 0.24, alpha: 1.0)
            strokeColor = NSColor(srgbRed: 0.45, green: 0.44, blue: 0.58, alpha: 1.0)
        }

        ctx.saveGState()
        ctx.setAlpha(opacity)

        // Keycap body
        ctx.addPath(viewPath)
        ctx.setFillColor(fillColor.cgColor)
        ctx.fillPath()

        ctx.addPath(viewPath)
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(strokeWidth)
        ctx.strokePath()

        // Texts
        for txt in key.texts {
            let viewPt = txt.position.applying(transform)
            let scaledFontSize = max(5.5, txt.fontSize * scale)
            let font = NSFont.systemFont(ofSize: scaledFontSize, weight: txt.isBold ? .semibold : .medium)
            let color: NSColor = (isSelected || isActiveModFilter || (hasQuery && hasAnyRelevant))
                ? .white
                : txt.fill
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            let attrStr = NSAttributedString(string: txt.text, attributes: attrs)
            let size = attrStr.size()
            let drawPt = NSPoint(
                x: txt.anchorCentered ? (viewPt.x - size.width * 0.5) : viewPt.x,
                y: viewPt.y - size.height * 0.52
            )
            attrStr.draw(at: drawPt)
        }

        // Indicator dot in top-right corner for mapped keys
        if !matchingSearchBindings.isEmpty && modRole == nil {
            let viewRect = key.bounds.applying(transform)
            let dotSize = max(3.5, 5.2 * scale)
            let inset = max(3.0, 5.5 * scale)
            let dotRect = CGRect(
                x: viewRect.maxX - inset - dotSize,
                y: viewRect.minY + inset,
                width: dotSize,
                height: dotSize
            )
            let dotColor: NSColor
            if hasDirectShortcut {
                dotColor = NSColor.systemCyan
            } else {
                dotColor = NSColor.systemOrange
            }
            ctx.setFillColor(dotColor.cgColor)
            ctx.fillEllipse(in: dotRect)
        }

        ctx.restoreGState()
    }
}
