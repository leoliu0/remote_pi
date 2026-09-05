# x86_64 Binary

Cockpit.app build notes for x86_64 architecture compiled on Intel hardware.

Processor: Intel(R) Core(TM) i7-14700K
GPU: AMD Radeon RX 6800 XT 16GB
RAM: 64GB (4x16GB) DDR5 5200MHz
OS: macOS Tahoe 26.2

Flutter 3.44.2 • channel stable • https://github.com/flutter/flutter.git
Framework • revision c9a6c48423 (5 weeks ago) • 2026-06-10 15:52:41 -0700
Engine • hash 04efd7c093d4e9281d5526ebcad6ecc60ba8badf (revision 77e2e94772)
Tools • Dart 3.12.2 • DevTools 2.57.0

Self-signing instructions for local unsigned runs:

```bash
APP="build/macos/Build/Products/Release/Cockpit.app"
ENT="$(mktemp)"
cp macos/Runner/Release.entitlements "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENT"
codesign --force --deep --options runtime --entitlements "$ENT" --sign - "$APP"
codesign -d --entitlements - "$APP" 2>&1
```
