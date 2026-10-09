#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -x Framelet >/dev/null; then
    echo "请先正常退出 Framelet，再构建并安装，避免覆盖正在运行的应用。" >&2
    exit 1
fi
identity_file="$PWD/.framelet-signing-identity"
sign_identity="${FRAMELET_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" && -f "$identity_file" ]]; then
    sign_identity="$(cat "$identity_file")"
fi
if [[ -z "$sign_identity" ]]; then
    sign_identity="$(security find-identity -v -p codesigning | sed -n 's/^[[:space:]]*[0-9]*) \([A-F0-9]\{40\}\) "Apple Development:.*$/\1/p' | head -n 1)"
fi
if [[ -z "$sign_identity" || "$sign_identity" == "-" ]]; then
    echo "需要固定的 Apple Development 或 Developer ID 签名身份。请设置 FRAMELET_SIGN_IDENTITY；不再回退到临时签名。" >&2
    exit 1
fi
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"
app_path="$PWD/dist/Framelet.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/Framelet" "$app_path/Contents/MacOS/Framelet"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
swift scripts/GenerateIcon.swift "$PWD/.build/AppIcon.iconset"
iconutil -c icns .build/AppIcon.iconset -o "$app_path/Contents/Resources/AppIcon.icns"
codesign --force --sign "$sign_identity" "$app_path"
codesign --verify --deep --strict "$app_path"
signature_details="$(codesign -dv "$app_path" 2>&1)"
if [[ ! "$signature_details" =~ TeamIdentifier=[A-Z0-9]{10} ]]; then
    echo "签名缺少开发团队标识，未安装此构建。" >&2
    exit 1
fi
printf '%s\n' "$sign_identity" > "$identity_file"

install_path="/Applications/Framelet.app"
stage_dir="$(mktemp -d /Applications/.framelet-install.XXXXXX)"
cleanup() {
    local result=$?
    if [[ "$result" -ne 0 && -d "$stage_dir/previous.app" ]]; then
        rm -rf "$install_path"
        mv "$stage_dir/previous.app" "$install_path"
    fi
    rm -rf "$stage_dir"
}
trap cleanup EXIT
ditto "$app_path" "$stage_dir/Framelet.app"
codesign --verify --deep --strict "$stage_dir/Framelet.app"
if pgrep -x Framelet >/dev/null; then
    echo "Framelet 在构建期间被打开，请退出后重新安装。" >&2
    exit 1
fi
if [[ -e "$install_path" ]]; then
    installed_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$install_path/Contents/Info.plist")"
    [[ "$installed_id" == "studio.framelet.mac" ]] || { echo "安装路径被其他应用占用。" >&2; exit 1; }
    mv "$install_path" "$stage_dir/previous.app"
fi
mv "$stage_dir/Framelet.app" "$install_path"
codesign --verify --deep --strict "$install_path"
echo "Installed: $install_path"
