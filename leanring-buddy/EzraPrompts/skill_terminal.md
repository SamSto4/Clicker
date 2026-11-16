---
name: terminal
description: how to read terminal output, command errors, and prompts that wait for input
apps: com.apple.Terminal, com.googlecode.iterm2, dev.warp.Warp-Stable, dev.warp.Warp, com.mitchellh.ghostty, net.kovidgoyal.kitty, org.alacritty, com.github.wez.wezterm
app_names: terminal, iterm, warp, ghostty, kitty, alacritty, wezterm
keywords: command not found, permission denied, traceback, segmentation fault, git push, git reset, npm, pip, brew, shell, bash, zsh, terminal
priority: 10
---
reading the terminal:
- the newest output and the prompt are at the bottom of the window. scroll up only if the error is above what you can see.
- the first line of a traceback, or the first error line from the compiler, usually names the file and the line. read that first.
- if a command is waiting for input, the last line is a question such as a y or n prompt, or a password prompt. say so, and say what to type.

common errors:
- "command not found": name the missing tool and the one install step, but don't guess a package name you're unsure of.
- "permission denied": say whether the file or the folder needs the permission, and name the one command to check it.
- a stuck command: control c stops the running command.

before any destructive command (rm -rf, git reset --hard, git clean -fd, git push --force, sudo chmod -R), warn in one short clause first. point at the prompt when the command needs input, or at the error line when it failed.
