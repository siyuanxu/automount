import Foundation
import CoreLocation

/// 应用内持续使用的定位提供器（主线程回调）。
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private(set) var lastFix: CLLocation?
    private(set) var lastFixDate: Date?
    private(set) var authStatus: CLAuthorizationStatus = .notDetermined
    private var refreshInFlight = false
    private var restartWorkItem: DispatchWorkItem?

    /// 位置或授权状态变化时回调（主线程）。
    var onUpdate: (() -> Void)?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
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

    /// 主动刷新一次位置（节流由调用方负责）。
    ///
    /// 静止时 `startUpdatingLocation` 可能不再产生新坐标，而持续更新期间
    /// `requestLocation()` 会被系统忽略（"Ignoring requestLocation due to
    /// ongoing location"）。因此先暂停持续更新，再请求一次单次定位，拿到结果后恢复。
    func requestOneShot() {
        guard isAuthorized, !refreshInFlight else { return }
        refreshInFlight = true
        manager.stopUpdatingLocation()
        manager.requestLocation()
        scheduleUpdateRestart()
    }

    /// 重新启动持续定位（例如系统唤醒后）。
    func restartUpdates() {
        guard isAuthorized else { return }
        restartWorkItem?.cancel()
        refreshInFlight = false
        manager.stopUpdatingLocation()
        manager.startUpdatingLocation()
    }

    private func scheduleUpdateRestart() {
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshInFlight = false
            if self.isAuthorized {
                self.manager.startUpdatingLocation()
            }
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
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
        if refreshInFlight {
            refreshInFlight = false
            restartWorkItem?.cancel()
            manager.startUpdatingLocation()
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
