import Foundation

// MARK: - 命令行工具（供安装脚本 / 调试使用）

func freshAppStatus() -> [String: Any]? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: AppPaths.statusURL.path),
          let mtime = attributes[.modificationDate] as? Date,
          -mtime.timeIntervalSinceNow < 30,
          let data = try? Data(contentsOf: AppPaths.statusURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

func runStatusCLI() -> Int32 {
    if let object = freshAppStatus() {
        print(jsonString(object))
        return 0
    }
    Engine.shared.start()
    _ = LocationProvider.shared.waitForFix(timeout: 8)
    let status = Engine.shared.snapshot()
    print(statusJSON(status))
    return 0
}

func runCheckCLI() -> Int32 {
    if let object = freshAppStatus(), let met = object["conditionsMet"] as? Bool {
        print((object["summary"] as? String) ?? (met ? "条件已满足" : "条件未满足"))
        return met ? 0 : 1
    }
    Engine.shared.start()
    _ = LocationProvider.shared.waitForFix(timeout: 8)
    let status = Engine.shared.snapshot()
    print(status.conditionSummary)
    return status.conditionsMet ? 0 : 1
}

func runMountCLI(force: Bool) -> Int32 {
    Engine.shared.start()
    _ = LocationProvider.shared.waitForFix(timeout: 10)
    do {
        let path = try Engine.shared.mountSynchronously(force: force)
        print(statusJSON(Engine.shared.snapshot()))
        print("已挂载到 \(path)")
        return 0
    } catch {
        print("错误：\(error)")
        return 1
    }
}

func runUnmountCLI() -> Int32 {
    Engine.shared.start()
    do {
        try Engine.shared.unmountSynchronously()
        print("已卸载")
        return 0
    } catch {
        print("错误：\(error)")
        return 1
    }
}

func runLearnCLI() -> Int32 {
    Engine.shared.start()
    guard let fix = LocationProvider.shared.waitForFix(timeout: 12) else {
        print("错误：没有取得定位坐标（请确认已允许定位权限）")
        return 1
    }
    var config = Config.load()
    config.geofence = Geofence(
        latitude: fix.coordinate.latitude,
        longitude: fix.coordinate.longitude,
        radiusMeters: config.geofence?.radiusMeters ?? 500,
        note: "安装时记录的当前位置"
    )
    if let ssid = WiFi.snapshot().ssid, !ssid.isEmpty,
       !config.wifiNames.contains(where: { $0.caseInsensitiveCompare(ssid) == .orderedSame }) {
        config.wifiNames.append(ssid)
    }
    do {
        try config.save()
    } catch {
        print("错误：保存配置失败：\(error.localizedDescription)")
        return 1
    }
    let payload: [String: Any] = [
        "geofence": [
            "latitude": config.geofence!.latitude,
            "longitude": config.geofence!.longitude,
            "radiusMeters": config.geofence!.radiusMeters,
        ],
        "wifiNames": config.wifiNames,
        "ssid": WiFi.snapshot().ssid ?? "",
        "config": AppPaths.configURL.path,
    ]
    print(jsonString(payload))
    return 0
}

func runInitCLI() -> Int32 {
    let config = Config.load()
    try? config.save()
    var payload: [String: Any] = [
        "config": AppPaths.configURL.path,
        "server": config.server,
        "serverConfigured": config.serverConfigured,
        "wifiNames": config.wifiNames,
    ]
    if let geofence = config.geofence {
        payload["geofence"] = [
            "latitude": geofence.latitude,
            "longitude": geofence.longitude,
            "radiusMeters": geofence.radiusMeters,
        ]
    }
    print(jsonString(payload))
    return 0
}

func runRemoveDesktopAliasCLI() -> Int32 {
    let config = Config.load()
    DesktopAlias.remove(name: config.resolvedAliasName)
    print("已移除桌面入口：\(AppPaths.desktopURL.appendingPathComponent(config.resolvedAliasName).path)")
    return 0
}

func runInstallAgentCLI() -> Int32 {
    guard let executable = Bundle.main.executablePath ?? CommandLine.arguments.first else {
        print("错误：无法确定程序路径")
        return 1
    }
    return LaunchAgent.install(executable: executable, bootoutFirst: true) ? 0 : 1
}

func runUninstallAgentCLI() -> Int32 {
    LaunchAgent.uninstall(removePlist: true, bootout: true)
    return 0
}

func printUsage() {
    print("""
    AutoMount \(AppInfo.version)

    用法：
      AutoMount                       以菜单栏 App 方式运行
      AutoMount --agent               供 launchd 使用（同 App 方式）
      AutoMount --status              输出当前状态 JSON
      AutoMount --check               条件满足返回 0，否则返回 1
      AutoMount --mount [--force]     立即挂载（--force 跳过条件检查）
      AutoMount --unmount             立即卸载
      AutoMount --learn-current       把当前位置和当前 Wi-Fi 记录到配置
      AutoMount --init                创建默认配置文件
      AutoMount --install-agent       安装登录启动项
      AutoMount --uninstall-agent     移除登录启动项
      AutoMount --remove-desktop-alias 移除桌面入口
      AutoMount --version             显示版本
    """)
}
