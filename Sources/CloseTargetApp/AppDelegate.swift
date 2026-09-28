import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?
    private var recentStatusText: String?
    private var activePowerAction: PowerAction?
    /// Wi-Fi 恢复与窗口同生命周期；只处理本软件发起的操作，不常驻轮询系统状态。
    private let wifiRecovery = WiFiRecoveryCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.onChange = { [weak self] in
            self?.rebuildMenu()
        }

        configureStatusItem()
        wifiRecovery.onStatusChange = { [weak self] message in
            self?.recentStatusText = message
            self?.rebuildMenu()
        }
        wifiRecovery.onStateChange = { [weak self] in self?.rebuildMenu() }
        store.ensureRecoveryLaunchAtLogin()
        wifiRecovery.start()
        rebuildMenu()
    }

    /// 系统关机时仅撤销监听，保留磁盘凭据给下次登录，不在退出回调中重新打开 Wi-Fi。
    func applicationWillTerminate(_ notification: Notification) {
        wifiRecovery.stop()
    }

    /// 用户从访达再次打开菜单栏应用时显示设置；登录自启动仍保持安静，不弹窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
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

        for action in PowerAction.allCases {
            let item = NSMenuItem(
                title: activePowerAction == action ? "正在\(action.shortTitle)..." : action.shortTitle,
                action: #selector(performPowerActionFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = action.rawValue
            item.isEnabled = activePowerAction == nil && !wifiRecovery.isBusy && wifiRecovery.pendingRecord == nil
            item.image = NSImage(systemSymbolName: action.systemImageName, accessibilityDescription: nil)
            menu.addItem(item)
        }

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

        if wifiRecovery.pendingRecord != nil {
            let restoreItem = NSMenuItem(title: "恢复 Wi-Fi", action: #selector(restoreWiFi), keyEquivalent: "")
            restoreItem.target = self
            restoreItem.isEnabled = activePowerAction == nil && !wifiRecovery.isBusy
            menu.addItem(restoreItem)
        }

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(title: "开机自启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = store.launchAtLoginEnabled ? .on : .off
        loginItem.isEnabled = !store.managesWiFi
        loginItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(loginItem)

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 CloseTargetApp", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = activePowerAction == nil && !wifiRecovery.isBusy
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func performPowerActionFromMenu(_ sender: NSMenuItem) {
        guard
            activePowerAction == nil, !wifiRecovery.isBusy, wifiRecovery.pendingRecord == nil,
            let rawValue = sender.representedObject as? String,
            let action = PowerAction(rawValue: rawValue)
        else {
            return
        }

        closeTargetsThenPerform(action)
    }

    private func closeTargetsThenPerform(_ action: PowerAction) {
        // 固定本次选项，等待期间修改设置只影响下一次操作。
        let timeoutSeconds = store.terminationTimeoutSeconds
        let managesWiFi = store.managesWiFi
        if managesWiFi {
            if let error = wifiRecovery.storageError {
                recentStatusText = error
                rebuildMenu()
                return
            }
            store.refreshLaunchAtLoginStatus()
            if action != .sleep && !store.launchAtLoginEnabled {
                recentStatusText = "请先在系统登录项中允许 CloseTargetApp 自启动，以便恢复 Wi-Fi"
                rebuildMenu()
                return
            }
        }
        activePowerAction = action
        recentStatusText = nil
        rebuildMenu()

        Task { @MainActor in
            if store.targetApplications.isEmpty {
                recentStatusText = "没有配置目标应用，直接执行\(action.shortTitle)"
            } else {
                let result = await TargetApplicationTerminator.close(store.targetApplications, timeoutSeconds: timeoutSeconds)
                recentStatusText = result.summaryText

                guard result.stillRunningApplications.isEmpty else {
                    activePowerAction = nil
                    rebuildMenu()
                    return
                }
            }

            do {
                if managesWiFi {
                    try await wifiRecovery.prepare(for: action)
                    try wifiRecovery.markRequestSent()
                }
                try await PowerActionExecutor.perform(action)
                recentStatusText = "已发送\(action.title)请求"
            } catch {
                let failure = "\(action.title)失败：\(error.localizedDescription)"
                if managesWiFi { await wifiRecovery.rollbackAfterFailure() }
                recentStatusText = failure + (wifiRecovery.pendingRecord == nil ? "" : "；请点击“恢复 Wi-Fi”重试")
            }

            activePowerAction = nil
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
        guard activePowerAction == nil, !wifiRecovery.isBusy else { return }
        Task { @MainActor in
            if wifiRecovery.pendingRecord != nil {
                await wifiRecovery.restoreManually()
                guard wifiRecovery.pendingRecord == nil else { return }
            }
            NSApp.terminate(nil)
        }
    }

    /// 用户主动重试恢复失败的 Wi-Fi；失败时保留菜单入口和持久化凭据。
    @objc private func restoreWiFi() {
        Task { @MainActor in
            await wifiRecovery.restoreManually()
            rebuildMenu()
        }
    }
}
