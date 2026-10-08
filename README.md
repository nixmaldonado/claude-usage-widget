# Claude Usage — a macOS desktop widget

Your Claude plan limits on the desktop, next to the clock and calendar: the
**5-hour session**, **this week** (all models), and **model-scoped weekly caps
like Fable**, each with its reset time. The same numbers as
[claude.ai → Settings → Usage](https://claude.ai/settings/usage), without opening it.

<!-- Add a screenshot: docs/widget.png -->

- **Small and medium** widget sizes, in light and dark mode
- A **pace marker** on each bar shows where an even burn rate would be right now
- The medium widget tells you whether the week is **on track** or when it **runs out at this pace**
- A tiny menu-bar item (optional) with the same numbers and a Refresh button

## Requirements

- macOS 14 Sonoma or later
- **Claude Code**, installed and signed in with your Claude Pro/Max account (`claude`, then `/login`).
  The widget reuses that login; it doesn't ask for your password.

## Install

**Prebuilt (no Xcode needed):**

```sh
curl -fsSL https://raw.githubusercontent.com/nixmaldonado/claude-usage-widget/main/install.sh | bash
```

This downloads `ClaudeUsage.zip` from the [latest release](https://github.com/nixmaldonado/claude-usage-widget/releases/latest),
built by [GitHub Actions](.github/workflows/build.yml) from this repo. Prefer to look first?
Download the zip and [`install.sh`](install.sh), read it, and run `bash install.sh ~/Downloads/ClaudeUsage.zip`.

**From source** (needs Xcode 15+, free on the Mac App Store):

```sh
git clone https://github.com/nixmaldonado/claude-usage-widget.git
cd claude-usage-widget
./build.sh
```

Either way the script copies the app to `/Applications`, checks that it can read
your usage, and launches it. Then:

**Right-click the desktop → Edit Widgets… → search "Claude Usage"** and drag it out.

The app runs in the background, starts at login, and refreshes every 2 minutes.
Clicking the widget refreshes immediately.

## How it works

```
Claude Code login (Keychain)          api.anthropic.com/api/oauth/usage
            │  read-only                         ▲
            ▼                                    │ every 2 min
   ClaudeUsage.app  (menu-bar agent) ────────────┘
            │  writes
            ▼
   ~/Library/Application Support/ClaudeUsageWidget/usage.json
            │  reads (sandboxed, read-only exception for this folder)
            ▼
   Claude Usage widget
```

- The app reads the OAuth token Claude Code keeps in your login Keychain
  (item `Claude Code-credentials`) with `/usr/bin/security`. It **never refreshes or
  rewrites** that token, so it can't log Claude Code out.
- It calls `GET https://api.anthropic.com/api/oauth/usage`, the endpoint behind
  Claude Code's `/usage`. That's the only network request it makes.
- The result goes to a small JSON file that the widget extension reads. WidgetKit
  requires widgets to be sandboxed, so the extension has a read-only exception for
  that one folder and no network access.

## Caveats

- **The usage endpoint is undocumented.** Anthropic can change it at any time. The
  parser is lenient (it understands both the `limits[]` array and the older
  `five_hour` / `seven_day` fields), but expect the occasional fix.
- **Your Claude Code login has to be current.** If you haven't used Claude Code for a
  while, its token may expire and the widget shows *"run `claude` to sign in"*. Run
  `claude` once and it recovers on the next refresh.
- **Signed ad-hoc, not notarized.** Notarization needs a paid Apple Developer ID, so
  `install.sh` clears the download's quarantine flag for you. Opening the zip by
  double-click instead will get it blocked by Gatekeeper.

## Troubleshooting

```sh
# Fetch once and print what the widget will show
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --once

# Print the raw API response (no secrets in it — just percentages and dates)
/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage --raw

# Live logs
log stream --predicate 'subsystem == "com.nixmaldonado.ClaudeUsage"'
```

- **Widget missing from the gallery:** make sure the app is in `/Applications` and has
  been opened once, then run `killall chronod NotificationCenter` and look again.
- **Widget shows old numbers:** WidgetKit throttles reloads. Click the widget to force a
  refresh.
- **Menu-bar icon hidden:** open Claude Usage again from Spotlight to bring it back.

## Uninstall

```sh
./uninstall.sh
```

## Development

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). Edit
`project.yml`, then run `xcodegen generate` or `./build.sh`.

```
App/      menu-bar agent: Keychain login, API fetch, parser, login item
Widget/   WidgetKit extension: timeline + small/medium views
Shared/   snapshot model and file location used by both
```

## Credits

Endpoint details were worked out by the community; see
[ClaudeBar](https://github.com/GordonBeeming/claude-bar) and
[ai-usagebar](https://docs.rs/crate/ai-usagebar/latest) for menu-bar takes on the same idea.

Not affiliated with Anthropic.

## License

[MIT](LICENSE)
