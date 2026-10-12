# found-issues hero GIF: log -> PR -> merged -> [fixed]
# Render from the repo root: vhs hero.tape
# docs/demo/hero-setup.sh builds a throwaway repo and stubs gh, so every
# line of output below is the real CLI's.

Output hero.gif

Set Shell "bash"
Set FontSize 14
Set Width 1180
Set Height 360
Set Theme "Catppuccin Mocha"
Set TypingSpeed 22ms
Set Padding 26

Hide
Type "source docs/demo/hero-setup.sh && clear" Enter
Sleep 1s
Show

Type "# Claude spots a bug outside its task, and logs it instead of shrugging" Enter
Sleep 600ms
Type 'found-issues log --fix small "src/config.ts:2 — parseConfig swallows errors"' Enter
Sleep 1.8s

Type "# a fix lands in PR #42" Enter
Sleep 500ms
Type "found-issues annotate-pr 42 --pick src/config.ts:2" Enter
Sleep 1.8s

Type "# PR #42 merges; the next session start syncs" Enter
Sleep 500ms
Type "found-issues sync" Enter
Sleep 1.8s
Type "grep '^- ' docs/found-issues.md" Enter
Sleep 3.5s
