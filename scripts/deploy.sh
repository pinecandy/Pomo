#!/bin/bash
#
# Deploys the release binary into both app bundles.
#
#   ~/Pomo/Pomo.app        the local bundle
#   /Applications/Pomo.app the one that actually gets launched
#
# Both, always — they are meant to be identical, and updating only one has
# bitten this project before (you fix a bug, relaunch, and the old binary is
# still what starts).
#
# Copy-then-rename rather than writing in place: a partial write over a running
# binary is how you get a bundle that will not launch. The rename is atomic, so
# the bundle is only ever pointing at a complete file. Then an ad-hoc re-sign,
# because replacing the executable invalidates the bundle's signature and
# macOS will refuse to launch it.
#
# Refuses to run if the gates are not green — shipping an unverified binary is
# the thing this script exists to prevent.

set -uo pipefail
cd "$(dirname "$0")/.."

BUNDLES=("$HOME/Pomo/Pomo.app" "/Applications/Pomo.app")
ICON="Assets/PomoIcon.icns"
ICON_NAME="PomoIcon.icns"
APP_COPYRIGHT="Copyright © 2026 pinecandy."

[ -f "$ICON" ] || { echo "no app icon at $ICON"; exit 1; }

set_plist_string() {
    local plist="$1"
    local key="$2"
    local value="$3"

    if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist"
    else
        /usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist"
    fi
}

install_branding() {
    local bundle="$1"
    local plist="$bundle/Contents/Info.plist"
    local resources="$bundle/Contents/Resources"

    [ -f "$plist" ] || { echo "FAILED: no Info.plist"; return 1; }
    mkdir -p "$resources" || { echo "FAILED to create Resources"; return 1; }
    cp "$ICON" "$resources/$ICON_NAME.new" || { echo "FAILED to stage icon"; return 1; }
    mv -f "$resources/$ICON_NAME.new" "$resources/$ICON_NAME" || {
        echo "FAILED to swap in icon"
        return 1
    }
    set_plist_string "$plist" CFBundleIconFile "$ICON_NAME" || return 1
    set_plist_string "$plist" NSHumanReadableCopyright "$APP_COPYRIGHT" || return 1
}

echo "=== gates ==="
if ! ./scripts/check.sh >/tmp/pomo-deploy-check.log 2>&1; then
    echo "REFUSING: scripts/check.sh failed. Not deploying."
    tail -20 /tmp/pomo-deploy-check.log
    exit 1
fi
echo "ok"

echo "=== build (release) ==="
swift build -c release 2>&1 | tail -1 || exit 1
BINARY=".build/release/Pomo"
[ -x "$BINARY" ] || { echo "no release binary at $BINARY"; exit 1; }
echo "source: $(shasum "$BINARY" | cut -d' ' -f1)"

if pgrep -x Pomo >/dev/null 2>&1; then
    echo
    echo "NOTE: Pomo is running. The rename is atomic so this is safe, but the"
    echo "      running instance keeps the OLD code until you quit and relaunch."
fi

for bundle in "${BUNDLES[@]}"; do
    echo
    echo "=== $bundle ==="
    dest="$bundle/Contents/MacOS/Pomo"
    if [ ! -d "$bundle" ]; then
        echo "SKIP: bundle does not exist"
        continue
    fi
    install_branding "$bundle" || exit 1
    cp "$BINARY" "$dest.new" || { echo "FAILED to stage"; exit 1; }
    mv -f "$dest.new" "$dest" || { echo "FAILED to swap in"; exit 1; }
    codesign --force -s - "$bundle" 2>&1 | sed 's/^/  /'
    codesign -v "$bundle" 2>&1 | sed 's/^/  /'
    echo "  deployed: $(shasum "$dest" | cut -d' ' -f1)"
done

echo
echo "=== verify ==="
for bundle in "${BUNDLES[@]}"; do
    [ -d "$bundle" ] || continue
    printf '  %-28s %s\n' "$(basename "$(dirname "$(dirname "$bundle")")")/$(basename "$bundle")" \
        "$(shasum "$bundle/Contents/MacOS/Pomo" | cut -d' ' -f1)"
    printf '  %-28s %s\n' "$(basename "$bundle") icon" \
        "$(shasum "$bundle/Contents/Resources/$ICON_NAME" | cut -d' ' -f1)"
done
echo "  source                       $(shasum "$BINARY" | cut -d' ' -f1)"
