import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            applicationList
            Divider()
            footer
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("一键关闭目标")
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
                Text(store.launchAtLoginStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }
}
