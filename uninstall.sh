#!/usr/bin/env bash
# Removes Claude Usage, its login item and its cached snapshot.
set -euo pipefail

for app in /Applications/ClaudeUsage.app "$HOME/Applications/ClaudeUsage.app"; do
  if [[ -d "$app" ]]; then
    # Unregister the login item while the binary still exists.
    "$app/Contents/MacOS/ClaudeUsage" --unregister-login-item 2>/dev/null || true
    pkill -x ClaudeUsage 2>/dev/null || true
    pluginkit -r "$app/Contents/PlugIns/ClaudeUsageWidget.appex" >/dev/null 2>&1 || true
    rm -rf "$app"
    echo "Removed $app"
  fi
done

rm -rf "$HOME/Library/Application Support/ClaudeUsageWidget"
defaults delete com.nixmaldonado.ClaudeUsage >/dev/null 2>&1 || true
echo "Done. If the widget is still on your desktop, remove it with Edit Widgets."
