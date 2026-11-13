import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    private var startupProjectManagerWC: ProjectManagerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()
        showStartupProjectManager()
    }

    private func showStartupProjectManager() {
        let pm = ProjectManagerWindowController()
        pm.onOpenProject = { [weak self] doc in
            self?.openEditor(with: doc)
        }
        pm.onCreateNewProject = { [weak self] name in
            let newProj = EditorProject()
            newProj.projectName = name
            let blankDoc = ProjectDocumentData(project: newProj, mediaItems: [])
            ProjectDatabase.shared.saveProjectImmediately(project: newProj, mediaItems: [])
            self?.openEditor(with: blankDoc)
        }
        pm.onCloseWithoutProject = { [weak self] in
            if self?.window == nil {
                NSApp.terminate(nil)
            }
        }
        self.startupProjectManagerWC = pm
        pm.showModal(relativeTo: nil)
    }

    private func openEditor(with doc: ProjectDocumentData) {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetW = min(1440, max(950, floor(visibleFrame.width * 0.88)))
        let targetH = min(900, max(600, floor(visibleFrame.height * 0.86)))

        let win: NSWindow
        if let existingWin = self.window, let editorVC = existingWin.contentViewController as? MainEditorViewController {
            win = existingWin
            editorVC.restoreProjectFromSnapshot(doc)
        } else {
            win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: targetW, height: targetH),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.minSize = NSSize(width: min(950, visibleFrame.width), height: min(600, visibleFrame.height))
            win.title = "Vision"
            win.isReleasedWhenClosed = false
            win.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]

            let editorVC = MainEditorViewController(initialDocument: doc)
            win.contentViewController = editorVC
            self.window = win

            let clampedW = min(targetW, visibleFrame.width)
            let clampedH = min(targetH, visibleFrame.height)
            win.setFrame(NSRect(
                x: visibleFrame.origin.x + floor((visibleFrame.width - clampedW) / 2.0),
                y: visibleFrame.origin.y + floor((visibleFrame.height - clampedH) / 2.0),
                width: clampedW,
                height: clampedH
            ), display: true)
        }

        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        startupProjectManagerWC = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let win = window {
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
        } else if let pm = startupProjectManagerWC {
            pm.showModal(relativeTo: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @objc func menuOpenProjectManager() {
        if let editor = window?.contentViewController as? MainEditorViewController {
            editor.openProjectManager()
        } else {
            startupProjectManagerWC?.showModal(relativeTo: nil)
        }
    }

    @objc func menuUndo() {
        if let editor = window?.contentViewController as? MainEditorViewController {
            editor.performUndo()
        }
    }

    @objc func menuRedo() {
        if let editor = window?.contentViewController as? MainEditorViewController {
            editor.performRedo()
        }
    }

    @objc func menuToggleHistory() {
        if let editor = window?.contentViewController as? MainEditorViewController {
            editor.toggleHistoryPopover()
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Informazioni su Vision", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Nascondi Vision", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Nascondi altre", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Mostra tutte", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Esci da Vision", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // File Menu
        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Project Manager...", action: #selector(menuOpenProjectManager), keyEquivalent: "o")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Chiudi Finestra", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu

        // Edit Menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Modifica")
        editMenu.addItem(withTitle: "Annulla", action: #selector(menuUndo), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Ripeti", action: #selector(menuRedo), keyEquivalent: "Z")
        editMenu.addItem(redoItem)
        editMenu.addItem(withTitle: "Cronologia Azioni...", action: #selector(menuToggleHistory), keyEquivalent: "y")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Taglia", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copia", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Incolla", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Elimina", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenuItem.submenu = editMenu

        // Window Menu
        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Finestra")
        windowMenu.addItem(withTitle: "Contrai", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Ridimensiona", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(withTitle: "Porta tutto in primo piano", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}

var strongDelegate: AppDelegate? = AppDelegate()
let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.delegate = strongDelegate
withExtendedLifetime(strongDelegate) {
    app.run()
}
