import Foundation
import Darwin
import NetFS

struct MountedVolume {
    var path: String
    var source: String
}

enum VolumeError: Error, CustomStringConvertible {
    case badServerURL(String)
    case mountFailed(Int32, String)
    case noMountPoint
    case unmountFailed(Int32, String)
    case busy

    var description: String {
        switch self {
        case .badServerURL(let server):
            return "无效的服务器地址：\(server)"
        case .mountFailed(let code, let message):
            return "挂载失败（错误码 \(code)：\(message)）"
        case .noMountPoint:
            return "挂载命令返回成功，但没有找到挂载点"
        case .unmountFailed(let code, let message):
            return "卸载失败（错误码 \(code)：\(message)）"
        case .busy:
            return "文件夹正在使用中，暂时无法卸载"
        }
    }
}

enum VolumeManager {
    /// 把 `smb://host/share` 归一化成 `host/share`，用于和 mount 表里的来源比较。
    static func normalizedServer(_ server: String) -> String? {
        guard let components = URLComponents(string: server), let host = components.host else { return nil }
        let share = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "\(host.lowercased())/\(share.lowercased())"
    }

    static func normalizedSource(_ source: String) -> String {
        var text = source
        if text.hasPrefix("//") { text.removeFirst(2) }
        if let at = text.firstIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        return text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 扫描 /Volumes，找到对应服务器的 smbfs 挂载点（若存在）。
    static func findMounted(server: String) -> MountedVolume? {
        guard let target = normalizedServer(server) else { return nil }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") else { return nil }
        for name in names.sorted() where !name.hasPrefix(".") {
            let path = "/Volumes/" + name
            var info = statfs()
            guard statfs(path, &info) == 0 else { continue }
            let fsType = cString(of: info.f_fstypename)
            guard fsType == "smbfs" else { continue }
            let source = cString(of: info.f_mntfromname)
            if normalizedSource(source) == target {
                return MountedVolume(path: path, source: source)
            }
        }
        return nil
    }

    /// 通过 NetFS 挂载（等价于 Finder 的“连接服务器”，会复用钥匙串凭据）。
    static func mount(server: String) throws -> String {
        guard let url = URL(string: server) else { throw VolumeError.badServerURL(server) }
        if let existing = findMounted(server: server) { return existing.path }

        var mountPoints: Unmanaged<CFArray>?
        let result = NetFSMountURLSync(url as CFURL, nil, nil, nil, nil, nil, &mountPoints)
        if result != 0 {
            if let existing = findMounted(server: server) { return existing.path }
            throw VolumeError.mountFailed(result, String(cString: strerror(result)))
        }
        if let array = mountPoints?.takeRetainedValue() as? [String], let first = array.first {
            return first
        }
        if let existing = findMounted(server: server) { return existing.path }
        throw VolumeError.noMountPoint
    }

    static func unmount(path: String) throws {
        let result = path.withCString { Darwin.unmount($0, 0) }
        if result == 0 { return }
        let code = errno
        if code == ENOENT { return }
        if code == EBUSY { throw VolumeError.busy }
        throw VolumeError.unmountFailed(code, String(cString: strerror(code)))
    }

    /// 读取 C 字符数组（statfs 的 f_mntfromname / f_fstypename 是定长元组）。
    static func cString<T>(of value: T) -> String {
        var copy = value
        return withUnsafeBytes(of: &copy) { raw in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
    }
}
