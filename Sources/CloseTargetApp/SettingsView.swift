import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            powerOptions
            Divider()
            applicationList
            Divider()
            footer
        }
        .frame(minWidth: 580, minHeight: 480)
    }

    /// 电源操作的持久化选项；等待时间是上限，无线总开关覆盖软件操作和合盖睡眠。
    private var powerOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Stepper(value: Binding(
                get: { store.terminationTimeoutSeconds },
                set: { store.setTerminationTimeoutSeconds($0) }
            ), in: SettingsStore.terminationTimeoutRange) {
                Text("关闭应用最多等待：\(store.terminationTimeoutSeconds) 秒")
            }
            Text("可设置 1–60 秒；所有目标应用退出后立即继续，超时则取消电源操作。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("睡眠时自动关闭 Wi-Fi 和蓝牙，正常唤醒后打开", isOn: Binding(
                get: { store.managesRadios },
                set: { store.setManagesRadios($0) }
            ))
            Text("适用于软件的睡眠、关机、重启及合盖睡眠。开盖闲置自动睡眠不操作；后台唤醒保持关闭，重启后登录恢复。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("无线恢复后通知", isOn: Binding(
                get: { store.notifiesRadioRecovery },
                set: { store.setNotifiesRadioRecovery($0) }
            ))
            Text(store.recoveryNotificationStatusText.isEmpty
                 ? "Wi-Fi 和蓝牙自动恢复成功后显示一条无声通知。"
                 : store.recoveryNotificationStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("目标应用")
                    .font(.headline)
                Text("\(store.targetApplications.count) 个应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                store.addApplicationFromPanel()
            } label: {
                Label("添加应用", systemImage: "plus")
            }
        }
        .padding(16)
    }

    private var applicationList: some View {
        Group {
            if store.targetApplications.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "app.badge")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("还没有配置目标应用")
                        .font(.headline)
                    Button {
                        store.addApplicationFromPanel()
                    } label: {
                        Label("添加应用", systemImage: "plus")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.targetApplications) { application in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: application.path))
                                .resizable()
                                .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 3) {
                                Text(application.displayName)
                                    .font(.body)
                                Text(application.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Button {
                                store.removeApplication(application)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("移除")
                        }
                        .padding(.vertical, 6)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if let settingsMessage = store.settingsMessage {
                Text(settingsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Toggle(
                    "开机自启动",
                    isOn: Binding(
                        get: { store.launchAtLoginEnabled },
                        set: { store.setLaunchAtLogin($0) }
                    )
                )
                .disabled(store.managesRadios)
                .help(store.managesRadios ? "无线自动恢复需要登录自启动；关闭该功能后可关闭自启动。" : "登录后启动菜单栏应用")
                Text(store.launchAtLoginStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}
