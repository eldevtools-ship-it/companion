import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem?
    private let versionItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Rechercher une mise à jour", action: nil, keyEquivalent: "u")
    private let focusItem = NSMenuItem(title: "Concentration", action: nil, keyEquivalent: "")
    private(set) var islandController: IslandWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ignore SIGPIPE — prevents crash when compagnon-hook closes socket before we write response
        signal(SIGPIPE, SIG_IGN)
        // Warm up Keychain cache on main thread BEFORE any poller or view touches it
        _ = KeychainStore.shared
        NSApp.setActivationPolicy(.accessory)
        IslandCursor.allowInBackground()
        setupMenuBarItem()
        setupIsland()
    }

    // MARK: - Menu bar

    private func setupMenuBarItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Compagnon")
        button.image?.size = NSSize(width: 24, height: 18)
        button.image?.accessibilityDescription = "Compagnon"
        button.image?.isTemplate = true

        // Same menu on left and right click
        let menu = NSMenu()
        menu.delegate = self
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Ouvrir Compagnon", action: #selector(openIsland), keyEquivalent: "")
        menu.addItem(withTitle: "Réglages…", action: #selector(openSettings), keyEquivalent: ",")
        focusItem.target = self
        focusItem.action = #selector(toggleFocus)
        menu.addItem(focusItem)
        menu.addItem(.separator())
        updateItem.target = self
        updateItem.action = #selector(checkForUpdate)
        menu.addItem(updateItem)
        let force = NSMenuItem(title: "Réinstaller la dernière version", action: #selector(forceUpdate), keyEquivalent: "")
        force.target = self
        menu.addItem(force)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
        refreshMenu()
    }

    // MARK: - Menu state

    func menuWillOpen(_ menu: NSMenu) { refreshMenu() }

    private func refreshMenu() {
        versionItem.title = "Compagnon · version \(UpdateService.currentBuild)"
        focusItem.state = AppState.shared.focusMode ? .on : .off
        switch AppState.shared.updateStatus {
        case .available(let build): updateItem.title = "Installer la version \(build)"
        case .checking:             updateItem.title = "Recherche en cours…"
        case .installing:           updateItem.title = "Installation en cours…"
        default:                    updateItem.title = "Rechercher une mise à jour"
        }
        let busy = AppState.shared.updateStatus == .checking || AppState.shared.updateStatus == .installing
        updateItem.isEnabled = !busy
    }

    // MARK: - Actions

    /// Checks now and installs right away if there's something newer (no waiting for a quiet moment).
    @objc private func checkForUpdate() {
        Task { @MainActor in
            await UpdateService.shared.check()
            if case .available = AppState.shared.updateStatus {
                await UpdateService.shared.install()
            }
            // Only reached when nothing was installed (a successful install relaunches the app)
            showUpdateResult()
        }
    }

    /// Downloads and reinstalls the latest release even if it's the same version.
    @objc private func forceUpdate() {
        Task { @MainActor in
            await UpdateService.shared.install(force: true)
            showUpdateResult()
        }
    }

    private func showUpdateResult() {
        let status = AppState.shared.updateStatus
        let alert = NSAlert()
        if status == .upToDate {
            alert.messageText = "Compagnon est à jour"
            alert.informativeText = "Tu as la dernière version (\(UpdateService.currentBuild))."
        } else {
            alert.messageText = "Mise à jour impossible"
            alert.informativeText = status.label
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Ouvrir les réglages")
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            UserDefaults.standard.set("updates", forKey: "settingsSection")
            openSettings()
        }
    }

    @objc private func toggleFocus() {
        AppState.shared.focusMode.toggle()
    }

    @objc private func openIsland() {
        islandController?.open(to: .overview)
    }

    private var settingsWindow: NSWindow?

    @objc private func openSettingsFromNotification(_ notification: Notification) {
        if let section = notification.object as? String {
            UserDefaults.standard.set(section, forKey: "settingsSection")
        }
        openSettings()
    }

    @objc private func openSettings() {
        // The island floats above every window; fold it away so it can't cover Settings.
        if AppState.shared.mode == .expanded { islandController?.collapse() }

        if let w = settingsWindow, w.isVisible {
            placeBelowIsland(w)
            w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Réglages — Compagnon"
        let host = NSHostingView(rootView: SettingsView())
        host.sizingOptions = [.minSize]
        win.contentView = host
        win.contentMinSize = NSSize(width: 640, height: 420)
        win.isReleasedWhenClosed = false
        placeBelowIsland(win)
        settingsWindow = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Centres the window horizontally and keeps its title bar clear of the island panel
    /// (320 pt tall at the top of the notch screen), shrinking it to fit if needed.
    private func placeBelowIsland(_ win: NSWindow) {
        let screen = IslandWindowController.notchScreen() ?? NSScreen.main ?? win.screen
        guard let screen else { win.center(); return }
        let visible = screen.visibleFrame
        let islandBottom = screen.frame.maxY - 320 - 12   // island panel height + margin
        let top = min(visible.maxY, islandBottom)
        var frame = win.frame
        frame.size.height = min(frame.height, max(top - visible.minY - 12, win.minSize.height))
        frame.origin.x = visible.midX - frame.width / 2
        frame.origin.y = max(visible.minY + 12, top - frame.height)
        win.setFrame(frame, display: true)
    }

    // MARK: - Island setup

    private func setupIsland() {
        islandController = IslandWindowController()
        islandController?.showWindow(nil)
        islandController?.fsm.launch()
        HookServer.shared.start()
        GithubPoller.shared.start()
        VercelService.shared.start()
        CalendarService.shared.start()
        SlackService.shared.start()
        HarvestService.shared.start()
        UpdateService.shared.start()
        NotificationCenter.default.addObserver(self, selector: #selector(openSettingsFromNotification(_:)),
                                               name: .openFullSettings, object: nil)
    }
}
