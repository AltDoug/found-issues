# Demo GIF storyboard

For the README's hero GIF. Length target: **15-20 seconds.** Recorded
with [vhs](https://github.com/charmbracelet/vhs), [terminalizer](https://github.com/faressoft/terminalizer),
or [asciinema → asciicast2gif](https://github.com/asciinema/asciicast2gif).

## What the GIF must show

The closure loop in <20 seconds. The viewer should walk away thinking:
*"oh, the AI logs the bug, opens a PR, and the entry auto-flips when the
PR merges. I get it."*

If the GIF doesn't communicate that exact thought, it failed.

## Recommended tool: vhs

`vhs` produces deterministic, scriptable GIFs from a `.tape` file. No
manual recording, no flubs, can re-render endlessly.

Install: `brew install vhs` (also requires `ffmpeg`, `ttyd`).

Below is a complete `.tape` file you can save as `demo.tape` in the repo
root and render with `vhs demo.tape`.

## demo.tape (copy-paste this)

```tape
# found-issues demo
# Render: vhs demo.tape

Output demo.gif

Set FontSize 14
Set Width 900
Set Height 480
Set Theme "Catppuccin Mocha"
Set TypingSpeed 25ms
Set PlaybackSpeed 1.0

Hide
Type "cd ~/demo-repo && clear" Enter
Show

# Title card (briefly)
Type "# found-issues — the closure loop in 15s" Enter
Sleep 1.5s
Type "clear" Enter
Sleep 200ms

# Step 1: Show empty repo, no found-issues yet
Type "ls docs/" Enter
Sleep 1.5s

# Step 2: Claude logs an issue (simulated via the CLI directly for demo speed)
Type "# Claude noticed a bug while working on something else..." Enter
Sleep 800ms
Type "found-issues log src/foo.py:42 — null check missing (suggested: add guard)" Enter
Sleep 2s

# Step 3: See the entry
Type "cat docs/found-issues.md" Enter
Sleep 2s

# Step 4: Claude opens a PR addressing the bug
Type "# Claude fixes it later, opens a PR..." Enter
Sleep 600ms
Type "git checkout -b fix/null-check && git commit -am fix && gh pr create --fill" Enter
Sleep 1.5s

# Step 5: Claude annotates the PR (auto-prompted by post-pr-create hook)
Type "found-issues annotate-pr 1" Enter
Sleep 2s

# Step 6: PR merges (simulated)
Type "gh pr merge 1 --squash" Enter
Sleep 1.5s

# Step 7: Sync flips the entry
Type "found-issues sync" Enter
Sleep 2s

# Step 8: See the closed entry
Type "cat docs/found-issues.md" Enter
Sleep 2.5s

# End frame
Type "# Issue tracked. Fixed. Auto-closed. Zero manual bookkeeping." Enter
Sleep 2.5s
```

## What the user (you) needs to do

1. Set up a demo repo with `gh` authenticated and a clean state:
   ```bash
   mkdir ~/demo-repo && cd ~/demo-repo
   git init -b main
   gh repo create demo-found-issues --public --source . --push
   mkdir src docs
   echo 'def foo(): return None' > src/foo.py
   git add -A && git commit -m init && git push
   ```
2. Install bats `vhs` if needed: `brew install vhs ffmpeg ttyd`
3. Save the `.tape` content above as `demo.tape` in the demo repo
4. Run: `vhs demo.tape`
5. Output: `demo.gif` in the current directory

## Where to put the GIF in the README

Top of README, immediately after the hero tagline:

```markdown
# found-issues

> Your AI agent has a blind spot. This fixes it.

![demo](demo.gif)

## Install
...
```

The GIF is the first thing visitors see after the tagline. It either
sells the project in 15 seconds or it doesn't.

## Quality checklist

Before publishing the GIF:

- [ ] Total length 12-22 seconds
- [ ] Final frame holds the **closed** entry visible for ≥1.5 seconds
- [ ] Font is readable at GitHub's default render size (900px wide GIF
      means ~14px font is the floor)
- [ ] No obvious typos in the bash commands
- [ ] Theme matches the operator's terminal (or pick something neutral
      like Catppuccin / Dracula / Solarized)
- [ ] File size under 5MB so GitHub renders it inline
- [ ] First 2 seconds are visually attention-grabbing (the title card
      helps)

## Alternative tools

If `vhs` doesn't work for you:

- **terminalizer** — interactive, more flexible, larger output files
- **asciinema** + `agg` — record asciicast, convert to GIF
- **screen capture** (Kap on macOS, ScreenToGif on Windows) — manual but
  maximum control

## Optional: a longer screencast for the docs

A separate ~2-minute screencast walking through:
1. The hooks firing in real time during a Claude session
2. The SessionStart count appearing
3. The Stop-hook acknowledgment marker
4. The format-enforcer blocking a bad edit
5. The pre-branch-delete hook blocking with promotion message
6. `/found-issues:setup` running

This is for the docs site / video tour, not the README. Not blocking for
v1 launch — record after the project gets traction.
