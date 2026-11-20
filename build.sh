#!/bin/bash
# 拣影 —— 构建脚本（纯命令行工具链，不需要 Xcode）
set -e
cd "$(dirname "$0")"

APP="拣影.app"
BIN=".build/jianying"

echo "==> 编译"
swiftc -O -parse-as-library -target arm64-apple-macos14.0 \
  -o "$BIN" Sources/*.swift \
  -framework SwiftUI -framework AppKit -framework Photos -framework ImageIO -framework AVFoundation

echo "==> 打包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Jianying"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>拣影</string>
  <key>CFBundleDisplayName</key><string>拣影</string>
  <key>CFBundleIdentifier</key><string>com.alma.jianying</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>Jianying</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><true/>
  <key>NSPhotoLibraryAddUsageDescription</key>
  <string>拣影需要把您挑选保留的照片导入「照片」App。</string>
  <key>NSPhotoLibraryUsageDescription</key>
  <string>拣影需要访问「照片」App 来导入您挑选的照片。</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>文件夹</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSItemContentTypes</key><array><string>public.folder</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "==> 签名 (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   跳过签名"

echo "==> 完成: $(pwd)/$APP"
