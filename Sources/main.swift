import Foundation
import Darwin
import AppKit

var lockFileDescriptor: Int32 = -1

func acquireSingleInstanceLock() -> Bool {
    try? FileManager.default.createDirectory(at: AppPaths.supportDir, withIntermediateDirectories: true)
    let descriptor = open(AppPaths.lockURL.path, O_CREAT | O_RDWR, 0o644)
    guard descriptor >= 0 else { return true }
    if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        close(descriptor)
        return false
    }
    lockFileDescriptor = descriptor
    return true
}

func runApplication() {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
    _ = delegate
}

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? ""
let flags = Set(arguments)

switch command {
case "--status":
    exit(runStatusCLI())
case "--check":
    exit(runCheckCLI())
case "--mount":
    exit(runMountCLI(force: flags.contains("--force")))
case "--unmount":
    exit(runUnmountCLI())
case "--learn-current":
    exit(runLearnCLI())
case "--init":
    exit(runInitCLI())
case "--install-agent":
    exit(runInstallAgentCLI())
case "--uninstall-agent":
    exit(runUninstallAgentCLI())
case "--remove-desktop-alias":
    exit(runRemoveDesktopAliasCLI())
case "--version":
    print("AutoMount \(AppInfo.version)")
    exit(0)
case "--help", "-h":
    printUsage()
    exit(0)
default:
    guard acquireSingleInstanceLock() else {
        Log.line("已有实例在运行，本次启动退出")
        exit(0)
    }
    runApplication()
}
