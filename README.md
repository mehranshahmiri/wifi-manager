# Wi-Fi Manager for macOS

A small native SwiftUI app for diagnosing and repairing Wi-Fi on older Macs.

- **Networks** – scan, join (with password) and manage saved networks
- **Fix** – diagnose and one-click repair for "no IP" and DNS failures (flush DNS, reset to DHCP, cycle Wi-Fi, renew lease)
- **DNS** – view and change DNS servers
- **Info** – interface, RSSI and link details

Built with `networksetup` and the `airport` utility. Operations that need root go through the standard macOS admin password dialog (AppleScript); the app never stores passwords.

Tested on macOS 12.7.6 (Intel). Note: Apple removed the `airport` utility in macOS 14.4+, so scanning/RSSI may not work there.

## Build
```sh
./build.sh            # builds "Wi-Fi Manager.app"
./build.sh install    # ...and copies it to /Applications
```
Requires macOS 12+ and Xcode command line tools.

## Icon
`AppIcon.icns` is included; `makeicon.swift` renders the 1024px source.

## License
MIT
