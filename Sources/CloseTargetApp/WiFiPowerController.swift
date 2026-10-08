import CoreWLAN
import Foundation
import OSLog

/// 一次操作取得的无线接口快照；不读取 SSID、密码或扫描附近网络。
struct WiFiPowerSnapshot: Sendable {
    /// 系统返回的接口名，用于恢复同一接口，不假定设备始终叫 en0。
    let interfaceName: String
    /// 操作前的电源状态，用于电源请求失败时还原现场。
    let powerOn: Bool
}

/// Wi-Fi 电源操作边界；异步接口使驱动调用不阻塞主线程，也允许离线验证恢复流程。
protocol WiFiPowerControlling: Sendable {
    /// 获取默认无线接口及其当前开关状态。
    func snapshot() async throws -> WiFiPowerSnapshot
    /// 设置指定接口的电源状态，并确认驱动读回的状态一致。
    func setPower(_ enabled: Bool, interfaceName: String) async throws
}

/// Wi-Fi 功能的可展示错误；失败会中止按钮操作或保留恢复任务，避免静默丢失状态。
enum WiFiPowerError: LocalizedError {
    /// 默认无线接口不存在或暂时尚未就绪。
    case interfaceUnavailable
    /// 驱动接受请求后仍未达到目标状态。
    case stateNotConfirmed
    /// 上次恢复任务尚未完成，不能覆盖它发起新的电源操作。
    case recoveryPending

    /// 将接口不可用、状态不一致和未完成恢复转换为菜单可读的提示。
    var errorDescription: String? {
        switch self {
        case .interfaceUnavailable: return "Wi-Fi 接口暂不可用"
        case .stateNotConfirmed: return "未能确认 Wi-Fi 开关状态"
        case .recoveryPending: return "上次无线恢复尚未完成，请先点击“恢复 Wi-Fi 和蓝牙”"
        }
    }
}

/// 在独立 actor 上调用 CoreWLAN；复用系统单例，空闲时不扫描、不计时、不查询网络。
actor WiFiPowerController: WiFiPowerControlling {
    /// CoreWLAN 客户端较重，整个控制器生命周期只复用一个实例。
    private let client = CWWiFiClient.shared()
    /// 仅记录开关动作和失败，不记录无线网络名称或凭据。
    private let logger = Logger(subsystem: "com.local.CloseTargetApp", category: "WiFi")

    /// 动态获取默认接口；只读取电源状态，不申请网络扫描权限。
    func snapshot() async throws -> WiFiPowerSnapshot {
        try Task.checkCancellation()
        guard let interface = client.interface(), let name = interface.interfaceName else {
            throw WiFiPowerError.interfaceUnavailable
        }
        let enabled = interface.powerOn()
        try Task.checkCancellation()
        return WiFiPowerSnapshot(interfaceName: name, powerOn: enabled)
    }

    /// 切换接口电源并在最多一秒内读回确认；这些短期检查只发生在用户操作或恢复时。
    func setPower(_ enabled: Bool, interfaceName: String) async throws {
        try Task.checkCancellation()
        guard let interface = client.interface(withName: interfaceName) else {
            throw WiFiPowerError.interfaceUnavailable
        }
        do {
            let initial = interface.powerOn()
            try Task.checkCancellation()
            if initial != enabled {
                try interface.setPower(enabled)
            }
            for attempt in 0..<6 {
                try Task.checkCancellation()
                if interface.powerOn() == enabled {
                    logger.info("Wi-Fi interface=\(interfaceName, privacy: .public) power=\(enabled)")
                    return
                }
                if attempt < 5 {
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            throw WiFiPowerError.stateNotConfirmed
        } catch {
            logger.error("Wi-Fi power=\(enabled) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
