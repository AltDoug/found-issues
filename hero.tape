# found-issues hero screenshot
# Render: vhs hero.tape
# Output: hero.png — captures the "Claude logs an issue" moment

Output hero.gif

Set FontSize 16
Set Width 900
Set Height 200
Set Theme "Catppuccin Mocha"
Set TypingSpeed 25ms
Set Padding 30

Hide
Type "cd ~/demo-repo && rm -f docs/found-issues.md && clear" Enter
Show

# The log moment — this is the load-bearing line.
# No narrative comment; the command + output speak for themselves.
Type 'found-issues log "lib/foo.py:42 — null check missing (suggested: add guard before deref)"' Enter
Sleep 2.5s

Screenshot hero.png

# Hold a beat for the GIF version
Sleep 1s
