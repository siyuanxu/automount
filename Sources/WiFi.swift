import Foundation
import CoreWLAN
import Darwin

struct WiFiSnapshot {
    var ssid: String?
    var rssi: Int?
    var poweredOn: Bool

    static let empty = WiFiSnapshot(ssid: nil, rssi: nil, poweredOn: false)
}

enum WiFi {
    static func snapshot() -> WiFiSnapshot {
        guard let client = CWWiFiClient.shared() as CWWiFiClient?,
              let interface = client.interface() else {
            return .empty
        }
        let poweredOn = interface.powerOn()
        guard poweredOn else { return .empty }
        return WiFiSnapshot(ssid: interface.ssid(), rssi: interface.rssiValue(), poweredOn: true)
    }

    /// 支持通配符（例如 "Office*"），大小写不敏感。
    static func matches(_ ssid: String?, names: [String]) -> Bool {
        guard let ssid = ssid, !ssid.isEmpty else { return false }
        let lower = ssid.lowercased()
        return names.contains { pattern in
            let p = pattern.lowercased()
            if p.contains("*") || p.contains("?") {
                return fnmatch(p, lower, 0) == 0
            }
            return p == lower
        }
    }
}
