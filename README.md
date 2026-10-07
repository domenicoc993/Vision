# Vision

Vision è un editor video non-lineare (NLE) nativo per macOS, ottimizzato e accelerato per l'architettura Apple Silicon (Metal, AVFoundation, Core Image e VideoToolbox).

## Caratteristiche Principali

- **Architettura Apple Silicon Nativa**: Riproduzione fluida, esportazione accelerata in hardware e elaborazione Metal.
- **Editing Overwrite e Ripple Cut**:
  - Trimming senza scarto (inizio/fine) con ricalcolo immediato dei gap.
  - Spostamento e sostituzione delle clip trascinate sopra altre porzioni temporali.
  - Chiusura rapida degli spazi vuoti (**⌥⌘W**).
  - Divisione clip (**S** / **B**) sulla testina di riproduzione.
- **Timeline e Tracce Multi-Livello**:
  - Tracce Video e Audio indipendenti con mute/disable (**👁️** / **🔇**) e blocco (**🔒**).
  - Tracce audio con waveform visuale reale calcolata da campioni PCM a 16-bit.
  - Calamita / Magnet Snapping (**N**) intelligente su bordi clip, marker e testina.
  - Link/Unlink A/V (**⌘L** / **⌥L**) che sincronizza spostamenti e trimming.
  - Selezione sotto la testina in stile DaVinci Resolve.
- **Media Pool e Storyboard Grid**:
  - Organizzazione in cartelle e timeline multiple con passaggio istantaneo.
  - Visualizzazione a lista con metadati completi o a griglia con miniature generate in locale.
  - Selezione multipla con supporto a drag & drop simultaneo verso timeline e cartelle.
  - Modalità Storyboard Timeline per il riordino rapido sequenziale delle clip.
- **Viewer Integrato e Schermo Intero**:
  - Riproduzione AVPlayer ad alte prestazioni.
  - Modalità Viewer a schermo intero (**⌃F**) con barra di controllo trasparente e comandi dedicati.
  - Supporto motore LUT accelerato in tempo reale via Core Image / Metal.

## Requisiti

- macOS 14.0 (Sonoma) o versioni successive
- Mac con Apple Silicon (M1/M2/M3/M4 o successivi)
- Swift 5.9+ / Xcode Command Line Tools

## Compilazione ed Esecuzione

```bash
# Compilazione
swift build

# Avvio
swift run Vision
```
