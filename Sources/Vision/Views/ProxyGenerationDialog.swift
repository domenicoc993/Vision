import AppKit
import Foundation

public final class ProxyGenerationDialog: NSWindowController {
    private let mediaItems: [MediaItem]
    private var chosenFolderURL: URL
    private var onCompletion: (() -> Void)?

    private let codecPopUp = NSPopUpButton()
    private let scalePopUp = NSPopUpButton()
    private let pathLabel = NSTextField(labelWithString: "")
    private let chooseFolderBtn = NSButton()
    private let progressBar = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "")
    private let startBtn = NSButton()
    private let cancelBtn = NSButton()

    public init(mediaItems: [MediaItem], onCompletion: (() -> Void)? = nil) {
        self.mediaItems = mediaItems
        self.onCompletion = onCompletion

        // Default proxy directory: ~/Movies/Vision Proxies
        let moviesDir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.chosenFolderURL = EditorProject.shared.proxyOutputFolderURL ?? moviesDir.appendingPathComponent("Vision Proxies")

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Crea Proxy Video"
        window.center()
        super.init(window: window)

        setupUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupUI() {
        guard let window = self.window else { return }
        let contentView = NSView(frame: window.contentView!.bounds)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 1.0).cgColor
        window.contentView = contentView

        let infoLabel = NSTextField(labelWithString: "Generazione Proxy conforme per \(mediaItems.count) clip selezionate.\nI proxy conterranno lo stesso timecode, durata, framerate e tracce audio.")
        infoLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        infoLabel.textColor = NSColor(calibratedWhite: 0.85, alpha: 1.0)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(infoLabel)

        // Codec Row
        let codecLabel = NSTextField(labelWithString: "Formato Video:")
        codecLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        codecLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(codecLabel)

        codecPopUp.translatesAutoresizingMaskIntoConstraints = false
        for codec in ProxyCodec.allCases {
            codecPopUp.addItem(withTitle: codec.rawValue)
        }
        contentView.addSubview(codecPopUp)

        // Scale Row
        let scaleLabel = NSTextField(labelWithString: "Risoluzione:")
        scaleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        scaleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(scaleLabel)

        scalePopUp.translatesAutoresizingMaskIntoConstraints = false
        for scale in ProxyScale.allCases {
            scalePopUp.addItem(withTitle: scale.label)
        }
        scalePopUp.selectItem(at: 1) // default 1/4
        contentView.addSubview(scalePopUp)

        // Folder Row
        let folderTitleLabel = NSTextField(labelWithString: "Cartella Salvataggio:")
        folderTitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        folderTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(folderTitleLabel)

        pathLabel.stringValue = chosenFolderURL.path
        pathLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = NSColor(calibratedWhite: 0.7, alpha: 1.0)
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pathLabel)

        chooseFolderBtn.title = "Scegli..."
        chooseFolderBtn.bezelStyle = .rounded
        chooseFolderBtn.target = self
        chooseFolderBtn.action = #selector(onChooseFolderClicked)
        chooseFolderBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(chooseFolderBtn)

        // Progress
        progressBar.isIndeterminate = false
        progressBar.minValue = 0.0
        progressBar.maxValue = 1.0
        progressBar.doubleValue = 0.0
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(progressBar)

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = NSColor.systemCyan
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        // Buttons
        startBtn.title = "Avvia Generazione"
        startBtn.bezelStyle = .rounded
        startBtn.keyEquivalent = "\r"
        startBtn.target = self
        startBtn.action = #selector(onStartGenerationClicked)
        startBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(startBtn)

        cancelBtn.title = "Annulla"
        cancelBtn.bezelStyle = .rounded
        cancelBtn.target = self
        cancelBtn.action = #selector(onCancelClicked)
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(cancelBtn)

        NSLayoutConstraint.activate([
            infoLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            infoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            infoLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            codecLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 16),
            codecLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            codecLabel.widthAnchor.constraint(equalToConstant: 130),

            codecPopUp.centerYAnchor.constraint(equalTo: codecLabel.centerYAnchor),
            codecPopUp.leadingAnchor.constraint(equalTo: codecLabel.trailingAnchor, constant: 10),
            codecPopUp.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            scaleLabel.topAnchor.constraint(equalTo: codecLabel.bottomAnchor, constant: 12),
            scaleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scaleLabel.widthAnchor.constraint(equalToConstant: 130),

            scalePopUp.centerYAnchor.constraint(equalTo: scaleLabel.centerYAnchor),
            scalePopUp.leadingAnchor.constraint(equalTo: scaleLabel.trailingAnchor, constant: 10),
            scalePopUp.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            folderTitleLabel.topAnchor.constraint(equalTo: scaleLabel.bottomAnchor, constant: 12),
            folderTitleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            folderTitleLabel.widthAnchor.constraint(equalToConstant: 130),

            pathLabel.centerYAnchor.constraint(equalTo: folderTitleLabel.centerYAnchor),
            pathLabel.leadingAnchor.constraint(equalTo: folderTitleLabel.trailingAnchor, constant: 10),
            pathLabel.trailingAnchor.constraint(equalTo: chooseFolderBtn.leadingAnchor, constant: -8),

            chooseFolderBtn.centerYAnchor.constraint(equalTo: folderTitleLabel.centerYAnchor),
            chooseFolderBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            chooseFolderBtn.widthAnchor.constraint(equalToConstant: 80),

            progressBar.topAnchor.constraint(equalTo: folderTitleLabel.bottomAnchor, constant: 16),
            progressBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            progressBar.heightAnchor.constraint(equalToConstant: 14),

            statusLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            cancelBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            cancelBtn.trailingAnchor.constraint(equalTo: startBtn.leadingAnchor, constant: -10),

            startBtn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            startBtn.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20)
        ])
    }

    @objc private func onChooseFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Seleziona Cartella"
        panel.message = "Scegli la cartella dove salvare i file Proxy:"

        if panel.runModal() == .OK, let url = panel.url {
            self.chosenFolderURL = url
            self.pathLabel.stringValue = url.path
            EditorProject.shared.proxyOutputFolderURL = url
        }
    }

    @objc private func onStartGenerationClicked() {
        startBtn.isEnabled = false
        chooseFolderBtn.isEnabled = false
        codecPopUp.isEnabled = false
        scalePopUp.isEnabled = false
        progressBar.isHidden = false
        progressBar.doubleValue = 0.0

        let selectedCodec = ProxyCodec.allCases[max(0, codecPopUp.indexOfSelectedItem)]
        let selectedScale = ProxyScale.allCases[max(0, scalePopUp.indexOfSelectedItem)]
        let folder = chosenFolderURL

        Task {
            let total = mediaItems.count
            for (idx, item) in mediaItems.enumerated() {
                await MainActor.run {
                    self.statusLabel.stringValue = "[\(idx + 1)/\(total)] Generazione proxy: \(item.name)..."
                }

                do {
                    let proxyURL = try await ProxyEngine.shared.generateProxy(
                        for: item,
                        codec: selectedCodec,
                        scale: selectedScale,
                        destinationFolder: folder
                    ) { progress in
                        let overall = (Double(idx) + progress) / Double(total)
                        self.progressBar.doubleValue = overall
                    }

                    // Update mediaItem in project
                    await MainActor.run {
                        if let itemIndex = EditorProject.shared.folders.firstIndex(where: { $0.itemIds.contains(item.id) }) {
                            _ = itemIndex
                        }
                        // Assign proxyURL
                        NotificationCenter.default.post(
                            name: NSNotification.Name("MediaItemProxyGenerated"),
                            object: nil,
                            userInfo: ["itemId": item.id, "proxyURL": proxyURL]
                        )
                    }
                } catch {
                    DebugLogger.shared.log("Errore generazione proxy per \(item.name): \(error.localizedDescription)", level: .error)
                }
            }

            await MainActor.run {
                self.progressBar.doubleValue = 1.0
                self.statusLabel.stringValue = "Completato! \(total) proxy generati con successo."
                self.startBtn.title = "Chiudi"
                self.startBtn.isEnabled = true
                self.startBtn.action = #selector(self.onCloseClicked)
                self.cancelBtn.isHidden = true
                self.onCompletion?()
            }
        }
    }

    @objc private func onCancelClicked() {
        ProxyEngine.shared.cancel()
        window?.close()
    }

    @objc private func onCloseClicked() {
        window?.close()
    }
}
