import AppKit
import OSLog
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Keys {
        static let enabled = "enabled"
    }

    private var statusItem: NSStatusItem!
    private let monitor = DragMonitor()
    private let picker = PickerController()
    private let toast = ToastController()
    private let workbench = WorkbenchModel()
    private var hasProgressToast = false
    private lazy var mainWindow = WorkbenchWindowController(model: workbench)
    private let log = Logger(subsystem: "com.a2289866844.fileflipper", category: "actions")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two running copies (e.g. one in Applications and one in a build folder) would each show a picker.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if let existing = others.first {
            existing.activate(options: [.activateAllWindows])
            NSApp.terminate(nil)
            return
        }

        UserDefaults.standard.register(defaults: [Keys.enabled: true])

        setUpStatusItem()

        monitor.isEnabled = UserDefaults.standard.bool(forKey: Keys.enabled)
        monitor.onShow = { [weak self] point, urls, tools in
            self?.picker.show(at: point, urls: urls, tools: tools)
        }
        monitor.onModeChange = { [weak self] tools in
            self?.picker.setToolsMode(tools)
        }
        monitor.onEnd = { [weak self] in
            self?.picker.hide(afterDelay: 0.35)
        }
        picker.onPick = { [weak self] item, urls in
            self?.run(item, on: urls)
        }
        monitor.start()

        workbench.onRun = { [weak self] item, urls in self?.run(item, on: urls) }
        // Login launches remain quiet. Opening the app normally presents its workspace.
        if NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue != keyAELaunchedAsLogInItem {
            showWorkbench()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWorkbench()
        return true
    }

    @objc private func showWorkbench() { mainWindow.present() }

    // MARK: Running actions

    private func run(_ item: PickerItem, on urls: [URL]) {
        guard !workbench.isWorking else {
            showWorkbench()
            return
        }
        guard !urls.isEmpty, !Catalog.items(for: urls, tools: false).isEmpty || !Catalog.items(for: urls, tools: true).isEmpty else {
            workbench.setFiles(urls)
            showWorkbench()
            return
        }
        workbench.tools = Catalog.items(for: urls, tools: true).contains { $0.title == item.title }
        workbench.begin(item, files: urls)
        // Sandbox: we need permission to write into the folders holding these files.
        guard let endAccess = FolderAccess.shared.beginAccess(to: urls.map { $0.deletingLastPathComponent() }) else {
            log.error("No folder access for \(urls.first?.deletingLastPathComponent().path ?? "?", privacy: .public)")
            workbench.complete(outputs: [], message: L("Folder access was not granted. Choose a folder when you try again."), failed: true)
            showWorkbench()
            return
        }

        let what = urls.count == 1 ? urls[0].lastPathComponent : L("%@ files", String(urls.count))
        hasProgressToast = !(mainWindow.window?.isVisible ?? false)
        if hasProgressToast {
            toast.show(L("%@: %@…", item.title, what), symbol: "hourglass", duration: nil)
        }

        let work = { () -> Result<[URL], Error> in
            Result { try item.action(urls) }
        }
        if item.runsOnMain {
            DispatchQueue.main.async { [weak self] in
                let result = work()
                endAccess()
                self?.finish(result, item: item)
            }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = work()
                DispatchQueue.main.async { [weak self] in
                    endAccess()
                    self?.finish(result, item: item)
                }
            }
        }
    }

    private func finish(_ result: Result<[URL], Error>, item: PickerItem) {
        let message: String
        let outputs: [URL]
        let failed: Bool
        switch result {
        case .success(let files):
            outputs = files
            failed = false
            message = files.count == 1 ? L("Saved %@", files[0].lastPathComponent)
                : (files.isEmpty ? L("%@: nothing to do", item.title) : L("Saved %@ files", String(files.count)))
        case .failure(ConversionError.cancelled):
            outputs = []; failed = false; message = L("Cancelled")
        case .failure(let error):
            outputs = []; failed = true; message = error.localizedDescription
            log.error("\(item.title, privacy: .public) failed: \(message, privacy: .public)")
        }
        workbench.complete(outputs: outputs, message: message, failed: failed)
        // A completed toast also dismisses any persistent progress toast from a Finder action.
        if hasProgressToast || !(mainWindow.window?.isVisible ?? false) {
            toast.show(message, symbol: failed ? "exclamationmark.circle.fill" : (outputs.isEmpty ? "info.circle" : "checkmark.circle.fill"),
                       duration: failed ? 5 : 2.5)
        }
        hasProgressToast = false
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.badge.arrow.up", accessibilityDescription: "FileFlipper")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let open = NSMenuItem(title: L("Open FileFlipper…"), action: #selector(showWorkbench), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let enabled = NSMenuItem(title: L("Finder shortcuts"), action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = monitor.isEnabled ? .on : .off
        menu.addItem(enabled)

        let login = NSMenuItem(title: L("Launch at Login"), action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        if FolderAccess.isSandboxed {
            menu.addItem(.separator())
            let folders = FolderAccess.shared.grantedFolders
            let header = NSMenuItem(title: folders.isEmpty ? L("No Folder Access Yet") : L("Can Save In:"),
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for folder in folders {
                let entry = NSMenuItem(title: "  " + folder.path, action: nil, keyEquivalent: "")
                entry.isEnabled = false
                menu.addItem(entry)
            }
            let grant = NSMenuItem(title: L("Choose allowed folder…"), action: #selector(grantFolder), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
            if !folders.isEmpty {
                let reset = NSMenuItem(title: L("Reset Folder Access"), action: #selector(resetFolders), keyEquivalent: "")
                reset.target = self
                menu.addItem(reset)
            }
        }

        menu.addItem(.separator())

        let about = NSMenuItem(title: L("About FileFlipper"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit FileFlipper"), action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    @objc private func toggleEnabled() {
        monitor.isEnabled.toggle()
        UserDefaults.standard.set(monitor.isEnabled, forKey: Keys.enabled)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            toast.show(L("Launch at Login: %@", error.localizedDescription), symbol: "xmark.octagon.fill", duration: 4)
        }
    }

    @objc private func grantFolder() {
        FolderAccess.shared.chooseFolderAccess()
    }

    @objc private func resetFolders() {
        FolderAccess.shared.resetAll()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: L("Convert files right in Finder.\nOpen source under the MIT License.")),
        ])
    }

}
