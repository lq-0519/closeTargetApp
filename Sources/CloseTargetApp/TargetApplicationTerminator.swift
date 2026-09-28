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
    /// 仅在用户发起退出操作后每 250ms 检查一次进程；空闲时不轮询。
    private static let forceTerminationPollingIntervalNanoseconds: UInt64 = 250_000_000

    /// 强制退出当前正在运行的目标应用，并等待这些应用从系统运行列表中消失。
    ///
    /// - Parameters:
    ///   - applications: 用户配置的目标应用列表。
    ///   - timeoutSeconds: 本次操作开始时取得的最长等待秒数，进程提前退出会立即继续。
    /// - Returns: 强制退出请求、原本未运行的应用，以及等待超时后仍在运行的应用汇总。
    static func close(_ applications: [TargetApplication], timeoutSeconds: Int) async -> CloseTargetApplicationsResult {
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
        let stillRunningApplications = await waitForApplicationsToTerminate(requestedTargets, timeoutSeconds: timeoutSeconds)

        return CloseTargetApplicationsResult(
            requestedApplications: requestedApplications,
            notRunningApplications: notRunningApplications,
            stillRunningApplications: stillRunningApplications
        )
    }

    /// 持续按 Bundle ID 和应用路径重新查询运行状态，避免只检查旧 PID 而漏掉自动拉起的新进程。
    ///
    /// - Parameters:
    ///   - applications: 已经发送强制退出请求的目标应用。
    ///   - timeoutSeconds: 最长等待秒数；使用单调时钟，系统时间校准不会延长等待。
    /// - Returns: 全部退出时返回空数组；超时则返回仍在运行的目标应用名称。
    private static func waitForApplicationsToTerminate(_ applications: [TargetApplication], timeoutSeconds: Int) async -> [String] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))

        while true {
            let stillRunningApplications = applications.compactMap { application in
                findRunningApplications(for: application).isEmpty ? nil : application.displayName
            }

            if stillRunningApplications.isEmpty || clock.now >= deadline || Task.isCancelled {
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
