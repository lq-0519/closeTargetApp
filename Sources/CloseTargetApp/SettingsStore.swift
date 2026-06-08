import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var targetApplications: [TargetApplication] = [] {
        didSet {
            saveTargetApplications()
            onChange?()
        }
    }

    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginStatusText = ""
    @Published var settingsMessage: String?

    var onChange: (() -> Void)?

    private let defaults: UserDefaults
    private let targetApplicationsKey = "targetApplications"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.targetApplications = Self.loadTargetApplications(from: defaults, key: targetApplicationsKey)
        refreshLaunchAtLoginStatus()
    }

    func addApplicationFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择要一键关闭的应用"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK else {
            return
        }

        var addedCount = 0
        for url in panel.urls {
            if addApplication(at: url) {
                addedCount += 1
            }
        }

        if addedCount > 0 {
            settingsMessage = "已添加 \(addedCount) 个应用"
        }
    }

    func removeApplication(_ application: TargetApplication) {
        targetApplications.removeAll { $0.id == application.id }
        settingsMessage = "已移除 \(application.displayName)"
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }

            settingsMessage = enabled ? "已开启开机自启动" : "已关闭开机自启动"
        } catch {
            settingsMessage = "开机自启动设置失败：\(error.localizedDescription)"
        }

        refreshLaunchAtLoginStatus()
        onChange?()
    }

    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled

        switch status {
        case .enabled:
            launchAtLoginStatusText = "已开启"
        case .notRegistered:
            launchAtLoginStatusText = "未开启"
        case .requiresApproval:
            launchAtLoginStatusText = "需要在系统设置 > 通用 > 登录项中允许"
        case .notFound:
            launchAtLoginStatusText = "请先打包成 .app 后再开启"
        @unknown default:
            launchAtLoginStatusText = "当前状态未知"
        }
    }

    @discardableResult
    private func addApplication(at url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        let bundle = Bundle(url: standardizedURL)
        let bundleIdentifier = bundle?.bundleIdentifier

        if bundleIdentifier == Bundle.main.bundleIdentifier {
            settingsMessage = "不能把 CloseTargetApp 加入关闭列表"
            return false
        }

        if targetApplications.contains(where: { existing in
            existing.path == standardizedURL.path ||
                (bundleIdentifier != nil && existing.bundleIdentifier == bundleIdentifier)
        }) {
            settingsMessage = "\(displayName(for: standardizedURL, bundle: bundle)) 已在列表中"
            return false
        }

        let application = TargetApplication(
            displayName: displayName(for: standardizedURL, bundle: bundle),
            bundleIdentifier: bundleIdentifier,
            path: standardizedURL.path
        )
        targetApplications.append(application)
        return true
    }

    private func saveTargetApplications() {
        guard let data = try? JSONEncoder().encode(targetApplications) else {
            return
        }

        defaults.set(data, forKey: targetApplicationsKey)
    }

    private static func loadTargetApplications(from defaults: UserDefaults, key: String) -> [TargetApplication] {
        guard
            let data = defaults.data(forKey: key),
            let applications = try? JSONDecoder().decode([TargetApplication].self, from: data)
        else {
            return []
        }

        return applications
    }

    private func displayName(for url: URL, bundle: Bundle?) -> String {
        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, !name.isEmpty {
            return name
        }

        if let name = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String, !name.isEmpty {
            return name
        }

        return url.deletingPathExtension().lastPathComponent
    }
}
