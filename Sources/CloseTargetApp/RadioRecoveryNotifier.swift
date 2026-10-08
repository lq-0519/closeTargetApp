import Foundation
import OSLog
import UserNotifications

/// 发送系统本地恢复通知；只响应配置及恢复事件，不联网、不创建后台计时器。
@MainActor
final class RadioRecoveryNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// 权限及提交失败反馈到设置页，不将通知失败当作无线恢复失败。
    var onStatusChange: ((String) -> Void)?
    /// 点击通知打开已有设置窗口，方便调整通知偏好。
    var onOpenSettings: (() -> Void)?
    /// 用户通知偏好的实时读取入口，异步授权或提交期间关闭也必须生效。
    private let isEnabled: () -> Bool
    /// 系统通知中心复用实例，不注册 APNs 或远程推送。
    private let center = UNUserNotificationCenter.current()
    /// 保存上次偏好，修改其他设置不会重复查询通知权限。
    private var lastPreference: Bool?
    /// 合并首次权限请求；登录恢复可等待它，但不会阻塞设备恢复流程。
    private var authorizationTask: Task<Void, Never>?
    /// 最近处理的恢复任务标识，重复回调不会再次提交同一次恢复通知。
    private var lastRecoveryIdentifier: UUID?
    /// 仅记录权限错误与通知提交结果，不周期性输出日志。
    private let logger = Logger(subsystem: "com.local.CloseTargetApp", category: "RecoveryNotification")

    /// 应用持有本对象以保持系统的弱引用 delegate 有效，前台设置窗口打开时也可展示横幅。
    init(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled
        super.init()
        center.delegate = self
    }

    /// 开启偏好时检查系统权限；未决定才申请 alert，不请求声音、角标或重复弹出拒绝后的授权。
    func updatePreference() {
        let enabled = isEnabled()
        guard lastPreference != enabled else { return }
        lastPreference = enabled
        guard enabled else { onStatusChange?("已关闭无线恢复通知"); return }
        guard authorizationTask == nil else { return }
        authorizationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.authorizationTask = nil }
            do {
                var settings = await self.center.notificationSettings()
                if settings.authorizationStatus == .notDetermined && self.isEnabled() {
                    self.onStatusChange?("请允许 CloseTargetApp 发送通知")
                    _ = try await self.center.requestAuthorization(options: [.alert])
                    settings = await self.center.notificationSettings()
                }
                guard self.isEnabled() else { return }
                self.showAuthorizationStatus(settings)
            } catch {
                if self.isEnabled() { self.onStatusChange?("通知授权失败：\(error.localizedDescription)") }
                self.logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 每次完整自动恢复至多提交一条无声通知；关闭偏好或无权限只跳过通知，不重新请求恢复。
    func notifyRecovery(identifier: UUID) {
        guard isEnabled(), lastRecoveryIdentifier != identifier else { return }
        lastRecoveryIdentifier = identifier
        Task { [weak self] in
            guard let self else { return }
            await self.authorizationTask?.value
            guard self.isEnabled() else { return }
            let settings = await self.center.notificationSettings()
            guard self.isEnabled() else { return }
            self.showAuthorizationStatus(settings)
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "无线已恢复"
            content.body = "Wi-Fi 和蓝牙已自动打开。"
            content.sound = nil
            // 同一任务标识用于系统请求；立即发送，不使用延迟触发器或定时器。
            let request = UNNotificationRequest(identifier: "radio-recovery-\(identifier.uuidString)", content: content, trigger: nil)
            do {
                try await self.center.add(request)
                self.logger.info("Recovery notification submitted id=\(identifier.uuidString, privacy: .public)")
            } catch {
                self.onStatusChange?("恢复已完成，但通知发送失败：\(error.localizedDescription)")
                self.logger.error("Recovery notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 事件发生时展示系统权限状态；系统横幅被关闭时明确给出路径，不主动更改系统偏好。
    private func showAuthorizationStatus(_ settings: UNNotificationSettings) {
        if settings.authorizationStatus == .denied {
            onStatusChange?("通知未获允许；可在系统设置 > 通知 > CloseTargetApp 中开启。")
        } else if settings.authorizationStatus == .notDetermined {
            onStatusChange?("请允许 CloseTargetApp 发送通知")
        } else if settings.alertSetting != .enabled {
            onStatusChange?("系统通知横幅未开启；可在系统设置 > 通知 > CloseTargetApp 中调整。")
        } else {
            onStatusChange?("Wi-Fi 和蓝牙自动恢复成功后显示一条无声通知。")
        }
    }

    /// 应用处于前台时仍展示横幅和通知中心条目，明确不包含 sound 呈现选项。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    /// 只响应用户点击通知的默认动作；系统完成回调及时返回，窗口操作回到主 actor。
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            Task { @MainActor [weak self] in self?.onOpenSettings?() }
        }
        completionHandler()
    }
}
