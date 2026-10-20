# Changelog

The latest release is on the [Releases page](https://github.com/msfbeast/reset/releases/latest). Older builds are kept but not listed; this file is the history.

## 0.3.24 — memory stays low

- The menu bar pill is drawn with AppKit instead of SwiftUI's image renderer, which left graphics memory behind for every pill it drew. 0.3.21's fix slowed that down; over a day it still reached about 400 MB. Now it stays near 65 MB.

## 0.3.23 — accurate numbers

- The Claude desktop app's own sessions are counted (they sit in a hidden folder and were skipped).
- Older sessions, from before Claude Code recorded the account, are split between accounts from the desktop app's records instead of all landing on the signed-in one. On the maintainer's Mac that moved about $1,300 from Team back to Pro.
- Each plan counts from its own account's first use, in every range, the menu and the widgets, so a new account isn't charged a whole month.
- The dashboard's windows are placed from Claude's exact reset times, per account, and no longer shift as days pass; a window starts at your prompt, not Claude's first reply.
- Reset times no longer show a minute early; weekly lift times worked out from history read "about".
- The weekly 80% warning covers every account.
- The first launch re-reads all transcripts once (about 20 seconds).

## 0.3.22 — all means all

- The dashboard's All range is now all time: every transcript on disk, not just the last 35 days, labelled "since" your first response. The value multiple for All spreads your plan over the same days. The "When you build" heatmap still shows the last 5 weeks.

## 0.3.21 — lighter

- Much less memory: about 70 MB instead of 400+. The menu bar pill was being redrawn as a new image every second though its text changes about once a minute; it now redraws only when it changes.
- Cursor backs off after failures (5, 15, then every 30 minutes; a refused sign-in waits up to 2 hours) instead of retrying every minute.
- Live usage for other desktop-app accounts moves to Settings → Advanced, with a plain explanation of the Keychain key it uses.
- A CONTRIBUTING.md: what fits, the privacy rules, and how to run the tests.

## 0.3.20 — every account live, and Cursor

- Live usage for the other accounts signed in to the Claude desktop app, not just the one Claude Code in Terminal uses: Settings → General → Also other accounts in the Claude desktop app. Off by default; macOS asks before Reset can read the desktop app's key, and the sign-ins are only sent to api.anthropic.com. With it on, the top card, menu bar, mascot and MCP server show live numbers for whichever account you're using (thanks @DhananjayBhosale, whose pull request also found the `claude auth status` account mix-up that 0.3.19 fixed).
- Cursor: this month's included usage and when the billing month resets, read from Cursor with the Cursor app's sign-in. Off until you switch it on in Settings → General (thanks @DhananjayBhosale).

## 0.3.19 — work and personal accounts, done properly

- Switch accounts in the Claude desktop app and Reset follows: the menu's top card, the menu bar and the Claude mascot move to the account you're using. Live usage, auto-start and the widgets stay with the account Claude Code in Terminal is signed in to, and the menu says so.
- Live numbers only go on the account they're for. After switching in the desktop app, Team's used-up window showed on Pro's card, labelled Team.
- The MCP server answers for the account the asking agent runs on, and says which. Budgets are judged on the account of the agent that set them.
- The dashboard's sessions say which account they ran under, and the resume command warns when Claude Code in Terminal is signed in to the other one.
- The menu bar can show the weekly limit: 5-hour, weekly, or both (thanks @DhananjayBhosale).
- The other tools and accounts can each get a card in the menu, in your chosen look (Settings → Appearance; thanks @DhananjayBhosale).
- Less background CPU and memory, and a faster launch: transcripts aren't re-read every minute, and the cache is saved when Reset quits.

## 0.3.18 — agents know how old the numbers are

- The MCP server's get_claude_usage says when usage was last read (usage_as_of, usage_age_minutes) and, if the live check is failing, since when and why (usage_may_be_stale). The advice and any budget then warn that the reading may be out of date.
- A pace warning with plenty of window left reads "On pace to run out before the reset" instead of "Window nearly exhausted".

## 0.3.17 — name your accounts

- Two Claude accounts on the same plan no longer both show as "Claude · Pro": they're numbered ("Pro", "Pro 2"), and Settings → General → Claude accounts lets you name them, say Work and Personal.

## 0.3.16 — easier setup, earlier warnings

- One-click Claude Code setup: Settings → Advanced shows whether the status line and MCP server are set up and adds them for you (backing up settings.json first), using Reset's real location.
- The status line and MCP server say when Reset isn't running, instead of showing the last numbers as if they were live. Settings offers Update for the older status line.
- The weekly limit warns from 80%: amber in the menu, "wk 85%" in the status line, one notification per week, and the numbers for Claude through MCP.
- The update button downloads the DMG, shows what's new, can skip a version, and tells copies built from source how to rebuild instead.
- Right-click projects and sessions to reveal the folder, copy its path, or copy a command that resumes the session.
- Send test shows whether it worked; the phone switch needs a topic; plan prices are in Settings too; Quit asks first when auto-start is on; the heatmap labels days and hours.
- The test suite no longer starts a second, fully running Reset alongside yours.

## 0.3.15 — polish

- The run-out warning only shows while it's still ahead and live readings are arriving; it no longer freezes on an old time.
- Clicking a notification opens the dashboard. Signed-out alerts have a Sign in button, reset alerts a Start now button, and they say when auto-start will open the window for you.
- Times follow your Mac's 12/24-hour setting.
- The dashboard's main card follows the All / Team / Pro switch.
- Keyboard shortcuts: ⌘D dashboard, ⌘, Settings, ⌘R rescan, ⌘Q quit, ⌘1–4 for the dashboard's range.
- Tooltips explain the value multiple, cache savings and the pace behind the run-out warning; the menu says how old a live reading is.
- Settings warns when macOS has notifications turned off for Reset.
- Fixes: the MCP server no longer says "Plenty of window left" when usage is unknown; Run setup again keeps your tools; the session detail no longer goes blank; the week widget counts 7 days; Today and Calendar widgets start fresh at midnight; an empty token mix is grey.

## 0.3.14 — each account's own plan

- A plan price per Claude account: the value multiple compares Team's usage with Team's price and Pro's with Pro's, and All adds them up. A price set before stays with the account Claude Code is signed in to.
- A used-up weekly limit (read from the Claude desktop app) shows until the latest it can lift, worked out from when it last reset, instead of a note beside "ready".
- The dashboard's Providers list shows a second Claude account, and its small arcs no longer draw as a blob.
- The unit tests run on GitHub for every push and pull request.

## 0.3.13 — the menu bar follows the account you're using

- With two Claude accounts, the menu bar showed a green "Pro ready" just because the second account was unused, hiding the signed-in account's countdown, what's left and the run-out warning. While that account's window runs, the menu bar now shows only it.

## 0.3.12 — costs per account

- With more than one Claude account, the dashboard has an All / Team / Pro switch: costs, sessions, projects, this week's windows, the heatmap and the share card for just that account.
- Snapshot tests draw the dashboard, the menu bar pill and every widget look and compare them with reference images, so layout slips like the arc running through the countdown fail the tests.

## 0.3.11 — two accounts, and VoiceOver

- Separate Claude accounts get separate entries: for example "Claude · Team" (the account the Claude Code CLI is signed in to, with live usage, the forecast and auto-start) and "Claude · Pro", each with its own window from its own sessions, plus the Claude desktop app's readings for the second one, including a weekly limit.
- VoiceOver: the menu bar pill speaks ("Claude: 2 hours 46 minutes until the reset, 42 percent left"), dashboard switches say whether they're on, and charts and bars are described or skipped.
- Every "slow down" from Anthropic is logged, to check whether 2-minute polling ever trips the limit.

## 0.3.10 — gentler on Anthropic's limits

- Live usage remembers when Anthropic asks it to slow down, across restarts and app updates, instead of asking again straight away. After a restart, the last reading shows immediately if it's recent.
- While you're using Claude Code, live usage now updates every 2 minutes (every 5 when idle). Once a minute could trip Anthropic's rate limit.

## 0.3.9 — fresher, steadier

- Live usage updates more often while you're using Claude Code and every 5 minutes when idle: fresher numbers when they move, fewer requests overall. (Every minute at first; 0.3.10 makes it every 2.)
- When you're running out, the red pill shows what's left and when it runs out ("86% · out 9:29") instead of a countdown that read like a second clock time.
- Auto-start and Start now wait for a working network instead of timing out offline and using up their tries.
- Antigravity's last reading stays visible while the app is closed, labelled with when it was seen.

## 0.3.8 — your window at a glance

- A colored pill in the menu bar: orange "2:46 · 42%" as usual, red when the window is nearly empty or your pace runs out before the reset ("38% · out 10:07"), green "ready" when a fresh window is waiting, a warning sign while Claude Code is signed out, and a moon with the time a weekly limit lifts. Settings → Appearance switches back to plain text.
- The run-out warning survives restarts, and a window you've already been warned about doesn't warn again.

## 0.3.7 — clearer Settings, honest estimates

- Settings in four tabs: General, Automation, Appearance, Advanced. Live usage sits at the top.
- When Reset is guessing, it says so and why ("estimated · live usage off"). Without a usage reading, cards say "~70% of time left" instead of passing the clock off as usage.
- Report a problem: a GitHub issue pre-filled with versions and on/off states, never usage numbers, paths, project names or your phone topic.
- The dashboard's window arc no longer runs through the countdown on narrow windows.

## 0.3.6 — Start now

- A Start now button in the countdown and Fuse widgets when a fresh window is waiting.

## 0.3.5 — the Fuse

- Fuse widget: your window as a burning fuse, with where today's pace runs out and how much to slow down to make the reset.
- Auto-start keeps the Mac awake for the few seconds a run takes, so a run started while the Mac sleeps on battery finishes on time.

## 0.3.4 — fewer, better widgets

- Seven polished widgets instead of 22. Arrival and Game Boy read properly when a fresh window is waiting.

## 0.3.3

- Auto-start keeps a retry in progress, or a start waiting on a sign-in, across a restart.
- A way to preview the log-format warning without breaking anything.

## 0.3.2 — auto-start tells you when it fails

- Every auto-start run gets a clear result (started, signed out, limit not reset yet, timed out, or failed with a reason), saved so an overnight failure is still visible in the morning.
- Signed out: one notification, a banner with Fix, and the waiting window starts right after you sign in.

## 0.3.1

- A warning when Claude Code changes how it writes its logs, instead of quietly undercounting.
- Pacing budgets show in the terminal status line and the menu.
- Release builds are stripped: smaller, and without the build machine's folder paths.

## 0.3 — pacing budgets

- The MCP server gains `set_budget` and `clear_budget`: give a task a cap and an optional model to switch to; `get_claude_usage` then says when to wrap up and when to downshift. Shown on the dashboard with a Clear button.
- Mac notifications fire at the actual reset time; dashboard switches work; widgets stay current.
- A format-drift check with anonymised samples of every log format Reset reads.
- Fixes: mascot panels no longer pile up in memory, a future-dated transcript row can't crash the app, tool counts no longer inflate on re-reads, a stale weekly limit clears from live data.

## 0.2 — one-minute setup

- First-run setup: pick your tools, sign Claude Code in, set up phone alerts with a QR code, add your plan price.
- Redesigned menu; sign-in warnings with a one-click fix; Stay awake; much faster scanning; update checks.

## 0.1 — first public release

- Menu bar countdown to your next Claude window, live or estimated.
- Phone alerts through ntfy that arrive while your Mac sleeps.
- Limit forecast and optional auto-start of the next window.
- Dashboard: value vs plan, cache savings, windows, token mix, sessions and projects.
- Widgets, looks, animated mascots (unofficial fan art), a share card for X.
- Claude Code status line and MCP server.
