<p align="center"><img src="docs/icon.png" width="128" alt="Reset icon"></p>

<h1 align="center">Reset</h1>

<p align="center">Know exactly when your AI usage window resets, get pinged on your phone when it does, and see what your usage is actually worth.</p>

<p align="center"><a href="https://msfbeast.github.io/reset/"><b>Website</b></a> · <a href="https://github.com/msfbeast/reset/releases/latest"><b>Download</b></a> · <a href="#faq">FAQ</a> · <a href="#troubleshooting">Troubleshooting</a> · <a href="CHANGELOG.md">Changelog</a></p>

<p align="center"><a href="https://github.com/msfbeast/reset/actions/workflows/tests.yml"><img src="https://github.com/msfbeast/reset/actions/workflows/tests.yml/badge.svg" alt="Tests"></a></p>

<p align="center"><img src="docs/share-card.png" width="720" alt="Reset share card"></p>

Reset is a free, open source macOS app for people who live inside Claude Code (with Codex, Gemini CLI, Antigravity and Cursor support too). It sits in your menu bar, counts down to your next fresh window, and turns your local usage logs into a dashboard, desktop widgets and a card you can post.

Everything it reads stays on your Mac.

## What it does

- **Your window at a glance.** A colored pill in the menu bar: orange "2:46 · 42%" as usual, red when the window is nearly empty or your pace runs out before the reset ("38% · out 10:07": 38% left, empty at 10:07 at this pace), green "ready" when a fresh window is waiting. Exact when live usage is on; estimated from your activity when it isn't, and labelled as such.
- **Phone alerts while your Mac sleeps.** Reset queues each reset alert on an [ntfy](https://ntfy.sh) server ahead of time, so it arrives on your phone even with the lid closed.
- **Limit forecast.** At your current pace, will you hit the limit before the reset? Reset warns you once per window, on your Mac and your phone.
- **Weekly limit, early.** On Pro and Max plans, Reset warns from 80% of the weekly limit (in the menu, the status line and one notification a week), so a used-up week doesn't come as a surprise. To keep an eye on it all the time, **Settings → Appearance → Limits** shows the weekly limit under the 5-hour window in the menu bar pill ("Both"), or on its own ("Weekly"). For Claude this needs live usage.
- **Work and personal accounts.** Use a Team account and a personal Pro plan? Each gets its own entry, window and countdown, and the dashboard splits costs, sessions and projects by account, each against its own plan price. The menu's top card, the menu bar and the mascot follow the account you're using. Live usage covers the account Claude Code is signed in to and, if you allow it, the other accounts signed in to the Claude desktop app.
- **Notifications you can act on.** Clicking one opens the dashboard; reset alerts have a Start now button and sign-in problems a Sign in button. Times follow your 12 or 24-hour clock.
- **Auto-start.** Optional. When a window runs out, Reset sends a one-word prompt so the next window starts right away instead of when you wake up.
- **Dashboard.** API-price value of your usage against your plan, cache savings, every 5-hour window of the week, token mix, when you build, cost per session and per project, and what used each session (main thread, subagents, each MCP server). Right-click a session to copy the command that resumes it; with two accounts it says which one the session ran under, and warns when Claude Code is signed in to the other. ⌘1–4 switch the range, ⌘R rescans.
- **8 desktop widgets**, including **Fuse**: your window as a burning fuse, with where today's pace runs out and how much to slow down to make the reset. The others: countdown, gauge, arrival, today's spend, month calendar, week, and a Game Boy. When a fresh window is waiting, the countdown and Fuse widgets show a **Start now** button that starts it right from your desktop. Plus **8 looks** for the menu card, and the other tools and accounts can each get a card too (Settings → Appearance).
- **Mascots.** Animated desktop pets whose mood and health bar follow your usage: fresh, focused, tired, asleep at the limit, waking at the reset.
- **Share card.** A 1200 × 675 image of your month for X.
- **Claude Code integration.** A status line for your terminal and an MCP server, so Claude can check how much window is left (and the weekly limit) and pace itself, including a per-task budget that tells it when to wrap up or switch to a smaller model. One click in Settings sets both up, and both say so when Reset isn't running rather than showing old numbers.
- **Stay awake.** Keeps the Mac from idle-sleeping (when plugged in, or always) so auto-start and alerts run on time, without a separate app. The display still sleeps.
- **One-minute setup.** A first-run guide picks your tools, signs Claude Code in, sets up phone alerts with a QR code, and takes your plan price.

<p align="center"><img src="docs/menubar.png" width="720" alt="Menu bar pill: as usual, almost empty, pace runs out first, fresh window waiting, weekly limit"></p>

<p align="center"><img src="docs/dashboard.png" width="820" alt="Dashboard"></p>

<p align="center"><img src="docs/widgets.png" width="820" alt="Widgets"></p>

<p align="center"><img src="docs/looks.png" width="560" alt="Looks"></p>

## Install

**Download:** grab the latest `.dmg` from [Releases](https://github.com/msfbeast/reset/releases/latest), open it and drag Reset to Applications.

Reset isn't notarized yet, so macOS blocks the first launch. Open Reset once, close the warning, then go to **System Settings → Privacy & Security** and click **Open Anyway** next to Reset. You only do this once. (Or run `xattr -dr com.apple.quarantine /Applications/Reset.app` in Terminal.)

The download is ad-hoc signed, so its widgets won't appear. For widgets, build it yourself as below.

**Build from source** (about two minutes):

You need macOS 14 or later, Xcode 16 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
git clone https://github.com/msfbeast/reset.git
cd reset
./scripts/build.sh --install
```

That builds an ad-hoc signed app and copies it to `/Applications`.

**Widgets need a real signature.** macOS only lists widgets from apps signed with an Apple Development certificate. If you're signed in to Xcode with any Apple ID (a free one works), pass your team ID:

```bash
TEAM=ABCDE12345 ./scripts/build.sh --install
```

Find your team ID in Xcode under Settings → Accounts, or in Keychain Access on your "Apple Development" certificate.

## Setting it up

The first launch opens a short setup guide that covers all of this. You can run it again from **Settings → Advanced**, or change anything below in **Settings**, which has four tabs: **General** (live usage, your tools, alerts), **Automation** (auto-start, stay awake), **Appearance** (look, mascots) and **Advanced** (commands, custom tools, Claude Code integration, diagnostics).

| Feature | How |
|---|---|
| Exact Claude usage | **Settings → General**: turn on **Live usage from your Claude account**. Reset reads the sign-in that the Claude Code CLI stores in your Keychain and asks Anthropic for your current usage every 2 minutes while you're using Claude Code, and every 5 minutes otherwise. If it says the sign-in expired, run `claude auth login` once. |
| Phone alerts | Install the free ntfy app, subscribe to a long random topic name, and enter the same topic under **Settings → General → Phone alerts**. Anyone who knows the topic can read it, so make it unguessable. |
| Auto-start | **Settings → Automation**: turn on **Auto-start** for Claude. It runs `claude -p "hi" --model haiku` (the command is under Advanced) once when a window you were watching runs out, while the Mac is awake. Each run uses a little of your quota. |
| Value multiple | Press **Add your plan price** on the dashboard and enter what you pay per month. |
| Stay awake | **Settings → Automation → Stay awake**: Off, When plugged in, or Always. Blocks idle sleep only; closing the lid still sleeps the Mac unless it's plugged in with an external display. |
| Status line | **Settings → Advanced → Claude Code integration → Add for me** (it backs up `settings.json` first), or add to `~/.claude/settings.json`: `"statusLine": {"type": "command", "command": "cat \"$HOME/Library/Application Support/Reset/statusline.txt\""}` |
| MCP server | **Add for me** in the same place, or `claude mcp add --scope user reset -- /Applications/Reset.app/Contents/MacOS/reset-mcp` (with Reset's real location if it isn't in Applications). Tools: `get_claude_usage`, plus `set_budget` (task, max window %, optional downshift model) and `clear_budget`. With a budget set, the advice moves from normal to wrap-up at 80% of the cap to downshift at the cap. The active budget shows under the burn bar on the dashboard, with a Clear button. It's kept in `budget.json` next to `widget.json` and never leaves the Mac. |

## FAQ

**Does Claude checking its own window over MCP use up that window?** Barely. Reset's MCP server makes no API call; it reads a file Reset already keeps on your Mac. The only cost is the answer landing in the conversation, about 150 to 250 tokens a check, plus about 350 tokens for the three tools' descriptions in context. That's less than Claude reading one small file.

**Can an agent tell when the numbers are old?** Yes. `get_claude_usage` includes `usage_as_of` and `usage_age_minutes` (when the usage was last read from Anthropic), and if the live check starts failing, `live_check_failing_since_local`, the reason, and `usage_may_be_stale: true`. The advice and any budget then say the reading may be out of date. If Reset itself quits, everything is marked `stale`.

**How exact is the countdown?** With live usage on, the reset time and % come straight from your Claude account, refreshed every 2 minutes while you work and every 5 when idle. Without it, Reset estimates from your Claude Code activity and labels the numbers "estimated", so you always know which you're looking at.

**Does it track the weekly limit?** Yes, on Pro and Max plans with live usage on. The menu shows the weekly %, it warns you from 80% (in the menu, the status line and one notification a week), and once it's used up it shows when it lifts. Claude sees it through the MCP server too.

**How do task budgets work?** Before a big task, Claude (or you, by asking it) sets a budget over MCP: a task name, the window % to stop at, and optionally a smaller model to fall back to. As the window nears that % Claude is told to wrap up, and past it to move to the fallback model or stop and check in. Reset doesn't switch models itself, and Claude can't change its own: it hands the remaining steps to subagents on that model (which start fresh, with only the brief Claude writes), or asks you to run `/model` to continue with the whole conversation. The cap is the window's total usage ("stop when the window hits 60%"), not the task's own share. It's guidance Claude follows, not a hard lock.

**Does auto-start use up my usage?** Almost none. It sends one word to the smallest model (Haiku) with no tools or MCP servers loaded, which is just enough to start the 5-hour clock. It waits for a working network instead of failing offline, and gives up after 4 tries.

**Does it work with the lid closed?** Phone alerts do: each one is queued on the ntfy server ahead of time, so it arrives while the Mac sleeps. Auto-start needs the Mac awake, so leave it plugged in with **Stay awake** on; on battery with the lid closed, it starts the window the moment the Mac wakes.

**I have two Claude accounts.** Each gets its own entry, window, costs and plan price, and you can name them (Settings → General → Claude accounts). Live usage, the forecast, auto-start and budgets follow the account Claude Code is signed in to; the other one is estimated. See [Troubleshooting](#troubleshooting) for details.

**Does it read my prompts or code?** No. From Claude Code's local logs it keeps token counts, model names, times, tool names, project folders and session titles, never the text of your prompts or Claude's replies. See [Privacy](#privacy) for exactly what leaves your Mac and when.

**Is this made by Anthropic?** No. Reset is an independent, open source project, not affiliated with or endorsed by Anthropic.

**Why does the first launch need "Open Anyway", and why no widgets in the download?** Reset isn't notarized by Apple yet. Notarization is coming; until then, open it once via System Settings → Privacy & Security, and build from source for widgets (see [Install](#install)).

## Troubleshooting

**macOS says it can't open Reset.** It isn't notarized yet. Open it once, close the warning, then go to **System Settings → Privacy & Security** and click **Open Anyway**. You only do this once.

**I don't see Reset's widgets.** The download is ad-hoc signed, and macOS only lists widgets from apps signed with an Apple Development certificate. Build it yourself with your team ID (see [Install](#install)); a free Apple ID works. If they still don't appear, log out and back in so macOS refreshes the widget list.

**The menu or widgets say "estimated".** Reset is guessing from your Claude Code activity instead of reading your real usage. Turn on **Settings → General → Live usage from your Claude account**. The note says why it's guessing:
- *live usage off*: turn it on.
- *Claude Code signed out*: press **Fix** in the menu, or run `claude auth login` in Terminal.
- *waiting for live usage*: it was just switched on or Reset just started; give it a minute.
- *live usage unavailable*: Settings → General shows the reason under the switch.

If macOS asks whether `security` may read "Claude Code-credentials" from your Keychain, click **Always Allow**. That's how Reset reads Claude Code's sign-in.

**The countdown is off, or the window started earlier than Reset thinks.** Without live usage, Reset can't see Claude used on claude.ai or in the desktop app, only Claude Code. Live usage fixes this. Without it, pick **I just used Claude on the web** from the menu's **…** button when you start there.

**I use two Claude accounts (say, a work Team plan and a personal Pro plan).** Reset shows each as its own entry, with its own window and countdown, worked out from that account's Claude Code sessions. The menu's top card, the menu bar and the mascot follow the account you're using: switching accounts in the Claude desktop app moves them. Live usage, the forecast, auto-start and the widgets go through the account Claude Code in Terminal is signed in to; with live usage on, Reset asks Anthropic which account that is, because `claude auth status` can show the Claude desktop app's account instead. Other accounts are estimated from their sessions and the desktop app's readings, unless they're signed in to the Claude desktop app: then turn on **Settings → General → Also other accounts in the Claude desktop app** for live usage there too. The MCP server answers for the account the asking agent runs on. The dashboard's All / Team / Pro switch splits costs, sessions and projects by account, and each account can have its own plan price (Settings → General).

**The menu bar shows only the countdown, with no percentage.** There's no usage reading yet, and Reset won't show the clock as if it were usage. Turn on live usage. Want plain text instead of the colored pill? **Settings → Appearance → Menu bar**.

**Phone alerts don't arrive.** Check that the topic in **Settings → General → Phone alerts** matches the one you subscribed to in the ntfy app exactly, then press **Send test**. Make sure notifications are allowed for ntfy on your phone, and to get through Do Not Disturb, allow high-priority alerts for that topic in the ntfy app.

**Mac notifications don't show.** Allow them in **System Settings → Notifications → Reset**.

**Auto-start didn't run.** **Settings → Automation** shows each tool's last run and why it failed, with a **Sign in** button if Claude Code was signed out. Also know that auto-start:
- only runs for a window Reset watched run out, never right when you switch it on;
- is skipped while a weekly limit is used up;
- needs the Claude Code command-line tool installed and signed in;
- runs late if the Mac was asleep. **Settings → Automation → Stay awake** keeps it awake when plugged in or always.

**Settings shows a "Claude Code log format" warning.** A Claude Code update probably changed how it writes its logs, so some usage can't be read. Check for a Reset update in the same box, or report it.

**Something else.** **Settings → Advanced → Report a problem** opens a GitHub issue with versions and on/off states filled in, never usage numbers, paths, project names or your phone topic. You see everything before sending.

**Uninstalling.** Quit Reset, drag it to the Trash, and delete `~/Library/Application Support/Reset`. If you set them up, also run `claude mcp remove --scope user reset` and remove the `statusLine` entry from `~/.claude/settings.json`.

## Privacy

Reset reads local files only:

- Claude Code transcripts in `~/.claude/projects`. Reset scans them for usage and keeps only token counts, models, timestamps, tool and MCP names, project folders and session titles, in a cache in `~/Library/Application Support/Reset`. Your prompts and Claude's replies are never stored.
- `~/Library/Application Support/Claude/plan-usage-history.json` from the Claude desktop app
- Only if you turn on **Also other accounts in the Claude desktop app**: the sign-in the desktop app keeps in `~/Library/Application Support/Claude/config.json`, decrypted in memory with the desktop app's key from your Keychain. macOS asks you first; click **Always Allow** so it doesn't ask again each time Reset starts. The downloaded build is ad-hoc signed, so macOS asks once more after each update. The same key can decrypt other data the desktop app encrypts on this Mac; Reset reads only the sign-in
- Codex session logs in `~/.codex/sessions`
- Antigravity's local language server, while Antigravity is open
- If you switch Cursor on: the Cursor app's sign-in and plan name in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, opened read-only

It only sends anything off your Mac for these features, and only to the place you'd expect:

- **Live Claude usage** sends Claude Code's sign-in to `api.anthropic.com` to read your usage and which account it belongs to. With **Also other accounts in the Claude desktop app** on, it does the same with the desktop app's sign-in for each of its other accounts. Reset never stores, refreshes or rewrites a sign-in.
- **Cursor**, off until you switch it on in Settings, sends the Cursor app's sign-in to `api2.cursor.sh` to read this month's usage. Reset never stores, refreshes or rewrites that sign-in.
- **Phone alerts** send the alert text to the ntfy server you choose. The text is only reset and run-out times, such as "Claude has reset: fresh window ready since 7:40 PM", but anyone who knows your topic name can read it, so pick a long, random topic.
- **Update checks** ask `api.github.com` once a day whether a newer release exists. Turn this off in Settings → General.

No analytics, no accounts, no servers of its own.

**About the MCP server:** when Claude calls one of Reset's MCP tools, the result goes into your Claude Code conversation like any other tool result, so Anthropic sees it: your window usage %, reset time, API-value cost, and the task name of any budget you set. Don't put anything in a budget's task name you wouldn't type in a prompt. The terminal status line is different: it's only shown in your terminal and isn't sent to the model.

## How the numbers work

- **Cost** is the API list price of your tokens (input, cache writes split into 5-minute and 1-hour, cache reads, output, and advisor calls), not what you're billed on a subscription. Prices live in `Reset/Usage/Pricing.swift`.
- **De-duplication.** Claude Code writes one transcript row per streamed content block, and resumed sessions copy rows between files. Reset counts each response once, by message id, keeping the row with the final output count.
- **Window estimate.** Without live usage, a window is assumed to open at your first message after the previous one ended, rounded down to 10 minutes, and run 5 hours. Exact reset times from Claude Code's own limit messages override the estimate.

## Tests

```bash
./scripts/test.sh
```

GitHub runs them on every push and pull request (all but the UI snapshots). The unit tests cover pricing, de-duplication, incremental parsing, window estimates, the forecast, project grouping, update checks, the MCP server's JSON-RPC round-trips and budgets, and the format-drift check below.

### UI snapshots

```bash
./scripts/snapshots.sh            # compare
./scripts/snapshots.sh --record   # rewrite the references after an intended change
```

Draws the dashboard hero at three widths and in its main states, the menu bar pill and every widget look, with made-up numbers, and compares them pixel by pixel with the images in `Fixtures/snapshots`. A layout slip like the arc running through the countdown fails the suite; a failure saves the actual image and a diff (changed pixels in red) to the temporary folder. Rendering shifts slightly between macOS versions, so record the references on the Mac that runs the tests.

### Format-drift check

```bash
./scripts/drift-check.sh                    # compare
./scripts/drift-check.sh --update-goldens   # rewrite the goldens from the current parsers
```

`Fixtures/transcripts/` holds small anonymised samples of every log format Reset parses: a streamed multi-row Claude Code session, one that hits the 5-hour and weekly limits, a resumed session that copies rows into a second file, a Codex session with `rate_limits`, and the Claude desktop app's `plan-usage-history.json`. The check parses them with the real parsers and compares the result with `Fixtures/golden/`. It runs as part of `./scripts/test.sh` too (`DriftTests`), and exits non-zero with a diff on any mismatch.

### When the drift check fails

The fixtures are frozen files, so a failure means **Reset's parsing changed**, not that a tool changed its format.

- **You changed a parser on purpose:** read the diff the script prints (it compares `Fixtures/golden` with the fresh output in your temporary folder). If every difference is one you intended, run `--update-goldens` and commit the new goldens with the parser change.
- **You didn't mean to change anything:** treat it as a regression and fix the code, not the golden.

**After a Claude Code update**, Reset watches for you: while scanning, it counts recent transcript rows that look like usage but can't be read (bad JSON, a timestamp it can't parse, a missing message, id, model or token counts, token counts that aren't numbers, an unknown limit kind), and notices when Claude Code writes plenty of log lines with no usage in them at all. If that happens in the last 2 days, Settings shows a warning at the top naming the Claude Code version. Healthy logs show one quiet line under Settings → Advanced → Diagnostics. It runs on your Mac and sends nothing. The goldens themselves won't fail, because they don't read your live logs. To capture a new format for them:

1. Copy a few fresh rows of the changed kind from `~/.claude/projects/…/*.jsonl` (or the other source).
2. Anonymise them: replace ids, uuids, session ids, request ids, `cwd`, org ids, and all prompt, reply, thinking and signature text. Keep every key and the shape and types of every value; that's what the parsers depend on.
3. Add them to the matching fixture, or a new one with its own test in `ResetTests/DriftTests.swift`, then run the check. A diff you didn't expect means the new format breaks Reset: fix the parser, then `--update-goldens`.
4. Before committing, grep `Fixtures/` for your username, home folder and real ids.

## Demo mode

For screenshots and screen recordings, start Reset with made-up data:

```bash
open -a Reset --args -demo YES
```

Nothing is read, written, alerted or auto-started while demo mode is on.

To see the log-format warning without breaking a real transcript, quit Reset and open Settings with a made-up problem:

```bash
open -a Reset --args -openSettings YES -simulateLogFormat problems
```

Use `no_rows` instead of `problems` for the "no usage found" variant. `-renderSettings /path/to/settings.png` saves a picture of the window instead.

## Trademarks

Reset is an independent project and is not affiliated with, endorsed by or sponsored by Anthropic, OpenAI, Google or Anysphere. Claude, Codex, Gemini, Antigravity and Cursor are trademarks of their owners. The mascots are unofficial fan art based on those products' logos; you can turn them off in Settings → Appearance. If you represent one of these companies and want the fan art changed or removed, please open an issue.

## License

MIT. See [LICENSE](LICENSE). It grants no rights to the logos the mascot fan art is based on; see [NOTICE](NOTICE) and Trademarks above.
