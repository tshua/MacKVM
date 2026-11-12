#!/bin/zsh
# 构建 SwitchBar.app（无需 Xcode 工程，只需命令行工具）
set -e
cd "${0:A:h}"
APP=build/SwitchBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -parse-as-library -swift-version 5 -target arm64-apple-macos13.0 Sources/*.swift -o "$APP/Contents/MacOS/SwitchBar"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.switchbar</string>
    <key>CFBundleName</key><string>SwitchBar</string>
    <key>CFBundleDisplayName</key><string>设备切换</string>
    <key>CFBundleExecutable</key><string>SwitchBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force -s - "$APP"
echo "已生成 $PWD/$APP"
