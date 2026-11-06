import Foundation
import Darwin
import CoreLocation

// MARK: - 基本常量

enum AppInfo {
    static let bundleID = "io.github.siyuanxu.automount"
    static let agentLabel = "io.github.siyuanxu.automount"
    static let displayName = "AutoMount"
    static let statusTitle = "AutoMount"
    static let version = "1.0.0"
}

enum AppPaths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let supportDir = home.appendingPathComponent("Library/Application Support/AutoMount", isDirectory: true)
    static let configURL = supportDir.appendingPathComponent("config.json")
    static let logDir = home.appendingPathComponent("Library/Logs/AutoMount", isDirectory: true)
    static let logURL = logDir.appendingPathComponent("AutoMount.log")
    static let lockURL = supportDir.appendingPathComponent("agent.lock")
    static let statusURL = supportDir.appendingPathComponent("status.json")
    static let launchAgentURL = home.appendingPathComponent("Library/LaunchAgents/\(AppInfo.agentLabel).plist")

    static var desktopURL: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Desktop", isDirectory: true)
    }
}

// MARK: - 日志

enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    private static let lock = NSLock()

    static func line(_ message: String) {
        let text = "[\(formatter.string(from: Date()))] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: AppPaths.logDir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: AppPaths.logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: AppPaths.logURL.path, contents: Data(text.utf8))
        }
        rotateIfNeeded()
    }

    static func debug(_ message: String) {
        line(message)
        if ProcessInfo.processInfo.environment["AUTOMOUNT_DEBUG"] == "1" {
            FileHandle.standardError.write(Data(("[debug] " + message + "\n").utf8))
        }
    }

    private static func rotateIfNeeded() {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: AppPaths.logURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue > 2_000_000 else { return }
        let old = AppPaths.logDir.appendingPathComponent("AutoMount.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: AppPaths.logURL, to: old)
    }
}

// MARK: - 配置

struct Geofence: Codable, Equatable {
    var latitude: Double
    var longitude: Double
    var radiusMeters: Double
    var note: String?

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct Config: Codable {
    var server: String
    var volumeName: String
    var desktopAliasName: String
    var wifiNames: [String]
    var geofence: Geofence?
    var autoUnmountWhenLeaving: Bool
    var unmountGraceSeconds: Double
    var maxFixAgeSeconds: Double
    var openFinderOnMount: Bool

    enum CodingKeys: String, CodingKey {
        case server, volumeName, desktopAliasName, wifiNames, geofence
        case autoUnmountWhenLeaving, unmountGraceSeconds, maxFixAgeSeconds, openFinderOnMount
    }

    /// 默认配置里的示例地址；用户需要改成自己的 SMB 服务器。
    static let placeholderServer = "smb://192.168.1.100/Shared"

    static func defaults() -> Config {
        Config(
            server: placeholderServer,
            volumeName: "Shared",
            desktopAliasName: "",
            wifiNames: [],
            geofence: nil,
            autoUnmountWhenLeaving: true,
            unmountGraceSeconds: 300,
            maxFixAgeSeconds: 600,
            openFinderOnMount: false
        )
    }

    /// 是否已经把示例服务器改成了真实地址。
    var serverConfigured: Bool {
        let value = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.lowercased().hasPrefix("smb://") else { return false }
        return value.caseInsensitiveCompare(Config.placeholderServer) != .orderedSame
    }

    /// 从 SMB 地址推导共享名，用于默认的桌面入口名称。
    var shareName: String {
        guard let components = URLComponents(string: server),
              let last = components.path.split(separator: "/").last,
              !last.isEmpty else { return "Shared" }
        return String(last)
    }

    /// 桌面入口名称：配置为空时自动使用共享名。
    var resolvedAliasName: String {
        let name = desktopAliasName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? shareName : name
    }

    init(server: String, volumeName: String, desktopAliasName: String, wifiNames: [String],
         geofence: Geofence?, autoUnmountWhenLeaving: Bool, unmountGraceSeconds: Double,
         maxFixAgeSeconds: Double, openFinderOnMount: Bool) {
        self.server = server
        self.volumeName = volumeName
        self.desktopAliasName = desktopAliasName
        self.wifiNames = wifiNames
        self.geofence = geofence
        self.autoUnmountWhenLeaving = autoUnmountWhenLeaving
        self.unmountGraceSeconds = unmountGraceSeconds
        self.maxFixAgeSeconds = maxFixAgeSeconds
        self.openFinderOnMount = openFinderOnMount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.defaults()
        server = try c.decodeIfPresent(String.self, forKey: .server) ?? d.server
        volumeName = try c.decodeIfPresent(String.self, forKey: .volumeName) ?? d.volumeName
        desktopAliasName = try c.decodeIfPresent(String.self, forKey: .desktopAliasName) ?? d.desktopAliasName
        wifiNames = try c.decodeIfPresent([String].self, forKey: .wifiNames) ?? d.wifiNames
        geofence = try c.decodeIfPresent(Geofence.self, forKey: .geofence)
        autoUnmountWhenLeaving = try c.decodeIfPresent(Bool.self, forKey: .autoUnmountWhenLeaving) ?? d.autoUnmountWhenLeaving
        unmountGraceSeconds = try c.decodeIfPresent(Double.self, forKey: .unmountGraceSeconds) ?? d.unmountGraceSeconds
        maxFixAgeSeconds = try c.decodeIfPresent(Double.self, forKey: .maxFixAgeSeconds) ?? d.maxFixAgeSeconds
        openFinderOnMount = try c.decodeIfPresent(Bool.self, forKey: .openFinderOnMount) ?? d.openFinderOnMount
    }

    static func load() -> Config {
        if let data = try? Data(contentsOf: AppPaths.configURL),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }
        let config = Config.defaults()
        try? config.save()
        return config
    }

    func save() throws {
        try FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: AppPaths.configURL, options: .atomic)
    }
}

// MARK: - 状态快照

struct Status {
    var timestamp = Date()
    var ssid: String?
    var wifiMatched = false
    var locationAuthorized = false
    var locationServicesEnabled = false
    var fix: CLLocation?
    var fixAge: TimeInterval?
    var distance: Double?
    var inGeofence = false
    var conditionsMet = false
    var mounted = false
    var mountPoint: String?
    var aliasPath: String?
    var geofence: Geofence?
    var lastError: String?
    var paused = false
    var server: String?
    var serverConfigured = false

    var conditionSummary: String {
        if paused { return "已暂停自动挂载" }
        if mounted && conditionsMet { return "已挂载" }
        if !serverConfigured { return "尚未配置 SMB 服务器（编辑 config.json 的 server）" }
        if conditionsMet { return "条件已满足，等待挂载" }
        if !locationServicesEnabled { return "系统定位服务已关闭" }
        if !locationAuthorized { return "未获得定位权限" }
        if ssid == nil { return "未连接 Wi-Fi" }
        if !wifiMatched { return "Wi-Fi 不在白名单（当前：\(ssid ?? "未知")）" }
        if geofence == nil { return "尚未记录触发位置" }
        if fix == nil { return "等待定位结果" }
        if !inGeofence { return "不在触发范围内" }
        return "等待满足条件"
    }

    var detailLines: [String] {
        var lines: [String] = []
        if let server = server {
            lines.append("服务器：\(server)\(serverConfigured ? "" : "（示例，需修改）")")
        }
        lines.append("Wi-Fi：\(ssid ?? "未连接")\(wifiMatched ? "（匹配）" : "")")
        if let gf = geofence {
            if let d = distance {
                let inside = inGeofence ? "范围内" : "范围外"
                lines.append("定位：距触发点 \(Int(d.rounded())) m / 半径 \(Int(gf.radiusMeters.rounded())) m（\(inside)）")
            } else if let age = fixAge {
                lines.append("定位：有记录（\(Int(age)) 秒前），暂无新坐标")
            } else {
                lines.append("定位：尚未取得坐标")
            }
        } else {
            lines.append("定位：尚未记录触发位置")
        }
        if mounted, let m = mountPoint {
            lines.append("挂载点：\(m)")
        }
        if let e = lastError { lines.append("最近错误：\(e)") }
        return lines
    }
}

// MARK: - 工具

func formatBytes(_ value: Double) -> String {
    if value >= 1000 { return String(format: "%.1f km", value / 1000) }
    return String(format: "%.0f m", value)
}

func jsonString(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
          let text = String(data: data, encoding: .utf8) else { return "{}" }
    return text
}

func statusJSON(_ status: Status) -> [String: Any] {
    let iso = ISO8601DateFormatter()
    var result: [String: Any] = [
        "timestamp": iso.string(from: status.timestamp),
        "conditionsMet": status.conditionsMet,
        "mounted": status.mounted,
        "wifiMatched": status.wifiMatched,
        "locationAuthorized": status.locationAuthorized,
        "locationServicesEnabled": status.locationServicesEnabled,
        "inGeofence": status.inGeofence,
        "paused": status.paused,
        "serverConfigured": status.serverConfigured,
        "summary": status.conditionSummary,
    ]
    if let ssid = status.ssid { result["ssid"] = ssid }
    if let server = status.server { result["server"] = server }
    if let mountPoint = status.mountPoint { result["mountPoint"] = mountPoint }
    if let aliasPath = status.aliasPath { result["desktopAlias"] = aliasPath }
    if let fix = status.fix {
        result["location"] = [
            "latitude": fix.coordinate.latitude,
            "longitude": fix.coordinate.longitude,
            "accuracyMeters": fix.horizontalAccuracy,
        ]
    }
    if let distance = status.distance { result["distanceMeters"] = distance.rounded() }
    if let age = status.fixAge { result["fixAgeSeconds"] = age.rounded() }
    if let geofence = status.geofence {
        result["geofence"] = [
            "latitude": geofence.latitude,
            "longitude": geofence.longitude,
            "radiusMeters": geofence.radiusMeters,
        ]
    }
    if let lastError = status.lastError { result["lastError"] = lastError }
    return result
}
