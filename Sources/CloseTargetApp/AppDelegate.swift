import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private var statusItem: NSStatusItem?
    private var settingsWindowController: SettingsWindowController?
    private var recentStatusText: String?
    private var activePowerAction: PowerAction?
    /// 与恢复凭据无关的命令发送标记，关闭总开关时也能识别软件自身的睡眠请求。
    private var powerCommandIssued = false
    /// 系统在关闭应用或无线设备期间抢先睡眠时，取消未发出的软件电源请求。
    private var powerActionTask: Task<Void, Never>?
    /// 双无线恢复与事件监听同生命周期，处理软件操作与合盖，不常驻轮询。
    private lazy var radioRecovery = RadioRecoveryCoordinator(isEnabled: { [weak store] in store?.managesRadios ?? false })
    /// 系统本地通知与应用同生命周期；通知偏好实时检查，发送过程不阻塞无线恢复。
    private lazy var recoveryNotifications = RadioRecoveryNotifier(isEnabled: { [weak store] in store?.notifiesRadioRecovery ?? false })

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.onChange = { [weak self] in
            self?.radioRecovery.initializeIfEnabled()
            self?.recoveryNotifications.updatePreference()
            self?.rebuildMenu()
        }

        configureStatusItem()
        recoveryNotifications.onStatusChange = { [weak store] in store?.recoveryNotificationStatusText = $0 }
        recoveryNotifications.onOpenSettings = { [weak self] in self?.openSettings() }
        recoveryNotifications.updatePreference()
        radioRecovery.onStatusChange = { [weak self] message in
            self?.recentStatusText = message
            self?.rebuildMenu()
        }
        radioRecovery.onStateChange = { [weak self] in self?.rebuildMenu() }
        radioRecovery.onAutomaticRecoveryComplete = { [weak self] in self?.recoveryNotifications.notifyRecovery(identifier: $0) }
        radioRecovery.onUnrequestedSleep = { [weak self] in
            guard let self, !self.powerCommandIssued else { return nil }
            self.powerActionTask?.cancel()
            return self.powerActionTask
        }
        store.ensureRecoveryLaunchAtLogin()
        radioRecovery.start()
        rebuildMenu()
    }

    /// 系统关机时仅撤销监听，保留磁盘凭据给下次登录，不在退出回调中重新打开无线设备。
    func applicationWillTerminate(_ notification: Notification) {
        powerActionTask?.cancel()
        radioRecovery.stop()
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
            item.isEnabled = activePowerAction == nil && !radioRecovery.isBusy && radioRecovery.pendingRecord == nil
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

        if radioRecovery.pendingRecord != nil {
            let restoreItem = NSMenuItem(title: "恢复 Wi-Fi 和蓝牙", action: #selector(restoreRadios), keyEquivalent: "")
            restoreItem.target = self
            restoreItem.isEnabled = activePowerAction == nil && !radioRecovery.isBusy
            menu.addItem(restoreItem)
        }

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(title: "开机自启动", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = store.launchAtLoginEnabled ? .on : .off
        loginItem.isEnabled = !store.managesRadios
        loginItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        menu.addItem(loginItem)

        let settingsItem = NSMenuItem(title: "设置...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 CloseTargetApp", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.isEnabled = activePowerAction == nil && !radioRecovery.isBusy
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func performPowerActionFromMenu(_ sender: NSMenuItem) {
        guard
            activePowerAction == nil, !radioRecovery.isBusy, radioRecovery.pendingRecord == nil,
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
        let managesRadios = store.managesRadios
        if managesRadios {
            if let error = radioRecovery.storageError {
                recentStatusText = error
                rebuildMenu()
                return
            }
            store.refreshLaunchAtLoginStatus()
            if action != .sleep && !store.launchAtLoginEnabled {
                recentStatusText = "请先在系统登录项中允许 CloseTargetApp 自启动，以便恢复 Wi-Fi 和蓝牙"
                rebuildMenu()
                return
            }
        }
        activePowerAction = action
        powerCommandIssued = false
        recentStatusText = nil
        rebuildMenu()

        powerActionTask = Task { @MainActor in
            defer {
                activePowerAction = nil
                powerCommandIssued = false
                powerActionTask = nil
                rebuildMenu()
            }
            do {
                try Task.checkCancellation()
                if store.targetApplications.isEmpty {
                    recentStatusText = "没有配置目标应用，直接执行\(action.shortTitle)"
                } else {
                    let result = await TargetApplicationTerminator.close(store.targetApplications, timeoutSeconds: timeoutSeconds)
                    try Task.checkCancellation()
                    recentStatusText = result.summaryText
                    guard result.stillRunningApplications.isEmpty else { return }
                }
                try Task.checkCancellation()
                if managesRadios {
                    try await radioRecovery.prepare(for: action)
                    try Task.checkCancellation()
                    try radioRecovery.markRequestSent()
                }
                try Task.checkCancellation()
                powerCommandIssued = true
                try await PowerActionExecutor.perform(action)
                recentStatusText = "已发送\(action.title)请求"
            } catch {
                if Task.isCancelled {
                    // 已经由系统睡眠接管，不能回滚开网或在开盖后补发软件睡眠命令。
                    recentStatusText = "系统已进入睡眠，已取消尚未发送的软件电源操作"
                    return
                }
                let failure = "\(action.title)失败：\(error.localizedDescription)"
                if managesRadios { await radioRecovery.rollbackAfterFailure() }
                recentStatusText = failure + (radioRecovery.pendingRecord == nil ? "" : "；请点击“恢复 Wi-Fi 和蓝牙”重试")
            }
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
        guard activePowerAction == nil, !radioRecovery.isBusy else { return }
        Task { @MainActor in
            if radioRecovery.pendingRecord != nil {
                await radioRecovery.restoreManually()
                guard radioRecovery.pendingRecord == nil else { return }
            }
            NSApp.terminate(nil)
        }
    }

    /// 用户主动重试恢复失败的无线设备；失败时保留菜单入口和持久化凭据。
    @objc private func restoreRadios() {
        Task { @MainActor in
            await radioRecovery.restoreManually()
            rebuildMenu()
        }
    }
}
