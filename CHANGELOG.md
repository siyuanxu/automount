# Changelog

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
