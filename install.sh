#!/usr/bin/env bash
# Installs Claude Usage into /Applications (or ~/Applications) and launches it.
#
#   curl -fsSL https://github.com/nixmaldonado/claude-usage-widget/releases/latest/download/install.sh | bash
#   bash install.sh ~/Downloads/ClaudeUsage.zip
#   bash install.sh build/Release/ClaudeUsage.app      # what build.sh does
#
# The copy of this script attached to each GitHub release has the two lines
# below filled in, so it only installs the zip from that same release and
# refuses it unless its SHA-256 matches.
release_tag="latest"
expected_sha256=""

repo="nixmaldonado/claude-usage-widget"

# Everything runs inside main, so a download cut off halfway through
# `curl | bash` executes nothing.
main() {
  set -euo pipefail

  say() { printf '\033[1;38;5;173m==>\033[0m %s\n' "$*"; }
  die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

  [[ "$(uname)" == "Darwin" ]] || die "Claude Usage is a macOS widget."
  [[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || die "Needs macOS 14 Sonoma or later."

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  local source="${1:-}"
  if [[ -z "$source" ]]; then
    local base="https://github.com/$repo/releases/latest/download"
    [[ "$release_tag" == "latest" ]] || base="https://github.com/$repo/releases/download/$release_tag"
    source="$tmp/ClaudeUsage.zip"
    say "Downloading ClaudeUsage.zip ($release_tag release)..."
    curl -fL --progress-bar "$base/ClaudeUsage.zip" -o "$source" \
      || die "Download failed. Get ClaudeUsage.zip from https://github.com/$repo/releases and run: bash install.sh ~/Downloads/ClaudeUsage.zip"
    if [[ -z "$expected_sha256" ]]; then
      expected_sha256="$(curl -fsSL "$base/ClaudeUsage.zip.sha256" | cut -d' ' -f1)" \
        || die "Couldn't fetch the release checksum."
    fi
  fi

  local app
  case "$source" in
    *.zip)
      [[ -f "$source" ]] || die "No such file: $source"
      if [[ -n "$expected_sha256" ]]; then
        local actual
        actual="$(shasum -a 256 "$source" | cut -d' ' -f1)"
        [[ "$actual" == "$expected_sha256" ]] || die "Checksum mismatch for $source (expected $expected_sha256, got $actual). Not installing."
        say "Checksum OK ($actual)"
      fi
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
  codesign --verify --deep --strict "$app" 2>/dev/null || die "$app has a broken code signature. Not installing."

  local dest_dir="/Applications"
  [[ -w "$dest_dir" ]] || dest_dir="$HOME/Applications"
  mkdir -p "$dest_dir"
  local dest="$dest_dir/ClaudeUsage.app"

  say "Installing to ${dest}..."
  pkill -x ClaudeUsage 2>/dev/null || true
  sleep 0.5
  rm -rf "$dest"
  ditto "$app" "$dest"
  # Release builds are ad-hoc signed, not notarized (that needs a paid Apple
  # Developer ID), so clear the quarantine flag the download picked up.
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R "$dest" >/dev/null 2>&1 || true
  pluginkit -a "$dest/Contents/PlugIns/ClaudeUsageWidget.appex" >/dev/null 2>&1 || true

  say "Checking your Claude Code login..."
  if "$dest/Contents/MacOS/ClaudeUsage" --once >"$tmp/first.json" 2>"$tmp/first.err"; then
    local i=0 label pct
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
Add the widget: right-click the desktop, choose Edit Widgets..., search "Claude Usage".
EOF
}

main "$@"
