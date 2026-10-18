# Contributing to Reset

Thanks for helping. Reset is small on purpose: a menu bar pill that tells you where you stand in your Claude Code window, and everything else stays out of the way. These notes say what gets merged quickly and what needs a conversation first.

## Before you start

- **Bugs and performance:** open a pull request straight away. Fixes with a test that fails before and passes after are the easiest to merge.
- **New features:** open an issue first and describe the problem it solves. A short "would you take this?" saves you building something that doesn't fit.
- **One change per pull request.** A fix bundled into a feature PR is easy to miss and hard to merge on its own. Small, focused PRs get reviewed and merged faster.

## What fits

- **Claude first.** Reset is for people who live in Claude Code. Other tools are welcome when they're cheap to support and off by default.
- **The pill stays simple.** New things go in the menu, the dashboard or Settings, not the menu bar, and the defaults should stay the same.
- **Fewer settings, not more.** If something can just work, prefer that to a new option. Expert options go under Settings → Advanced.

## Privacy rules (not negotiable)

- **Nothing new leaves the Mac without a conversation first.** Today only these do, and only when switched on: live usage (to `api.anthropic.com`), phone alerts (to the user's ntfy server), Cursor usage (to `api2.cursor.sh`) and a daily update check (to GitHub).
- **Read the least you need.** Token counts, times and model names, never prompts, replies or file contents. Never store, log or renew anyone's sign-in.
- **Say it in the README.** Anything Reset reads or sends belongs in the Privacy section, in plain words.
- **Be polite to other services.** Back off after failures instead of retrying on a timer; Anthropic's usage endpoint rate-limits.

## Code

- **No third-party dependencies.** Apple frameworks only.
- **Match the style.** Every non-obvious branch gets a `///` comment saying *why*, in plain English.
- **Tests for everything.** Pure logic is kept out of views so it can be tested. Run the suite before you push:

  ```bash
  ./scripts/test.sh
  ```

  Layout changes: `./scripts/snapshots.sh`, and `--record` if the change is intended (see the README's Tests section). Snapshot references are recorded on the maintainer's Mac, so expect them to be re-recorded when merging.
- **The project is generated** with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`; don't commit `Reset.xcodeproj`.

## How pull requests are merged

The public repository's history is kept separate from the maintainer's working copy, so accepted pull requests are applied by hand and closed with a link to the commit, not merged with GitHub's button. You stay the author of your commits, and the public commit credits you as co-author.

## Questions

Open an issue, or reply on the launch post. Thanks again for making Reset better.
