#!/usr/bin/env bash
set -euo pipefail

# Vision App Packager Script for macOS
# Domenico Ciavattone - 2026

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

CONFIG="release"
DO_RUN=false
DO_INSTALL=false

for arg in "$@"; do
    case "$arg" in
        --debug|-d)
            CONFIG="debug"
            ;;
        --release)
            CONFIG="release"
            ;;
        --run|-r)
            DO_RUN=true
            ;;
        --install|-i)
            DO_INSTALL=true
            ;;
        --help|-h)
            echo "Uso: ./build_app.sh [OPZIONI]"
            echo ""
            echo "Opzioni:"
            echo "  --release        Compila in modalità Release (default, ottimizzata)"
            echo "  --debug, -d      Compila in modalità Debug"
            echo "  --run, -r        Avvia l'app al termine della compilazione"
            echo "  --install, -i    Installa Vision.app nella cartella /Applications"
            echo "  --help, -h       Mostra questo messaggio di aiuto"
            exit 0
            ;;
        *)
            echo "Opzione sconosciuta: $arg"
            echo "Esegui './build_app.sh --help' per la lista delle opzioni."
            exit 1
            ;;
    esac
done

APP_NAME="Vision"
OUTPUT_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"

echo "========================================="
echo "   Creazione Bundle $APP_NAME.app ($CONFIG)"
echo "========================================="

# 1. Compilazione con SwiftPM
echo "==> [1/5] Compilazione Swift ($CONFIG)..."
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
EXECUTABLE="$BIN_DIR/$APP_NAME"

if [[ ! -f "$EXECUTABLE" ]]; then
    echo "ERRORE: Eseguibile non trovato in $EXECUTABLE"
    exit 1
fi

# 2. Creazione della struttura del bundle .app
echo "==> [2/5] Struttura cartelle $APP_NAME.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 3. Copia binario ed asset
echo "==> [3/5] Copia file e risorse..."
cp "$EXECUTABLE" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Info.plist
if [[ -f "$PROJECT_DIR/Resources/Info.plist" ]]; then
    cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
else
    echo "ATTENZIONE: Resources/Info.plist non trovato."
fi

# PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Icona applicazione (.icns)
if [[ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Diagrammi vettoriali Tastiera & Speed Editor (SVG interattivi)
if [[ -f "$PROJECT_DIR/Resources/keyboard.svg" ]]; then
    cp "$PROJECT_DIR/Resources/keyboard.svg" "$APP_BUNDLE/Contents/Resources/keyboard.svg"
fi
if [[ -f "$PROJECT_DIR/Resources/speed_editor.svg" ]]; then
    cp "$PROJECT_DIR/Resources/speed_editor.svg" "$APP_BUNDLE/Contents/Resources/speed_editor.svg"
fi

# Modelli CoreML / risorse ML per Beat Detection
if [[ -d "$PROJECT_DIR/Resources/Models" ]]; then
    echo "    Copia modelli ML in Contents/Resources/Models..."
    cp -R "$PROJECT_DIR/Resources/Models" "$APP_BUNDLE/Contents/Resources/Models"
fi

# Copia eventuali risorse di bundle prodotte da SwiftPM se presenti
for bundle in "$BIN_DIR"/*.bundle; do
    if [[ -d "$bundle" ]]; then
        echo "    Copia bundle di risorse: $(basename "$bundle")"
        cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
    fi
done

# 4. Code Signing (Ad-hoc con Entitlements)
echo "==> [4/5] Firma codice ad-hoc (Gatekeeper friendly)..."
ENTITLEMENTS_FLAG=()
if [[ -f "$PROJECT_DIR/Resources/Vision.entitlements" ]]; then
    ENTITLEMENTS_FLAG=(--entitlements "$PROJECT_DIR/Resources/Vision.entitlements")
fi

codesign --force --deep --sign - "${ENTITLEMENTS_FLAG[@]}" "$APP_BUNDLE"

# Verifica firma
codesign --verify --deep --strict "$APP_BUNDLE"

# Notifica a LaunchServices
touch "$APP_BUNDLE"

# Collega o copia anche alla radice del progetto per facilità d'uso
rm -rf "$PROJECT_DIR/$APP_NAME.app"
cp -R "$APP_BUNDLE" "$PROJECT_DIR/$APP_NAME.app"

# 5. Completamento
echo "==> [5/5] Bundle creato con successo!"
echo "-----------------------------------------"
echo "Percorso applicazione:"
echo "  -> $PROJECT_DIR/$APP_NAME.app"
echo "  -> $APP_BUNDLE"
echo "Dimensione: $(du -sh "$APP_BUNDLE" | cut -f1)"
echo "-----------------------------------------"

if $DO_INSTALL; then
    echo "==> Installazione in /Applications/$APP_NAME.app..."
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
    echo "Vision installato in /Applications!"
fi

if $DO_RUN; then
    echo "==> Avvio di $APP_NAME.app..."
    open "$APP_BUNDLE"
fi
