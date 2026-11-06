import Foundation
import CoreLocation

/// 应用内持续使用的定位提供器（主线程回调）。
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private(set) var lastFix: CLLocation?
    private(set) var lastFixDate: Date?
    private(set) var authStatus: CLAuthorizationStatus = .notDetermined

    /// 位置或授权状态变化时回调（主线程）。
    var onUpdate: (() -> Void)?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 25
    }

    var isAuthorized: Bool {
        authStatus == .authorizedAlways || authStatus == .authorized
    }

    var fixAge: TimeInterval? {
        lastFixDate.map { -$0.timeIntervalSinceNow }
    }

    func start() {
        authStatus = manager.authorizationStatus
        if authStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        if isAuthorized {
            manager.startUpdatingLocation()
        }
    }

    /// 主动请求一次位置（节流由调用方负责）。
    func requestOneShot() {
        guard isAuthorized else { return }
        manager.requestLocation()
    }

    /// 未决定时弹出系统授权框；已被拒绝时只能去系统设置。
    func requestAuthorization() {
        authStatus = manager.authorizationStatus
        if authStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authStatus = manager.authorizationStatus
        if isAuthorized {
            manager.startUpdatingLocation()
            manager.requestLocation()
        }
        onUpdate?()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        if location.horizontalAccuracy >= 0 {
            lastFix = location
            lastFixDate = Date()
        }
        onUpdate?()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if (error as? CLError)?.code == .denied {
            Log.debug("定位请求被拒绝")
        } else {
            Log.debug("定位失败: \(error.localizedDescription)")
        }
    }

    /// 在命令行模式下等待一次定位（会驱动 RunLoop，允许系统授权弹窗出现）。
    @discardableResult
    func waitForFix(timeout: TimeInterval) -> CLLocation? {
        start()
        if let fix = lastFix, let age = fixAge, age < 120 {
            return fix
        }
        requestOneShot()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            if lastFix != nil { break }
        }
        return lastFix
    }
}
