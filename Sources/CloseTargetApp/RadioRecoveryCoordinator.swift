import AppKit
import CoreGraphics
import Foundation
import OSLog

/// 一次无线管理的明确来源；合盖恢复要求开盖，软件操作兼容外接显示器唤醒。
enum RadioSleepTrigger: String, Codable, Sendable {
    /// 软件菜单的睡眠、关机或重启按钮。
    case software
    /// 系统确认由新合盖状态变化引起的睡眠。
    case lid
}

/// 断网前原子保存的恢复凭据；沿用旧文件与字段，兼容升级前仅管理 Wi-Fi 的记录。
struct RadioRecoveryRecord: Codable, Sendable {
    /// 区分连续动作，防止旧异步任务清除新记录。
    let id: UUID
    /// 软件电源动作；合盖也按 sleep 保存。
    let action: PowerAction
    /// 动作来源决定是否必须开盖才能正常恢复。
    var trigger: RadioSleepTrigger
    /// 本次 Wi-Fi 接口名，不假定接口始终为 en0。
    let interfaceName: String
    /// 旧版本字段名称保留；失败时恢复原有 Wi-Fi 状态。
    let originalPowerOn: Bool
    /// 旧记录为 nil，升级恢复时不会意外操作从未关闭的蓝牙。
    let originalBluetoothPowerOn: Bool?
    /// 已发出电源请求；合盖在系统即将睡眠时直接置为 true。
    var requestSent: Bool
    /// 明确失败后还原原状态，正常唤醒则按用户要求打开。
    var rollback: Bool
    /// 两个设备独立保存完成状态，一个失败不会使另一个的进度丢失。
    var wifiPending: Bool
    /// 蓝牙待恢复标记；旧 Wi-Fi 记录默认为 false。
    var bluetoothPending: Bool

    /// 使用原字段名序列化，旧版本未完成的任务也可直接解码。
    private enum CodingKeys: String, CodingKey {
        case id, action, trigger, interfaceName, originalPowerOn, originalBluetoothPowerOn
        case requestSent, rollback, wifiPending, bluetoothPending
    }

    /// 创建新的双无线恢复任务，在实际关闭设备前完成落盘。
    init(action: PowerAction, trigger: RadioSleepTrigger, wifi: WiFiPowerSnapshot, bluetooth: Bool) {
        id = UUID(); self.action = action; self.trigger = trigger
        interfaceName = wifi.interfaceName; originalPowerOn = wifi.powerOn
        originalBluetoothPowerOn = bluetooth; requestSent = trigger == .lid; rollback = false
        wifiPending = true; bluetoothPending = true
    }

    /// 对新增字段使用明确的旧版本默认值，保留原恢复意图且不新增蓝牙动作。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        action = try values.decode(PowerAction.self, forKey: .action)
        trigger = try values.decodeIfPresent(RadioSleepTrigger.self, forKey: .trigger) ?? .software
        interfaceName = try values.decode(String.self, forKey: .interfaceName)
        originalPowerOn = try values.decode(Bool.self, forKey: .originalPowerOn)
        originalBluetoothPowerOn = try values.decodeIfPresent(Bool.self, forKey: .originalBluetoothPowerOn)
        requestSent = try values.decode(Bool.self, forKey: .requestSent)
        rollback = try values.decode(Bool.self, forKey: .rollback)
        wifiPending = try values.decodeIfPresent(Bool.self, forKey: .wifiPending) ?? true
        bluetoothPending = try values.decodeIfPresent(Bool.self, forKey: .bluetoothPending) ?? (originalBluetoothPowerOn != nil)
    }

    /// 正常唤醒打开 Wi-Fi；失败或未发出请求时保持用户原来的状态。
    var wifiRestorationPower: Bool { requestSent && !rollback ? true : originalPowerOn }
    /// 正常唤醒打开蓝牙；旧记录的 nil 状态不会被调用方恢复。
    var bluetoothRestorationPower: Bool { requestSent && !rollback ? true : (originalBluetoothPowerOn ?? false) }
}

/// 管理软件电源操作和合盖睡眠的无线关闭与恢复；开盖空闲睡眠没有恢复凭据，因此无开关动作。
@MainActor
final class RadioRecoveryCoordinator {
    /// 状态文本供设置与菜单展示，仅在事件发生时更新。
    var onStatusChange: ((String) -> Void)?
    /// 忙碌状态或待恢复记录变化时刷新菜单可用性。
    var onStateChange: (() -> Void)?
    /// 两项无线均自动恢复并清除凭据后调用一次；手动恢复、回滚和旧 Wi-Fi 单项记录不调用。
    var onAutomaticRecoveryComplete: ((UUID) -> Void)?
    /// 系统抢先睡眠时取消尚未发送的软件电源动作；返回任务供合盖关闭等待其退出。
    var onUnrequestedSleep: (() -> Task<Void, Never>?)?
    /// 成功恢复两个设备后才移除持久化记录。
    private(set) var pendingRecord: RadioRecoveryRecord?
    /// 损坏凭据不能被新任务静默覆盖。
    private(set) var storageError: String?
    /// 状态切换期间禁止并发按钮操作。
    private(set) var isBusy = false { didSet { onStateChange?() } }
    /// Wi-Fi 与蓝牙分别在独立 actor 中调用驱动。
    private let wifi: any WiFiPowerControlling
    /// 蓝牙控制接口可注入离线验证替身。
    private let bluetooth: any BluetoothPowerControlling
    /// 总开关实时查询入口，关闭总开关不阻断已存在的恢复任务。
    private let isEnabled: () -> Bool
    /// 仅检查显示器是否正常亮起，不扫描网络。
    private let displayIsAwake: () -> Bool
    /// 原子保存到原有 Application Support 文件，保持升级兼容。
    private let recordURL: URL
    /// 消费物理合盖边沿，排除闲置睡眠与后台维护睡眠。
    private var lidPolicy: LidSleepPolicy
    /// IOKit 事件源与整个协调器同生命周期。
    private let monitor = SystemSleepMonitor()
    /// AppKit 屏幕和唤醒通知令牌。
    private var observers: [NSObjectProtocol] = []
    /// 必须观察到真正睡眠或加载旧凭据，才能由正常唤醒恢复。
    private var recoveryArmed = false
    /// 新睡眠清除该标记，后台唤醒即使显示状态滞后也不能恢复。
    private var screenWakeObserved = false
    /// 合并正常唤醒通知，仅保留一个恢复任务。
    private var recoveryTask: Task<Void, Never>?
    /// 合盖睡眠前的短期关闭任务，可因时间预算用尽取消。
    private var preparationTask: Task<Void, Never>?
    /// 合盖关闭的处理预算，默认八秒；离线验证可注入短预算覆盖超时和迟到回调。
    private let preparationBudgetNanoseconds: UInt64
    /// 合盖关闭最多延迟睡眠八秒，绝不等待系统默认三十秒超时。
    private var preparationTimeout: Task<Void, Never>?
    /// 软件请求后没有实际睡眠时的一次性回滚保护。
    private var requestWatchdog: Task<Void, Never>?
    /// 开启功能时只初始化一次蓝牙接口，避免第一次合盖才等待新增的系统授权。
    private var initializationTask: Task<Void, Never>?
    /// 已完成初始化后设置其他选项不再读取控制器；不创建常驻轮询。
    private var bluetoothInitialized = false
    /// 用于记录动作来源、关闭失败与独立恢复结果。
    private let logger = Logger(subsystem: "com.local.CloseTargetApp", category: "RadioRecovery")

    /// 默认使用真实控制器；状态和文件可注入，验证流程不需要实际睡眠或断网。
    init(wifi: any WiFiPowerControlling = WiFiPowerController(),
         bluetooth: any BluetoothPowerControlling = BluetoothPowerController(),
         recordURL: URL? = nil, isEnabled: @escaping () -> Bool = { true },
         initialLidState: (closed: Bool, causesSleep: Bool)? = nil,
         preparationBudgetNanoseconds: UInt64 = 8_000_000_000,
         displayIsAwake: @escaping () -> Bool = RadioRecoveryCoordinator.hasAwakeDisplay) {
        self.wifi = wifi; self.bluetooth = bluetooth; self.isEnabled = isEnabled
        self.recordURL = recordURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloseTargetApp/wifi-recovery.json")
        self.displayIsAwake = displayIsAwake
        self.preparationBudgetNanoseconds = preparationBudgetNanoseconds
        let state = initialLidState ?? SystemSleepMonitor.lidState() ?? (false, false)
        lidPolicy = LidSleepPolicy(closed: state.closed, causesSleep: state.causesSleep)
        do {
            if FileManager.default.fileExists(atPath: self.recordURL.path) {
                pendingRecord = try JSONDecoder().decode(RadioRecoveryRecord.self, from: Data(contentsOf: self.recordURL))
                recoveryArmed = true; screenWakeObserved = true
            }
        } catch { storageError = "读取无线恢复记录失败：\(error.localizedDescription)" }
    }

    /// 注册事件而非常驻计时器；普通启动没有待恢复记录时不会操作无线设备。
    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restoreIfAwake() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidWake() }
        })
        monitor.onLidChange = { [weak self] in self?.lidChanged(closed: $0, causesSleep: $1) }
        monitor.onWillSleep = { [weak self] complete in
            guard let self else { complete(); return }
            self.systemWillSleep(complete: complete)
        }
        monitor.onDidWake = { [weak self] in self?.restoreIfAwake() }
        monitor.onError = { [weak self] in self?.report($0) }
        monitor.start()
        initializeIfEnabled()
        if let storageError { report(storageError) }
        restoreIfAwake()
    }

    /// 退出时保留凭据并放行任何未完成的睡眠通知，不在系统关机中重新打开设备。
    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll(); monitor.stop()
        recoveryTask?.cancel(); preparationTask?.cancel(); preparationTimeout?.cancel(); requestWatchdog?.cancel()
        initializationTask?.cancel()
    }

    /// 软件启动或总开关打开时，在亮屏阶段完成接口初始化及首次授权，不改变无线开关。
    func initializeIfEnabled() {
        guard isEnabled(), !bluetoothInitialized, initializationTask == nil else { return }
        initializationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.initializationTask = nil }
            do {
                _ = try await self.bluetooth.powerOn()
                self.bluetoothInitialized = true
                self.logger.info("Bluetooth interface initialized while awake")
            } catch {
                if !Task.isCancelled { self.report("蓝牙初始化失败：\(error.localizedDescription)") }
            }
        }
    }

    /// 只记录合盖状态；实际关闭要等即将睡眠，避免合盖外接显示器继续工作时断网。
    func lidChanged(closed: Bool, causesSleep: Bool) {
        lidPolicy.update(closed: closed, causesSleep: causesSleep)
        if !closed { restoreIfAwake() }
    }

    /// 软件操作先保存两个设备原状态，再关闭；失败由调用方回滚并取消电源操作。
    func prepare(for action: PowerAction, trigger: RadioSleepTrigger = .software) async throws {
        guard pendingRecord == nil, storageError == nil, !isBusy else { throw WiFiPowerError.recoveryPending }
        isBusy = true
        defer { isBusy = false }
        let snapshot = try await wifi.snapshot()
        let originalBluetooth = try await bluetooth.powerOn()
        try Task.checkCancellation()
        let record = RadioRecoveryRecord(action: action, trigger: trigger, wifi: snapshot, bluetooth: originalBluetooth)
        try save(record)
        recoveryArmed = trigger == .lid
        if trigger == .software { screenWakeObserved = false }
        report("正在关闭 Wi-Fi 和蓝牙")
        try await closeRadios(record)
        report("Wi-Fi 和蓝牙已关闭")
    }

    /// 保存正常恢复意图，软件电源请求未进入睡眠时只创建一次三十秒回滚保护。
    func markRequestSent() throws {
        guard var record = pendingRecord else { return }
        record.requestSent = true; try save(record)
        let identifier = record.id
        requestWatchdog?.cancel()
        requestWatchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
            guard let self, self.pendingRecord?.id == identifier, !self.recoveryArmed else { return }
            self.report("电源请求未进入睡眠，正在还原无线状态")
            await self.rollbackAfterFailure()
        }
    }

    /// 明确的软件操作失败恢复原状态，不把用户原本关闭的设备打开。
    func rollbackAfterFailure() async {
        requestWatchdog?.cancel()
        guard var record = pendingRecord else { return }
        record.rollback = true
        do { try save(record) } catch { pendingRecord = record; report("保存回滚记录失败：\(error.localizedDescription)") }
        recoveryArmed = true
        await restore(automatic: false)
    }

    /// 开盖空闲睡眠立即放行；新合盖睡眠才准备关闭，后台再睡眠不创建新任务。
    func systemWillSleep(complete: @escaping () -> Void = {}) {
        let lidSleep = lidPolicy.consumeSleep(enabled: isEnabled())
        let interruptedSoftware = pendingRecord?.requestSent == true ? nil : onUnrequestedSleep?()
        requestWatchdog?.cancel(); screenWakeObserved = false; recoveryTask?.cancel()
        guard lidSleep || pendingRecord != nil else { complete(); return }
        recoveryArmed = true
        // 软件已经关闭，或上次恢复尚未开始：不重复读取和写入控制器。
        if let record = pendingRecord, record.wifiPending && (record.bluetoothPending || record.originalBluetoothPowerOn == nil), recoveryTask == nil, interruptedSoftware == nil, !isBusy {
            complete(); return
        }
        guard preparationTask == nil else { complete(); return }
        let interruptedRecovery = recoveryTask
        preparationTask = Task { [weak self] in
            guard let self else { complete(); return }
            defer {
                self.preparationTimeout?.cancel(); self.preparationTimeout = nil
                self.preparationTask = nil; complete(); self.restoreIfAwake()
            }
            await interruptedRecovery?.value
            await interruptedSoftware?.value
            do {
                try Task.checkCancellation()
                if let existing = self.pendingRecord {
                    if self.isEnabled() || !existing.requestSent {
                        self.isBusy = true
                        defer { self.isBusy = false }
                        var reset = existing
                        if lidSleep { reset.trigger = .lid }
                        reset.requestSent = true
                        reset.wifiPending = true; reset.bluetoothPending = reset.originalBluetoothPowerOn != nil
                        try self.save(reset)
                        try await self.closeRadios(reset)
                    }
                } else {
                    try await self.prepare(for: .sleep, trigger: .lid)
                }
            } catch {
                // 强制合盖睡眠必须继续；部分关闭保留凭据，正常唤醒后再独立恢复。
                self.report("合盖无线关闭未全部完成：\(error.localizedDescription)")
            }
        }
        let budget = preparationBudgetNanoseconds
        preparationTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: budget) } catch { return }
            guard let self, self.preparationTask != nil else { return }
            self.preparationTask?.cancel()
            self.report("无线关闭处理超时，继续系统睡眠并保留恢复任务")
            complete()
        }
    }

    /// 操作之间检查取消，避免窗口结束后的迟到任务继续关闭另一台设备。
    private func closeRadios(_ record: RadioRecoveryRecord) async throws {
        try Task.checkCancellation()
        try await wifi.setPower(false, interfaceName: record.interfaceName)
        try Task.checkCancellation()
        if record.originalBluetoothPowerOn != nil { try await bluetooth.setPower(false) }
        try Task.checkCancellation()
    }

    /// 正常恢复必须有亮屏事件和实时亮屏；合盖来源还必须已经开盖。
    private var canRestoreNormally: Bool {
        recoveryArmed && screenWakeObserved && displayIsAwake()
            && (pendingRecord?.trigger != .lid || !lidPolicy.closed)
    }

    /// 合并重复唤醒事件，后台 DarkWake 不建立恢复任务；关闭总开关也允许完成旧恢复。
    func restoreIfAwake() {
        guard pendingRecord != nil, canRestoreNormally, !isBusy, preparationTask == nil, recoveryTask == nil else { return }
        recoveryTask = Task { [weak self] in
            guard let self else { return }
            await self.restore(automatic: true)
            self.recoveryTask = nil
            // 取消的旧任务完成期间可能收到新的开盖事件，重新检查以免漏掉恢复。
            if Task.isCancelled { self.restoreIfAwake() }
        }
    }

    /// 只有屏幕唤醒才满足恢复门禁，锁屏亮起也可恢复而无需解锁。
    func screensDidWake() { screenWakeObserved = true; restoreIfAwake() }

    /// 菜单中的手动恢复可处理部分失败，不需要再次睡眠或切换总开关。
    func restoreManually() async {
        requestWatchdog?.cancel(); recoveryArmed = true
        await restore(automatic: false)
    }

    /// 独立持久化每项恢复结果；最多三轮重试，失败后等待新唤醒或显式重试。
    private func restore(automatic: Bool) async {
        guard pendingRecord != nil, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        for attempt in 0..<3 {
            if automatic && (Task.isCancelled || !canRestoreNormally) { return }
            var errors: [String] = []
            if let record = pendingRecord, record.wifiPending {
                do {
                    try await wifi.setPower(record.wifiRestorationPower, interfaceName: record.interfaceName)
                    if automatic && (Task.isCancelled || !canRestoreNormally) { return }
                    var updated = record; updated.wifiPending = false; try save(updated)
                    report("Wi-Fi 已恢复")
                } catch { errors.append("Wi-Fi：\(error.localizedDescription)") }
            }
            if automatic && (Task.isCancelled || !canRestoreNormally) { return }
            if let record = pendingRecord, record.bluetoothPending {
                do {
                    try await bluetooth.setPower(record.bluetoothRestorationPower)
                    if automatic && (Task.isCancelled || !canRestoreNormally) { return }
                    var updated = record; updated.bluetoothPending = false; try save(updated)
                    report("蓝牙已恢复")
                } catch { errors.append("蓝牙：\(error.localizedDescription)") }
            }
            if let record = pendingRecord, !record.wifiPending && !record.bluetoothPending {
                do {
                    try FileManager.default.removeItem(at: recordURL)
                    pendingRecord = nil; storageError = nil; recoveryArmed = false; requestWatchdog?.cancel()
                    report("Wi-Fi 和蓝牙恢复完成")
                    if automatic && record.requestSent && !record.rollback && record.originalBluetoothPowerOn != nil {
                        onAutomaticRecoveryComplete?(record.id)
                    }
                    return
                } catch { errors.append("清理恢复记录：\(error.localizedDescription)") }
            }
            report("无线恢复失败（\(attempt + 1)/3）：\(errors.joined(separator: "；"))")
            if attempt < 2 {
                do { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) } catch { return }
            }
        }
    }

    /// 先原子写入再更新内存；任何持久化失败都不能继续首次关闭设备。
    private func save(_ record: RadioRecoveryRecord) throws {
        try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
        pendingRecord = record; onStateChange?()
    }

    /// 日志与菜单文本共同更新，不做周期性状态查询。
    private func report(_ message: String) { logger.info("\(message, privacy: .public)"); onStatusChange?(message) }

    /// 检查在线显示器状态；纯后台唤醒没有可绘制的亮屏，因此不能恢复无线。
    nonisolated static func hasAwakeDisplay() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0 }
    }
}
