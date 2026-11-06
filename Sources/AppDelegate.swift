import AppKit
import Network

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private var pendingEvaluate: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.line("AutoMount \(AppInfo.version) 启动（pid \(getpid())）")
        StatusBarController.shared.install()
        Engine.shared.onStatus = { status in
            StatusBarController.shared.update(status)
        }
        LocationProvider.shared.start()
        LocationProvider.shared.onUpdate = { [weak self] in
            self?.scheduleEvaluate(after: 1.0)
        }
        Engine.shared.start()

        let timer = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            self?.scheduleEvaluate(after: 0)
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.scheduleEvaluate(after: 2.0)
        }
        monitor.start(queue: DispatchQueue(label: "io.github.siyuanxu.automount.network"))
        pathMonitor = monitor

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        scheduleEvaluate(after: 0.5)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        pathMonitor?.cancel()
        Log.line("AutoMount退出")
    }

    @objc private func didWake() {
        Log.line("系统已唤醒，重新检查")
        scheduleEvaluate(after: 3.0)
    }

    private func scheduleEvaluate(after delay: TimeInterval) {
        pendingEvaluate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingEvaluate = nil
            Engine.shared.evaluate(reason: "事件触发")
        }
        pendingEvaluate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
