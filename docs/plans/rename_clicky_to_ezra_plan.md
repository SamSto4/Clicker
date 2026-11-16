# Plan (builder brief): rename Clicky to Ezra, all the way through

Sam's decision (15 Nov 2026): "lets rename clicky to ezra". When asked how deep, he chose **"Full rename incl. code"**: everything the user sees and hears, the app's name, the code's own names, files and folders, and the docs.

**Stacks on round 21** (`feature/explaining`, after its review commit). The orchestrator creates `feature/rename-ezra` and a worktree for it. Rounds 22 to 25 build on the renamed code.

## Orchestrator's notes (read first; they win over the text below)

1. **Base and branch.** Worktree `/Users/samsto/Clicker-worktrees/ezra-rename`, branch `feature/ezra-rename`. It starts from the last commit of `feature/agent-context`, which holds round 21, its fixes, and round 21b (the context tab, PR #16).
2. **The smoke program.** Copy `/Users/samsto/Clicker-handoff/scratchpad/loop/round21c_smoke/` (5,721 PASS), not `round21_smoke`, to `/Users/samsto/Clicker-handoff/scratchpad/loop/rename_smoke/`.
   - Point its scripts at your worktree, and rename its code with the same script.
   - Its `run_all_checks.sh` runs everything. Window checks need an awake display: it uses `caffeinate -u -d`.
   - Two round 17 keyboard checks in `live_size_render` fail while the screen is locked. That is expected.
3. **New names from round 21 and 21b.** They are renamed like the rest:
   - `ClickyAgentContextStore`, `ClickyAgentContextText`, `ClickyAgentContextEditor`, `ClickyChatPanelContextView`;
   - `ClickySpotlightShade`, `ClickyWalkthroughState` and `ClickyPointSnap`;
   - `ClickyAccessibilityElementReader`;
   - `CLICKY_CONTEXT_DIRECTORY`, which becomes `EZRA_CONTEXT_DIRECTORY`.
4. **The data move for Application Support** is per entry, as written under "Data folders" below: `Chats`, `Memories`, `Backups`, `Timers`, `Voices` and `Context`. Never move the shared `Clicky` folder itself.
5. **The model's words.**
   - The base prompt, the skills and the context tab's heading say "clicky", and they become "ezra". This changes the cached static block once, and that is intended.
   - The context heading's words are pinned in the smoke program. Update that pin on purpose and list it.
6. **Holdouts.** The holdout files (`eval/scenarios/holdout/`) are edited by your script only, blind, as the plan says. Never open them.

## What is renamed
1. **The name the user sees and hears.** Every user-facing "Clicky"/"clicky" becomes "Ezra"/"ezra", in the app's own lowercase style where the text is lowercase.
   - The prompts: the base prompt's "you're clicky…", the skills, the memory compaction prompt including its `clicky:` turn label (which becomes `ezra:` in both the prompt and the code that writes the chat), and the dictation cleanup prompt.
   - Every UI string: "ask clicky…", "show clicky", "shows what clicky is doing", "You're all set. Hit Start to meet Clicky.", the menu bar panel, settings hints, and the pill.
   - The voice sample sentence ("hi, i'm ezra. this is how i sound."), the persona's default assistant name ("ezra"), and the polite prefixes ("hey ezra", "ezra").
   - The console log lines ("🔊 Ezra …") and the `Info.plist` usage descriptions ("Ezra adds and reads reminders when you ask it to.").
   - The profile file's heading for a new file ("# Ezra profile"). An existing file keeps its own heading, since the reader is tolerant.
2. **The app's name:** `PRODUCT_NAME = Ezra` and `INFOPLIST_KEY_CFBundleDisplayName = Ezra` in both configurations of the app target in `leanring-buddy.xcodeproj/project.pbxproj`. The app becomes `Ezra.app`.
3. **Code names.**
   - Every Swift identifier starting with `Clicky` becomes `Ezra` (`ClickyTurnFinisher` → `EzraTurnFinisher`; there are about 450 distinct names). Lower-camel names containing `clicky` change the same way (`clickyChatPanelBottom` → `ezraChatPanelBottom`, `isClickyCursorEnabled` (the Swift property) → `isEzraCursorEnabled`).
   - Files and folders: `leanring-buddy/ClickyCore/` → `EzraCore/`, `ClickyPrompts/` → `EzraPrompts/`, every `Clicky*.swift` → `Ezra*.swift`, `clicky_base_system_prompt.md` → `ezra_base_system_prompt.md`.
   - Use `git mv`, so history follows. The app target uses synchronized folders, so no project edit is needed for files; check that no path in the project file names them.
   - Update every place code loads a prompt or resource by name or folder.
   - Eval programs and scripts under `eval/` (Swift and `.mjs`) are renamed the same way, including expected words in scenario files.
4. **Environment variables** for self tests and eval: `CLICKY_*` → `EZRA_*` (`EZRA_DRAW_SELF_TEST`, `EZRA_PANEL_SELF_TEST`, `EZRA_CHAT_STORE_DIRECTORY`, `EZRA_NOTES_DIRECTORY`, `EZRA_METRICS_DIRECTORY`, `EZRA_MEMORIES_DIRECTORY`, `EZRA_TIMERS_DIRECTORY`, and the rest).
5. **Data folders, with a one-time move at launch.**
   - The folders: `~/Documents/Clicky Notes` → `~/Documents/Ezra Notes`, and `~/Library/Logs/Clicky` → `~/Library/Logs/Ezra`. That logs folder holds only Clicky's own metrics logs.
   - **Application Support is different (orchestrator's fix, 15 Nov 2026).** Another app on this Mac also uses `~/Library/Application Support/Clicky`. It keeps AgentHarness, BrowserBridge, CodexHome, DictationTranscripts, helper, HeyClickyHistory, HomeSpaceCache, OneBrain, projects and SkillLibraryCache.json there. So never move, rename or delete that folder itself.
     - Move only Clicky's own entries, one by one, into `~/Library/Application Support/Ezra/`: `Chats`, `Memories`, `Backups`, `Timers`, `Voices` and (from round 21b) `Context`.
     - Apply the rule below to each entry on its own.
     - Leave everything else where it is.
   - The move rule, in a pure, checked function (`EzraDataFolderMigration`) plus one call early in launch, before anything reads these folders:
     - When the old folder exists and the new one does not, move it (a rename on the same volume).
     - When both exist, use the new one, leave the old one alone, and print one line.
     - When neither exists, do nothing.
     - A failed move prints one line and the app uses the new path. Nothing is ever deleted.
   - Self tests never touch the real folders.
6. **Docs.** `AGENTS.md` (`CLAUDE.md` is a symlink to it), `eval/README.md`, `docs/roadmap.md` and `docs/plans/*`: product and code names become Ezra. Add a short "Renamed from Clicky (15 Nov 2026)" note at the top of `AGENTS.md` listing what was kept and why.

## What is NOT renamed (say each in the AGENTS.md note)
- **HeyClicky, a different product.** It is the clean-room reference: "HeyClicky", "heyclicky", `api.heyclicky.com`. Never touch these. Grep for them before and after; the counts must match.
- **The deployed Worker's contract,** because Sam's running Worker and his secrets file depend on it:
  - the Worker's name and URL (`clicky-proxy`);
  - the headers `X-Clicky-App-Token`, `X-Clicky-Cap`, `X-Clicky-Voice-Fallback`;
  - the error type `clicky_daily_cap`;
  - the secret `CLICKY_APP_TOKEN`, the vars `CLICKY_DAILY_CHAT_REQUEST_CAP` and `CLICKY_DAILY_TTS_CHARACTER_CAP`, the binding `CLICKY_DAILY_CAP`, and the Durable Object class `ClickyDailyCap` (renaming a class needs a migration).

  In the app, keep these as string constants with a comment saying why. Do **not** edit `worker/` at all. The Worker's own docs paragraph stays.
- **Stored settings keys** (`UserDefaults` key strings such as `"isClickyCursorEnabled"`): they are data. Renaming them would reset Sam's settings. Rename the Swift constant's name, keep its string value, and comment why.
- **The Worker secrets file name.** `ClickyWorkerSecrets.plist` (git-ignored, Sam's local file with the Worker URL and token) and its template `ClickyWorkerSecrets.example.plist` keep their names, so nothing on Sam's Mac has to move. The path policy still protects that name. Comment why.
- **The bundle identifier** `com.samsto4.leanring-buddy` (macOS permissions are tied to it), the Xcode project and scheme name `leanring-buddy` (AGENTS.md says never rename them), and the repo name `Clicker`. `ClickerMemoryClient` is about the memory server, and "Clicker" is not "Clicky".
- **Git history and old commit messages.**

## How to do it
1. Write the rename as a script, not by hand: a Python script in the scratchpad that renames files and folders with `git mv` and then applies the replacements in this order:
   1. protect the kept strings by swapping in unique placeholders;
   2. `Clicky` → `Ezra`, `clicky` → `ezra`, `CLICKY_` → `EZRA_`;
   3. restore the placeholders.

   Run it on the worktree, including `eval/scenarios/holdout/`. **Never open, read or print a holdout file**: the script edits it blind, and that is the only contact allowed.
2. Then read the diff of the user-facing strings and prompts by eye. They must read naturally ("ask ezra…", "you're ezra, a friendly companion…").
3. Apply the same script to the smoke program. Copy the latest smoke folder (round 21's) to `rename_smoke/`, rewrite its paths to your worktree, and rename its code the same way.
4. Add the migration code and its checks: a temporary home with the old folders gives the new ones, both present leaves both, neither does nothing, a file in the way does not crash.
5. Update the pinned prompt checks on purpose, and list them.

## Hard rules
- Only your worktree.
- No builds: never `xcodebuild`, no Xcode, no app runs.
- No network.
- No git commits; `git mv` is allowed and is the only git command that changes anything.
- Never read, print or `cat` the secrets plist or any key.
- Never edit `worker/`.
- Temporary folders only.

## Done means
- **Checks:**
  - The smoke program passes with the same check count as round 21's last run, apart from checks you deliberately changed, which you list, plus the new migration checks.
  - `typecheck_core.sh` (4 variants), the app type-check and the SIL check `swiftc -wmo -emit-sil -o /dev/null` show 0 errors.
- **Leftovers:**
  - `grep -ri clicky` over the worktree, outside `.git`, returns only the kept items above. Report the count by category.
  - `grep -ri heyclicky` gives the same count as before.
- **The eval programs** type-check against EzraCore.

## Orchestrator's part after the build
- Commit.
- Rename `Clicky.app` references in the scratchpad scripts: `relaunch.sh` uses `Ezra.app` and `pgrep -x Ezra`; quitting by bundle id is unchanged.
- Build in Xcode and check that macOS permissions survived; same bundle id and signature, so they should.
- Run the self tests with the `EZRA_*` variables.
- Check that the data folders moved on the first launch.
- Add a names note to the round 22–25 briefs: "Every Clicky name is now Ezra (ClickyFoo → EzraFoo, ClickyCore → EzraCore; the kept items are listed in AGENTS.md)".
- Open the PR.
