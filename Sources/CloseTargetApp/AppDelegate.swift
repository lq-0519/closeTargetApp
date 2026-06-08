import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?
    private var recentStatusText: String?
    private var isClosingApplications = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.onChange = { [weak self] in
            self?.rebuildMenu()
        }

        configureStatusItem()
        rebuildMenu()
    }

    private func configureStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "xmark.octagon",
                accessibilityDescription: "CloseTargetApp"
            )
            button.image?.isTemplate = true
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let closeItem = NSMenuItem(
            title: isClosingApplications ? "正在关闭..." : "一键关闭指定软件",
            action: #selector(closeTargetApplications),
            keyEquivalent: ""
        )
        closeItem.target = self
        closeItem.isEnabled = !isClosingApplications
        closeItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(closeItem)

        if !store.targetApplications.isEmpty {
            let targetMenu = NSMenu()
            for application in store.targetApplications {
                let item = NSMenuItem(title: application.displayName, action: nil, keyEquivalent: "")
                item.isEnabled = false
                targetMenu.addItem(item)
            }

            let targetItem = NSMenuItem(title: "当前目标", action: nil, keyEquivalent: "")
            targetItem.submenu = targetMenu
            menu.addItem(targetItem)
        }

        if let recentStatusText {
            menu.addItem(NSMenuItem.separator())
            let statusItem = NSMenuItem(title: recentStatusText, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        }

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(title: "开机自启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = store.launchAtLoginEnabled ? .on : .off
        loginItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(loginItem)

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 CloseTargetApp", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func closeTargetApplications() {
        guard !store.targetApplications.isEmpty else {
            recentStatusText = "请先在设置里添加目标应用"
            openSettings()
            rebuildMenu()
            return
        }

        isClosingApplications = true
        recentStatusText = nil
        rebuildMenu()

        Task { @MainActor in
            let result = await TargetApplicationTerminator.close(store.targetApplications)
            recentStatusText = result.summaryText
            isClosingApplications = false
            rebuildMenu()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        store.setLaunchAtLogin(!store.launchAtLoginEnabled)
        recentStatusText = store.launchAtLoginStatusText
        rebuildMenu()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(store: store)
        }

        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
