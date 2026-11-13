import AppKit
import Foundation
import CoreMedia
import AVFoundation

public final class BeatAnalysisDialog: NSWindowController {
    private let audioClip: TimelineClip
    private var onCagesGenerated: (([RhythmicCage], Double) -> Void)?

    private var analysisResult: BeatAnalysisResult?
    private let statusIndicator = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Avvio analisi energetica audio...")
    private let bpmResultLabel = NSTextField(labelWithString: "")
    private let modePopUp = NSPopUpButton()
    private let cagesPreviewLabel = NSTextField(labelWithString: "")
    private let generateBtn = NSButton()
    private let cancelBtn = NSButton()

    public init(audioClip: TimelineClip, onCagesGenerated: (([RhythmicCage], Double) -> Void)? = nil) {
        self.audioClip = audioClip
        self.onCagesGenerated = onCagesGenerated

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 290),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "🎵 Analizzatore Ritmico & Gabbie Musicali"
        window.center()
        super.init(window: window)

        setupUI()
        startAnalysis()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let window = self.window else { return }
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1.0).cgColor
        window.contentView = contentView

        let titleLabel = NSTextField(labelWithString: "Struttura Ritmica Guidata dalla Musica")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleLabel)

        let trackLabel = NSTextField(labelWithString: "Traccia: \(audioClip.mediaItem.name) (\(String(format: "%.1f", CMTimeGetSeconds(audioClip.duration)))s)")
        trackLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        trackLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1.0)
        trackLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(trackLabel)

        statusIndicator.style = .spinning
        statusIndicator.controlSize = .small
        statusIndicator.translatesAutoresizingMaskIntoConstraints = false
        statusIndicator.startAnimation(nil)
        contentView.addSubview(statusIndicator)

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = NSColor.systemYellow
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        bpmResultLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .bold)
        bpmResultLabel.textColor = NSColor.systemCyan
        bpmResultLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bpmResultLabel)

        let modeLabel = NSTextField(labelWithString: "Ritmo di Taglio:")
        modeLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        modeLabel.textColor = .white
        modeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(modeLabel)

        modePopUp.bezelStyle = .rounded
        modePopUp.translatesAutoresizingMaskIntoConstraints = false
        modePopUp.target = self
        modePopUp.action = #selector(onModeChanged)
        for mode in BeatIntervalMode.allCases {
            modePopUp.addItem(withTitle: mode.rawValue)
        }
        modePopUp.selectItem(at: 1) // Default: 2 battiti
        modePopUp.isEnabled = false
        contentView.addSubview(modePopUp)

        cagesPreviewLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        cagesPreviewLabel.textColor = NSColor(calibratedWhite: 0.75, alpha: 1.0)
        cagesPreviewLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cagesPreviewLabel)

        cancelBtn.title = "Annulla"
        cancelBtn.bezelStyle = .rounded
        cancelBtn.target = self
        cancelBtn.action = #selector(onCancelClicked)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelBtn)

        generateBtn.title = "⚡️ Crea Gabbie Ritmate"
        generateBtn.bezelStyle = .rounded
        generateBtn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        generateBtn.target = self
        generateBtn.action = #selector(onGenerateClicked)
        generateBtn.isEnabled = false
        generateBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(generateBtn)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            trackLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            trackLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            statusIndicator.topAnchor.constraint(equalTo: trackLabel.bottomAnchor, constant: 18),
            statusIndicator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            statusLabel.centerYAnchor.constraint(equalTo: statusIndicator.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusIndicator.trailingAnchor, constant: 8),

            bpmResultLabel.topAnchor.constraint(equalTo: statusIndicator.bottomAnchor, constant: 12),
            bpmResultLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            modeLabel.topAnchor.constraint(equalTo: bpmResultLabel.bottomAnchor, constant: 16),
            modeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            modePopUp.centerYAnchor.constraint(equalTo: modeLabel.centerYAnchor),
            modePopUp.leadingAnchor.constraint(equalTo: modeLabel.trailingAnchor, constant: 12),
            modePopUp.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            cagesPreviewLabel.topAnchor.constraint(equalTo: modePopUp.bottomAnchor, constant: 8),
            cagesPreviewLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            cancelBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            cancelBtn.trailingAnchor.constraint(equalTo: generateBtn.leadingAnchor, constant: -12),
            cancelBtn.widthAnchor.constraint(equalToConstant: 90),

            generateBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            generateBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            generateBtn.widthAnchor.constraint(equalToConstant: 180)
        ])
    }

    private func startAnalysis() {
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let result = try await AudioBeatDetector.shared.analyze(
                    url: self.audioClip.mediaItem.effectiveURL,
                    timeRange: self.audioClip.sourceTimeRange
                )

                DispatchQueue.main.async {
                    self.analysisResult = result
                    self.statusIndicator.stopAnimation(nil)
                    self.statusIndicator.isHidden = true
                    self.statusLabel.stringValue = "Analisi completata con successo!"
                    self.statusLabel.textColor = NSColor.systemGreen

                    self.bpmResultLabel.stringValue = "Tempo: \(result.bpm) BPM  •  \(result.beatTimes.count) battiti  •  \(result.transientTimes.count) accenti"
                    self.modePopUp.isEnabled = true
                    self.generateBtn.isEnabled = true
                    self.updateCagesPreview()
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusIndicator.stopAnimation(nil)
                    self.statusIndicator.isHidden = true
                    self.statusLabel.stringValue = "Errore analisi audio: \(error.localizedDescription)"
                    self.statusLabel.textColor = NSColor.systemRed
                }
            }
        }
    }

    @objc private func onModeChanged() {
        updateCagesPreview()
    }

    private func updateCagesPreview() {
        guard let res = analysisResult else { return }
        let selectedIdx = modePopUp.indexOfSelectedItem
        let mode = BeatIntervalMode.allCases[max(0, min(selectedIdx, BeatIntervalMode.allCases.count - 1))]
        let cages = AudioBeatDetector.shared.generateCages(from: res, mode: mode, startTimeOffset: audioClip.timelineStart)
        cagesPreviewLabel.stringValue = "Verranno generate \(cages.count) gabbie di montaggio sulla timeline (durata media ~\(String(format: "%.2f", CMTimeGetSeconds(res.duration) / Double(max(1, cages.count))))s)."
    }

    @objc private func onGenerateClicked() {
        guard let res = analysisResult else { return }
        let selectedIdx = modePopUp.indexOfSelectedItem
        let mode = BeatIntervalMode.allCases[max(0, min(selectedIdx, BeatIntervalMode.allCases.count - 1))]
        let cages = AudioBeatDetector.shared.generateCages(from: res, mode: mode, startTimeOffset: audioClip.timelineStart)

        onCagesGenerated?(cages, res.bpm)
        self.window?.close()
    }

    @objc private func onCancelClicked() {
        self.window?.close()
    }
}
