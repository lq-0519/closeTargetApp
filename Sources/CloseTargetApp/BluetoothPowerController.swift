import Foundation
import Darwin
import CoreBluetooth
import OSLog

/// 蓝牙电源操作边界；状态读取与切换均在主线程之外执行，不枚举或扫描蓝牙设备。
protocol BluetoothPowerControlling: Sendable {
    /// 读取控制器当前电源状态，供失败回滚使用。
    func powerOn() async throws -> Bool
    /// 切换电源并在有限时间内确认；取消任务不能继续发起新的开关写入。
    func setPower(_ enabled: Bool) async throws
}

/// 非公开蓝牙接口缺失或未达到请求状态时的可展示错误。
enum BluetoothPowerError: LocalizedError {
    /// 当前系统没有提供所需接口，不能假装已经关闭蓝牙。
    case unavailable
    /// 控制器没有在确认窗口内达到目标状态。
    case stateNotConfirmed
    /// 首次新增蓝牙能力需要系统授权；拒绝或尚未授权时不能把接口返回的 false 当作真实状态。
    case permissionRequired

    /// 显示兼容性与实际开关失败，不依赖不透明的接口返回码。
    var errorDescription: String? {
        switch self {
        case .unavailable: return "当前系统不支持蓝牙电源控制接口"
        case .stateNotConfirmed: return "未能确认蓝牙开关状态"
        case .permissionRequired: return "请在系统设置中允许 CloseTargetApp 使用蓝牙"
        }
    }
}

/// 使用与 blueutil 相同的 IOBluetooth 电源接口；actor 保持 AppKit 主事件循环可处理系统回调。
actor BluetoothPowerController: BluetoothPowerControlling {
    /// 获取接口的 C 调用约定，不通过 Objective-C 设备对象触发扫描或配对操作。
    private typealias Getter = @convention(c) () -> Int32
    /// 电源写入接口没有返回值，必须随后读回实际状态确认。
    private typealias Setter = @convention(c) (Int32) -> Void
    /// 系统框架句柄在控制器生命周期内保持加载，系统更新缺失符号时安全失败。
    private let framework = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_LAZY)
    /// 只在电源操作发生时记录状态，不使用常驻轮询。
    private let logger = Logger(subsystem: "com.local.CloseTargetApp", category: "Bluetooth")

    /// 动态解析接口，避免非公开符号缺失导致整个菜单栏应用不能启动。
    private func functions() throws -> (Getter, Setter) {
        guard let framework,
              let getter = dlsym(framework, "IOBluetoothPreferenceGetControllerPowerState"),
              let setter = dlsym(framework, "IOBluetoothPreferenceSetControllerPowerState") else {
            throw BluetoothPowerError.unavailable
        }
        return (unsafeBitCast(getter, to: Getter.self), unsafeBitCast(setter, to: Setter.self))
    }

    /// 读取前后均检查取消，避免睡眠处理窗口结束后继续执行迟到的写入。
    func powerOn() async throws -> Bool {
        try Task.checkCancellation()
        let (get, _) = try functions()
        let value = get() != 0
        try Task.checkCancellation()
        guard CBManager.authorization == .allowedAlways else { throw BluetoothPowerError.permissionRequired }
        return value
    }

    /// 后台调用并最多确认五秒；主线程保持运行以处理 CoreBluetooth 初始化和状态回调。
    func setPower(_ enabled: Bool) async throws {
        let (get, set) = try functions()
        let initial = get() != 0
        try Task.checkCancellation()
        guard CBManager.authorization == .allowedAlways else { throw BluetoothPowerError.permissionRequired }
        if initial != enabled { set(enabled ? 1 : 0) }
        for attempt in 0..<26 {
            try Task.checkCancellation()
            if (get() != 0) == enabled {
                logger.info("Bluetooth power=\(enabled)")
                return
            }
            if attempt < 25 { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        throw BluetoothPowerError.stateNotConfirmed
    }
}
