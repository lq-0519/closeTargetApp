import AppKit
import Foundation

struct CloseTargetApplicationsResult {
    let requestedApplications: [String]
    let notRunningApplications: [String]
    let stillRunningApplications: [String]

    var summaryText: String {
        if requestedApplications.isEmpty {
            return "没有目标应用正在运行"
        }

        if stillRunningApplications.isEmpty {
            return "已强制关闭：\(requestedApplications.joined(separator: "、"))"
        }

        return "强制退出失败，已取消电源操作：\(stillRunningApplications.joined(separator: "、"))"
    }
}

@MainActor
enum TargetApplicationTerminator {
    /// 强制退出请求发出后等待目标应用完全退出的最长时间。
    ///
    /// `NSRunningApplication.forceTerminate()` 只表示系统接受了强制退出请求，并不保证
    /// 方法返回时进程已经消失，因此必须在执行睡眠、关机或重启前继续确认运行状态。
    private static let forceTerminationTimeout: TimeInterval = 5

    /// 等待强制退出完成时的轮询间隔，较短间隔可以减少所有应用退出后的额外等待时间。
    private static let forceTerminationPollingIntervalNanoseconds: UInt64 = 100_000_000

    /// 强制退出当前正在运行的目标应用，并等待这些应用从系统运行列表中消失。
    ///
    /// - Parameter applications: 用户配置的目标应用列表。
    /// - Returns: 强制退出请求、原本未运行的应用，以及等待超时后仍在运行的应用汇总。
    static func close(_ applications: [TargetApplication]) async -> CloseTargetApplicationsResult {
        var requestedApplications: [String] = []
        var notRunningApplications: [String] = []
        var runningApplicationsByTarget: [(TargetApplication, [NSRunningApplication])] = []

        for application in applications {
            let runningApplications = findRunningApplications(for: application)
            if runningApplications.isEmpty {
                notRunningApplications.append(application.displayName)
            } else {
                requestedApplications.append(application.displayName)
                runningApplicationsByTarget.append((application, runningApplications))
            }
        }

        for (_, runningApplications) in runningApplicationsByTarget {
            for runningApplication in runningApplications where !runningApplication.isTerminated {
                _ = runningApplication.forceTerminate()
            }
        }

        let requestedTargets = runningApplicationsByTarget.map { $0.0 }
        let stillRunningApplications = await waitForApplicationsToTerminate(requestedTargets)

        return CloseTargetApplicationsResult(
            requestedApplications: requestedApplications,
            notRunningApplications: notRunningApplications,
            stillRunningApplications: stillRunningApplications
        )
    }

    /// 持续按 Bundle ID 和应用路径重新查询运行状态，避免只检查旧 PID 而漏掉自动拉起的新进程。
    ///
    /// - Parameter applications: 已经发送强制退出请求的目标应用。
    /// - Returns: 全部退出时返回空数组；超时则返回仍在运行的目标应用名称。
    private static func waitForApplicationsToTerminate(_ applications: [TargetApplication]) async -> [String] {
        let deadline = Date().addingTimeInterval(forceTerminationTimeout)

        while true {
            let stillRunningApplications = applications.compactMap { application in
                findRunningApplications(for: application).isEmpty ? nil : application.displayName
            }

            if stillRunningApplications.isEmpty || Date() >= deadline {
                return stillRunningApplications
            }

            try? await Task.sleep(nanoseconds: forceTerminationPollingIntervalNanoseconds)
        }
    }

    private static func findRunningApplications(for target: TargetApplication) -> [NSRunningApplication] {
        var matches: [NSRunningApplication] = []

        if let bundleIdentifier = target.bundleIdentifier, !bundleIdentifier.isEmpty {
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier) {
                append(application, to: &matches)
            }
        }

        let targetURL = URL(fileURLWithPath: target.path).standardizedFileURL
        for application in NSWorkspace.shared.runningApplications {
            guard let bundleURL = application.bundleURL?.standardizedFileURL else {
                continue
            }

            if bundleURL == targetURL {
                append(application, to: &matches)
            }
        }

        return matches
    }

    private static func append(_ application: NSRunningApplication, to applications: inout [NSRunningApplication]) {
        guard !applications.contains(where: { $0.processIdentifier == application.processIdentifier }) else {
            return
        }

        applications.append(application)
    }
}
