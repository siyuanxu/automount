import AppKit

final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var menu: NSMenu?
    private var statusMenuItem: NSMenuItem?
    private var wifiMenuItem: NSMenuItem?
    private var locationMenuItem: NSMenuItem?
    private var mountMenuItem: NSMenuItem?
    private var actionMountItem: NSMenuItem?
    private var actionUnmountItem: NSMenuItem?
    private var actionOpenItem: NSMenuItem?
    private var autoStartItem: NSMenuItem?
    private var pauseItem: NSMenuItem?
    private var errorItem: NSMenuItem?
    private var lastStatus: Status?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = symbolImage("externaldrive.badge.questionmark")
        item.button?.toolTip = AppInfo.statusTitle
        statusItem = item

        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "状态：正在检测…", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        statusMenuItem = header
        menu.addItem(.separator())

        wifiMenuItem = infoItem("Wi-Fi：—")
        locationMenuItem = infoItem("定位：—")
        mountMenuItem = infoItem("挂载点：未挂载")
        menu.addItem(wifiMenuItem!)
        menu.addItem(locationMenuItem!)
        menu.addItem(mountMenuItem!)
        menu.addItem(.separator())

        actionMountItem = actionItem("立即挂载", #selector(mountNow))
        actionUnmountItem = actionItem("卸载", #selector(unmountNow))
        actionOpenItem = actionItem("在 Finder 中打开", #selector(openInFinder))
        menu.addItem(actionMountItem!)
        menu.addItem(actionUnmountItem!)
        menu.addItem(actionOpenItem!)
        menu.addItem(.separator())

        menu.addItem(actionItem("立即检查", #selector(checkNow)))
        menu.addItem(actionItem("以当前位置更新触发点…", #selector(updateGeofence)))
        menu.addItem(actionItem("打开定位服务设置", #selector(openLocationSettings)))
        menu.addItem(actionItem("打开配置文件", #selector(openConfig)))
        menu.addItem(actionItem("打开日志", #selector(openLog)))
        menu.addItem(.separator())

        autoStartItem = actionItem("登录时自动启动", #selector(toggleAutoStart))
        menu.addItem(autoStartItem!)
        pauseItem = actionItem("暂停自动挂载", #selector(togglePause))
        menu.addItem(pauseItem!)
        errorItem = infoItem("")
        errorItem?.isHidden = true
        menu.addItem(errorItem!)
        menu.addItem(.separator())

        let versionItem = NSMenuItem(title: "版本 \(AppInfo.version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(actionItem("退出", #selector(quit)))

        item.menu = menu
        self.menu = menu
        updateAutoStartState()
    }

    func update(_ status: Status) {
        lastStatus = status
        guard let statusItem else { return }
        let symbol: String
        if status.mounted {
            symbol = "externaldrive.fill.badge.checkmark"
        } else if status.conditionsMet {
            symbol = "arrow.down.circle"
        } else if !status.locationAuthorized {
            symbol = "location.slash"
        } else {
            symbol = "externaldrive.badge.questionmark"
        }
        statusItem.button?.image = symbolImage(symbol)
        statusItem.button?.toolTip = "\(AppInfo.statusTitle)：\(status.conditionSummary)"

        statusMenuItem?.title = "状态：" + status.conditionSummary
        wifiMenuItem?.title = "Wi-Fi：" + (status.ssid ?? "未连接") + (status.wifiMatched ? "（匹配）" : "")
        if let distance = status.distance, let geofence = status.geofence {
            locationMenuItem?.title = "定位：距触发点 \(Int(distance.rounded())) m / 半径 \(Int(geofence.radiusMeters.rounded())) m" + (status.inGeofence ? "（范围内）" : "（范围外）")
        } else if !status.locationAuthorized {
            locationMenuItem?.title = "定位：未授权"
        } else if status.geofence == nil {
            locationMenuItem?.title = "定位：尚未记录触发位置"
        } else if status.fix == nil {
            locationMenuItem?.title = "定位：等待坐标"
        } else {
            locationMenuItem?.title = "定位：坐标已过期"
        }
        mountMenuItem?.title = status.mounted ? "挂载点：\(status.mountPoint ?? "")" : "挂载点：未挂载"
        actionMountItem?.isEnabled = !status.mounted
        actionUnmountItem?.isEnabled = status.mounted
        actionOpenItem?.isEnabled = status.mounted
        pauseItem?.state = status.paused ? .on : .off
        if let error = status.lastError, !error.isEmpty {
            errorItem?.title = "最近错误：\(error)"
            errorItem?.isHidden = false
        } else {
            errorItem?.isHidden = true
        }
        updateAutoStartState()
    }

    // MARK: - Menu actions

    @objc private func checkNow() {
        Engine.shared.evaluate(reason: "手动检查", force: true)
    }

    @objc private func mountNow() {
        Engine.shared.manualMount(force: false) { result in
            if case .failure(let error) = result {
                self.showAlert(title: "未能挂载", message: "\(error)")
            }
        }
    }

    @objc private func unmountNow() {
        Engine.shared.manualUnmount { result in
            if case .failure(let error) = result {
                self.showAlert(title: "未能卸载", message: "\(error)")
            }
        }
    }

    @objc private func openInFinder() {
        guard let path = lastStatus?.mountPoint else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func updateGeofence() {
        Engine.shared.learnCurrentPosition { result in
            switch result {
            case .success(let geofence):
                let wifi = WiFi.snapshot().ssid ?? "（未连接）"
                var message = "位置：\(String(format: "%.6f, %.6f", geofence.latitude, geofence.longitude))\n半径：\(Int(geofence.radiusMeters)) m\n当前 Wi-Fi：\(wifi)"
                if !Engine.shared.config.serverConfigured {
                    message += "\n\n提示：还需要编辑配置文件里的 server 字段，填写你的 SMB 地址。"
                }
                self.showAlert(title: "触发点已更新", message: message)
            case .failure(let error):
                self.showAlert(title: "更新失败", message: "\(error)")
            }
        }
    }

    @objc private func openLocationSettings() {
        if !LocationProvider.shared.isAuthorized {
            NSApp.activate(ignoringOtherApps: true)
            LocationProvider.shared.requestAuthorization()
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openConfig() {
        _ = Config.load()
        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configURL])
    }

    @objc private func openLog() {
        if FileManager.default.fileExists(atPath: AppPaths.logURL.path) {
            NSWorkspace.shared.open(AppPaths.logURL)
        } else {
            showAlert(title: "暂无日志", message: AppPaths.logURL.path)
        }
    }

    @objc private func togglePause() {
        Engine.shared.setPaused(!Engine.shared.paused)
    }

    @objc private func toggleAutoStart() {
        if LaunchAgent.isInstalled {
            LaunchAgent.uninstall(removePlist: true, bootout: false)
        } else if let executable = Bundle.main.executablePath {
            LaunchAgent.install(executable: executable, bootoutFirst: true)
        }
        updateAutoStartState()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func updateAutoStartState() {
        autoStartItem?.state = LaunchAgent.isInstalled ? .on : .off
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    private func symbolImage(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: AppInfo.statusTitle)
        image?.isTemplate = true
        return image
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
