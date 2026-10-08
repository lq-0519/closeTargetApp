import Foundation
import IOKit
import IOKit.pwr_mgt
import OSLog

/// 只消费合盖状态变化；初始状态、后台唤醒和开盖空闲睡眠都不会制造一次新的合盖请求。
struct LidSleepPolicy {
    /// 最近一次系统报告的物理盖子状态。
    private(set) var closed: Bool
    /// 系统是否把合盖视为睡眠请求，外接显示器继续工作时通常为 false。
    private var causesSleep: Bool
    /// 新的合盖请求只能被一次即将睡眠事件消费，防止维护睡眠重复触发。
    private var pendingClose = false

    /// 启动时读取当前状态作为基线，不把“启动时盖子已关闭”误当作新合盖。
    init(closed: Bool, causesSleep: Bool) {
        self.closed = closed
        self.causesSleep = causesSleep
    }

    /// 物理合盖或关闭外接工作模式才形成请求；开盖立即撤销未进入睡眠的请求。
    mutating func update(closed: Bool, causesSleep: Bool) {
        if closed && causesSleep && (!self.closed || !self.causesSleep) { pendingClose = true }
        if !closed || !causesSleep { pendingClose = false }
        self.closed = closed
        self.causesSleep = causesSleep
    }

    /// 只在有新的合盖请求时接管一次睡眠；总开关关闭也会消费旧请求，避免以后误触发。
    mutating func consumeSleep(enabled: Bool) -> Bool {
        defer { pendingClose = false }
        return enabled && closed && causesSleep && pendingClose
    }
}

/// 监听 IOKit 合盖与电源事件；无定时轮询，睡眠确认由调用方在有界处理后归还系统。
@MainActor
final class SystemSleepMonitor {
    /// 盖子状态变化回调，额外携带“合盖是否导致睡眠”以排除外接显示器工作模式。
    var onLidChange: ((Bool, Bool) -> Void)?
    /// 即将睡眠回调；必须调用给定完成函数，完成函数具有幂等保护。
    var onWillSleep: ((@escaping () -> Void) -> Void)?
    /// 驱动恢复完成时通知恢复协调器，但这个通知本身不代表屏幕亮起。
    var onDidWake: (() -> Void)?
    /// 注册失败时显示状态，不能静默声称合盖自动化可用。
    var onError: ((String) -> Void)?
    /// 电源管理连接，通知确认及退出清理使用同一连接。
    private var powerConnection: io_connect_t = 0
    /// 接收电源通知的端口，回调投递到主队列。
    private var powerPort: IONotificationPortRef?
    /// 电源通知注册令牌。
    private var powerNotifier: io_object_t = 0
    /// 盖子状态通知端口，不使用进程或 shell 轮询。
    private var lidPort: IONotificationPortRef?
    /// IOPMrootDomain 的服务引用。
    private var rootService: io_service_t = 0
    /// 合盖通知注册令牌。
    private var lidNotifier: io_object_t = 0
    /// IOPM.h 合盖通知：sys_iokit | err_sub(13) | 0x100，数值由当前 SDK 验证。
    private static let clamshellStateMessage: UInt32 = 0xe0034100
    /// IOKit/IOMessage.h 的 iokit_common_msg(0x270)，Swift 不能直接导入该函数式宏。
    private static let canSleepMessage: UInt32 = 0xe0000270
    /// 系统即将强制睡眠消息：iokit_common_msg(0x280)。
    private static let willSleepMessage: UInt32 = 0xe0000280
    /// 驱动恢复完成消息：iokit_common_msg(0x300)，不是屏幕亮起通知。
    private static let didWakeMessage: UInt32 = 0xe0000300
    /// 未完成确认的电源请求，停止监听时也必须放行。
    private var acknowledgements: Set<Int> = []
    /// 仅记录通知注册与错误，不持续记录无状态变化的数据。
    private let logger = Logger(subsystem: "com.local.CloseTargetApp", category: "SleepMonitor")

    /// 读取物理盖子及合盖睡眠策略，供启动与恢复时使用；读取失败不猜测合盖状态。
    static func lidState() -> (closed: Bool, causesSleep: Bool)? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let closed = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool,
              let causesSleep = IORegistryEntryCreateCFProperty(service, "AppleClamshellCausesSleep" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool else { return nil }
        return (closed, causesSleep)
    }

    /// 注册两个事件源；任何一步失败都清理已注册的资源并报告功能不可用。
    func start() {
        guard powerConnection == 0 else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        powerConnection = IORegisterForSystemPower(context, &powerPort, { context, _, type, argument in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<SystemSleepMonitor>.fromOpaque(context).takeUnretainedValue().receivePower(type, argument: argument)
            }
        }, &powerNotifier)
        rootService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        lidPort = IONotificationPortCreate(kIOMainPortDefault)
        guard powerConnection != 0, let powerPort, rootService != 0, let lidPort else {
            failRegistration(); return
        }
        IONotificationPortSetDispatchQueue(powerPort, .main)
        IONotificationPortSetDispatchQueue(lidPort, .main)
        let status = IOServiceAddInterestNotification(lidPort, rootService, kIOGeneralInterest, { context, _, type, argument in
            guard let context else { return }
            MainActor.assumeIsolated {
                let monitor = Unmanaged<SystemSleepMonitor>.fromOpaque(context).takeUnretainedValue()
                guard type == SystemSleepMonitor.clamshellStateMessage else { return }
                // 使用该事件自带的两位状态，避免查询当前属性时丢失快速合盖/开盖的先后顺序。
                let bits = UInt(bitPattern: argument)
                monitor.onLidChange?(bits & 1 != 0, bits & 2 != 0)
            }
        }, context, &lidNotifier)
        guard status == KERN_SUCCESS else { failRegistration(); return }
        logger.info("System sleep and lid notifications registered")
    }

    /// 空闲睡眠立即放行；即将睡眠交给协调器；早期唤醒不访问尚未就绪的驱动。
    private func receivePower(_ type: natural_t, argument: UnsafeMutableRawPointer?) {
        let identifier = Int(bitPattern: argument)
        switch type {
        case Self.canSleepMessage:
            IOAllowPowerChange(powerConnection, identifier)
        case Self.willSleepMessage:
            acknowledgements.insert(identifier)
            if let onWillSleep {
                onWillSleep { [weak self] in self?.acknowledge(identifier) }
            } else {
                acknowledge(identifier)
            }
        case Self.didWakeMessage: onDidWake?()
        default: break
        }
    }

    /// 一次请求至多确认一次，避免系统事件和处理超时都完成时重复使用旧通知标识。
    private func acknowledge(_ identifier: Int) {
        guard acknowledgements.remove(identifier) != nil, powerConnection != 0 else { return }
        IOAllowPowerChange(powerConnection, identifier)
    }

    /// 注册失败时撤销所有资源，保持普通系统睡眠正常。
    private func failRegistration() {
        stop()
        onError?("系统睡眠监听注册失败；合盖自动关闭无线功能暂不可用")
    }

    /// 退出或重建监听前放行剩余请求，再释放 IOKit 端口和服务。
    func stop() {
        for identifier in Array(acknowledgements) { acknowledge(identifier) }
        if powerNotifier != 0 { IODeregisterForSystemPower(&powerNotifier); powerNotifier = 0 }
        if powerConnection != 0 { IOServiceClose(powerConnection); powerConnection = 0 }
        if lidNotifier != 0 { IOObjectRelease(lidNotifier); lidNotifier = 0 }
        if rootService != 0 { IOObjectRelease(rootService); rootService = 0 }
        if let powerPort { IONotificationPortDestroy(powerPort); self.powerPort = nil }
        if let lidPort { IONotificationPortDestroy(lidPort); self.lidPort = nil }
    }
}
