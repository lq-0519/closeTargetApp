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
            return "已发送关闭请求：\(requestedApplications.joined(separator: "、"))"
        }

        return "部分应用仍在运行：\(stillRunningApplications.joined(separator: "、"))"
    }
}

@MainActor
enum TargetApplicationTerminator {
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
                runningApplication.terminate()
            }
        }

        try? await Task.sleep(nanoseconds: 1_200_000_000)

        var stillRunningApplications: [String] = []
        for (target, runningApplications) in runningApplicationsByTarget {
            if runningApplications.contains(where: { !$0.isTerminated }) {
                stillRunningApplications.append(target.displayName)
            }
        }

        return CloseTargetApplicationsResult(
            requestedApplications: requestedApplications,
            notRunningApplications: notRunningApplications,
            stillRunningApplications: stillRunningApplications
        )
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
