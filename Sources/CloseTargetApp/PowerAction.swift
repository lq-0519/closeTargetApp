import Foundation

enum PowerAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case sleep
    case shutDown
    case restart

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .sleep:
            return "睡眠"
        case .shutDown:
            return "关机"
        case .restart:
            return "重启"
        }
    }

    var shortTitle: String {
        switch self {
        case .sleep:
            return "睡眠"
        case .shutDown:
            return "关机"
        case .restart:
            return "重启"
        }
    }

    var systemImageName: String {
        switch self {
        case .sleep:
            return "moon"
        case .shutDown:
            return "power"
        case .restart:
            return "arrow.clockwise"
        }
    }

    fileprivate var command: PowerActionCommand {
        switch self {
        case .sleep:
            return PowerActionCommand(path: "/usr/bin/pmset", arguments: ["sleepnow"])
        case .shutDown:
            return PowerActionCommand(
                path: "/usr/bin/osascript",
                arguments: ["-e", #"tell application "System Events" to shut down"#]
            )
        case .restart:
            return PowerActionCommand(
                path: "/usr/bin/osascript",
                arguments: ["-e", #"tell application "System Events" to restart"#]
            )
        }
    }
}

struct PowerActionCommand: Sendable {
    let path: String
    let arguments: [String]
}

enum PowerActionError: LocalizedError {
    case commandFailed(action: PowerAction, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(action, status, output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "\(action.title)命令退出码：\(status)"
            }

            return detail
        }
    }
}

enum PowerActionExecutor {
    static func perform(_ action: PowerAction) async throws {
        let command = action.command

        try await Task.detached(priority: .userInitiated) {
            try run(command, for: action)
        }.value
    }

    private static func run(_ command: PowerActionCommand, for action: PowerAction) throws {
        let process = Process()
        let outputPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: command.path)
        process.arguments = command.arguments
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        process.waitUntilExit()

        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw PowerActionError.commandFailed(
                action: action,
                status: process.terminationStatus,
                output: output
            )
        }
    }
}
