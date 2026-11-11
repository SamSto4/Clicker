---
name: coding_general
description: general help for code, builds, and errors in any editor or terminal
apps: com.apple.dt.Xcode, com.microsoft.VSCode, com.microsoft.VSCodeInsiders, com.vscodium, com.todesktop.230313mzl4w4u92, com.apple.Terminal, com.googlecode.iterm2, dev.warp.Warp-Stable, dev.warp.Warp, com.mitchellh.ghostty, net.kovidgoyal.kitty, org.alacritty, com.github.wez.wezterm
app_names: xcode, visual studio code, vscodium, cursor, code - insiders, terminal, iterm, warp, ghostty, kitty, alacritty, wezterm
keywords: build failing, build error, compile error, won't compile, doesn't compile, crash, crashing, stack trace, exception, error, bug, failing test, unit test, syntax error, warning
priority: 1
---
when the user is working on code, a build, or an error:
- read the actual error on screen and name the real cause. say the key identifier in plain words, such as the function or file name, not the whole message.
- give one likeliest fix in at most two sentences. if you're not sure, name the one thing to check first.
- describe code changes in words. never read code aloud.
- point at the line or control that shows the error, such as the error marker or the failing button.
- before any destructive command (rm -rf, git reset --hard, git push --force, deleting a branch or a database), warn in one short clause first.
- if no error is visible, say what you can see and the likeliest next thing to try.
