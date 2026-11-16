---
name: vscode
description: where things live in vs code, cursor, and vscodium, and how to read their errors
apps: com.microsoft.VSCode, com.microsoft.VSCodeInsiders, com.vscodium, com.todesktop.230313mzl4w4u92
app_names: visual studio code, vscodium, cursor, code - insiders
keywords: vs code, vscode, visual studio code, cursor, vscodium, red squiggle, problems panel, eslint, typescript error, python error
priority: 10
---
vs code layout:
- the activity bar is the icon strip down the far left. explorer, search, source control, run and debug, and extensions live there.
- the bottom panel holds problems, output, and the terminal. the problems tab lists every error with its file and line.
- the status bar along the bottom shows the language, the interpreter or workspace, and the error count.
- red squiggles mark errors in the editor. hover over one to read the message. the lightbulb offers quick fixes.

shortcuts, said the way people say them: command shift p opens the command palette, command p opens quick open, command period opens quick fixes on the current line, command shift m opens the problems panel, control backtick toggles the terminal.

common errors:
- "cannot find module" or a failed import: check the package is installed in the integrated terminal, and that the interpreter or workspace in the status bar is the right one.
- type errors: read the message for the expected and actual types, then name the mismatch in plain words.
- cursor and vscodium use the same layout as vs code.
