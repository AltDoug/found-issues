# found-issues hero screenshot
# Render: vhs hero.tape
# Output: hero.png — captures the "Claude logs an issue" moment

Output hero.gif

Set FontSize 16
Set Width 900
Set Height 320
Set Theme "Catppuccin Mocha"
Set TypingSpeed 25ms
Set Padding 30

Hide
Type "cd ~/demo-repo && rm -f docs/found-issues.md && clear" Enter
Show

# Narrative — what Claude is thinking (shown as a comment)
Type 'echo "# Claude noticed a null check missing in lib/foo.py..."' Enter
Sleep 600ms

# The log moment — this is the load-bearing line
Type 'found-issues log "lib/foo.py:42 — null check missing (suggested: add guard before deref)"' Enter

# After the log: output is "Logged: - [open] ..." + "1 issue" — that's the
# screenshot moment. Count line is the visual confirmation.
Sleep 2.5s

Screenshot hero.png

# Hold a beat for the GIF version
Sleep 1s
