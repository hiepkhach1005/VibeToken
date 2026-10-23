# VibeToken

A super-light macOS menu bar app that shows your **Claude Code and Codex quota**, plus token and cost statistics in the spirit of [TokenWatch](https://github.com/alvin0/token-watch). No extra sign-in: it reads the credentials already on your Mac.

<p align="center"><img src="docs/screenshot.png" alt="VibeToken" width="460"></p>

```
✳ 5H 5% · W 87%        ← quota left: 5-hour session · weekly
```

- Pure Swift + AppKit, no dependencies, 3 source files.
- No Dock icon, no windows: just an `NSMenu`. Light/dark follows the system theme.
- Light: about 50 MB RAM and 0% CPU when idle. One timer fires every 5 minutes and queries providers in parallel.
- Providers you are not signed in to, or not using, are hidden.

## Install

**Download:** grab `VibeToken.zip` from [Releases](../../releases), unzip it, and drag `VibeToken.app` to `~/Applications` or `/Applications`.
The app is ad-hoc signed, not notarized. The first time, right-click it and choose **Open** (or run `xattr -dr com.apple.quarantine VibeToken.app`).

**Build from source** (Xcode Command Line Tools, macOS 13+):

```bash
./build.sh             # build, install to ~/Applications, launch
./build.sh --no-open   # build and install only
./build.sh --release   # universal build (Apple Silicon + Intel) -> build/VibeToken.zip
```

`VibeToken.app/Contents/MacOS/VibeToken --dump` prints the whole menu to the terminal and exits, which is handy for checking numbers.

## Features

**Quota (Claude Code / Codex)**
- 5-hour session and weekly windows: % left and % used, reset time, time remaining.
- Per-model or per-feature weekly limits (Opus, Sonnet, Code Review…) when the API returns them, plus weekly usage by surface and extra usage.
- Context of the latest session, e.g. `21.8% · 218.3K / 1.0M · project`.
- Account, organization, plan (Pro/Max, Plus/Pro/Team…).

**Usage statistics (TokenWatch-style)**
- Filter by source (All / Codex / Claude) and period (Today, 7 days, 7 weeks, 6 months, 2 years).
- Cost compared with the previous period, and tokens by type: input, output, cache read, cache write, reasoning. Also turns, tool calls, models, and cost per turn.
- Trend chart by tokens, cost, or turns. Top models, tool calls, sessions, and insights.

**Options**
- English / Tiếng Việt.
- Show today's cost in the menu bar.
- Notify when quota ≥ 80% / 95%.
- Daily, weekly, and monthly cost alerts, which notify at 80%, 95%, and 100% of the budget.
- Custom model pricing, and a full log rescan.
- Refresh (⌘R), Open at Login, Quit (⌘Q).

## Where the data comes from

| | Quota | Account |
|---|---|---|
| Claude Code | `GET api.anthropic.com/api/oauth/usage`, with the token read from the Keychain item `Claude Code-credentials` (fallback: `~/.claude/.credentials.json`) | `oauthAccount` in `~/.claude.json` |
| Codex | The last `token_count` event with `rate_limits` in `~/.codex/sessions/**/rollout-*.jsonl`. If that data is older than the reset time, VibeToken calls `GET chatgpt.com/backend-api/wham/usage` (endpoint taken from [openai/codex](https://github.com/openai/codex)) | Decoded `id_token` JWT in `~/.codex/auth.json` |

Token and cost statistics come from the JSONL logs that Claude Code and Codex already write. VibeToken keeps only counts, never content, and caches them incrementally in `~/Library/Caches/VibeToken`. Costs use TokenWatch's price table. You can override prices in `~/Library/Application Support/VibeToken/pricing.json` (USD per 1M tokens).

## Privacy & safety

- Read-only. VibeToken never refreshes tokens and never writes to the Keychain, `~/.claude*`, or `~/.codex/`. Refreshing would rotate the token and sign the CLI out.
- Tokens are only sent to `api.anthropic.com` and `chatgpt.com`. Nothing is logged, and there are no analytics.
- Expired sign-in: the provider shows `—` with a "sign in again" hint.
- Network errors: the last good numbers are kept and marked "(stale data)". The APIs are called at most once every 30 seconds.

## Uninstall

1. Untick **Open at Login** in the menu (or remove the app in System Settings → General → Login Items).
2. **Quit** (⌘Q).
3. Delete the app and its data:

```bash
rm -rf ~/Applications/VibeToken.app ~/Library/Caches/VibeToken "$HOME/Library/Application Support/VibeToken"
defaults delete com.vibetoken.VibeToken
```

## Credits

- The idea, the model price table, and the Claude/Codex icons come from [TokenWatch](https://github.com/alvin0/token-watch) by alvin0 (MIT).
- Author: **Bá Vương**. Licensed under [MIT](LICENSE).
