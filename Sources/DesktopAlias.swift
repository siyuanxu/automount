import Foundation

/// 桌面上的文件夹入口（符号链接），指向实际挂载点。
enum DesktopAlias {
    static func linkURL(name: String) -> URL {
        AppPaths.desktopURL.appendingPathComponent(name)
    }

    static func currentTarget(name: String) -> String? {
        let url = linkURL(name: name)
        guard isSymbolicLink(url) else { return nil }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
    }

    @discardableResult
    static func ensure(mountPoint: String, name: String) -> String? {
        let url = linkURL(name: name)
        if let target = currentTarget(name: name) {
            if target == mountPoint { return url.path }
            try? FileManager.default.removeItem(at: url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            Log.line("桌面上已存在名为「\(name)」的文件或文件夹，跳过创建快捷方式")
            return nil
        }
        do {
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: mountPoint)
            Log.line("已在桌面创建入口：\(url.path) -> \(mountPoint)")
            return url.path
        } catch {
            Log.line("创建桌面入口失败：\(error.localizedDescription)")
            return nil
        }
    }

    static func remove(name: String) {
        let url = linkURL(name: name)
        guard isSymbolicLink(url) else { return }
        try? FileManager.default.removeItem(at: url)
        Log.line("已移除桌面入口：\(url.path)")
    }
}
