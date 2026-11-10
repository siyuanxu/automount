import Foundation
import CoreLocation
import AppKit

enum EngineError: Error, CustomStringConvertible {
    case conditionsNotMet(String)
    case locationNotAuthorized
    case noLocationFix
    case serverNotConfigured
    case mountFailed(String)

    var description: String {
        switch self {
        case .conditionsNotMet(let summary):
            return "触发条件未满足：\(summary)"
        case .locationNotAuthorized:
            return "尚未获得定位权限，请在“系统设置 → 隐私与安全性 → 定位服务”中允许「AutoMount」"
        case .noLocationFix:
            return "暂时没有取得定位坐标，请稍后重试"
        case .serverNotConfigured:
            return "SMB 服务器尚未配置，请编辑配置文件里的 server 字段（示例：smb://192.168.1.100/Shared）"
        case .mountFailed(let message):
            return "挂载失败：\(message)"
        }
    }
}

/// 核心逻辑：读取 Wi-Fi / 定位状态，判断条件并执行挂载、卸载、桌面入口维护。
final class Engine {
    static let shared = Engine()

    private(set) var config: Config
    private var configMtime: Date?
    private var mountInProgress = false
    private var unmountInProgress = false
    private var lastMountAttempt = Date.distantPast
    private var lastMountError: String?
    private var pendingUnmountSince: Date?
    private var lastEvaluateAt = Date.distantPast
    private var lastRefreshAttempt = Date.distantPast
    private var didForceRefreshAlias = false
    private(set) var lastStatus = Status()
    private(set) var paused = false

    var onStatus: ((Status) -> Void)?

    private let workQueue = DispatchQueue(label: "io.github.siyuanxu.automount.work", qos: .utility)

    private init() {
        config = Config.load()
    }

    func start() {
        refreshConfigMtime()
        LocationProvider.shared.start()
        Log.line("配置：服务器 \(config.server)；Wi-Fi 白名单 \(config.wifiNames.joined(separator: ", "))；半径 \(Int(config.geofence?.radiusMeters ?? 0)) m")
    }

    // MARK: - 状态快照

    func snapshot() -> Status {
        var status = Status()
        status.geofence = config.geofence

        let wifi = WiFi.snapshot()
        status.ssid = wifi.ssid
        status.wifiMatched = wifi.poweredOn && WiFi.matches(wifi.ssid, names: config.wifiNames)

        status.locationServicesEnabled = CLLocationManager.locationServicesEnabled()
        let provider = LocationProvider.shared
        status.locationAuthorized = provider.isAuthorized
        status.fix = provider.lastFix
        status.fixAge = provider.fixAge

        if let geofence = config.geofence,
           let fix = provider.lastFix,
           let age = provider.fixAge,
           age <= config.maxFixAgeSeconds {
            let center = CLLocation(latitude: geofence.latitude, longitude: geofence.longitude)
            let distance = fix.distance(from: center)
            status.distance = distance
            status.inGeofence = distance <= geofence.radiusMeters
        }

        status.server = config.server
        status.serverConfigured = config.serverConfigured
        status.conditionsMet = status.serverConfigured && status.wifiMatched && status.inGeofence

        if let mounted = VolumeManager.findMounted(server: config.server) {
            status.mounted = true
            status.mountPoint = mounted.path
        }
        if DesktopAlias.currentTarget(name: config.resolvedAliasName) != nil {
            status.aliasPath = DesktopAlias.linkURL(name: config.resolvedAliasName).path
        }
        status.lastError = lastMountError
        return status
    }

    // MARK: - 周期检查

    func evaluate(reason: String, force: Bool = false) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.evaluate(reason: reason, force: force) }
            return
        }
        let now = Date()
        if !force && now.timeIntervalSince(lastEvaluateAt) < 1.0 { return }
        lastEvaluateAt = now

        reloadConfigIfChanged()

        var status = snapshot()
        if learnLocationIfNeeded(status: status) {
            status = snapshot()
        }

        // 静止时系统不会持续发送定位；定期主动刷新，避免 fixAge 过期被误判为离开。
        let refreshAfter = min(300.0, max(60.0, config.maxFixAgeSeconds * 0.5))
        if provider.isAuthorized,
           (provider.fixAge ?? .greatestFiniteMagnitude) > refreshAfter,
           now.timeIntervalSince(lastRefreshAttempt) > 30 {
            lastRefreshAttempt = now
            provider.requestOneShot()
        }

        lastStatus = status
        onStatus?(status)
        writeStatusFile(status)
        Log.debug("检查：\(status.conditionSummary)；ssid=\(status.ssid ?? "nil")；age=\(Int(status.fixAge ?? -1))s；inGeofence=\(status.inGeofence)；mounted=\(status.mounted)")

        guard !paused else { return }

        if status.conditionsMet {
            pendingUnmountSince = nil
            if let mountPoint = status.mountPoint {
                let forceRefresh = !didForceRefreshAlias
                _ = DesktopAlias.ensure(mountPoint: mountPoint, name: config.resolvedAliasName, forceRefresh: forceRefresh)
                didForceRefreshAlias = true
            } else if !mountInProgress && now.timeIntervalSince(lastMountAttempt) >= 60 {
                beginMount(reason: reason)
            }
            return
        }

        // 条件不满足
        if status.mounted && config.autoUnmountWhenLeaving && !unmountInProgress {
            if config.unmountGraceSeconds <= 0 {
                beginUnmount(reason: "离开 Wi-Fi/定位范围")
            } else if let startedAt = pendingUnmountSince {
                if now.timeIntervalSince(startedAt) >= config.unmountGraceSeconds {
                    beginUnmount(reason: "离开 Wi-Fi/定位范围")
                }
            } else {
                pendingUnmountSince = now
                Log.line("条件不再满足（\(status.conditionSummary)），\(Int(config.unmountGraceSeconds)) 秒后自动卸载")
            }
        } else {
            pendingUnmountSince = nil
        }

        if !status.mounted && !mountInProgress {
            DesktopAlias.remove(name: config.resolvedAliasName)
            didForceRefreshAlias = false
        }
    }

    private var provider: LocationProvider { LocationProvider.shared }

    func setPaused(_ value: Bool) {
        paused = value
        Log.line(value ? "已暂停自动挂载（仍会监控状态）" : "已恢复自动挂载")
        evaluate(reason: "暂停状态变更", force: true)
    }

    // MARK: - 首次运行学习

    private func learnLocationIfNeeded(status: Status) -> Bool {
        guard config.geofence == nil,
              provider.isAuthorized,
              let fix = status.fix,
              fix.horizontalAccuracy > 0,
              fix.horizontalAccuracy < 2000 else { return false }

        config.geofence = Geofence(
            latitude: fix.coordinate.latitude,
            longitude: fix.coordinate.longitude,
            radiusMeters: 500,
            note: "首次启动时自动记录的当前位置"
        )
        if let ssid = status.ssid, !ssid.isEmpty,
           !config.wifiNames.contains(where: { $0.caseInsensitiveCompare(ssid) == .orderedSame }) {
            config.wifiNames.append(ssid)
        }
        do {
            try saveConfig()
            Log.line("首次运行：已把当前位置记录为触发点（\(fix.coordinate.latitude), \(fix.coordinate.longitude)），半径 300 m")
            return true
        } catch {
            Log.line("保存配置失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 挂载 / 卸载

    private func beginMount(reason: String) {
        guard config.serverConfigured else {
            lastMountError = "\(EngineError.serverNotConfigured)"
            Log.line("跳过挂载：SMB 服务器尚未配置")
            evaluate(reason: "服务器未配置", force: true)
            return
        }
        guard !mountInProgress else { return }
        mountInProgress = true
        lastMountAttempt = Date()
        let server = config.server
        Log.line("开始挂载 \(server)（\(reason)）")
        workQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<String, Error>
            do {
                let path = try VolumeManager.mount(server: server)
                result = .success(path)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.mountInProgress = false
                switch result {
                case .success(let path):
                    self.lastMountError = nil
                    Log.line("挂载成功：\(path)")
                    _ = DesktopAlias.ensure(mountPoint: path, name: self.config.resolvedAliasName, forceRefresh: true)
                    self.didForceRefreshAlias = true
                    if self.config.openFinderOnMount {
                        NSWorkspace.shared.open(URL(fileURLWithPath: path))
                    }
                case .failure(let error):
                    self.lastMountError = "\(error)"
                    Log.line("挂载失败：\(error)")
                }
                self.evaluate(reason: "挂载结果", force: true)
            }
        }
    }

    private func beginUnmount(reason: String) {
        guard !unmountInProgress else { return }
        unmountInProgress = true
        pendingUnmountSince = nil
        let server = config.server
        Log.line("开始卸载（\(reason)）")
        workQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<Void, Error>
            if let mounted = VolumeManager.findMounted(server: server) {
                do {
                    try VolumeManager.unmount(path: mounted.path)
                    result = .success(())
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .success(())
            }
            DispatchQueue.main.async {
                self.unmountInProgress = false
                switch result {
                case .success:
                    self.lastMountError = nil
                    Log.line("卸载完成")
                    DesktopAlias.remove(name: self.config.resolvedAliasName)
                    self.didForceRefreshAlias = false
                case .failure(let error):
                    self.lastMountError = "\(error)"
                    Log.line("卸载失败：\(error)")
                }
                self.evaluate(reason: "卸载结果", force: true)
            }
        }
    }

    // MARK: - 手动操作（UI / CLI 共用）

    func manualMount(force: Bool, completion: ((Result<String, Error>) -> Void)? = nil) {
        guard config.serverConfigured else {
            lastMountError = "\(EngineError.serverNotConfigured)"
            completion?(.failure(EngineError.serverNotConfigured))
            evaluate(reason: "服务器未配置", force: true)
            return
        }
        if let mounted = VolumeManager.findMounted(server: config.server) {
            _ = DesktopAlias.ensure(mountPoint: mounted.path, name: config.resolvedAliasName)
            completion?(.success(mounted.path))
            evaluate(reason: "手动挂载（已挂载）", force: true)
            return
        }
        let status = snapshot()
        if !force && !status.conditionsMet {
            let error = EngineError.conditionsNotMet(status.conditionSummary)
            lastMountError = "\(error)"
            completion?(.failure(error))
            evaluate(reason: "手动挂载被条件阻止", force: true)
            return
        }
        mountInProgress = true
        lastMountAttempt = Date()
        let server = config.server
        workQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<String, Error>
            do {
                let path = try VolumeManager.mount(server: server)
                result = .success(path)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.mountInProgress = false
                switch result {
                case .success(let path):
                    self.lastMountError = nil
                    _ = DesktopAlias.ensure(mountPoint: path, name: self.config.resolvedAliasName)
                    completion?(.success(path))
                case .failure(let error):
                    self.lastMountError = "\(error)"
                    completion?(.failure(error))
                }
                self.evaluate(reason: "手动挂载结果", force: true)
            }
        }
    }

    func manualUnmount(completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let mounted = VolumeManager.findMounted(server: config.server) else {
            DesktopAlias.remove(name: config.resolvedAliasName)
            completion?(.success(()))
            evaluate(reason: "手动卸载（未挂载）", force: true)
            return
        }
        unmountInProgress = true
        workQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<Void, Error>
            do {
                try VolumeManager.unmount(path: mounted.path)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                self.unmountInProgress = false
                if case .success = result {
                    DesktopAlias.remove(name: self.config.resolvedAliasName)
                }
                completion?(result)
                self.evaluate(reason: "手动卸载结果", force: true)
            }
        }
    }

    func mountSynchronously(force: Bool) throws -> String {
        guard config.serverConfigured else { throw EngineError.serverNotConfigured }
        if let mounted = VolumeManager.findMounted(server: config.server) {
            _ = DesktopAlias.ensure(mountPoint: mounted.path, name: config.resolvedAliasName)
            return mounted.path
        }
        let status = snapshot()
        if !force && !status.conditionsMet {
            throw EngineError.conditionsNotMet(status.conditionSummary)
        }
        let path = try VolumeManager.mount(server: config.server)
        _ = DesktopAlias.ensure(mountPoint: path, name: config.resolvedAliasName)
        return path
    }

    func unmountSynchronously() throws {
        guard let mounted = VolumeManager.findMounted(server: config.server) else {
            DesktopAlias.remove(name: config.resolvedAliasName)
            return
        }
        try VolumeManager.unmount(path: mounted.path)
        DesktopAlias.remove(name: config.resolvedAliasName)
    }

    /// 把“现在的位置”写成触发点，并把当前 Wi-Fi 加入白名单。
    func learnCurrentPosition(completion: @escaping (Result<Geofence, Error>) -> Void) {
        provider.start()
        let deadline = Date().addingTimeInterval(10)
        func attempt() {
            if !provider.isAuthorized {
                completion(.failure(EngineError.locationNotAuthorized))
                return
            }
            if let fix = provider.lastFix, let age = provider.fixAge, age < 120 {
                let geofence = Geofence(
                    latitude: fix.coordinate.latitude,
                    longitude: fix.coordinate.longitude,
                    radiusMeters: config.geofence?.radiusMeters ?? 500,
                    note: "手动更新于 \(Date())"
                )
                config.geofence = geofence
                if let ssid = WiFi.snapshot().ssid, !ssid.isEmpty,
                   !config.wifiNames.contains(where: { $0.caseInsensitiveCompare(ssid) == .orderedSame }) {
                    config.wifiNames.append(ssid)
                }
                do {
                    try saveConfig()
                    Log.line("已把当前位置更新为触发点（\(geofence.latitude), \(geofence.longitude)）")
                    completion(.success(geofence))
                } catch {
                    completion(.failure(error))
                }
                return
            }
            if Date() >= deadline {
                completion(.failure(EngineError.noLocationFix))
                return
            }
            provider.requestOneShot()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { attempt() }
        }
        attempt()
    }

    // MARK: - 配置

    func reloadConfigIfChanged() {
        guard let mtime = configModificationDate() else { return }
        if let current = configMtime, mtime <= current { return }
        config = Config.load()
        configMtime = mtime
        Log.line("配置文件已更新，重新加载：Wi-Fi \(config.wifiNames.joined(separator: ", "))，半径 \(Int(config.geofence?.radiusMeters ?? 0)) m")
    }

    func saveConfig() throws {
        try config.save()
        refreshConfigMtime()
    }

    func writeStatusFile(_ status: Status) {
        let data = try? JSONSerialization.data(withJSONObject: statusJSON(status), options: [.prettyPrinted, .sortedKeys])
        try? data?.write(to: AppPaths.statusURL, options: .atomic)
    }

    private func configModificationDate() -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: AppPaths.configURL.path),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return date
    }

    private func refreshConfigMtime() {
        configMtime = configModificationDate() ?? Date()
    }
}
