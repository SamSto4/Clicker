# Round 19 plan (builder brief): Jarvis tuning — DRAFT

**Status: DRAFT.** Written 14 Nov 2026 by the planner, before round 18 ("Jarvis actions") finished. Every number marked "(fill)" comes from round 18's eval and from Sam's turn metrics log once round 18 has run for a few days. The orchestrator finalizes this brief with those numbers before the builder starts. Numbers written here without a mark were measured on 14 Nov from the real log (102 turns, none with tools) or come from round 17's report.

## Goal and Sam's decisions (14 Nov 2026)

Sam: "focus on optimizing jarvis function once current phases are done." Round 18 made Clicky act (open apps, links and files, search, timers, reminders, shortcuts, follow-up listening, a persona). Round 19 makes those actions **fast, accurate and cheap**, without changing what they do. Standing principles: Sam keeps control over what is written or sent; our own design from public Apple APIs and the Claude Messages API; nothing from HeyClicky.

Decisions Sam has already made that bind this round:
- Actions at once vs. confirmed, the link rule, the honesty rule and the change card are as round 18 built them. This round does not move anything between "at once" and "waits for a yes".
- Privacy rules stand: metrics hold numbers and fixed identifiers only; never an app name, link, search, path, label, title or transcript.

Decisions Sam still has to make (the orchestrator asks; recommendations in "Behaviour changes Sam should approve" at the end):
1. Fixed confirmation words that skip the persona (candidate A).
2. The local fast path with no model call (candidate B): on by default, off by default, or not built.
3. The daily cap number for the Worker (candidate I) and whether the cap counts requests or dollars.
4. Whether a timer that ended while Clicky was quit is spoken at the next launch (candidate G).

You work on branch `feature/jarvis-tuning`, created from `main` after round 18 is merged (or stacked on `feature/jarvis-actions` if it is not). Read `/Users/samsto/Clicker/AGENTS.md` first, closely the sections "File editing (round 17)" and "Jarvis actions (round 18)". Read round 18's report in the loop folder for the numbers and the known limits.

## What exists and must be reused

- **The tool loop.** `ClickyToolLoop.run` (`ClickyCore/ClickyToolLoop.swift`) sends up to 6 requests per turn, runs each `tool_use` in order with `await executeToolCall(...)` inside a plain `for` loop, and answers all of them in one user message. `buildRequestBody` is a closure that gets the messages; the system blocks and tools come from outside and are byte-identical from one request to the next. `ClickyStreamedMessageAssembler` keeps blocks as received. Keep both.
- **The request body.** `ClickyClaudeChatRequestBuilder.streamingRequestBody(model:systemPromptValue:messages:tools:)` builds it; `ClickyClaudeRequestSettings.addingSpokenReplySettings` adds `output_config.effort = "low"` and, for Sonnet 5.5 only, `thinking = {"type": "between_tools"}`. The two system blocks come from `ClickySystemPromptBlocks.makeSystemBlocks(staticText:dynamicText:)` (`ClickyCore/ClickyClaudeRequestSupport.swift`): the static block carries `cache_control: {"type": "ephemeral"}`; the dynamic block has none. There is no `cache_control` anywhere in `messages` today.
- **Metrics.** The turn record `ClickyTurnMetrics` (a struct in `ClickyCore/ClickyTurnMetricsLog.swift`; the log writer is the enum `ClickyTurnMetricsLog` in the same file) already has `toolRoundTripCount`, `toolCallCount`, `roundTripInputTokens`, `roundTripCacheReadTokens`, `roundTripMilliseconds`, `keyReleaseToAudioStartMilliseconds`, `timeToFirstReplyTextMilliseconds`, `textToSpeechFetchMilliseconds`, `speechPrefetchOutcome`, and since round 18 `actionToolCalls`, `actionKinds`, `startedByFollowUpListening`. The log is `~/Library/Logs/Clicky/turn_metrics.jsonl`, newest 500 lines kept. Dictation and memory compaction have their own logs with the same append-and-rotate code.
- **Round 18's action session, executor protocol and fake executor** (`ClickyCore/ClickyActionTools.swift`, `ClickyCore/ClickyActionExecutor.swift`, `ClickyRealActionExecutor.swift`, `ClickyTimerBoard`, `ClickyTimerController`, `ClickyFollowUpListening*`, `ClickyActionHonesty`), the `[done: ...]` history lines and the result texts. The eval `eval/actions_runner/main.swift` with `eval/scenarios/actions.json` (14 scenarios, fake executor, fixed "now").
- **The audio level.** `BuddyDictationManager` computes RMS × 10.2 clamped to 0...1 per buffer and smooths it with `max(new, previous × 0.72)` on the main thread (`BuddyDictationManager.swift`, around lines 805–825 at `main`). The follow-up state machine reads that value. Nothing about audio levels is logged today.
- **The status pill** notice path (`ClickyStatusPillController`, `ClickyStatusPillContent`): used for failed-turn notices (5–12 s) and, since round 18, "pasta timer done" (8 s).
- **The spoken error sentences** (`ClickyCore/ClickyTurnFailureMessage.swift`): HTTP 401, 402, 429 and billing messages each have a sentence.
- **The Worker** (`worker/src/index.ts`, 186 lines at `main`): three POST routes, the app token check, no counters, no KV binding. **You do not touch `worker/`** (hard rule below); the Worker candidate is designed here and built by the orchestrator in its own PR.

## Baseline today (measured 14 Nov 2026, before actions; 102 turns in the real log, 97 completed, 5 cancelled, 0 with tools)

Medians, spoken turns:

| step | median |
|---|---|
| key release to final transcript | 71 ms |
| screenshot capture | 53 ms |
| prompt assembly | 6 ms |
| time to first reply text (Claude) | 1,682 ms |
| Claude total (stream end) | 2,473 ms |
| text-to-speech fetch | 618 ms |
| key release to first reply text | 2,119 ms |
| **key release to audio start (what Sam feels)** | **3,780 ms** |
| image bytes per turn | 251 KB |
| input tokens, uncached (the tail after the cached base prompt) | 2,375 |
| cache read tokens (the base prompt) | 1,604 |
| cache creation tokens | 0 |
| output tokens | 65 |

Two things follow and decide most candidates below:
- Of the 3.8 s Sam waits, about 1.66 s lies between the first reply text and the audio start. The TTS fetch is 618 ms of it; the rest is the stream running to its end (tags, notes) and the finisher. A fixed confirmation that needs no stream removes that whole stretch.
- The screenshot costs 53 ms to capture but about 1,300–1,500 of the 2,375 uncached input tokens (estimate: a 1280-pixel-wide JPEG at 0.8 quality; `CompanionScreenCaptureUtility` scales to 1280 on the long side). Skipping it is a token saving and maybe a prefill saving; it is not a capture-time saving.

From round 17 (file tools, same loop): an edit turn was a median 3 requests, 6.4 s, $0.022; a question with tools present but no tool call 2.1 s, $0.007; about 75% of an edit turn's cost was input re-sent uncached on requests 2 and 3.

**(fill) Round 18 numbers.** Per scenario of `actions.json`: requests, `roundTripMs`, `roundTripInputTokens`, `roundTripCacheReadTokens`, output tokens, total $ at list prices; pass rate over 3 runs. From Sam's log after a few days: count of turns by `toolRoundTrips` (0, 1, 2, more), medians of `keyReleaseToAudioStartMs` for turns with and without an action, `startedByFollowUpListening` count and how many of those were `interruptedByEscape` within the reply (a proxy for a window that fired on noise), `actionKinds` histogram.

## Build order and stop rule

Stages. Finish each with its checks passing before the next. If you run short, stop at a stage boundary with everything type-checking, and report what is done and what is not. Stage 1 and 2 are worth more than a half-built stage 5.

1. **Measure (offline).** The metrics fields and the summarizer. No behaviour change.
2. **Cache breakpoint on the first user message** (candidate D) and the **status pill feedback line** (candidate H). Small, safe, both measurable.
3. **Skip the final request after a simple at-once action** (candidate A) with the fixed confirmation table. Needs Sam's yes on the words.
4. **Parallel independent action calls** (candidate E) and **timers that survive a restart** (candidate G).
5. **Follow-up listening log** (candidate F; the thresholds themselves are tuned in a later round from the data).
6. **Local fast path** (candidate B) — only if Sam approved it; otherwise skip and say so.
7. **Eval and docs.** `eval/actions_runner` gains the timing and cost columns and the candidate flags; `eval/README.md` and `AGENTS.md`.

Not built this round: candidate C (skip the screenshot) beyond its measurement; candidate I (Worker cap) is the orchestrator's own PR.

## The candidates, weighed

For each: expected gain, risk, how the tester measures it, and the recommendation. Gains are estimates from the baseline above unless marked measured.

### A. Skip the second request after a simple at-once action; speak a fixed confirmation
- **Today (round 18):** "open safari" is request 1 (text + `tool_use`), the executor opens Safari, request 2 returns "opened safari." as the spoken reply, then TTS. Estimated 1.8 + ~1.5 + 0.6 s ≈ 4 s to the first spoken word, and two requests' input (the second one re-sends ~2,400 uncached tokens plus tools and system, about $0.006).
- **Gain:** removes request 2 entirely: about 1.3–2 s and about $0.005–0.008 per simple action turn (estimate; (fill) from round 18's `roundTripMs[1]` and `roundTripInputTokens[1]`). Safari is open at ~2 s; Clicky says so at ~2.7 s.
- **Risk:** the words no longer come from the model, so the persona ("butler", "call me sir") and any nuance ("i opened safari; it was already running") are lost for these turns. A result that needs reasoning (an error, close names, "no app called xyz") must still go to the model. Text the model wrote before the tool call is a progress note and is never spoken (round 17 rule), so nothing is lost there.
- **Measure:** the actions eval reports requests per scenario (1 for scenarios 1–5, 10 when the gate fires) and the $ and ms per turn; the app log shows `skippedFinalRequest: true` and a lower `keyReleaseToAudioStartMs` for turns with `actionKinds` of one at-once kind. Accuracy: the confirmation must name the right thing (eval checks the fixed sentence against the fake executor's result).
- **Recommend: build (stage 3), with Sam's approval of the wording.** Highest gain per line of code after the fast path, and it keeps the model in the loop for the decision.

### B. Local fast path with no model call for very common commands
- **Gain:** "open safari" becomes transcript (71 ms) + open (tens of ms) + TTS of a fixed sentence (~600 ms): about 0.8 s instead of ~4 s, and $0 instead of ~$0.012. "set a timer for 10 minutes" and "stop the timer" the same.
- **Risk:** it bypasses the model, the screenshot, the persona, the honesty rule and the prompt's injection rules. A wrong match is a wrong action ("open the settings page" is not "open settings"; "open safari and read me the headline" must go to the model). Apple Speech may write "ten" or "10". The exchange must still reach the chat and the model's history, or "and chrome too" on the next turn has nothing to refer to.
- **Measure:** the pure parser gets an exact-match table (accepted and refused utterances, at least 60 cases); the eval runs the transcripts of scenarios 1, 4 and 5 through the parser offline and checks 0 model calls; a false-positive list of 30 near misses ("open safari and ...", "can you open safari?", "what does open safari mean") must all be refused. Live: `localFastPath: true` turns in the log with their `keyReleaseToAudioStartMs`.
- **Recommend: build last (stage 6), only with Sam's yes, as a setting "quick commands" (`isQuickCommandsEnabled`).** Recommended default: on, because the gain is the biggest in this round and the grammar is closed; but it is Sam's call because these replies ignore the persona.

### C. Skip the screenshot when the command clearly needs none
- **Gain:** about 1,300–1,500 input tokens (≈ $0.003) per request of the turn and some prefill time (unknown; guess 100–300 ms of the 1,682 ms to first text). Capture itself is only 53 ms.
- **Risk:** the decision is made before the model sees anything, from the transcript alone. "open the file i'm looking at", "remind me about this", "set a timer for what it says on screen" need the screen. Every clear case ("open safari", "set a timer for 10 minutes") is already covered by B when B ships, and the rest are the unclear ones.
- **Measure this round, build later:** the tester runs a paired probe through the Worker, same prompt with and without the image, 10 pairs, streaming, and reports TTFT and input tokens (about 20 calls, ≈ $0.15). If the TTFT gain is under 200 ms, drop the idea; if B ships, it covers the clear cases anyway.
- **Recommend: not built this round.**

### D. A cache breakpoint on the first user message, for loop requests after the first
- **Facts (Claude API docs, via the claude-api skill, 14 Nov 2026):** `cache_control` may sit on any content block, image and `tool_result` blocks included; at most 4 breakpoints per request; the minimum cacheable prefix on Sonnet 5.5 is 512 tokens; a 5-minute write costs 1.25× input, a read 0.1×; a write followed by one read (1.35×) already beats two uncached sends (2×), so a two-request tool turn wins and only the single-request turns pay the write premium for nothing. Render order is tools → system → messages, so a breakpoint on the last block of the first user message caches the tools, both system blocks and the screenshots together. Within one turn the loop's `buildRequestBody` closure re-sends the same system blocks and the same first user message, so requests 2…N read what request 1 wrote. A `thinking` or `effort` change would invalidate it; the app pins both.
- **Gain:** on each loop request after the first, about 90% of ~2,400 tokens is read instead of re-sent: about $0.004 per extra request, and some prefill time (unknown). Round 17 measured 75% of an edit turn's cost as this re-sent input; an edit turn (3 requests) would save about $0.008 of $0.022.
- **Cost:** on a single-request turn the write premium is 0.25 × ~2,400 tokens ≈ $0.0012, never read back (the next turn has a new screenshot). Since round 18 the tools go on every turn, so most turns are single-request. Net positive once more than about one turn in four runs a tool; (fill) the share of tool turns from Sam's log decides whether it ships as default or only when a tool call has already happened (then request 2 writes and request 3 reads; a 2-request turn gains nothing).
- **Risk:** low. The breakpoint must sit on the **last** block of the first user message (the text block after the images), never on an image alone. The dynamic system block has a time line since round 18 ("the time is 14:30"); it changes per turn but not within a turn, so it caches within the turn only, which is all that is needed.
- **Measure:** `roundTripCacheReadTokens[i]` for `i ≥ 1` must be about equal to `roundTripInputTokens[0]` plus the earlier cache read; `roundTripCacheCreationTokens` (new field) non-zero on request 1. The actions eval prints the $ per scenario with and without (a flag).
- **Recommend: build (stage 2).** Implement as `ClickyClaudeChatRequestBuilder.streamingRequestBody(... cacheFirstUserMessage: Bool)`; with `false` the body is byte-identical to today (keep the existing byte-identical checks and add one for `true`).

### E. Run the independent tool calls of one reply in parallel
- **Gain:** small for most actions (opening an app takes tens of milliseconds); real only for `list_shortcuts` (a `Process` with a 5 s limit) and `list_reminders` (EventKit) when they come together with other calls, and for several `read_file` calls (fast anyway).
- **Risk:** file proposals depend on order (two edits of one file are checked against each other); the action session keeps counts (3 apps or links per turn) that must not race; the real executor runs on the main actor. Swift 6 trap: `executeToolCall` takes a `[String: Any]` input, which is not `Sendable`, so a `withTaskGroup` child task capturing it fails the `-swift-version 6` type-check variant. Pass each call's input into the group as `Data` (the serialized JSON) or a small `Sendable` wrapper, and decode inside the child task.
- **Measure:** the eval's "open safari and youtube" style scenario (new, scenario 15) shows the same results in the same order; unit checks that results keep the `tool_use` order and that a mixed reply (file + action) stays sequential for the file calls.
- **Recommend: build small (stage 4):** parallel only for calls that are all action tools and all at-once kinds; everything else stays sequential. Results are returned in the original order in one user message.

### F. Tune the follow-up listening thresholds from real numbers
- **Today:** the state machine uses named constants (0.3 s floor window, 150 ms onset, 1.2 s quiet, 6 s window, 20 s cap, 5 chained follow-ups) chosen without data. A window that closes silently writes no line, so a window that never heard Sam is invisible, and a window that fired on a TV shows only as a model call whose reply he probably interrupted.
- **Gain:** correctness of the feature Sam will use most; no latency or cost gain by itself. A better onset and quiet rule can cut the 1.2 s quiet wait a little.
- **Risk:** none from logging. Tuning without data is guessing; do not change the constants this round.
- **Build (stage 5): a numbers-only log `~/Library/Logs/Clicky/follow_up_metrics.jsonl`** (`ClickyFollowUpMetrics`, reusing the turn log's append and rotation): per window one line: `measuredFloorLevelPerMille` (level × 1000 as an integer), `peakLevelPerMille`, `millisecondsToSpeechStart`, `speechMilliseconds`, `outcome` (`noSpeech`, `fillerOnly`, `endPhrase`, `sentToModel`, `escape`, `keyPress`, `dictationStarted`, `typed`, `chainCap`, `timerAlert`), `chainPosition` (1…5), `windowSeconds`, and for a window that reached the model the same `turnId` the turn line gets (a new field on both; a random UUID per turn is a fixed-shape identifier, not text). The type has no string field other than the fixed identifiers. Also add `interruptedWithinMilliseconds` to the turn line when Escape came during the reply (how soon), the proxy for "fired on noise".
- **Measure:** after a week, the orchestrator summarizes the log: distribution of floors, onset times, outcomes by chain position. The tester cannot measure audio through the Worker; Sam's hand tests (below) check the extremes.
- **Recommend: build the log now, tune in round 20 or a fix PR.**

### G. Timers that survive a restart
- **Gain:** reliability. A 25-minute timer lost because Clicky was relaunched is a broken promise.
- **Risk:** low. Decision needed: a timer that ended while Clicky was quit should be spoken once at launch ("your pasta timer ended while i was off") or only shown in the pill and the chat.
- **Build (stage 4):** `~/Library/Application Support/Clicky/Timers/timers.json` (id, label, end date, created date), written on every change, read at launch; ids continue from the highest stored (`t7` stays `t7` across a restart). Pure: `ClickyTimerBoard` gains `encode/decode` and an "ended while away" list. The self test uses a temporary folder (`CLICKY_TIMERS_DIRECTORY`, honoured only in a self test, like the memories folder).
- **Measure:** smoke checks (round trip, overdue list, id continuity); hand test.
- **Recommend: build.**

### H. A feedback line in the status pill ("opened safari")
- **Gain:** perceived speed. The pill shows the result the moment the executor returns (~2 s), before the model's words or the TTS (~4 s today). With A or B the pill and the voice arrive together, and the pill still helps when "speak replies" is off.
- **Risk:** none. The pill's text holds the app name or label; it is never logged (the pill never was).
- **Build (stage 2):** `ClickyStatusPillContent` gains an `actionNotice` of the same priority as the dictation notice, shown 3 s (6 s when nothing else follows). The text is the tool result's first sentence without the trailing full stop ("opened safari", "timer t1 pasta started", "queued: confirm the link"), cut at 60 characters with an ellipsis.
- **Recommend: build.**

### I. The Worker spend cap
- **Gain:** a safety net against a loop, a stuck follow-up chain or a leaked token. Not speed.
- **Facts:** the Worker streams the Anthropic response body through (`handleChat`), so dollar accounting would need to tee the SSE stream and read the `usage` fields of `message_start` and `message_delta`. A request counter needs a KV namespace (eventually consistent, fine for a cap) or a Durable Object (exact). The app maps HTTP 402 to "the ai account is out of credit." and 429 to "i'm being rate limited. try again in a moment." (`ClickyTurnFailureMessage`).
- **Design (for the orchestrator's own PR; the builder does not touch `worker/`):** v1 counts per UTC day in KV: `/chat` requests and `/tts` characters (`text.length` of the body). Over the cap the Worker answers HTTP 429 with body `{"error":{"type":"clicky_daily_cap","message":"daily cap reached"}}` and header `X-Clicky-Cap: daily`. **App side (this round, the builder):** `ClickyTurnFailureMessage` learns that body or header and says "i've hit today's spending cap." (a new sentence; a plain 429 keeps its sentence). Caps: Sam's number. Suggested defaults: 600 chat requests and 60,000 TTS characters per day (about $6 and $1 at list prices for a busy day; estimate). v2 (later): dollars from `usage`.
- **Measure:** none by the tester (no live calls over the cap); the orchestrator tests the Worker with `wrangler dev` and a low cap, then deploys with Sam.
- **Recommend: build as its own small PR, Worker by the orchestrator, app sentence by the builder.**

### Recommendation summary
Build: D (cache breakpoint), H (pill feedback), A (skip the final request; wording needs Sam's yes), E (parallel at-once actions), G (timer persistence), F (follow-up log). Build last and only with approval: B (fast path). Measure only: C (skip the screenshot). Own PR: I (Worker cap; app sentence in this round).

## Decisions on details

### Stage 1: measuring
- **New metrics fields** (numbers and fixed identifiers only), on the turn line: `roundTripCacheCreationTokens: [Int]?`, `skippedFinalRequest: Bool?` (A), `localFastPath: Bool?` (B), `parallelToolCalls: Int?` (E), `turnId` (UUID string, also written on the follow-up line), `interruptedWithinMilliseconds: Int?`. The turn log parser in `ClickyUsageSupport` must still read old lines, and the usage tab must count a fast-path turn as a question with zero tokens.
- **The summarizer** `eval/metrics_summary/main.swift` (compiled with ClickyCore, so it uses the app's own log parser): takes the path of a copy of `turn_metrics.jsonl` (and optionally `follow_up_metrics.jsonl`) and prints the baseline table above plus the (fill) tables: turns by `toolRoundTrips`, medians by turn kind (no tool, action at once, action queued, file tool, fast path, skipped final request), per-request-index medians of ms and tokens, cost at list prices per kind, and follow-up outcomes by chain position. It never reads `~/Library/Logs/Clicky` itself; the orchestrator copies the file into the scratchpad first. It prints nothing but numbers and the fixed identifiers.
- **The actions eval** `eval/actions_runner` gains per-scenario `requestCount`, `roundTripMs`, `roundTripInputTokens`, `roundTripCacheReadTokens`, `roundTripCacheCreationTokens`, `estimatedCostUSD` (list prices, `Decimal`), and flags `--cache-first-user-message`, `--skip-final-request`, `--parallel-actions` so the tester can run with and without each. The result file keeps the shape of `files_*.json`.

### Stage 2: the cache breakpoint (D)
- `ClickyClaudeChatRequestBuilder.currentUserContentBlocks(images:userPrompt:)` gains a parameter `cacheControlOnLastBlock: Bool` (default `false`). With `true`, the last block (the user prompt text) gets `"cache_control": {"type": "ephemeral"}`. Never on an image block.
- `CompanionManager` passes `true` only on a request that carries tools (so the plain no-tool body with actions off and no folder stays byte-identical, and the check that proves it stays).
- Default-on vs. only-after-a-tool-call: a setting is not needed; the builder implements default-on and the eval's flag measures both. The orchestrator decides with the (fill) share of tool turns. Write down the rule in `AGENTS.md`.
- Smoke checks: with `false` the body is byte-identical to round 18's; with `true` exactly one `cache_control` appears in `messages`, on the last block of the first user message, and the loop's requests 2…N carry the same first user message bytes.

### Stage 2: the pill feedback (H)
- Shown by `CompanionManager` when an action tool result arrives with `isError == false` and the action is an at-once kind (`openApp`, `openLink`, `searchWeb`, `openFile`, `revealFile`, `setTimer`, `cancelTimer`, `createReminder`). Queued kinds show "waiting for your yes". Errors show nothing (the spoken reply handles them).
- While the chat panel is open the same line appears in the panel's status row (the pill is hidden then).
- Pure: `ClickyActionNoticeText.notice(forResultText:kind:)` (first sentence, no trailing full stop, 60 characters). Smoke-check it on every example result text of round 18.

### Stage 3: skip the final request (A)
- **The gate** (`ClickyFinalRequestSkipDecision.shouldSkip`, pure, in ClickyCore): true only when all hold: the reply's `stop_reason` is `tool_use`; it holds exactly one `tool_use`; the tool is an action tool of kind `openApp`, `openLink` (opened at once, not queued), `searchWeb`, `openFile`, `revealFile`, `setTimer` or `cancelTimer`; the result is not an error; no file tool was called in this turn; the request was the first of the turn; the transcript has at most 12 words and no question mark (so "open safari and tell me what you see" still gets the model's answer: 8 words, but the gate also requires the transcript to hold no "and", "then", "also" and no interrogative start — list the words). `createReminder`, `listReminders`, `listShortcuts`, `runShortcut` and queued links never skip (their reply needs words the result does not give, or a confirmation sentence the honesty rule governs).
- **The fixed confirmation** (`ClickyFixedConfirmationText`, pure): built from the tool result, not the transcript: "opened safari.", "opened youtube.com.", "searching for best pizza in amsterdam." (the query cut to 60 characters), "opened compose.swift at line 9.", "showing compose.swift in finder.", "timer set, 10 minutes." (label when present: "pasta timer set, 10 minutes."), "stopped the pasta timer." The persona: when "call me" is set, the sentence ends with ", <call me>" before the full stop (Sam's decision 1; default is to ignore the persona entirely). The style setting is ignored (fixed words).
- **What happens:** the loop returns after request 1 with a new `ClickyToolLoopResult.endedBecauseFinalRequestWasSkipped`; `CompanionManager` treats the fixed sentence as the final spoken text through the normal finisher (so tags, markdown and memory rules still apply; there are none in it) and TTS. The model's history gets the fixed sentence plus the `[done: ...]` line, so the next turn sees what happened. The chat store's display text is the fixed sentence. The honesty rule is not needed (the sentence is built from a confirmed result) but still runs.
- **Early speech fetch for the fixed sentence:** start the TTS fetch the moment the executor returns, in parallel with nothing (there is no stream to wait for). Nothing else changes in `ElevenLabsSpeechPrefetch`.
- **Metrics:** `skippedFinalRequest: true`, `toolRoundTrips: 0` (no request ended in `tool_use` that was answered), `toolCalls: 1`.
- **Smoke checks:** the gate on 40 cases (each kind, errors, two tool calls, a file tool in the turn, a long or interrogative transcript, a queued link, a reminder), and the sentence for every kind including label and "call me" variants.
- **Eval:** scenarios 1–5 and 10 must now run with 1 request; their words are the fixed sentences; scenarios 6–9 and 11–14 are unchanged (2+ requests or none).

### Stage 4: parallel at-once actions (E)
- In `ClickyToolLoop.run`, when every `tool_use` of a reply names an action tool whose kind is at-once (the loop asks the session, `isParallelSafe(toolName:)`), run them in a `withTaskGroup`, collect results keyed by index and append the `tool_result` blocks in the original order. Any other mix keeps the sequential path. The real executor's main-actor work serializes itself; that is fine (the gain is on the slow calls, which are not main-actor bound).
- The per-turn counts (3 apps or links) are checked inside the session before the group starts (reserve, then run) so two parallel opens cannot both pass a count of 2.
- Metrics: `parallelToolCalls` = the number of calls run in a group.
- Smoke: order kept; a count limit refused for the fourth of four parallel opens; a mixed reply stays sequential.

### Stage 4: timers that survive a restart (G)
- As in candidate G. The alert for a timer that ended while away: pill notice and a chat line always; spoken only if Sam says yes (decision 4), once, at most 10 s after launch, and never over a running turn.
- A timer still running at launch is re-armed with its original end date (no drift).

### Stage 5: the follow-up log (F)
- As in candidate F. The line is written by `ClickyFollowUpListeningController` (or wherever round 18 ended up owning the window) when the window closes, whatever the outcome, with the same append-and-rotate code as the other logs. The usage tab is not changed this round.
- Thresholds are **not** changed. If the builder finds an obvious bug in the state machine while wiring the log, report it; do not tune.

### Stage 6: the local fast path (B), only with Sam's yes
- **Setting** "quick commands" (`isQuickCommandsEnabled`, default per Sam) in the settings tab's ACTIONS section with the hint "open apps and set timers without asking the ai".
- **Grammar** (`ClickyQuickCommandParser`, pure, Foundation only). The whole transcript, lowercased, trimmed of end punctuation and of a leading "hey clicky", "clicky", "please" or "can you" (one of them, once), must match exactly one of:
  - `open <app>` / `launch <app>` / `switch to <app>` / `go to <app>`, where `<app>` resolves to exactly one installed app through round 18's matcher (aliases and unique prefix included; two candidates means no match);
  - `set a timer for <n> (second|seconds|minute|minutes|hour|hours)` with optional `for <label>` or `called <label>` after it, also `<n> minute timer` and `timer <n> minutes`; `<n>` is digits or a number word up to "sixty" (table), 1 s to 24 h;
  - `stop the timer` / `cancel the timer` / `stop the <label> timer` / `cancel the <label> timer`, where the label resolves to exactly one running timer (or there is exactly one timer when no label is given).
  - Refused (so the model gets it): any transcript with "and", "then", "also", "but", "after", "when", a question word at the start ("what", "how", "can", "could", "is", "should", "why", "where"), a question mark, or more than 12 words; "open" followed by a word that is not an app ("open the settings page", "open my notes"); an app name that matches two apps.
- **What happens:** no screenshot, no prompt, no model. The executor runs the action; the fixed confirmation of stage 3 is spoken (the same table; the same "call me" rule); the pill shows the notice; the exchange is recorded in the chat and in the model's history as the user's words and the fixed sentence plus `[done: ...]`, so the next turn ("and chrome too") goes to the model with context. Follow-up listening opens as after any spoken reply. A failure (app not found after all, timer limit) falls back to the normal turn with the model, not to an error.
- **Never a quick command:** while a change set waits for a yes (the transcript might be an answer), while a dictation runs, or when actions are off.
- **Metrics:** a turn line with `localFastPath: true`, `model: "none"` (a fixed identifier the usage tab shows as "quick commands" with zero tokens), `keyReleaseToAudioStartMs`, and `actionKinds`.
- **Smoke checks:** the accepted table (≥ 60 cases, both number forms, aliases) and the refused table (≥ 30 near misses), run against a fake app list and a fake timer board.

## Design (files likely touched)
- `ClickyCore/ClickyToolLoop.swift`: the skip-final-request exit, the parallel group, `cacheControlOnLastBlock`.
- `ClickyCore/ClickyClaudeRequestSupport.swift`: unchanged (the system blocks stay); a check that the breakpoint count is ≤ 4 belongs with the request builder.
- `ClickyCore/ClickyTurnMetricsLog.swift`, `ClickyCore/ClickyUsageSupport.swift`: new fields, tolerant parsing, "quick commands" row.
- New in ClickyCore: `ClickyFinalRequestSkipDecision.swift`, `ClickyFixedConfirmationText.swift`, `ClickyActionNoticeText.swift`, `ClickyQuickCommandParser.swift`, `ClickyFollowUpMetrics.swift`, timer persistence in `ClickyTimerBoard.swift`.
- App: `CompanionManager.swift` (the gate, the fast path branch before the screenshot, the pill notice, the follow-up line), `ClickyTimerController.swift` (persistence), `ClickyStatusPillController.swift` and `ClickyCore/ClickyStatusPillSupport.swift` (the action notice), `ClickyChatPanelSettingsView.swift` and `ClickyCore/ClickyPanelSettings.swift` (the quick commands switch), `ClickyCore/ClickyTurnFailureMessage.swift` (the cap sentence).
- Eval: `eval/actions_runner/main.swift` (columns and flags), new `eval/metrics_summary/main.swift`, `eval/README.md`.
- Worker: nothing by the builder. The orchestrator's PR: `worker/src/index.ts` (KV counters, 429 body), `worker/wrangler.toml` (the KV binding; Sam's uncommitted test voice line must not be committed with it: the orchestrator commits only the binding lines).

## Hard rules
- **No builds and no app runs.** Never `xcodebuild`. No Xcode builds by the builder (the orchestrator builds in review). Never launch, quit or kill Clicky. Type-check with the smoke program's scripts.
- **No network calls.** Never read, print or `cat` `leanring-buddy/ClickyWorkerSecrets.plist` or any key. The eval runner is built, not run.
- **No real actions** from your own commands or tests: never open an app, link or file, create a reminder, run `shortcuts`, start a real timer with a sound, or play audio. Fake executors only.
- **Never touch `worker/`.** The Worker cap is the orchestrator's PR.
- **No git changes.** No commit, push, checkout, reset or stash.
- **Tests use temporary folders only.** Never `~/Library/Logs/Clicky`, never `~/Library/Application Support/Clicky`, never `~/Documents`, never `~/clicky-test`. The summarizer reads a path you are given; in checks that path is a temporary file you wrote.
- **Never log text.** Metrics and the follow-up log hold numbers and fixed identifiers only. No app name, link, query, path, label, title or transcript, ever. `turnId` is a UUID.
- **Leave these unchanged:** the static base prompt (byte-stable); the memory, profile and notes rules; the secret detector; dictation; drawing and pointing; the old-screen logic; round 16 memories; round 17's and round 18's behaviour with every new switch off (byte-identical request bodies, checked).
- **Hosting views.** No `MainActor.assumeIsolated`; nothing added inside an existing `NSHostingView`.
- **Naming and comments.** Descriptive names; comments say why. Pure logic in ClickyCore, Foundation only, `nonisolated`.
- **The smoke program.** Copy `scratchpad/loop/round18_smoke/` to `round19_smoke/`, fix the paths, add `round19_part*.swift` with the splice script. Every existing check (N at round 18's end; (fill)) must still pass. `typecheck_core.sh` (4 variants) and `app_check/typecheck_app.sh` clean. `eval/file_editing_runner`, `eval/actions_runner` and `eval/metrics_summary` type-check against ClickyCore.
- **AGENTS.md.** Update the architecture line, add "Jarvis tuning (round 19)" with the measured facts and the rules, the privacy rules, and Key Files rows.

## Acceptance checks
- Type-checks clean (ClickyCore in four variants, the whole app).
- Smoke checks:
  - byte-identical request bodies with every new switch off (actions off and no folder; actions off with a folder; actions on, no cache breakpoint) against round 18's;
  - the cache breakpoint on the last block of the first user message only, and identical across loop requests;
  - the skip gate (40 cases) and the fixed sentences (every kind, label, "call me");
  - the parallel group keeps order, enforces counts, stays sequential for mixed replies;
  - timer persistence round trip, overdue list, id continuity;
  - the follow-up line's shape (no string field but fixed identifiers) and rotation;
  - the quick command grammar (≥ 60 accepted, ≥ 30 refused) if built;
  - the pill notice texts for every round 18 example result;
  - the usage tab parser reads old and new lines; a fast-path turn counts as a question with no tokens;
  - the cap sentence for the 429 body and header.
- Offscreen renders: the settings tab with the "quick commands" switch (if built); the pill with an action notice.
- The summarizer run on a synthetic log of 50 lines prints every table.
- **Report:** model ID; files changed and why; checks with counts; type-check results; the gate's exact rules; the fixed sentence table; the request body with the breakpoint (shortened); which candidates were built, which not and why; known limits; a manual test list for Sam (below, extended); what could not be verified without running the app (the real cache reads, the pill timing, timer persistence across a real relaunch, parallel execution on the main actor).

## Sam's hand tests (for the orchestrator's list)
1. "open safari" with quick commands off: Safari opens at about 2 s, the pill says "opened safari", Clicky says "opened safari." once, nothing twice.
2. The same with quick commands on: under 1 s, no "thinking" in the pill.
3. "open safari and tell me what's on the page": goes to the model, Safari opens, the model describes the page.
4. "set a timer for 2 minutes for tea", quit Clicky, relaunch: the timer still fires at the right time; if it ended while quit, the agreed behaviour happens once.
5. Butler persona with "call me sir": "open notes" says the fixed sentence with or without "sir" as Sam decided.
6. A file edit turn with the cache breakpoint: the usage tab's estimated cost per edit turn is lower than before (compare with round 17's $0.022).
7. Follow-up listening with a TV on for a minute: count how often Clicky answers nobody; press Escape each time; the follow-up log (the orchestrator reads it) shows the outcomes.
8. The spend cap at a low test value in `wrangler dev` (orchestrator): the app says "i've hit today's spending cap."

## Tester's eval plan (round 19)
- `eval/actions_runner` on `actions.json` (14 scenarios + scenario 15 "open safari and youtube" for E), 2 runs, with and without each flag: about 14 × 2 × 3 configurations ≈ 90 scenario runs at a median 2 requests ≈ $0.02 each → about $2 (estimate). Report per scenario: pass, requests, ms, $, and the diff between flags.
- Holdout scenarios the builder never sees: 10 more commands for the fast-path grammar run offline (zero cost) plus 6 live ("open the settings page" must not open System Settings; "can you open safari" is fine either way but must not break; "set a timer for an hour and a half" must go to the model or parse to 90 minutes, never 1 minute).
- The screenshot probe (C): 10 pairs, about $0.15.
- Pass bar: every round 18 scenario still passes; no scenario got slower; the skipped-request scenarios run with 1 request; cost per action turn down by at least 25% on the eval with D and A on; zero false positives in the fast-path refusal set.
- Total: about $3.

## Behaviour changes Sam should approve
1. **Fixed confirmations (A and B) ignore the persona.** "opened safari." in the same words whatever the style; "call me" can be appended. Recommended: approve, with "call me" appended, because these are five-word sentences and the persona shows in every other reply.
2. **Quick commands (B) skip the model and the screenshot.** Nothing on the screen can influence them, which is also why they are safe. Recommended: on by default, exact grammar only.
3. **The cache breakpoint (D) adds about $0.001 to every single-request turn** to save about $0.004 per extra loop request. Recommended: on when the share of tool turns in Sam's log is above about 25%; otherwise only after a tool call has happened.
4. **Timers that ended while Clicky was quit (G):** spoken once at launch, or shown only. Recommended: shown in the pill and the chat; spoken only if the end was less than 10 minutes ago.
5. **The Worker cap (I):** the number, and request-count accounting in v1. Recommended: 600 chat requests and 60,000 TTS characters per day, raised later if the log shows he gets near it.
6. **The pill (H) shows app names and labels** on screen for 3 s. Recommended: approve (the overlay already shows the reply text).
