#!/usr/bin/env bash
# Installs Claude Usage into /Applications (or ~/Applications) and launches it.
#
#   bash install.sh                      # download the latest GitHub release (no Xcode needed)
#   bash install.sh ~/Downloads/ClaudeUsage.zip
#   bash install.sh build/Release/ClaudeUsage.app   # what build.sh does
set -euo pipefail

repo="nixmaldonado/claude-usage-widget"

say() { printf '\033[1;38;5;173m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Claude Usage is a macOS widget."
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || die "Needs macOS 14 Sonoma or later."

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

source="${1:-}"
if [[ -z "$source" ]]; then
  source="$tmp/ClaudeUsage.zip"
  say "Downloading the latest release..."
  curl -fL --progress-bar "https://github.com/$repo/releases/latest/download/ClaudeUsage.zip" -o "$source" \
    || die "Download failed. Get ClaudeUsage.zip from https://github.com/$repo/releases and run: bash install.sh ~/Downloads/ClaudeUsage.zip"
fi

case "$source" in
  *.zip)
    [[ -f "$source" ]] || die "No such file: $source"
    ditto -x -k "$source" "$tmp/unzipped"
    app="$tmp/unzipped/ClaudeUsage.app"
    ;;
  *.app | *.app/)
    app="${source%/}"
    ;;
  *)
    die "Expected a .zip or .app, got: $source"
    ;;
esac
[[ -d "$app/Contents/PlugIns/ClaudeUsageWidget.appex" ]] || die "$app doesn't look like a Claude Usage build."

dest_dir="/Applications"
[[ -w "$dest_dir" ]] || dest_dir="$HOME/Applications"
mkdir -p "$dest_dir"
dest="$dest_dir/ClaudeUsage.app"

say "Installing to ${dest}..."
pkill -x ClaudeUsage 2>/dev/null || true
sleep 0.5
rm -rf "$dest"
ditto "$app" "$dest"
# Downloaded builds are ad-hoc signed, not notarized; clear the quarantine flag
# so Gatekeeper lets the app and its widget run.
xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$dest" >/dev/null 2>&1 || true
pluginkit -a "$dest/Contents/PlugIns/ClaudeUsageWidget.appex" >/dev/null 2>&1 || true

say "Checking your Claude Code login..."
if "$dest/Contents/MacOS/ClaudeUsage" --once >"$tmp/first.json" 2>"$tmp/first.err"; then
  i=0
  while label=$(plutil -extract "limits.$i.label" raw -o - "$tmp/first.json" 2>/dev/null); do
    pct=$(plutil -extract "limits.$i.percent" raw -o - "$tmp/first.json")
    printf '    %-12s %3.0f%%\n' "$label" "$pct"
    i=$((i + 1))
  done
else
  printf '    \033[33m%s\033[0m\n' "$(cat "$tmp/first.err")"
  echo "    The widget will say so until it can fetch. See the README's Troubleshooting section."
fi

say "Launching..."
open "$dest"

cat <<'EOF'

Done. Claude Usage runs in the background (menu bar) and starts at login.
Add the widget: right-click the desktop → Edit Widgets... → search "Claude Usage".
EOF
