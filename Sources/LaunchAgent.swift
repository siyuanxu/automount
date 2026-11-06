import Foundation

enum LaunchAgent {
    static var plistURL: URL { AppPaths.launchAgentURL }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func plistContents(executable: String) -> String {
        let logPath = AppPaths.logURL.path
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(AppInfo.agentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executable)</string>
                <string>--agent</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>StandardOutPath</key>
            <string>\(logPath)</string>
            <key>StandardErrorPath</key>
            <string>\(logPath)</string>
        </dict>
        </plist>
        """
    }

    @discardableResult
    static func install(executable: String, bootoutFirst: Bool = true) -> Bool {
        let contents = plistContents(executable: executable)
        do {
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            Log.line("写入 LaunchAgent 失败：\(error.localizedDescription)")
            return false
        }
        if bootoutFirst {
            _ = runLaunchctl(["bootout", "gui/\(getuid())/\(AppInfo.agentLabel)"])
        }
        var result = runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        if result != 0 {
            result = runLaunchctl(["load", "-w", plistURL.path])
        }
        if result == 0 {
            Log.line("登录时自动启动已启用：\(plistURL.path)")
        } else {
            Log.line("设置登录启动失败（launchctl 返回 \(result)）")
        }
        return result == 0
    }

    /// 仅关闭“登录时自动启动”。不 bootout 当前进程，避免把正在运行的菜单栏进程杀掉。
    @discardableResult
    static func uninstall(removePlist: Bool = true, bootout: Bool = false) -> Bool {
        if bootout {
            _ = runLaunchctl(["bootout", "gui/\(getuid())/\(AppInfo.agentLabel)"])
        }
        if removePlist {
            try? FileManager.default.removeItem(at: plistURL)
        }
        Log.line("登录时自动启动已关闭")
        return true
    }

    @discardableResult
    static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            Log.line("launchctl 执行失败：\(error.localizedDescription)")
            return -1
        }
    }
}
