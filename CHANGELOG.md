# Changelog

## [1.0.2] - 2026-11-10

### Fixed

- The Desktop shortcut could keep a stale "?" icon after the SMB volume was unmounted and remounted (for example after sleep). AutoMount now recreates the shortcut and posts a filesystem-change notification when it mounts the share or starts while already mounted.

## [1.0.1] - 2026-11-06

### Fixed

- Location went stale while the Mac was stationary: macOS ignores `requestLocation()` while continuous updates are active, so the app could wrongly treat the Mac as "out of range" after 10 minutes and auto-unmount. The app now pauses continuous updates, requests a fresh fix, then resumes updates; it also restarts location updates after wake.

## [1.0.0] - 2026-11-06

### Added

- Menu bar agent that automatically mounts an SMB share when the Mac is connected to a whitelisted Wi-Fi network **and** within a saved location radius.
- Automatic unmount after leaving, with a configurable grace period.
- Desktop shortcut (symbolic link) to the mounted share.
- Menu bar status: SSID, distance to trigger, mount point, permission state, last error.
- Manual mount/unmount, "update trigger from current location", pause and check-now actions.
- LaunchAgent that starts at login, with a single-instance lock.
- CLI: `--status`, `--check`, `--mount`, `--unmount`, `--learn-current`, `--init`, `--install-agent`, `--uninstall-agent`, `--remove-desktop-alias`.
- macOS 26 (Tahoe) compatible icon that avoids the grey icon plate.
- English and Simplified Chinese documentation, MIT license.
