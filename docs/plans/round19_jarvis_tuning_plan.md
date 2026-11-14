# Round 19 plan (builder brief): Jarvis tuning

Final, 14 Nov 2026. Written by the planner from `AGENTS.md` at `feature/jarvis-actions` (f64f4b9, round 18 built, reviewed, tested live and committed), the round 18 source on that branch, the tester's live numbers of 14 Nov, and Sam's four decisions of 14 Nov. Numbers below are measured unless marked "estimate".

## Goal and Sam's decisions (14 Nov 2026)

Sam: "focus on optimizing jarvis function once current phases are done." Round 18 made Clicky act (open apps, links and files, search the web, timers, reminders, shortcuts, follow-up listening, a persona). Round 19 makes those actions **fast, accurate and cheap** without changing what they do or what waits for a yes. Standing principles: Sam keeps control over what is written or sent; our own design from public Apple APIs and the Claude Messages API; nothing from HeyClicky.

Sam decided (14 Nov 2026):
1. **Quick commands** (a local fast path with no model call) are built, **on by default**, with the exact grammar in this brief.
2. **Fixed confirmations** add the persona's "call me" name ("opened safari, sir.") and otherwise ignore the style.
3. **The Worker daily cap** is 600 chat requests plus 60,000 TTS characters per day, counting requests first. The Worker side is the orchestrator's own PR; the builder adds only the app's sentence.
4. **A timer that ended while Clicky was quit** is shown at launch, and spoken only if it ended under 10 minutes ago.

Standing: round 18's split between at-once and confirmed actions, its link rule, honesty rule and change card are not moved. Metrics stay numbers and fixed identifiers only.

## Where you work

- Branch `feature/jarvis-tuning`, created from `feature/jarvis-actions` at f64f4b9 (round 19 is stacked on round 18).
- **You work in your own git worktree, not in `/Users/samsto/Clicker`.** The orchestrator builds round 18 in Xcode from the main checkout while you work. Every path to the repo in your commands, scripts and smoke program must be your worktree's path. Never `cd` into or edit `/Users/samsto/Clicker`.
- Read `AGENTS.md` in your worktree first, closely "File editing (round 17)" and "Jarvis actions (round 18)" (the latter holds the live numbers, the review changes and the known limits).
- The smoke program: copy `/private/tmp/claude-501/-Users-samsto-Clicker-worker/173eab4d-044b-40e5-b527-b8d6803e1a18/scratchpad/loop/round18_smoke/` to `round19_smoke/` next to it and rewrite every repo path in its scripts (`typecheck_core.sh`, `app_check/typecheck_app.sh`, `build_and_run_smoke.sh`, `splice_section18.py` → `splice_section19.py`, the render and driver checks) to your worktree. **All 4,191 existing checks must pass.** Add `round19_part*.swift` files for the new checks.
- The builder is Opus 5.5 and does no Xcode builds: type-checks only.

## What exists and must be reused (names checked at f64f4b9)

- **The tool loop.** `ClickyToolLoop.run(baseMessages:buildRequestBody:executeToolCall:sendRequest:)` (`ClickyCore/ClickyToolLoop.swift`): up to 6 requests per turn (`ClickyFileEditingLimits.maximumRequestsPerTurn`); every `tool_use` block is run in order with `await executeToolCall(name, input)` inside a `for` loop; all results go back in one user message; `ClickyToolLoopRequestStats` already records per request `inputTokens`, `outputTokens`, `cacheCreationInputTokens`, `cacheReadInputTokens` and `milliseconds`. `ClickyStreamedMessageAssembler` keeps blocks as received. Keep both.
- **The request body.** `ClickyClaudeChatRequestBuilder.streamingRequestBody(model:systemPromptValue:messages:tools:)` and `currentUserContentBlocks(images:userPrompt:)` (same file); `ClickyClaudeRequestSettings.addingSpokenReplySettings` adds `output_config.effort = "low"` and, on Sonnet 5.5 only, `thinking = {"type": "between_tools"}`; `ClickySystemPromptBlocks.makeSystemBlocks(staticText:dynamicText:)` (`ClickyCore/ClickyClaudeRequestSupport.swift`) builds the two system blocks, the static one with `cache_control: {"type": "ephemeral"}`. There is no `cache_control` in `messages` today.
- **The turn with tools.** `ClaudeAPI.analyzeImageStreamingWithTools(images:staticSystemPrompt:dynamicSystemPrompt:conversationHistory:userPrompt:toolSession:onProgress:)` runs the loop with a `ClickyTurnToolSession` (`ClickyCore/ClickyActionExecutor.swift`, line 478: `toolsArray()`, `toolCallCount`, `execute(toolName:input:)`), which holds the file session and the `ClickyActionToolTurnSession`. `ClickyPreparedTurnTools` (`ClickyFileEditingController.swift`) is prepared while the screenshot is taken; it is nil only with actions off and no folder. In `CompanionManager.sendTranscriptToClaudeWithScreenshot(...)` the tool path is the `if let preparedTurnTools` branch (around line 2553); the metrics are filled from `preparedTurnTools.toolSession.toolCallCount`, `actionSession.toolCallCount` and `actionSession.actionKinds` (around line 2604); the honesty rule gets `anActionToolWasCalled`, `succeededCategories` and `actionsAreOn` (around line 2650); `actionSession.doneLines` go into history (around line 2811). The yes, no and undo answers come first (`fileEditingController.decision(forTranscript:)`, line 2175).
- **The action session** `ClickyActionToolTurnSession` (`ClickyCore/ClickyActionExecutor.swift`): `queuedActions`, `createdReminderIdentifiers`, `actionKinds` (`[ClickyActionKind]`: `openApp`, `openLink`, `openLinkQueued`, `searchWeb`, `openFile`, `revealFile`, `setTimer`, `cancelTimer`, `createReminder`, `listReminders`, `listShortcuts`, `runShortcutQueued`), `doneLines`, `succeededCategories` (`Set<ClickyActionClaimCategory>`: `timer`, `reminder`, `open`, `shortcut`, `close`), `toolCallCount`, `execute(toolName:input:)`; the per-turn counts (`reserveAnOpenedItem`, 3 opened items). The executor protocol `ClickyActionExecutor` (`installedApplications()`, `launchApplication(_:)`, `openLink(_:)`, `perform(_:onFileAt:)`, `startTimer(durationSeconds:rawLabel:)`, `cancelTimer(reference:)`, `createReminder(_:)`, `removeReminder(withIdentifier:)`, `listReminders(range:)`, `listShortcutNames()`, `runShortcut(named:)`), the real one `ClickyRealActionExecutor` (app), and the fake in the smoke program and `eval/actions_runner`. App matching `ClickyAppNameMatcher` (`ClickyCore/ClickyActionMatching.swift`, aliases, exact name, unique prefix, close names). Result texts `ClickyActionResultTexts` and `ClickyTimerResultTexts.started(_:timeZone:)` / `stopped(_:)`.
- **The timer board** `ClickyTimerBoard` (`ClickyCore/ClickyTimerBoard.swift`; `start(durationSeconds:rawLabel:at:)`, `cancel(reference:)`, `removeDueTimers(at:)`, `nextDueDate()`, `promptSectionText(at:timeZone:)`, `noticeText(for:)`, `spokenSentence(for:)`; `ClickyTimer` is `Sendable`), `ClickyTimerController` (`ClickyTimerController.swift`, 75 lines, `timerDueHandler`), and `CompanionManager.handleTimerEnded(_:)` (sound, pill notice 8 s, `timerAlertText` in the panel, the spoken sentence that waits for Clicky's own speech).
- **The honesty rule** `ClickyActionHonesty.honestSpokenText(_:facts:)` with `ClickyActionHonestyFacts` (`ClickyCore/ClickyActionHonesty.swift`), widened in review (past-tense starts, "pulled up", "i'll remind you", closing, "all set."; state claims only after a failed action call). Do not redo it; a fixed confirmation must pass through it unchanged (check it).
- **Follow-up listening.** `ClickyFollowUpListeningStateMachine`, `ClickyFollowUpListeningConstants` (0.3 s floor window, `levelThatCountsAsSpeechWhileMeasuring` 0.25, `defaultNoiseFloor` 0.03, `speechStartMarginAboveTheFloor` 0.12, `minimumSpeechLevel` 0.18, `speechStartHoldSeconds` 0.15, `quietMarginAboveTheFloor` 0.07, `endOfSpeechQuietSeconds` 1.2, `maximumSpeechSeconds` 20, `noSpeechGiveUpSeconds` 6, `maximumFollowUpTurnsInARow` 5), `ClickyFollowUpTurnCounter`, `ClickyFollowUpWindowGate`, `ClickyFollowUpTranscriptDecision` (end phrases, filler) in `ClickyCore/ClickyFollowUpListening.swift`. In the app: `CompanionManager.openFollowUpListeningWindow()`, `listenForTheEndOfTheFollowUp(windowIdentifier:)` (reads `currentAudioPowerLevel` every 50 ms), `handleFollowUpTranscript(_:windowIdentifier:)`, `closeFollowUpListeningWindow(because:)` with `FollowUpListeningCloseReason` (a `String` raw-value enum: `panelOpened`, `settingSwitchedOff`, `askKeysPressed`, `nothingWasSaid`, ...). `BuddyDictationManager` has the start source `.followUpListening`, `startFollowUpListening`, `stopFollowUpListening`, `isFollowUpListeningInProgress`. The level is RMS × 10.2 clamped to 0...1 and smoothed with `max(new, previous × 0.72)` (a quiet room reads about 0.01–0.08, speech 0.3–1). **Nothing about levels is logged today, and a window that closes silently writes no line.**
- **Persona** `ClickyPersona` (`ClickyCore/ClickyPersona.swift`: `assistantName`, `style`, `userAddress`, `cleanedName(_:)`, `isDefault`), `ClickyPersonaPromptSection`, `ClickyActionsPromptSection.timeLine(for:timeZone:)`. Settings keys in `ClickyPanelSettingsDefaults` (`ClickyCore/ClickyPanelSettings.swift`): `isActionsEnabledKey`, `isFollowUpListeningEnabledKey`, `personaAssistantNameKey`, `personaStyleKey`, `personaUserAddressKey`; `ClickyPanelSettingChange` cases; the mirror in `CompanionManager` (`mirrorAppStateIntoChatPanelSettings`, `applyPanelSettingChange`).
- **Metrics.** `ClickyTurnMetrics` (a struct in `ClickyCore/ClickyTurnMetricsLog.swift`; the writer is the enum `ClickyTurnMetricsLog`, `recordInBackground`): `toolRoundTripCount`, `toolCallCount`, `bytesRead`, `changesProposed`, `changeOutcome`, `roundTripInputTokens`, `roundTripCacheReadTokens`, `roundTripMilliseconds`, `keyReleaseToAudioStartMilliseconds`, `timeToFirstReplyTextMilliseconds`, `textToSpeechFetchMilliseconds`, `speechPrefetchOutcome`, `wasInterruptedByEscapeKey`, and since round 18 `actionToolCallCount`, `actionKinds`, `startedByFollowUpListening`. The log is `~/Library/Logs/Clicky/turn_metrics.jsonl` (newest 500 lines). The usage tab's parser is `ClickyUsageLogParser` (`ClickyCore/ClickyUsageSupport.swift`).
- **The status pill.** `ClickyStatusPillContent.content(...)` (`ClickyCore/ClickyStatusPillSupport.swift`) has a priority list: dictation, keys held, thinking, a dictation notice (`case notice(String)`), the turn failure notice (`turnFailureNoticeText`), speaking. `CompanionManager.handleTimerEnded` already shows a pill notice through the same path. `ClickyStatusPillController.show(_:onScreen:)`.
- **Spoken error sentences** `ClickyTurnFailureMessage.response` (`ClickyCore/ClickyTurnFailureMessage.swift`): HTTP 401, 402, 429 and provider billing messages each have a sentence; 429 says "i'm being rate limited. try again in a moment."
- **The eval.** `eval/actions_runner/main.swift` (compiled with ClickyCore, a fake executor whose world a scenario sets; flags `--runs`, `--only`, `--list scenarios|reserveScenarios`, `--actions-off`; per record `requestCount`, `toolRoundTrips`, `toolCallCount`, `toolCalls`, `executorCalls`, `actionKinds`, `perRequestMilliseconds`, `perRequestInputTokens`, `perRequestCacheReadTokens`, `perRequestCacheWriteTokens`, `perRequestOutputTokens`, `turnMilliseconds`, `estimatedDollars`, `honestyRuleChangedWords`, `unbackedClaimsBeforeHonestyRule`), the visible set `eval/scenarios/actions.json` (14 scenarios `act_01_open_safari` … `act_14_what_does_this_error_mean`), `eval/file_editing_runner --with-actions`. **Never read `eval/scenarios/holdout/` or the tester's result files.** "Now" in the eval is 2026-11-11 10:42 Europe/Amsterdam.
- **The Worker** (`worker/src/index.ts`, 186 lines at `main`): three POST routes, the app token check, no counters. **You do not touch `worker/`.**

## Baseline (measured)

**The app, 14 Nov 2026, before round 18 (Sam's real log, 102 turns, 0 with tools; medians, spoken turns):** key release → final transcript 71 ms; screenshot capture 53 ms; prompt assembly 6 ms; time to first reply text 1,682 ms; Claude total (stream end) 2,473 ms; TTS fetch 618 ms; key release → first reply text 2,119 ms; **key release → audio start 3,780 ms**; image bytes 251 KB; input 2,375 uncached tokens + 1,604 cache read (the base prompt); output 65 tokens.

**Round 18 through the Worker (the tester, 14 Nov 2026, Sonnet 5.5, fake executor; medians; the eval's time excludes TTS):**

| turn kind | requests | time | cost |
|---|---|---|---|
| no tool, actions off | 1 | 2.46 s | $0.0050 |
| no tool, actions on (the default) | 1 | 2.40 s | $0.0059 (the ten tools, the paragraph and the time line add about 1,950 input tokens: no measurable time, +$0.0008 a turn; the tools sit in the cached prefix) |
| one action at once ("open safari", "set a timer") | 2 | 4.7 s (p90 6.6 s) | $0.0117 |
| two actions, or a lookup (`list_reminders`, `list_shortcuts`) | 2 | 4.5 s | $0.0128 |
| open a file it has to find first | 4 to 5 | 10.5 to 12.1 s | $0.036 to $0.041 (the model called `list_folder` twice before `read_file` and `open_file`) |
| file edit with the action tools present | 3 | 7.7 s | $0.024 (same-day baseline without them: 7.0 s, $0.022) |

Honesty rule: rewrote 0 of about 100 live replies. Safety: 0 failures in 162 runs. **Not measured:** follow-up listening (no audio in the eval); real-app numbers for round 18 do not exist yet (the app was not rebuilt when this was written).

Three things follow and decide the candidates:
- An action turn is two model requests. Request 2 only turns the tool result into a sentence. It costs the whole second half of the 4.7 s and about half of the $0.0117. Removing it (A) or the whole model call (B) is where the time is.
- Before round 18, 1.66 s of the 3.78 s Sam waits lay between the first reply text and the audio start (TTS fetch 618 ms of it; the rest is the stream to its end and the finisher). A fixed sentence has no stream to wait for.
- The screenshot costs 53 ms to capture but about 1,300–1,500 of the 2,375 uncached tokens (estimate: a 1280-pixel JPEG at 0.8 quality). Skipping it saves tokens, not capture time.

## Build order and stop rule

Finish each stage with its checks passing before the next. If you run short, stop at a stage boundary with everything type-checking, and report exactly what is done and what is not. A finished stage 3 is worth more than five half stages.

1. **Measure (offline).** New metrics fields, the follow-up log, the summarizer, the eval's new flags and columns. No behaviour change.
2. **Cache breakpoint after the first tool call (D)** and the **status pill feedback line (H)**.
3. **Skip the final request after one simple at-once action (A)**, with the fixed confirmation table and "call me".
4. **Quick commands (B)**, the setting, the grammar, the fast path before the screenshot.
5. **`find_file` (J)**, **parallel at-once actions (E)** and **timers that survive a restart (G)**.
6. **The cap sentence (I, app side)** and the docs: `eval/README.md`, `AGENTS.md`.

Not built this round: skipping the screenshot (C; the tester measures it); tuning the follow-up thresholds (the log of stage 1 comes first; tune in a later round from a week of Sam's data); the Worker code (the orchestrator's PR).

## The candidates, weighed

### A. Skip the second request after one simple at-once action; speak a fixed confirmation
- **Gain:** the median action turn drops from 2 requests, 4.7 s, $0.0117 to 1 request, about 2.4 s (the no-tool median, plus a few output tokens for the tool call) and about $0.006 (estimate: request 1 costs about what a no-tool turn costs). Safari is open at about 2 s; Clicky says "opened safari, sir." at about 3 s including TTS, instead of about 5.3 s.
- **Risk:** the words come from a table, not the model, so the style ("butler", "playful") does not colour them (Sam approved; "call me" is appended). A result that needs reasoning (an error, close names, "is installed but did not start") still goes to the model. Text the model wrote before the tool call is a progress note and is never spoken (round 17 rule), so nothing is lost.
- **Measure:** `eval/actions_runner`: `act_01`, `act_02`, `act_03`, `act_04`, `act_05`, `act_10` run with `requestCount` 1 and the fixed words; every other scenario is unchanged. App log: `skippedFinalRequest: true` with a lower `keyReleaseToAudioStartMs`.
- **Build (stage 3).**

### B. Quick commands: a local fast path with no model call (Sam: built, on by default)
- **Gain:** "open safari" becomes transcript (71 ms) + launch (tens of ms) + TTS of a fixed sentence (about 600 ms): about 0.8 s and $0, instead of 4.7 s + TTS and $0.0117. Same for timers.
- **Risk:** it bypasses the model, the screenshot, the persona style and the prompt's injection rules; a wrong match is a wrong action. Mitigation: a closed grammar on the whole transcript, a unique app match, and every doubt goes to the model. Apple Speech may write "ten" or "10". The exchange must still reach the chat and the model's history so "and chrome too" has context.
- **Measure:** offline: an accepted table (≥ 60) and a refused table (≥ 30 near misses). Live: the tester's holdout commands; `localFastPath: true` turns in the app log.
- **Build (stage 4).** Note for D: quick commands take many simple action turns off the model entirely, which lowers the share of multi-request turns further.

### C. Skip the screenshot when the command clearly needs none
- **Gain:** about 1,300–1,500 input tokens (≈ $0.003) per request and an unknown share of the 1.7 s to first text (guess 100–300 ms). Capture itself is 53 ms.
- **Risk:** the decision is made from the transcript alone before the model sees anything ("open the file i'm looking at", "remind me about this" need the screen). The clear cases are exactly B's cases, and B skips the model entirely.
- **Measure only:** the tester runs 10 paired probes (same prompt with and without the image, streaming) and reports TTFT and tokens (≈ $0.15). If the TTFT gain is under 200 ms, drop the idea for good.
- **Not built.**

### D. A cache breakpoint on the first user message, for loop requests after the first
- **Facts (Claude API docs via the claude-api skill, 14 Nov 2026):** `cache_control` may sit on any content block, image and `tool_result` blocks included; at most 4 breakpoints per request; the minimum cacheable prefix on Sonnet 5.5 is 512 tokens; a 5-minute write costs 1.25× input, a read 0.1×: a write followed by one read (1.35×) already beats two uncached sends (2×). Render order is tools → system → messages, so a breakpoint on the last block of the first user message caches the tools, both system blocks and the screenshots together. Within one turn the loop re-sends the same system blocks (the time line changes per turn, not within one) and the same first user message, so a later request reads what an earlier one wrote. A `thinking` or `effort` change would invalidate the cache; the app pins both.
- **Arithmetic (list prices, the uncached tail about 2,400 tokens):** a write costs +0.25 × 2,400 × $2/M ≈ +$0.0012; each later request in the same turn saves 0.9 × 2,400 × $2/M ≈ $0.0043.
  - Default-on (breakpoint on every request 1): a no-tool turn pays +$0.0012 (+20% of $0.0059) for nothing; a 2-request turn nets −$0.0031 (−27%); a 3-request edit −$0.0074 (−30%); a 5-request find −$0.016 (−40%). It breaks even only when about 28% or more of all turns run a tool. Sam's log had 0 tool turns in 102 before round 18, and A and B remove the simplest action turns from the loop, so that share will stay well under 28%.
  - **After the first tool call (the breakpoint appears from request 2 onward):** a no-tool turn is untouched; a 2-request turn pays +$0.0012 (+10%, request 2 writes, nothing reads); a 3-request turn nets −$0.0031 (−13%); a 5-request find −$0.011 (−27%). It never costs more than $0.0012 on any turn and wins on every turn of three requests or more.
  - **Decision: after the first tool call.** Default-on is a bet on a tool-turn share the log does not support, and it bets against A and B. The orchestrator can flip to default-on later from the summarizer's numbers if the share of multi-request turns grows (Google in round 23 will make loops longer). The eval flag below measures both.
- **Risk:** low. The breakpoint must sit on the **last** block of the first user message (the text block after the images), never on an image alone, and the block's bytes must be the same across the loop's requests (only the `cache_control` key is added).
- **Measure:** `perRequestCacheReadTokens[2...]` ≈ `perRequestInputTokens[0]` plus the earlier cache read; `perRequestCacheWriteTokens[1]` non-zero; `estimatedDollars` per scenario with and without the flag. In the app, the new `roundTripCacheCreationTokens`.
- **Build (stage 2).**

### E. Run the independent tool calls of one reply in parallel
- **Gain:** small for most actions (opening an app takes tens of milliseconds); real for `list_shortcuts` (a `Process` with a 5 s limit) and `list_reminders` (EventKit) when they come with other calls. Two actions in one reply measured 4.5 s, the same as one, so the model already batches them and the gain is in the executor's time, not the model's.
- **Risk:** file proposals depend on order; the action session's counts (3 opened items via `reserveAnOpenedItem`) must not race; the real executor hops to the main actor (fine: the slow calls are not main-actor bound). Swift 6 trap: `executeToolCall` takes a `[String: Any]`, which is not `Sendable`, so a `withTaskGroup` child task capturing it fails the `-swift-version 6` type-check variant. Pass each call's input into the group as `Data` (the serialized JSON) or a small `Sendable` wrapper and decode inside the child.
- **Measure:** a new visible scenario `act_15_open_safari_and_youtube` (two at-once actions in one reply) gives the same results in the same order; checks that order is kept and that a mixed reply stays sequential.
- **Build small (stage 5):** parallel only when every `tool_use` of the reply is an action tool of an at-once kind; results returned in the original order in one user message.

### F. Tune the follow-up listening thresholds from real numbers
- **Today:** the constants were chosen without data (see "What exists"). A window that closes silently writes no line, so a window that never heard Sam is invisible, and one that fired on a TV shows only as a model call he probably interrupted. The eval cannot measure audio.
- **Build (stage 1): a numbers-only log**, `~/Library/Logs/Clicky/follow_up_metrics.jsonl` (`ClickyFollowUpMetrics`, reusing the turn log's append and newest-500 rotation): one line per window with `measuredFloorPerMille` (level × 1000, an integer), `peakLevelPerMille`, `millisecondsToSpeechStart`, `speechMilliseconds`, `closeReason` (the existing `FollowUpListeningCloseReason` raw values, moved into ClickyCore as a `String` enum so both the app and the log share it, plus `sentToModel`, `endPhrase`, `fillerOnly`, `chainCap`), `chainPosition` (1…5), `windowOpenMilliseconds`, and `turnId` (a UUID, also written on the turn line of a follow-up turn so the two can be joined). The type has no `String` field except the enums and the UUID. Also on the turn line: `interruptedWithinMilliseconds` (how soon after the reply began Escape came), the proxy for "fired on noise".
- **Do not change the constants this round.** If you find a bug in the state machine while wiring the log, report it.
- **Measure:** after a week the orchestrator runs the summarizer on a copy of the log: floors, onset times, close reasons by chain position; Sam's hand tests cover the extremes.

### G. Timers that survive a restart (Sam: shown at launch; spoken only if ended under 10 minutes ago)
- **Gain:** reliability. Round 18 lists "timers are lost when Clicky quits" as a known limit.
- **Build (stage 5):** `~/Library/Application Support/Clicky/Timers/timers.json` (id, label, start and end dates), written on every change, read at launch; ids continue from the highest stored (`t7` stays `t7` across a relaunch). Pure: `ClickyTimerBoard` gains `Codable` state and `timersEndedWhileAway(now:)`. At launch: a running timer is re-armed with its original end date (no drift); an ended one gets the pill notice ("pasta timer ended while i was off") and the panel line once, and the spoken sentence "your pasta timer ended while i was off." only when it ended under 10 minutes ago, at most 10 s after launch and never over a running turn. The self test uses a temporary folder (`CLICKY_TIMERS_DIRECTORY`, honoured only in a self test, like the memories folder).
- **Measure:** smoke checks (round trip, ended-while-away list and the 10-minute rule, id continuity); Sam's hand test.

### H. A feedback line in the status pill ("opened safari")
- **Gain:** perceived speed: the pill shows the result the moment the executor returns, about 2 s into an action turn today, 3 s before the model's words; with A and B the pill and the voice arrive together, and the pill still helps with "speak replies" off.
- **Build (stage 2):** `ClickyStatusPillContent.content(...)` gains an `actionNoticeText` of the same priority as the dictation notice (shown 3 s; 6 s when no reply follows). Pure `ClickyActionNoticeText.notice(forResultText:kind:)`: the result's first sentence without its full stop ("opened safari", "timer t1 pasta started", "waiting for your yes" for a queued kind), cut at 60 characters with an ellipsis; errors show nothing (the spoken reply handles them). While the chat panel is open the same words appear in its status row.
- **Privacy:** the pill shows an app name or label on screen for 3 s; it is never logged (the pill never was).
- **Measure:** the notice text for every example result of round 18 (smoke); an offscreen render of the pill with a notice.

### I. The Worker spend cap (Sam: 600 chat requests + 60,000 TTS characters per day, requests first)
- **The Worker side is the orchestrator's own PR** (`worker/src/index.ts`: a KV namespace binding, counters per UTC day for `/chat` requests and the `text.length` of `/tts` bodies, HTTP 429 with body `{"error":{"type":"clicky_daily_cap","message":"daily cap reached"}}` and header `X-Clicky-Cap: daily`; v2 later counts dollars by tee-ing the SSE stream for `usage`). The orchestrator commits only the binding lines of `wrangler.toml`, never Sam's test voice line, and deploys with Sam.
- **The builder's part (stage 6):** `ClickyTurnFailureMessage.response` recognises that body or header and says "i've hit today's spending cap."; a plain 429 keeps "i'm being rate limited. try again in a moment." The same sentence for a `/tts` 429 with the header: the pill shows "voice unavailable · <the reply>" as today plus the cap words. Smoke checks on the body, the header, and a plain 429.

### J. `find_file`: a new tuning target from the live numbers
- **Fact:** opening a file the model has to find first took 4 to 5 requests, 10.5 to 12.1 s and $0.036 to $0.041, because the model called `list_folder` twice before `read_file` and `open_file`.
- **Build (stage 5):** a sixth file tool `find_file {name}` ("find files by name in the folders you may edit: a file name or a part of it, case-insensitive. use it when you know the name but not the folder, instead of listing folders."), pure in `ClickyCore/ClickyFileTools.swift` through `ClickyFilePathPolicy` (inside allowed folders only, protected names never listed, `.git` skipped, at most 20 matches sorted by path, depth at most 6, result lines as relative paths the way tool results write them). The `open_file` description gains "if you know only the file's name, call find_file first." The `list_folder` description gains "to find a file by name, use find_file instead." The tools array is fixed text in fixed order: `find_file` goes last among the file tools, so the earlier five keep their bytes and only the round 17 byte-identical check for "a folder set, actions off" is updated (keep the old body as a second reference so the diff is exactly the one new tool and the two sentence additions).
- **Expected:** `act_11_open_file_at_the_send_button` from 4–5 requests to 3 (`find_file`, `read_file`, `open_file`), about 7 s and $0.025 (estimate). With D, request 3 reads the cache.
- **Measure:** `act_11` and a new `act_16_open_file_by_name_only` ("open compose.swift") with `requestCount` ≤ 3; the file editing eval `--with-actions` still 14 of 14.

### Recommendation summary (all approved by Sam where a decision was needed)
Build: D after the first tool call, H, A, B, J, E, G, the app sentence of I, the follow-up log of F. Measure only: C. Not this round: tuning F's thresholds; the Worker code.

## Decisions on details

### Stage 1: measuring
- **New fields on `ClickyTurnMetrics`** (numbers and fixed identifiers only): `roundTripCacheCreationTokens: [Int]?` (from `ClickyToolLoopRequestStats.cacheCreationInputTokens`), `skippedFinalRequest: Bool?` (A), `localFastPath: Bool?` (B), `parallelToolCalls: Int?` (E), `turnId: String?` (a UUID, set for every turn), `interruptedWithinMilliseconds: Int?`. `ClickyUsageLogParser` must still read old lines; the usage tab counts a quick-command turn as a question with zero tokens under a fixed model name `quick-commands` (shown as "quick commands", no price).
- **The follow-up log** as in F. Written where the window closes (`closeFollowUpListeningWindow(because:)` and `handleFollowUpTranscript`), whatever the outcome.
- **The summarizer** `eval/metrics_summary/main.swift` (compiled with ClickyCore, so it uses `ClickyUsageLogParser` and the new follow-up parser): takes the path of a **copy** of `turn_metrics.jsonl` and optionally of `follow_up_metrics.jsonl`, and prints: turns by request count (1, 2, 3, 4+), medians of `keyReleaseToAudioStartMs`, `timeToFirstReplyTextMs` and cost at list prices by turn kind (no tool; action at once; action queued; file tool; quick command; skipped final request), per-request-index medians of ms, input, cache read and cache creation tokens, the `actionKinds` histogram, the share of turns with any tool call (the number D's default is judged by), and follow-up close reasons by chain position with floor and onset distributions. It never reads `~/Library/Logs/Clicky` itself; the orchestrator copies the files into the scratchpad first. It prints nothing but numbers and fixed identifiers. A check runs it on a synthetic log of 50 lines written to a temporary folder.
- **The eval** `eval/actions_runner` gains the flags `--cache-after-first-tool-call`, `--cache-first-request` (default-on, for the comparison), `--skip-final-request`, `--quick-commands` (runs the transcript through the parser first and records a turn with 0 requests when it matches) and `--parallel-actions`, each off by default so the round 18 numbers can be reproduced, and the scenarios `act_15_open_safari_and_youtube` and `act_16_open_file_by_name_only` in the visible set. The result file keeps its shape; a `flags` object is added to the summary.

### Stage 2: the cache breakpoint (D)
- `ClickyClaudeChatRequestBuilder.currentUserContentBlocks(images:userPrompt:cacheControlOnLastBlock: Bool = false)`: with `true` the last block (the user prompt text) gets `"cache_control": {"type": "ephemeral"}`; never an image block.
- The loop: `ClickyToolLoop.run` gains `cacheFirstUserMessageFromRequest: Int?` (nil: never; 2: from the second request on). `buildRequestBody` already receives the messages; the loop replaces the first user message's content blocks with the cached variant for requests at or past that number. The messages are otherwise byte-identical from one request to the next (the API checks thinking signatures against them; the `cache_control` key is not content).
- `CompanionManager` passes 2 whenever `preparedTurnTools` exists. With actions off and no folder the plain path is untouched.
- Smoke checks: request 1 of every turn is byte-identical to round 18's; from request 2 exactly one `cache_control` is in `messages`, on the last block of the first user message; the messages of request 3 differ from request 2 only by the appended assistant and user messages; the breakpoint count never exceeds 4 (static system block + this one = 2).

### Stage 2: the pill feedback (H)
- `CompanionManager` shows the notice from the loop's `onProgress` when an action tool result arrives with `isError == false`; the kind decides the text (`ClickyActionNoticeText`). A reply with several actions shows the last. The notice gives way to "speaking" after 3 s or to a new state at once. In the self test (`CLICKY_DRAW_SELF_TEST=1`) the pill also shows a sample notice for the proof picture.

### Stage 3: skip the final request (A)
- **The gate** `ClickyFinalRequestSkipDecision.shouldSkip(replyToolUses:actionSession:transcript:)` (pure): true only when all hold: the reply's `stop_reason` is `tool_use`; it holds exactly one `tool_use`; the tool is an action tool whose recorded kind is `openApp`, `openLink` (at once; `openLinkQueued` never), `searchWeb`, `openFile`, `revealFile`, `setTimer` or `cancelTimer`; the result is not an error; no file tool was called in this turn; this was the turn's first request; the transcript has at most 12 words, no question mark, does not start with a question word (what, how, can, could, would, is, are, should, why, where, when, which, who) and holds none of "and", "then", "also", "after", "before", "while" (so "open safari and tell me what you see" still gets the model's answer). `createReminder`, `listReminders`, `listShortcuts`, `runShortcutQueued` and `openLinkQueued` never skip: their replies need words the result does not give, or the ready sentence the honesty rule governs.
- **The fixed confirmation** `ClickyFixedConfirmationText.sentence(forKind:resultText:persona:)` (pure), built from the tool result, not the transcript: "opened safari.", "opened youtube.com.", "searching for best pizza in amsterdam." (the query cut to 60 characters), "opened compose.swift at line 9.", "showing compose.swift in finder.", "timer set, 10 minutes." or "pasta timer set, 10 minutes.", "stopped the pasta timer." / "stopped timer t1.". **With a "call me" name set, the name is appended before the full stop: "opened safari, sir."** (Sam's decision 2). The style is ignored. The name is `ClickyPersona.userAddress` after `cleanedName`.
- **What happens:** `ClickyToolLoop.run` gets a `shouldStopAfterRequest` closure (the gate) and returns `ClickyToolLoopResult` with a new flag `endedBecauseTheFinalRequestWasSkipped`; `CompanionManager` uses the fixed sentence as the final spoken text and runs it through `ClickyTurnFinisher` and `ClickyActionHonesty.honestSpokenText` with facts that record the success (a check proves the sentence comes back unchanged), then TTS. The model's history gets the sentence plus the `[done: ...]` line from `actionSession.doneLines`; the chat store's display text is the sentence. Follow-up listening opens as after any spoken reply.
- **TTS:** fetch the sentence's audio the moment the executor returns (there is no stream to wait for); `ElevenLabsSpeechPrefetch` is otherwise unchanged.
- **Metrics:** `skippedFinalRequest: true`, `toolRoundTripCount` 0, `toolCallCount` 1, `actionKinds` as recorded.
- **Smoke checks:** the gate on at least 40 cases (each kind, errors, two tool calls, a file tool in the turn, a long or interrogative transcript, each never-skip kind) and the sentence for every kind with and without a label and with and without "call me".

### Stage 4: quick commands (B; Sam: on by default)
- **Setting** "quick commands" (`isQuickCommandsEnabled`, default on, key `isQuickCommandsEnabledKey` in `ClickyPanelSettingsDefaults`, a `ClickyPanelSettingChange` case, mirrored like the others) in the ACTIONS section with the hint "open apps and set timers without asking the ai". Off when actions are off.
- **Grammar** `ClickyQuickCommandParser.parse(transcript:installedApplications:runningTimers:)` (pure, Foundation only, returns `.openApp(ClickyInstalledApplication)`, `.setTimer(durationSeconds:label:)`, `.cancelTimer(reference:)` or nil). The whole transcript, lowercased, trimmed of end punctuation and of one leading "hey clicky", "clicky", "please" or "can you", must match exactly one of:
  - `open <app>`, `launch <app>`, `switch to <app>`, `go to <app>`, where `<app>` resolves through `ClickyAppNameMatcher` to exactly one installed app (aliases and unique prefix included; two candidates means nil);
  - `set a timer for <n> (second|seconds|minute|minutes|hour|hours)` with an optional `for <label>` or `called <label>` after it; also `<n> minute timer`, `timer for <n> minutes`, `set a <n> minute timer`; `<n>` is digits or a number word up to "sixty" and the compounds "an hour", "half an hour", "an hour and a half" (a table), 1 s to 24 h;
  - `stop the timer`, `cancel the timer`, `stop the <label> timer`, `cancel the <label> timer`, where the label resolves to exactly one running timer (or there is exactly one timer when no label is given).
  - **Refused (so the model gets it):** any transcript with "and", "then", "also", "but", "after", "before", "when", "while", a question word at the start, a question mark, or more than 12 words; "open" followed by words that do not resolve to exactly one app ("open the settings page", "open my notes", "open it"); an ambiguous app name; a timer with no number or a number outside the range.
- **Order in the turn:** in `sendTranscriptToClaudeWithScreenshot`, after `fileEditingController.decision(forTranscript:)` (a yes, no or undo wins), and for a follow-up transcript after `ClickyFollowUpTranscriptDecision` (so a lone "stop" is still the end phrase, and "stop the timer" is a quick command), and before the screenshot. Never while a dictation runs or while actions are off.
- **What happens:** no screenshot, no prompt, no model. The real executor runs the action through a fresh `ClickyActionToolTurnSession` (so the counts, the `[done: ...]` line and the result text are round 18's); the fixed sentence of A is spoken with the same "call me" rule; the pill shows the notice; the exchange is recorded in the chat and in the model's history (the user's words, the sentence, the `[done: ...]` line) so the next turn has context; follow-up listening opens as after any spoken reply. A result that is an error (the app did not start, the timer limit) falls back to the normal turn with the model, with the words as the transcript; nothing is spoken twice.
- **Metrics:** a turn line with `localFastPath: true`, `modelName: "quick-commands"`, `keyReleaseToAudioStartMilliseconds`, `actionKinds`, `actionToolCallCount` 1, and no token fields.
- **Smoke checks:** the accepted table (≥ 60, both number forms, aliases, labels) and the refused table (≥ 30 near misses) against a fake app list and a fake timer board; the order rule (a yes while a set waits is not a quick command; "stop" in a follow-up is the end phrase).

### Stage 5: `find_file` (J), parallel at-once actions (E), timer persistence (G)
- `find_file` as in J; input parsing like the other file tools; the result text "found 2 files: website/README.md, docs/README.md" or "no file named 'x' in the folders you may edit." At most 20 matches; "and N more" past that. Counts towards the 12 tool calls; reads nothing, so `bytesRead` is unchanged.
- Parallel calls: in `ClickyToolLoop.run`, when every `tool_use` of the reply names an action tool and the session says each is parallel-safe (`ClickyActionToolTurnSession.isParallelSafe(toolName:)`: `open_app`, `open_url`, `search_web`, `open_file`, `set_timer`, `cancel_timer`, `list_reminders`, `list_shortcuts`), run them in a `withTaskGroup` with `Data` inputs, collect results by index and append the `tool_result` blocks in the original order; any other mix keeps the sequential path. The opened-items count is reserved before the group starts (reserve, then run; a refused reservation gives that call the limit result). `parallelToolCalls` = the number of calls run in a group.
- Timer persistence as in G.

### Stage 6: the cap sentence (I) and docs
- `ClickyTurnFailureMessage`: an HTTP 429 whose body holds `"type":"clicky_daily_cap"` or whose headers hold `X-Clicky-Cap` gives "i've hit today's spending cap." (the error's `userInfo` must carry the body and the header; add them where the app builds the error from the response, in `ClaudeAPI` and `ElevenLabsTTSClient`). Smoke checks on the body, the header, and a plain 429.
- `AGENTS.md`: the architecture line, a "Jarvis tuning (round 19)" section (the measured baseline, the D decision and its arithmetic, the gate, the grammar, the fixed sentences, the follow-up log, timer persistence, `find_file`, the cap sentence, the privacy rules, known limits), Key Files rows for the new files, and the round 18 line "Timers are lost when Clicky quits" replaced. `eval/README.md`: the new flags, scenarios and the summarizer.

## Design (files likely touched)
- `ClickyCore/ClickyToolLoop.swift`: `cacheFirstUserMessageFromRequest`, `shouldStopAfterRequest`, the task group, `cacheControlOnLastBlock`.
- `ClickyCore/ClickyFileTools.swift`: `find_file` and the two description sentences; `ClickyCore/ClickyActionTools.swift`: `isParallelSafe`.
- `ClickyCore/ClickyTurnMetricsLog.swift`, `ClickyCore/ClickyUsageSupport.swift`: new fields, tolerant parsing, the "quick commands" row.
- New in ClickyCore: `ClickyFinalRequestSkipDecision.swift`, `ClickyFixedConfirmationText.swift`, `ClickyQuickCommandParser.swift`, `ClickyActionNoticeText.swift`, `ClickyFollowUpMetrics.swift` (with the close-reason enum moved from `CompanionManager`), timer persistence in `ClickyTimerBoard.swift`.
- App: `CompanionManager.swift` (the gate, the quick-command branch, the pill notice, the follow-up line, the launch-time timer check), `ClickyTimerController.swift` (persistence), `ClickyStatusPillController.swift` and `ClickyCore/ClickyStatusPillSupport.swift` (the action notice), `ClickyChatPanelSettingsView.swift` and `ClickyCore/ClickyPanelSettings.swift` (the switch), `ClickyCore/ClickyTurnFailureMessage.swift`, `ClaudeAPI.swift` and `ElevenLabsTTSClient.swift` (the 429 body and header in the error), `ClickyFileEditingController.swift` (`ClickyPreparedTurnTools` passes the gate's inputs).
- Eval: `eval/actions_runner/main.swift` (flags, columns, scenarios 15 and 16 in `eval/scenarios/actions.json`), new `eval/metrics_summary/main.swift`, `eval/README.md`.
- Worker: nothing by the builder.

## Hard rules
- **Your own worktree.** Every repo path is your worktree's. Never touch `/Users/samsto/Clicker` (the orchestrator builds round 18 there).
- **No builds and no app runs.** Never `xcodebuild`. No Xcode builds. Never launch, quit or kill Clicky. Type-check with the smoke program's scripts only.
- **No network calls.** Never read, print or `cat` `leanring-buddy/ClickyWorkerSecrets.plist` or any key. The eval runner and the summarizer are built and type-checked, not run against the Worker.
- **No real actions** from your own commands or checks: never open an app, link or file, create a reminder, run `shortcuts`, start a real timer with a sound, or play audio. Fake executors only.
- **Never touch `worker/`.** The Worker cap is the orchestrator's PR.
- **No git changes.** No commit, push, checkout, reset or stash (the orchestrator created the branch and the worktree).
- **Tests use temporary folders only.** Never `~/Library/Logs/Clicky`, never `~/Library/Application Support/Clicky`, never `~/Documents`, never `~/clicky-test`. The summarizer reads a path it is given; in checks that is a temporary file you wrote.
- **Never log text.** Metrics and the follow-up log hold numbers and fixed identifiers only: no app name, link, query, path, label, title or transcript, ever. `turnId` is a UUID. A smoke check greps every new line type for the fake world's names.
- **Never read `eval/scenarios/holdout/` or the tester's result files.**
- **Leave these unchanged:** the static base prompt (byte-stable); the memory, profile and notes rules; the secret detector; dictation; drawing and pointing; the old-screen logic; round 16 memories; round 17's and round 18's behaviour with every new switch off and before the first tool call (byte-identical request bodies, checked; the only accepted diff in a tools array is `find_file` and the two description sentences).
- **Hosting views.** No `MainActor.assumeIsolated`; nothing added inside an existing `NSHostingView`.
- **Naming and comments.** Descriptive names; comments say why. Pure logic in ClickyCore, Foundation only, `nonisolated`.
- **The smoke program.** `round19_smoke/` copied from `round18_smoke/` with every path rewritten to your worktree; `round19_part*.swift` with a splice script; all 4,191 existing checks pass; `typecheck_core.sh` (4 variants) and `app_check/typecheck_app.sh` clean; `eval/file_editing_runner`, `eval/actions_runner` and `eval/metrics_summary` type-check against ClickyCore.

## Acceptance checks
- Type-checks clean (ClickyCore in four variants, the whole app).
- Smoke checks:
  - byte-identical request bodies: actions off and no folder (today's plain body); actions off with a folder (round 17's body plus exactly `find_file` and the two sentences); actions on, request 1 (round 18's body plus the same file-tool diff);
  - the cache breakpoint absent on request 1, present from request 2 on the last block of the first user message only, messages otherwise identical across requests, never more than 2 breakpoints in a request;
  - the skip gate (≥ 40 cases) and the fixed sentences (every kind, with and without a label and "call me"); the honesty rule leaves every fixed sentence unchanged;
  - the quick command grammar (≥ 60 accepted, ≥ 30 refused), the order rule, the error fallback;
  - `find_file` (inside, outside, protected names, `.git`, the 20 cap, depth, case);
  - the parallel group keeps order, reserves counts, stays sequential for mixed replies, and passes `-swift-version 6`;
  - timer persistence round trip, ended-while-away list with the 10-minute rule, id continuity;
  - the follow-up line's shape (no free text) and rotation; `turnId` on both lines;
  - the pill notice texts for every round 18 example result;
  - the usage tab parser reads old and new lines; a quick-command turn counts as a question with no tokens;
  - the cap sentence for the body, the header, and a plain 429;
  - no fake-world name in any metrics or follow-up line.
- Offscreen renders (as in `live_size_render`, with the real panel controller): the settings tab with the "quick commands" switch; the pill with an action notice.
- The summarizer on a synthetic 50-line log prints every table.
- **Report:** model ID; files changed and why; checks with counts (4,191 + new); type-check results; the gate's exact rules; the fixed sentence table; the quick-command grammar as built; the `find_file` definition as sent and the two changed descriptions; the request body of a loop's request 2 with the breakpoint (shortened); which candidates were built and which not; known limits; a manual test list for Sam; what could not be verified without running the app (real cache reads, the pill timing, timer persistence across a real relaunch, parallel execution on the main actor, the follow-up log with a real microphone).

## Sam's hand tests (for the orchestrator's list)
1. "open safari" with quick commands off: Safari opens at about 2 s, the pill says "opened safari", Clicky says "opened safari, sir." once (with "call me" set to "sir"), nothing twice.
2. The same with quick commands on: under 1 s, no "thinking" in the pill, the same sentence.
3. "open safari and tell me what's on the page": goes to the model, Safari opens, the model describes the page.
4. "set a timer for 2 minutes for tea", quit Clicky, relaunch: the timer still fires on time. Set one for 1 minute, quit, wait 2 minutes, relaunch: the pill and the panel say it ended, and Clicky says so once (under 10 minutes). Repeat with a 15-minute wait: shown, not spoken.
5. "open compose.swift" with a folder set but Xcode not showing it: `find_file` makes it 3 requests (the usage tab's cost for the turn is about $0.025).
6. A file edit turn: the usage tab's estimated cost per edit turn is lower than round 18's $0.024.
7. Follow-up listening with a TV on for a minute: count how often Clicky answers nobody; press Escape each time; the orchestrator reads the follow-up log afterwards.
8. The spend cap at a low test value in `wrangler dev` (orchestrator): Clicky says "i've hit today's spending cap."

## Tester's eval plan (round 19)
- `eval/actions_runner` on the visible set (16 scenarios), 2 runs, in four configurations: round 18 flags (the reproduction), `--cache-after-first-tool-call`, `--cache-first-request`, and all of `--cache-after-first-tool-call --skip-final-request --quick-commands --parallel-actions`: about 16 × 2 × 4 = 128 scenario runs at about $0.012 each ≈ $1.60 (estimate; quick-command runs cost nothing).
- Holdout scenarios the builder never sees (the tester writes them): at least 16 quick-command transcripts run offline through the parser (zero cost) including near misses ("open the settings page" must not open System Settings; "set a timer for an hour and a half" is 90 minutes or goes to the model, never 1 minute), 6 of them also live; 4 skip-gate edge cases live ("open safari, is it updated?" must get the model's words); 2 `find_file` cases.
- The screenshot probe (C): 10 pairs, about $0.15.
- `eval/file_editing_runner --with-actions`, 1 run: 14 scenarios ≈ $0.35.
- Pass bar: every round 18 scenario still passes; no scenario slower than round 18's median; the six skip scenarios run with 1 request; `act_11` and `act_16` in ≤ 3 requests; cost per action turn on the eval down by at least 40% with all flags (A alone should give about 45% on the one-action median; estimate); zero false positives in the quick-command refusal set; `perRequestCacheReadTokens[2]` non-zero on the find and edit scenarios with the breakpoint; the file editing eval 14 of 14.
- Total: about $2.50.

## Known limits of this round, stated up front
- Quick commands and fixed confirmations do not follow the persona style (Sam's decision; "call me" is kept).
- The cache breakpoint after the first tool call makes a 2-request turn about $0.0012 dearer and only pays from the third request; the orchestrator revisits the default from the summarizer when the share of multi-request turns is known.
- The follow-up thresholds are unchanged until a week of the new log exists.
- Timers are persisted, but a timer that ends while Clicky is quit cannot play its sound at the right moment; it is reported at the next launch.
- Nothing in this round is verified in the running app by the builder; the orchestrator builds and runs the self tests, and Sam's hand tests cover the rest.
