import AppKit

/// Modal dialog for configuring a TimelineModel's resolution and frame rate (FPS).
public final class TimelineSettingsDialog {
    private static let fpsChoices: [(label: String, value: Float)] = [
        ("23.976 fps", 23.976),
        ("24 fps", 24.0),
        ("25 fps", 25.0),
        ("29.97 fps", 29.97),
        ("30 fps", 30.0),
        ("50 fps", 50.0),
        ("59.94 fps", 59.94),
        ("60 fps", 60.0)
    ]

    @discardableResult
    public static func runModal(for timeline: TimelineModel, on parentWindow: NSWindow? = nil) -> TimelineFormat? {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 270),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Impostazioni Timeline — \(timeline.name)"
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isFloatingPanel = true
        if let parent = parentWindow {
            let pf = parent.frame
            panel.setFrameOrigin(NSPoint(
                x: pf.midX - panel.frame.width / 2,
                y: pf.midY - panel.frame.height / 2
            ))
        } else {
            panel.center()
        }

        let controller = DialogController(timeline: timeline, panel: panel)
        panel.contentViewController = controller
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return response == .OK ? controller.resultingFormat : nil
    }

    public static func testApplySettings(for timeline: TimelineModel, fpsIndex: Int) -> TimelineFormat? {
        let controller = DialogController(timeline: timeline, panel: nil)
        _ = controller.view
        controller.setFpsIndexForTesting(fpsIndex)
        controller.applyForTesting()
        return controller.resultingFormat
    }

    private final class DialogController: NSViewController {
        private let timeline: TimelineModel
        private weak var panel: NSPanel?
        var resultingFormat: TimelineFormat?

        private let presetPopUp = VisionDropdownButton()
        private let widthField = NSTextField()
        private let heightField = NSTextField()
        private let fpsPopUp = VisionDropdownButton()
        private var isUpdatingFields = false

        init(timeline: TimelineModel, panel: NSPanel?) {
            self.timeline = timeline
            self.panel = panel
            super.init(nibName: nil, bundle: nil)
        }

        func setFpsIndexForTesting(_ index: Int) {
            fpsPopUp.selectItem(at: index)
            onFpsChanged()
        }

        func applyForTesting() {
            onSave()
        }

        required init?(coder: NSCoder) { fatalError() }

        override func loadView() {
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 270))
            root.wantsLayer = true
            root.layer?.backgroundColor = NSColor(calibratedWhite: 0.085, alpha: 1.0).cgColor
            self.view = root

            let titleLbl = NSTextField(labelWithString: "Formato e Frame Rate")
            titleLbl.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
            titleLbl.textColor = .white
            titleLbl.translatesAutoresizingMaskIntoConstraints = false

            let subLbl = NSTextField(labelWithString: timeline.name)
            subLbl.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            subLbl.textColor = NSColor(calibratedWhite: 0.62, alpha: 1.0)
            subLbl.translatesAutoresizingMaskIntoConstraints = false

            // Preset row
            let presetLbl = makeFieldLabel("Preset")
            for preset in TimelineFormat.presets {
                presetPopUp.addItem(withTitle: preset.name)
            }
            presetPopUp.addItem(withTitle: "Personalizzato")
            presetPopUp.translatesAutoresizingMaskIntoConstraints = false
            presetPopUp.onSelectionChanged = { [weak self] _, _ in
                self?.onPresetChanged()
            }

            // Resolution row
            let resLbl = makeFieldLabel("Risoluzione")
            configureNumberField(widthField, value: Int(timeline.format.size.width))
            configureNumberField(heightField, value: Int(timeline.format.size.height))
            widthField.target = self
            widthField.action = #selector(onCustomDimensionEdited)
            heightField.target = self
            heightField.action = #selector(onCustomDimensionEdited)

            let timesLbl = NSTextField(labelWithString: "×")
            timesLbl.font = NSFont.systemFont(ofSize: 13, weight: .medium)
            timesLbl.textColor = NSColor(calibratedWhite: 0.65, alpha: 1.0)
            timesLbl.translatesAutoresizingMaskIntoConstraints = false

            let pxLbl = NSTextField(labelWithString: "px")
            pxLbl.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            pxLbl.textColor = NSColor(calibratedWhite: 0.55, alpha: 1.0)
            pxLbl.translatesAutoresizingMaskIntoConstraints = false

            let resStack = NSStackView(views: [widthField, timesLbl, heightField, pxLbl])
            resStack.orientation = .horizontal
            resStack.spacing = 6
            resStack.translatesAutoresizingMaskIntoConstraints = false

            // FPS row
            let fpsLbl = makeFieldLabel("Frame Rate")
            for item in TimelineSettingsDialog.fpsChoices {
                fpsPopUp.addItem(withTitle: item.label)
            }
            fpsPopUp.translatesAutoresizingMaskIntoConstraints = false
            fpsPopUp.onSelectionChanged = { [weak self] _, _ in
                self?.onFpsChanged()
            }

            syncControlsFromFormat(timeline.format)

            // Action buttons
            let cancelBtn = FlatButton(title: "Annulla", target: self, action: #selector(onCancel))
            cancelBtn.translatesAutoresizingMaskIntoConstraints = false
            let saveBtn = FlatButton(title: "Applica", target: self, action: #selector(onSave))
            saveBtn.isAccentActive = true
            saveBtn.translatesAutoresizingMaskIntoConstraints = false

            let btnStack = NSStackView(views: [cancelBtn, saveBtn])
            btnStack.orientation = .horizontal
            btnStack.spacing = 10
            btnStack.translatesAutoresizingMaskIntoConstraints = false

            root.addSubview(titleLbl)
            root.addSubview(subLbl)
            root.addSubview(presetLbl)
            root.addSubview(presetPopUp)
            root.addSubview(resLbl)
            root.addSubview(resStack)
            root.addSubview(fpsLbl)
            root.addSubview(fpsPopUp)
            root.addSubview(btnStack)

            NSLayoutConstraint.activate([
                titleLbl.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
                titleLbl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),

                subLbl.topAnchor.constraint(equalTo: titleLbl.bottomAnchor, constant: 3),
                subLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),

                presetLbl.topAnchor.constraint(equalTo: subLbl.bottomAnchor, constant: 22),
                presetLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
                presetLbl.widthAnchor.constraint(equalToConstant: 86),

                presetPopUp.centerYAnchor.constraint(equalTo: presetLbl.centerYAnchor),
                presetPopUp.leadingAnchor.constraint(equalTo: presetLbl.trailingAnchor, constant: 10),
                presetPopUp.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),

                resLbl.topAnchor.constraint(equalTo: presetLbl.bottomAnchor, constant: 20),
                resLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
                resLbl.widthAnchor.constraint(equalToConstant: 86),

                resStack.centerYAnchor.constraint(equalTo: resLbl.centerYAnchor),
                resStack.leadingAnchor.constraint(equalTo: resLbl.trailingAnchor, constant: 10),
                widthField.widthAnchor.constraint(equalToConstant: 80),
                heightField.widthAnchor.constraint(equalToConstant: 80),

                fpsLbl.topAnchor.constraint(equalTo: resLbl.bottomAnchor, constant: 20),
                fpsLbl.leadingAnchor.constraint(equalTo: titleLbl.leadingAnchor),
                fpsLbl.widthAnchor.constraint(equalToConstant: 86),

                fpsPopUp.centerYAnchor.constraint(equalTo: fpsLbl.centerYAnchor),
                fpsPopUp.leadingAnchor.constraint(equalTo: fpsLbl.trailingAnchor, constant: 10),
                fpsPopUp.widthAnchor.constraint(equalToConstant: 140),

                btnStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
                btnStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
                cancelBtn.widthAnchor.constraint(equalToConstant: 86),
                cancelBtn.heightAnchor.constraint(equalToConstant: 28),
                saveBtn.widthAnchor.constraint(equalToConstant: 92),
                saveBtn.heightAnchor.constraint(equalToConstant: 28)
            ])
        }

        private func makeFieldLabel(_ text: String) -> NSTextField {
            let lbl = NSTextField(labelWithString: text)
            lbl.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            lbl.textColor = NSColor(calibratedWhite: 0.78, alpha: 1.0)
            lbl.alignment = .right
            lbl.translatesAutoresizingMaskIntoConstraints = false
            return lbl
        }

        private func configureNumberField(_ field: NSTextField, value: Int) {
            field.stringValue = "\(value)"
            field.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            field.alignment = .right
            field.bezelStyle = .roundedBezel
            field.translatesAutoresizingMaskIntoConstraints = false
        }

        private func syncControlsFromFormat(_ format: TimelineFormat) {
            isUpdatingFields = true
            defer { isUpdatingFields = false }

            widthField.stringValue = "\(Int(format.size.width))"
            heightField.stringValue = "\(Int(format.size.height))"

            if let idx = TimelineFormat.presets.firstIndex(where: {
                abs($0.size.width - format.size.width) < 1 &&
                abs($0.size.height - format.size.height) < 1 &&
                abs($0.fps - format.fps) < 0.05
            }) {
                presetPopUp.selectItem(at: idx)
            } else if let idx = TimelineFormat.presets.firstIndex(where: {
                abs($0.size.width - format.size.width) < 1 &&
                abs($0.size.height - format.size.height) < 1
            }) {
                presetPopUp.selectItem(at: idx)
            } else {
                presetPopUp.selectItem(at: TimelineFormat.presets.count)
            }

            if let fpsIdx = TimelineSettingsDialog.fpsChoices.firstIndex(where: { abs($0.value - format.fps) < 0.05 }) {
                fpsPopUp.selectItem(at: fpsIdx)
            } else {
                fpsPopUp.selectItem(at: 4) // 30 fps fallback
            }
        }

        @objc private func onPresetChanged() {
            guard !isUpdatingFields else { return }
            let idx = presetPopUp.selectedIndex
            guard idx >= 0 && idx < TimelineFormat.presets.count else { return }
            let chosen = TimelineFormat.presets[idx]
            syncControlsFromFormat(chosen)
        }

        @objc private func onCustomDimensionEdited() {
            guard !isUpdatingFields else { return }
            presetPopUp.selectItem(at: TimelineFormat.presets.count)
        }

        @objc private func onFpsChanged() {
            // Keep preset if resolution matches, or mark custom if FPS differs from preset
            guard !isUpdatingFields else { return }
            let idx = presetPopUp.selectedIndex
            let fpsIdx = fpsPopUp.selectedIndex
            guard idx >= 0 && idx < TimelineFormat.presets.count,
                  fpsIdx >= 0 && fpsIdx < TimelineSettingsDialog.fpsChoices.count else { return }
            let preset = TimelineFormat.presets[idx]
            let fps = TimelineSettingsDialog.fpsChoices[fpsIdx].value
            if abs(preset.fps - fps) > 0.05 {
                presetPopUp.selectItem(at: TimelineFormat.presets.count)
            }
        }

        @objc private func onCancel() {
            resultingFormat = nil
            if panel != nil {
                NSApp.stopModal(withCode: .cancel)
            }
        }

        @objc private func onSave() {
            let w = max(128, min(8192, Int(widthField.stringValue) ?? Int(timeline.format.size.width)))
            let h = max(128, min(8192, Int(heightField.stringValue) ?? Int(timeline.format.size.height)))
            let fpsIdx = max(0, min(TimelineSettingsDialog.fpsChoices.count - 1, fpsPopUp.selectedIndex))
            let fps = TimelineSettingsDialog.fpsChoices[fpsIdx].value

            if let matched = TimelineFormat.presets.first(where: {
                Int($0.size.width) == w && Int($0.size.height) == h && abs($0.fps - fps) < 0.05
            }) {
                resultingFormat = matched
            } else {
                let fpsText: String
                if abs(fps - 23.976) < 0.005 {
                    fpsText = "23.976"
                } else if fps.truncatingRemainder(dividingBy: 1) == 0 {
                    fpsText = "\(Int(fps))"
                } else {
                    fpsText = String(format: "%.2f", fps)
                }
                resultingFormat = TimelineFormat(
                    id: "custom_\(w)x\(h)_\(fpsText)",
                    name: "\(w) × \(h) @ \(fpsText)fps",
                    size: CGSize(width: w, height: h),
                    fps: fps
                )
            }
            if panel != nil {
                NSApp.stopModal(withCode: .OK)
            }
        }
    }
}
