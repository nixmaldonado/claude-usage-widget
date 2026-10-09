#!/usr/bin/env bash
# Builds Claude Usage from source (needs Xcode), then installs and launches it
# via install.sh. No Xcode? Use install.sh on its own to get a prebuilt release.
set -euo pipefail
cd "$(dirname "$0")"

say() { printf '\033[1;38;5;173m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "Claude Usage is a macOS widget."

# WidgetKit extensions need full Xcode, not just the Command Line Tools. If
# xcode-select points at the CLT, look for any Xcode*.app and use it via
# DEVELOPER_DIR (no sudo, doesn't change your global setting).
developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ "$developer_dir" != *.app/* ]]; then
  xcode_app="$( { mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null;
                  ls -d /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app 2>/dev/null; } | head -1)"
  if [[ -z "$xcode_app" ]]; then
    die "Full Xcode is required to build from source (free on the Mac App Store); the Command Line Tools can't build widgets.
       No Xcode? Download a prebuilt ClaudeUsage.zip from the GitHub Releases page instead (see README)."
  fi
  export DEVELOPER_DIR="$xcode_app/Contents/Developer"
  say "Using $xcode_app"
fi

# Regenerate the project from project.yml when XcodeGen is around; otherwise
# fall back to the committed ClaudeUsage.xcodeproj.
if command -v xcodegen >/dev/null 2>&1; then
  say "Generating Xcode project..."
  xcodegen generate --quiet
elif [[ ! -d ClaudeUsage.xcodeproj ]]; then
  command -v brew >/dev/null 2>&1 || die "XcodeGen is needed: https://github.com/yonaskolb/XcodeGen"
  say "Installing XcodeGen..."
  brew install xcodegen
  xcodegen generate --quiet
fi

mkdir -p build
say "Building (Release)..."
if ! xcodebuild -project ClaudeUsage.xcodeproj -target ClaudeUsage -configuration Release \
     SYMROOT="$PWD/build" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
     ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
     CLAUDE_USAGE_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo local)" \
     build >build/xcodebuild.log 2>&1; then
  grep -E "error:|license" build/xcodebuild.log | head -20 || tail -30 build/xcodebuild.log
  die "Build failed. Full log: build/xcodebuild.log"
fi

app="build/Release/ClaudeUsage.app"
[[ -d "$app" ]] || die "Build finished but $app is missing."

bash ./install.sh "$app"
