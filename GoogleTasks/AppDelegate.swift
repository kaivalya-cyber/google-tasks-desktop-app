import SwiftUI
import AppKit
import Combine
import HotKey

// MARK: - Keyable Panel

class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        NotificationCenter.default.post(name: AppConstants.Notifications.closeMenuBarPanel, object: nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelOperation(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var dataManager: DataManager!
    private var cancellables = Set<AnyCancellable>()

    // Menu bar panel
    private var menuBarPanel: NSPanel?
    private var menuBarHostingController: NSHostingController<AnyView>?
    private var isMenuBarPanelOpen: Bool = false
    private var menuBarClickMonitor: Any?

    // Keyboard shortcut
    private var hotKey: HotKey?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        dataManager = DataManager.shared

        // Setup status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            updateStatusIcon()
            button.action = #selector(handleStatusBarClick(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Register global hotkey: Ctrl+Opt+T
        registerHotkey()

        // Listen for auth state changes to update icon
        dataManager.authManager.$isAuthenticated
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        // Listen for close notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloseMenuBarPanel),
            name: AppConstants.Notifications.closeMenuBarPanel,
            object: nil
        )

        // If already authenticated, refresh data
        if dataManager.authManager.isAuthenticated {
            Task {
                await dataManager.refreshAll()
                dataManager.startAutoRefresh()
            }
        }
    }

    // MARK: - Hotkey

    private func registerHotkey() {
        hotKey = HotKey(key: .t, modifiers: [.control, .option])
        hotKey?.keyDownHandler = { [weak self] in
            Task { @MainActor [weak self] in
                self?.toggleMenuBarPanelViaHotkey()
            }
        }
    }

    private func toggleMenuBarPanelViaHotkey() {
        // If panel is already open, close it. Otherwise open it (positioned at center of screen
        // since we don't have a status bar button context from the hotkey).
        if isMenuBarPanelOpen {
            closeMenuBarPanel()
        } else {
            showMenuBarPanelFromHotkey()
        }
    }

    private func showMenuBarPanelFromHotkey() {
        let isFirstShow = menuBarPanel == nil

        if menuBarPanel == nil {
            createMenuBarPanel()
        }

        guard let panel = menuBarPanel, let screen = NSScreen.main else { return }

        // Center the panel on screen
        let panelX = screen.visibleFrame.midX - AppConstants.MenuBar.width / 2
        let panelY = screen.visibleFrame.midY - AppConstants.MenuBar.height / 2
        panel.setFrame(
            NSRect(x: panelX, y: panelY, width: AppConstants.MenuBar.width, height: AppConstants.MenuBar.height),
            display: false
        )

        isMenuBarPanelOpen = true

        if isFirstShow {
            panel.alphaValue = 0
            panel.orderFront(nil)
            DispatchQueue.main.async { [weak panel] in
                panel?.alphaValue = 1
                panel?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        if menuBarClickMonitor == nil {
            menuBarClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self, let panel = self.menuBarPanel, panel.isVisible else { return }
                if !panel.frame.contains(event.locationInWindow) {
                    DispatchQueue.main.async {
                        self.closeMenuBarPanel()
                    }
                }
            }
        }
    }

    // MARK: - Status Bar

    @objc private func handleStatusBarClick(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showStatusItemMenu()
            return
        }

        if event.type == .leftMouseUp {
            toggleMenuBarPanel()
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }

        if dataManager.authManager.isAuthenticated {
            if let image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Google Tasks") {
                button.image = image
                button.image?.size = NSSize(width: 18, height: 18)
            } else {
                button.title = "✓"
            }
        } else {
            if let image = NSImage(systemSymbolName: "checklist.unchecked", accessibilityDescription: "Sign in") {
                button.image = image
                button.image?.size = NSSize(width: 18, height: 18)
            } else {
                button.title = "☐"
            }
        }
    }

    private func showStatusItemMenu() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "Open Google Tasks in Browser", action: #selector(openInBrowser), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openInBrowser() {
        if let url = URL(string: "https://tasks.google.com/") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Menu Bar Panel

    private func toggleMenuBarPanel() {
        if isMenuBarPanelOpen {
            closeMenuBarPanel()
        } else {
            guard let button = statusItem.button else { return }
            showMenuBarPanel(relativeTo: button)
        }
    }

    private func showMenuBarPanel(relativeTo button: NSStatusBarButton) {
        let isFirstShow = menuBarPanel == nil

        if menuBarPanel == nil {
            createMenuBarPanel()
        }

        guard let panel = menuBarPanel else { return }

        // Position panel under the menu bar
        if let buttonWindow = button.window,
           let screen = buttonWindow.screen ?? NSScreen.main {
            let buttonFrameInScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
            var panelX = buttonFrameInScreen.minX
            let panelY = screen.visibleFrame.maxY - AppConstants.MenuBar.height

            let screenMaxX = screen.visibleFrame.maxX
            let panelRightEdge = panelX + AppConstants.MenuBar.width
            if panelRightEdge > screenMaxX {
                panelX = screenMaxX - AppConstants.MenuBar.width
            }
            let screenMinX = screen.visibleFrame.minX
            if panelX < screenMinX {
                panelX = screenMinX
            }

            panel.setFrame(
                NSRect(x: panelX, y: panelY, width: AppConstants.MenuBar.width, height: AppConstants.MenuBar.height),
                display: false
            )
        }

        isMenuBarPanelOpen = true

        if isFirstShow {
            panel.alphaValue = 0
            panel.orderFront(nil)
            DispatchQueue.main.async { [weak panel] in
                panel?.alphaValue = 1
                panel?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        // Global click monitor to close when clicking outside
        if menuBarClickMonitor == nil {
            menuBarClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self = self, let panel = self.menuBarPanel, panel.isVisible else { return }
                if !panel.frame.contains(event.locationInWindow) {
                    DispatchQueue.main.async {
                        self.closeMenuBarPanel()
                    }
                }
            }
        }
    }

    private func closeMenuBarPanel() {
        menuBarPanel?.orderOut(nil)
        isMenuBarPanelOpen = false

        if let monitor = menuBarClickMonitor {
            NSEvent.removeMonitor(monitor)
            menuBarClickMonitor = nil
        }
    }

    @objc private func handleCloseMenuBarPanel() {
        closeMenuBarPanel()
    }

    private func createMenuBarPanel() {
        let panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: AppConstants.MenuBar.width, height: AppConstants.MenuBar.height),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false

        // Create menu view
        let menuView = MenuView().environmentObject(dataManager)
        menuBarHostingController = NSHostingController(rootView: AnyView(menuView))

        if let hostingController = menuBarHostingController {
            hostingController.view.translatesAutoresizingMaskIntoConstraints = false
            if #available(macOS 13.3, *) {
                hostingController.safeAreaRegions = []
            }
            hostingController.view.wantsLayer = true
            hostingController.view.layer?.cornerRadius = 12
            hostingController.view.layer?.masksToBounds = true

            panel.contentView?.addSubview(hostingController.view)

            if let contentView = panel.contentView {
                contentView.wantsLayer = true
                NSLayoutConstraint.activate([
                    hostingController.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                    hostingController.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    hostingController.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                    hostingController.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
                ])
            }
        }

        menuBarPanel = panel

        // Close when panel loses key
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuBarPanelDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
    }

    @objc private func menuBarPanelDidResignKey(_ notification: Notification) {
        guard notification.object as? NSPanel === menuBarPanel else { return }
        closeMenuBarPanel()
    }

    // MARK: - Settings

    @objc func openSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancellables.forEach { $0.cancel() }
        dataManager.stopAutoRefresh()
    }
}
