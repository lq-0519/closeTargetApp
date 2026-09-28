import AppKit
import CoreGraphics
import Foundation
import OSLog

/// 写在断网之前的恢复凭据；原子保存，确保关机、重启或进程意外退出后仍可恢复。
struct WiFiRecoveryRecord: Codable, Sendable {
    /// 区分连续电源操作，旧异步回调不能清除新操作的恢复凭据。
    let id: UUID
    /// 本次由菜单按钮发起的电源动作，用于日志和恢复判断。
    let action: PowerAction
    /// 本次关闭的无线接口，恢复时使用同一个接口。
    let interfaceName: String
    /// 断网前的状态；请求失败或尚未发送时应还原此状态。
    let originalPowerOn: Bool
    /// 只有在关闭 Wi-Fi 后、即将执行电源命令时才置为 true。
    var requestSent: Bool
    /// 已知失败时持久化回滚意图，避免重开应用后误当成正常唤醒。
    var rollback: Bool

    /// 正常电源操作后按用户要求打开 Wi-Fi；失败则保留操作前的开关状态。
    var restorationPowerOn: Bool {
        requestSent && !rollback ? true : originalPowerOn
    }
}

/// 管理一次菜单电源操作的断网与恢复；只有存在本软件写入的凭据时才会操作 Wi-Fi。
@MainActor
final class WiFiRecoveryCoordinator {
    /// 状态变化传给菜单显示，不通过常驻轮询刷新界面。
    var onStatusChange: ((String) -> Void)?
    /// 异步操作结束后刷新按钮可用性，避免界面停留在“正在处理”的旧状态。
    var onStateChange: (() -> Void)?
    /// 当前待恢复记录；成功打开或回滚后才删除。
    private(set) var pendingRecord: WiFiRecoveryRecord?
    /// 持久化损坏等错误需显式展示；不能悄悄覆盖未知的旧恢复任务。
    private(set) var storageError: String?
    /// 实际网络控制接口，驱动操作在独立 actor 中执行。
    private let controller: any WiFiPowerControlling
    /// 恢复凭据位于 Application Support，不放入应用包或代码仓库。
    private let recordURL: URL
    /// 查询可绘制的亮屏状态；注入入口用于无需实际睡眠的离线验证。
    private let displayIsAwake: () -> Bool
    /// 系统通知令牌，避免重复注册和重复触发恢复。
    private var observers: [NSObjectProtocol] = []
    /// 只有真正观察到睡眠或加载到上次凭据，才允许由唤醒通知触发恢复。
    private var recoveryArmed = false
    /// 本次睡眠后必须收到屏幕唤醒事件，不能仅凭后台系统唤醒时可能滞后的显示状态恢复。
    private var screenWakeObserved = false
    /// 合并重复唤醒通知；最多保留一个有界重试任务。
    private var recoveryTask: Task<Void, Never>?
    /// 单次超时保护：请求后 30 秒仍未观察到睡眠时回滚，不周期性唤醒进程。
    private var requestWatchdog: Task<Void, Never>?
    /// 防止一次断网与恢复并发进行，特别是网络驱动异步返回时。
    private(set) var isBusy = false {
        didSet { onStateChange?() }
    }
    /// 记录状态转换，便于核对实际睡眠、亮屏和 Wi-Fi 开关顺序。
    private let logger = Logger(subsystem: "com.local.CloseTargetApp", category: "WiFiRecovery")

    /// 加载原子恢复记录；默认控制真实 Wi-Fi，测试可注入内存控制器和临时文件。
    init(controller: any WiFiPowerControlling = WiFiPowerController(), recordURL: URL? = nil,
         displayIsAwake: @escaping () -> Bool = WiFiRecoveryCoordinator.hasAwakeDisplay) {
        self.controller = controller
        self.recordURL = recordURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloseTargetApp", isDirectory: true)
            .appendingPathComponent("wifi-recovery.json")
        self.displayIsAwake = displayIsAwake
        do {
            if FileManager.default.fileExists(atPath: self.recordURL.path) {
                pendingRecord = try JSONDecoder().decode(WiFiRecoveryRecord.self, from: Data(contentsOf: self.recordURL))
                recoveryArmed = true
                // 登录或手动重开应用可能发生在亮屏之后，因此启动恢复使用实时显示状态。
                screenWakeObserved = true
            }
        } catch {
            storageError = "读取 Wi-Fi 恢复记录失败：\(error.localizedDescription)"
        }
    }

    /// 应用启动时注册事件，并尝试处理上次记录；没有记录时所有通知都是无操作。
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemWillSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreIfAwake() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidWake() }
        })
        if let storageError { report(storageError) }
        restoreIfAwake()
    }

    /// 退出前撤销事件和短期任务；不会在系统关机期间重新打开 Wi-Fi。
    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        recoveryTask?.cancel()
        requestWatchdog?.cancel()
    }

    /// 先落盘，再关闭 Wi-Fi；调用方须在目标应用全部退出后调用，失败时不能发送电源命令。
    func prepare(for action: PowerAction) async throws {
        guard pendingRecord == nil, storageError == nil, !isBusy else { throw WiFiPowerError.recoveryPending }
        isBusy = true
        defer { isBusy = false }
        let snapshot = try await controller.snapshot()
        let record = WiFiRecoveryRecord(id: UUID(), action: action, interfaceName: snapshot.interfaceName,
            originalPowerOn: snapshot.powerOn, requestSent: false, rollback: false)
        try save(record)
        recoveryArmed = false
        screenWakeObserved = false
        report("正在关闭 Wi-Fi")
        try await controller.setPower(false, interfaceName: record.interfaceName)
        report("Wi-Fi 已关闭")
    }

    /// 在电源命令前持久化恢复意图；不根据子进程退出码假定系统已经睡眠或关机。
    func markRequestSent() throws {
        guard var record = pendingRecord else { return }
        record.requestSent = true
        try save(record)
        let requestID = record.id
        requestWatchdog?.cancel()
        requestWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard let self, self.pendingRecord?.id == requestID, !self.recoveryArmed else { return }
            self.requestWatchdog = nil
            self.report("电源请求后应用仍在运行，正在还原 Wi-Fi")
            await self.rollbackAfterFailure()
        }
    }

    /// 电源或断网失败时恢复原状态；回滚失败仍保留记录供登录或手动恢复重试。
    func rollbackAfterFailure() async {
        requestWatchdog?.cancel()
        guard var record = pendingRecord else { return }
        record.rollback = true
        do {
            try save(record)
        } catch {
            // 内存仍保留回滚意图，立即尝试还原；磁盘错误通过状态和日志保留。
            pendingRecord = record
            report("保存回滚记录失败：\(error.localizedDescription)")
        }
        recoveryArmed = true
        await restore(automatic: false)
    }

    /// 只标记正在进行的菜单操作；普通合盖不会因此新增关闭 Wi-Fi 的行为。
    func systemWillSleep() {
        guard pendingRecord != nil else { return }
        recoveryArmed = true
        screenWakeObserved = false
        requestWatchdog?.cancel()
        recoveryTask?.cancel()
        report("睡眠期间保持 Wi-Fi 关闭")
    }

    /// 系统唤醒加亮屏双重门禁；DarkWake 没有可绘制的亮屏，不创建恢复任务。
    func restoreIfAwake() {
        guard pendingRecord != nil, recoveryArmed, screenWakeObserved, displayIsAwake(), recoveryTask == nil, !isBusy else { return }
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.restore(automatic: true)
            self.recoveryTask = nil
            // 新的亮屏事件可能在旧任务取消收尾期间到达；完成收尾后再检查一次，避免漏恢复。
            if Task.isCancelled { self.restoreIfAwake() }
        }
    }

    /// 屏幕唤醒是正常恢复的必要事件；锁屏也可恢复联网，不要求先输入解锁密码。
    func screensDidWake() {
        screenWakeObserved = true
        restoreIfAwake()
    }

    /// 用户显式点击“恢复 Wi-Fi”时重试待处理任务；成功前不会删除凭据。
    func restoreManually() async {
        requestWatchdog?.cancel()
        recoveryArmed = true
        await restore(automatic: false)
    }

    /// 最多三次恢复，间隔 1 秒和 2 秒；重复事件合并，失败后等待新的事件或用户操作。
    private func restore(automatic: Bool) async {
        guard let record = pendingRecord, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        for attempt in 0..<3 {
            if automatic && (Task.isCancelled || !screenWakeObserved || !displayIsAwake()) { return }
            do {
                try await controller.setPower(record.restorationPowerOn, interfaceName: record.interfaceName)
                if automatic && (Task.isCancelled || !screenWakeObserved || !displayIsAwake()) {
                    // 恢复过程中再次睡眠时把 Wi-Fi 关回去，继续保留下一次亮屏恢复的记录。
                    try await controller.setPower(false, interfaceName: record.interfaceName)
                    return
                }
                guard pendingRecord?.id == record.id else { return }
                try FileManager.default.removeItem(at: recordURL)
                pendingRecord = nil
                storageError = nil
                recoveryArmed = false
                requestWatchdog?.cancel()
                report(record.restorationPowerOn ? "Wi-Fi 已打开" : "已还原 Wi-Fi 关闭状态")
                return
            } catch {
                report("Wi-Fi 恢复失败（\(attempt + 1)/3）：\(error.localizedDescription)")
                if attempt < 2 {
                    do { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) }
                    catch { return }
                }
            }
        }
    }

    /// 小型 JSON 文件通过原子替换持久化；写入失败时禁止继续断网或发送电源请求。
    private func save(_ record: WiFiRecoveryRecord) throws {
        try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        pendingRecord = record
    }

    /// 合并菜单状态和统一日志输出；只在动作发生时记录，不做周期性日志。
    private func report(_ message: String) {
        logger.info("\(message, privacy: .public)")
        onStatusChange?(message)
    }

    /// 检查所有在线显示器，兼容合盖外接显示器；无亮屏时按后台唤醒处理。
    nonisolated static func hasAwakeDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0 }
    }
}
