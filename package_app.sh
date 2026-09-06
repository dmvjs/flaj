#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="Flaj.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/Flaj "$APP/Contents/MacOS/Flaj"
cp AppIcon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp AppIcon/FlajDoc.icns "$APP/Contents/Resources/FlajDoc.icns"

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Flaj</string>
    <key>CFBundleDisplayName</key><string>Flaj</string>
    <key>CFBundleIdentifier</key><string>com.flaj.app</string>
    <key>CFBundleExecutable</key><string>Flaj</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Flaj Document</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>CFBundleTypeIconFile</key><string>FlajDoc</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>flaj</string></array>
            <key>LSItemContentTypes</key>
            <array><string>com.flaj.document</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.flaj.document</string>
            <key>UTTypeDescription</key><string>Flaj Document</string>
            <key>UTTypeIconFile</key><string>FlajDoc</string>
            <key>UTTypeConformsTo</key>
            <array><string>public.data</string></array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array><string>flaj</string></array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
EOF

touch "$APP"

# swift build already ad-hoc-signs the bare executable, but Info.plist and
# the icons get added to the bundle afterward, so the signature never
# covered them (codesign -dv showed "Sealed Resources=none" and
# "Info.plist=not bound") — re-signing the whole assembled bundle here
# seals everything together, which is what Finder/LaunchServices need to
# trust the declared icons rather than falling back to a generic one.
codesign --force --deep --sign - "$APP"

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(pwd)/$APP"
echo "Built $APP"
