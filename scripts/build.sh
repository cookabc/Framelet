#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if pgrep -x Framelet >/dev/null; then
    echo "Quit Framelet before building and installing, so the running app is not overwritten." >&2
    exit 1
fi
identity_file="$PWD/.framelet-signing-identity"
sign_identity="${FRAMELET_SIGN_IDENTITY:-}"
if [[ -z "$sign_identity" && -f "$identity_file" ]]; then
    sign_identity="$(cat "$identity_file")"
fi
if [[ -z "$sign_identity" ]]; then
    # Accept either identity the README mentions. BSD sed has no alternation, hence two patterns.
    sign_identity="$(
        security find-identity -v -p codesigning \
            | sed -n -e 's/^[[:space:]]*[0-9]*) \([A-F0-9]\{40\}\) "Apple Development:.*$/\1/p' \
                -e 's/^[[:space:]]*[0-9]*) \([A-F0-9]\{40\}\) "Developer ID Application:.*$/\1/p' \
            | head -n 1
    )"
fi
if [[ -z "$sign_identity" || "$sign_identity" == "-" ]]; then
    echo "A stable Apple Development or Developer ID signing identity is required. Set FRAMELET_SIGN_IDENTITY; the script no longer falls back to ad-hoc signing." >&2
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
    echo "The signature has no team identifier, so this build was not installed." >&2
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
    echo "Framelet was opened during the build. Quit it and install again." >&2
    exit 1
fi
if [[ -e "$install_path" ]]; then
    installed_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$install_path/Contents/Info.plist")"
    [[ "$installed_id" == "studio.framelet.mac" ]] || { echo "Another application already occupies the install path." >&2; exit 1; }
    mv "$install_path" "$stage_dir/previous.app"
fi
mv "$stage_dir/Framelet.app" "$install_path"
codesign --verify --deep --strict "$install_path"
echo "Installed: $install_path"
