# Clicky - Agent Instructions

<!-- This is the single source of truth for all AI coding agents. CLAUDE.md is a symlink to this file. -->
<!-- AGENTS.md spec: https://github.com/agentsmd/agents.md — supported by Claude Code, Cursor, Copilot, Gemini CLI, and others. -->

## Overview

macOS menu bar companion app. Lives entirely in the macOS status bar (no dock icon, no main window). Clicking the menu bar icon opens a custom floating panel with companion voice controls. Uses push-to-talk (ctrl+option) to capture voice input, transcribes it via AssemblyAI streaming, and sends the transcript + a screenshot of the user's screen to Claude. Claude responds with text (streamed via SSE) and voice (ElevenLabs TTS). A blue cursor overlay can fly to and point at UI elements Claude references on any connected monitor.

All API keys live on a Cloudflare Worker proxy — nothing sensitive ships in the app.

## Architecture

- **App Type**: Menu bar-only (`LSUIElement=true`), no dock icon or main window
- **Framework**: SwiftUI (macOS native) with AppKit bridging for menu bar panel and cursor overlay
- **Pattern**: MVVM with `@StateObject` / `@Published` state management
- **AI Chat**: Claude (Sonnet 5.5 default, Opus 4.6 optional) via Cloudflare Worker proxy with SSE streaming. Requests send `output_config.effort = "low"` (set in `ClaudeAPI.swift`) to keep spoken replies cheap and fast.
- **Speech-to-Text**: AssemblyAI real-time streaming (`u3-rt-pro` model) via websocket, with OpenAI and Apple Speech as fallbacks
- **Text-to-Speech**: ElevenLabs (`eleven_flash_v2_5` model) via Cloudflare Worker proxy. Fetching and playing are separate steps (`fetchSpeechAudio`, `playSpeechAudio`); the audio for the words before the first reply tag is fetched early (see "Early speech fetch" below).
- **Screen Capture**: ScreenCaptureKit (macOS 14.2+), multi-monitor support
- **Voice Input**: Push-to-talk via `AVAudioEngine` + pluggable transcription-provider layer. System-wide keyboard shortcut via listen-only CGEvent tap.
- **Element Pointing**: Claude embeds `[POINT:x,y:label:screenN]` tags in responses. The overlay parses these, maps coordinates to the correct monitor, and animates the blue cursor along a bezier arc to the target.
- **Concurrency**: `@MainActor` isolation, async/await throughout
- **Analytics**: PostHog via `ClickyAnalytics.swift`

### API Proxy (Cloudflare Worker)

The app never calls external APIs directly. All requests go through a Cloudflare Worker (`worker/src/index.ts`) that holds the real API keys as secrets.

| Route | Upstream | Purpose |
|-------|----------|---------|
| `POST /chat` | `api.anthropic.com/v1/messages` | Claude vision + streaming chat |
| `POST /tts` | `api.elevenlabs.io/v1/text-to-speech/{voiceId}` | ElevenLabs TTS audio |
| `POST /transcribe-token` | `streaming.assemblyai.com/v3/token` | Fetches a short-lived (480s) AssemblyAI websocket token |

Reply tag grammar (parsed by `ClickyReplyTagParser`, case-insensitive, any order): `[POINT:x,y:label]`, `[POINT:x,y:label:screenN]`, `[POINT:none]`, `[NOTE:text]` (one line, at most 400 characters, at most three per reply) and `[PROFILE:text]` (one line, at most 200 characters, at most two per reply). Tags never reach TTS or history as tag text; history keeps `[NOTE:...]` and `[PROFILE:...]` (only for facts that were actually saved) so the model keeps the format.

Worker secrets: `ANTHROPIC_API_KEY`, `ASSEMBLYAI_API_KEY`, `ELEVENLABS_API_KEY`, `CLICKY_APP_TOKEN`

Every Worker request must carry `X-Clicky-App-Token` matching `CLICKY_APP_TOKEN`, or the Worker answers 401 (and refuses everything if the secret is unset). The app reads the Worker URL and token from the git-ignored `leanring-buddy/ClickyWorkerSecrets.plist` (template: `ClickyWorkerSecrets.example.plist` at the repo root).

In this fork, PostHog analytics, the FormSpark email submission and the Sparkle update feed are switched off.
Worker vars: `ELEVENLABS_VOICE_ID`

### Key Architecture Decisions

**Menu Bar Panel Pattern**: The companion panel uses `NSStatusItem` for the menu bar icon and a custom borderless `NSPanel` for the floating control panel. This gives full control over appearance (dark, rounded corners, custom shadow) and avoids the standard macOS menu/popover chrome. The panel is non-activating so it doesn't steal focus. A global event monitor auto-dismisses it on outside clicks.

**Cursor Overlay**: A full-screen transparent `NSPanel` hosts the blue cursor companion. It's non-activating, joins all Spaces, and never steals focus. The cursor position, response text, waveform, and pointing animations all render in this overlay via SwiftUI through `NSHostingView`.

**Global Push-To-Talk Shortcut**: Background push-to-talk uses a listen-only `CGEvent` tap instead of an AppKit global monitor so modifier-based shortcuts like `ctrl + option` are detected more reliably while the app is running in the background.

**Shared URLSession for AssemblyAI**: A single long-lived `URLSession` is shared across all AssemblyAI streaming sessions (owned by the provider, not the session). Creating and invalidating a URLSession per session corrupts the OS connection pool and causes "Socket is not connected" errors after a few rapid reconnections.

**Reply Tags, Notes, and Skills**: Claude's reply can carry `[POINT:x,y:label]` / `[POINT:x,y:label:screenN]` / `[POINT:none]`, up to three `[NOTE:text]` tags and up to two `[PROFILE:text]` tags. `ClickyReplyTagParser` strips every tag from the spoken text (including truncated fragments) and returns the point target, note texts and profile fact texts. Notes are saved only when the user's transcript has save language (`ClickyNoteIntentDetector`), and a dictated "remember that ..." is saved directly if Claude forgets the tag. Notes live as one markdown file per day in `~/Documents/Clicky Notes` (next to `profile.md`, which the notes reader ignores) and are injected into the system prompt: all of them when the store is small (up to 15 notes and 1500 characters, so the model matches paraphrases), otherwise by word relevance plus recent notes, or the newest notes when the user asks what Clicky remembers. Skills are `leanring-buddy/ClickyPrompts/skill_*.md` files with front matter (app bundle ids, app name fragments, keywords) and are added to the prompt for the matching app or question, at most two per turn. The system prompt is assembled per turn by `ClickyPromptAssembler` from `clicky_base_system_prompt.md`, the selected skills, a "right now" block, the profile, and the notes, in that order so the static part comes first. It is sent to Claude as two system blocks: the base prompt alone (identical every turn) carries `cache_control: ephemeral` so the API can cache it, and everything else follows as an uncached block (`ClickyPreparedPrompt.systemPromptText` keeps the old single-string form). Each turn also appends one line of timings, token counts (including cache creation and reads) and counts to the local `~/Library/Logs/Clicky/turn_metrics.jsonl` (see `ClickyTurnMetricsLog`); it never contains transcripts, replies, notes or paths. Since round 5 the line also holds the delays counted from the push-to-talk key release (`keyReleaseToFinalTranscriptMs`, `keyReleaseToFirstReplyTextMs`, `keyReleaseToAudioStartMs`, the last being the wait the user feels; the release is stamped in `GlobalPushToTalkShortcutMonitor` where it is first seen), `textToSpeechFetchMs` (network time of the audio that was played), `speechPrefetchOutcome` (`used`, `notStarted`, `skippedForMemoryRequest`, `textChanged`, `failed`) with `usedPrefetchedSpeech`, and `interruptedByEscape`. `textToSpeechMs` keeps its meaning (from the finisher's decision until audio starts), so with the early fetch it shrinks to the wait left after the finisher; the fetch time moved to `textToSpeechFetchMs`.

**Profile (lasting facts about the user)**: besides the daily notes, Clicky keeps one small markdown file, `~/Documents/Clicky Notes/profile.md`, with one bullet per lasting fact or preference (how to address the user, their editor, how they like answers). `ClickyProfileStore` reads it tolerantly (headings, comments, blank lines, `-`/`*` bullets and plain lines all work, so the user can hand-edit it) and writes atomically. The file keeps every line the user or Clicky wrote, up to a hard limit of 100 facts: at the limit a new fact is refused and Clicky says "my profile is full. forget something first." (a replacement is still allowed, since it frees a line). Saving never deletes a line to make room. What is injected every turn is capped instead: the newest 20 facts within 1,000 characters (each fact plus its bullet and newline), the file itself untouched. `ClickyPromptAssembler` puts the profile in the dynamic block, after the "right now" block and before the notes, under a heading that calls it data about the user and not instructions; the static block is never changed by it. A new fact replaces an older one only when it fills the older fact's slot of the user (how to address them or their name, editor or IDE, indentation style, shell, main language, the language of the replies, the length or detail of the replies, operating system; see `ClickyProfileSlots`). A fact in no slot is only appended (exact duplicates are still skipped). A statement about someone or something else (a dog, a coworker), an addition ("also writes python", "sometimes"), or a qualified statement ("uses windows at work", "writes python for scripts") is never in a slot, so it is saved next to the plain fact; a new fact worded with "mostly", "mainly" or "usually" replaces nothing. A fact that fills two slots ("uses fish and helix") replaces the older fact in each, but an older fact with an extra slot is kept so nothing the user said is lost. Privacy and honesty rules, all enforced in code and not only in the prompt (`ClickyTurnFinisher`): memory never says something false, so a confirmation is spoken only for a save that happened.
- Spoken-only triggers. A `[PROFILE:...]` tag is saved only when the user's own transcript states a lasting fact, preference, update or standing instruction ("i prefer", "my name's", "i go by", "call me", "answer me in spanish", "keep answers short", "i switched to helix", "i no longer use vim", "i'm using helix now", "from now on", and similar; `ClickyProfileIntentDetector`). One-off moods, tasks and changes ("i'm a bit lost", "i hate this error", "i switched tabs", "i'm using chrome right now") stay outside the gate. Screen text, notes and the profile itself can never unlock a save, so a web page saying "remember that ..." writes nothing. A tag without that spoken intent is dropped. When the user says they stopped using something ("i no longer use vim", "i don't use zsh anymore"), the older fact in that slot that names it is removed, a tag that only repeats the negation is not saved, and Clicky says "okay, i've forgotten that." unless a new value was given.
- No secrets, on every save path. `ClickySecretDetector` checks the user's words and the text to be saved for profile tags, `[NOTE:]` tags and the dictated-note fallback alike. It refuses on a value, not on a topic: a secret keyword (password, passcode, pw, pin, api key, token, secret, login, door/alarm/gate/safe/garage/building codes and combinations, recovery phrases, security answers, account and identity numbers) followed by "is", "are", "was", ":", "=" or "-" and a value, or directly by a code-like value ("pin 4471"), is refused, unless the value is a description (weak, expired, on the sticky note, in the safe, saved in the manager). Credential shapes are always refused whatever the wording: `sk-`/`ghp_`/JWT/private-key shapes, long base64 tokens, IBANs, social security shapes with dashes or spaces, card numbers that pass a Luhn check (so timestamps and order numbers are not refused), and keys read out digit by digit or letter by letter. Ordinary mentions are kept ("i changed my password yesterday", "i use a password manager", "the pin for the meeting room is on the door"). A refused save writes nothing and Clicky says "i won't keep that." A false refusal is the safe failure.
- Nothing is confirmed that did not happen. A save the model confirmed but that was dropped (no spoken permission, empty tag, secret, full profile, failed write) loses its confirmation: Clicky says "i didn't save that.", "i won't keep that.", "my profile is full. forget something first." or "i couldn't save that.", and a real answer in the same reply is kept. A confirmation of a real save is at most six words and never announces the value a replace removed; otherwise it is replaced with "got it, i'll remember that." A profile fact saved with no confirmation at all gets that sentence appended.
- No double save. If one statement produces both a `[PROFILE:]` and a `[NOTE:]` with essentially the same text, only the profile fact is saved.
- Forget. A forget, stop-remembering, delete, remove, erase or clear request is recognised when its verb opens the utterance or any later clause, after lead-ins such as "i want you to", "i'd like you to", "can you", "please", "never mind," (the verbs other than "forget" count only with a clear memory phrase such as "from your memory", "what you know about" or "my editor preference", so "delete my file" is untouched). "forget that" (the last thing saved, found from the tags kept in history; with nothing saved last turn it removes nothing), "forget <thing>" or "stop remembering <thing>" removes at most one matching thing. Trailing politeness ("please", "thank you very much", "anymore") is stripped before matching. A target that says "note" or "reminder" searches the notes only, one that says "profile", "preference" or "fact" the profile only, and with neither the profile first and then the notes if the profile has no match, so "forget the vim note" never removes the vim fact. A slot target ("my editor", "my name") finds the fact in that slot; other targets need real key words in common, and a match on one generic word ("name") is too weak to delete anything. Whatever the model wrote, the spoken answer is fixed and honest: "okay, i've forgotten that." after a removal; otherwise "i didn't forget anything." plus the reason ("i don't have that saved.", "i have two like that. say which one.", "i can't wipe everything by voice."), or "one at a time. say which one first." for several targets ("forget my editor and my shell"). A request that comes with a question ("forget my editor, and what time is it", "forget it, where's the run button") deletes nothing, answers the question normally, and no model claim of "forgotten", "deleted", "removed", "erased" or "cleared" reaches speech unless something was actually removed.
- No voice wipe. "forget everything", "forget what you know about me", "wipe your memory", "clear everything you know" and the other ways of asking are refused ("i can't wipe everything by voice."). To wipe the profile, delete the file `~/Documents/Clicky Notes/profile.md`; to wipe the notes, delete the daily files in the same folder.
- Known limits, left alone on purpose: facts about other people are not blocked by code (the prompt and the model are the guard); a bare "sure." counts as a confirmation of a save; a gate over-match such as "i'm from marketing" is harmless without a model tag; "forget the build error, how do i ..." answers the question and adds nothing about memory when the object is not something about the user.

**Early speech fetch**: the spoken answer is complete once the first reply tag opens (the first `[` that begins `[POINT:`, `[NOTE:` or `[PROFILE:`), but the stream goes on for the tags and `ClickyTurnFinisher` only decides the final spoken text after the stream ends. `ElevenLabsSpeechPrefetch` (in `ElevenLabsTTSClient.swift`) starts downloading the audio for the words before that tag while Claude is still writing, using `ClickySpeechPrefetch` (`ClickyCore/ClickySpeechPrefetchSupport.swift`) to find them. Nothing is played from the early fetch. After the finisher has decided, the early audio is played only if the final spoken text is exactly the text it was made for (any difference at all, even a trailing full stop, throws it away and fetches the final text), so memory refusals, rewritten confirmations and removed false claims can never be heard. A reply that starts with a tag, or has no tag, takes the normal path. A turn whose transcript is a strict save command, a lasting fact or preference, a forget request or looks like a secret never fetches early (`transcriptAllowsSpeechPrefetch`), so text the finisher is about to refuse is not sent to the speech service; the loose "save/log/note" note gate is deliberately not used for this, so "where is the save button" still fetches early. A failed early fetch is silent and falls back to the normal fetch. A cancelled or interrupted turn cancels the early fetch.

**Escape interrupts**: the push-to-talk event tap also publishes Escape key-downs (`escapeKeyPressedPublisher`, key repeat ignored; the tap is listen-only so the key is never swallowed). While Clicky is waiting for the final transcript, working out an answer, or speaking, Escape cancels the dictation wait, the response task and the early fetch, stops the audio, clears pointing and returns to idle (`CompanionManager.handleEscapeKeyPressed`). It does nothing when Clicky is idle or while the user is holding the keys. The response task now stays alive while its audio plays (the overlay state still returns to idle at once) so Escape during speech can be recorded: the one metrics line is then written as `cancelled` at the `speechPlayback` step with `interruptedByEscape`. Escape while waiting for the final transcript cancels the dictation and writes no line, because no turn exists yet. A cancelled turn never plays the "out of credits" fallback message (a cancelled URLSession request used to be able to).

**Launch warm-up**: the first prompt assembly after each launch took 1.9 to 3.4 seconds in the turn metrics log, later ones 2 to 4 milliseconds. Prompt and skill file reads, date formatting and regexes each cost only a few milliseconds even on first use, so the cost is most likely the first access of `~/Documents/Clicky Notes` in a new process (Documents is protected and iCloud Drive backed on this Mac); this is inferred by elimination, not observed in the app. `CompanionManager.start()` therefore runs the real prompt assembly once, off the main thread, with a throwaway turn and discards the result (read-only; skipped until onboarding is done so a new user is not prompted for Documents access early), and prints the warm-up time in milliseconds to the console. No prompt or skill cache exists; assembly output is unchanged.

**Transient Cursor Mode**: When "Show Clicky" is off, pressing the hotkey fades in the cursor overlay for the duration of the interaction (recording → response → TTS → optional pointing), then fades it out automatically after 1 second of inactivity.

## Key Files

| File | Lines | Purpose |
|------|-------|---------|
| `leanring_buddyApp.swift` | ~89 | Menu bar app entry point. Uses `@NSApplicationDelegateAdaptor` with `CompanionAppDelegate` which creates `MenuBarPanelManager` and starts `CompanionManager`. No main window — the app lives entirely in the status bar. |
| `CompanionManager.swift` | ~1255 | Central state machine. Owns dictation, shortcut monitoring, screen capture, Claude API, ElevenLabs TTS, and overlay management. Tracks voice state (idle/listening/processing/responding), conversation history, model selection, and cursor visibility. Coordinates the full push-to-talk → screenshot → Claude → TTS → pointing pipeline. |
| `MenuBarPanelManager.swift` | ~243 | NSStatusItem + custom NSPanel lifecycle. Creates the menu bar icon, manages the floating companion panel (show/hide/position), installs click-outside-to-dismiss monitor. |
| `CompanionPanelView.swift` | ~761 | SwiftUI panel content for the menu bar dropdown. Shows companion status, push-to-talk instructions, model picker (Sonnet/Opus), permissions UI, DM feedback button, and quit button. Dark aesthetic using `DS` design system. |
| `OverlayWindow.swift` | ~881 | Full-screen transparent overlay hosting the blue cursor, response text, waveform, and spinner. Handles cursor animation, element pointing with bezier arcs, multi-monitor coordinate mapping, and fade-out transitions. |
| `CompanionResponseOverlay.swift` | ~217 | SwiftUI view for the response text bubble and waveform displayed next to the cursor in the overlay. |
| `CompanionScreenCaptureUtility.swift` | ~132 | Multi-monitor screenshot capture using ScreenCaptureKit. Returns labeled image data for each connected display. |
| `BuddyDictationManager.swift` | ~866 | Push-to-talk voice pipeline. Handles microphone capture via `AVAudioEngine`, provider-aware permission checks, keyboard/button dictation sessions, transcript finalization, shortcut parsing, contextual keyterms, and live audio-level reporting for waveform feedback. |
| `BuddyTranscriptionProvider.swift` | ~100 | Protocol surface and provider factory for voice transcription backends. Resolves provider based on `VoiceTranscriptionProvider` in Info.plist — AssemblyAI, OpenAI, or Apple Speech. |
| `AssemblyAIStreamingTranscriptionProvider.swift` | ~478 | Streaming transcription provider. Fetches temp tokens from the Cloudflare Worker, opens an AssemblyAI v3 websocket, streams PCM16 audio, tracks turn-based transcripts, and delivers finalized text on key-up. Shares a single URLSession across all sessions. |
| `OpenAIAudioTranscriptionProvider.swift` | ~317 | Upload-based transcription provider. Buffers push-to-talk audio locally, uploads as WAV on release, returns finalized transcript. |
| `AppleSpeechTranscriptionProvider.swift` | ~147 | Local fallback transcription provider backed by Apple's Speech framework. |
| `BuddyAudioConversionSupport.swift` | ~108 | Audio conversion helpers. Converts live mic buffers to PCM16 mono audio and builds WAV payloads for upload-based providers. |
| `GlobalPushToTalkShortcutMonitor.swift` | ~156 | System-wide push-to-talk monitor. Owns the listen-only `CGEvent` tap and publishes press/release transitions and Escape key-downs; stamps the key release time for the metrics. |
| `ClaudeAPI.swift` | ~362 | Claude vision API client with streaming (SSE) and non-streaming modes. TLS warmup optimization, image MIME detection, conversation history support. The chat turn calls the streaming overload that takes a static and a dynamic system prompt and returns token usage; the onboarding demo still passes one string. |
| `OpenAIAPI.swift` | ~142 | OpenAI GPT vision API client. |
| `ElevenLabsTTSClient.swift` | ~200 | ElevenLabs TTS client. Fetches audio from the Worker proxy (`fetchSpeechAudio`) and plays it via `AVAudioPlayer` (`playSpeechAudio`); `speakText` does both. Exposes `isPlaying` for transient cursor scheduling. Also holds `ElevenLabsSpeechPrefetch`, the per-turn early fetch that is played only when it matches the finisher's final spoken text. |
| `ElementLocationDetector.swift` | ~335 | Detects UI element locations in screenshots for cursor pointing. |
| `DesignSystem.swift` | ~880 | Design system tokens — colors, corner radii, shared styles. All UI references `DS.Colors`, `DS.CornerRadius`, etc. |
| `ClickyAnalytics.swift` | ~121 | PostHog analytics integration for usage tracking. |
| `WindowPositionManager.swift` | ~262 | Window placement logic, Screen Recording permission flow, and accessibility permission helpers. |
| `AppBundleConfiguration.swift` | ~28 | Runtime configuration reader for keys stored in the app bundle Info.plist. |
| `ClickyCore/ClickyReplyTagParser.swift` | ~160 | Foundation-only parser for `[POINT:...]`, `[NOTE:...]` and `[PROFILE:...]` tags. Returns spoken text, the point target, note texts and profile fact texts. Shared by the chat pipeline and the onboarding demo. |
| `ClickyCore/ClickyNoteStore.swift` | ~415 | Daily markdown notes in `~/Documents/Clicky Notes`: save with same-minute dedupe, tolerant reader, relevance and full-recall selection with caps, and removal of the one note a spoken "forget ..." points at (a tie removes nothing). |
| `ClickyCore/ClickyProfileStore.swift` | ~420 | The profile, `profile.md` next to the notes: tolerant reader, atomic writes, dedupe, slot-based replacement, a 100-fact hard limit (the file is never trimmed), the newest 20 facts within the 1,000-character injection budget, forget removal of at most one fact (slot match, then key words, ties remove nothing), and removal of the stale fact when a value is no longer used. No method throws; failures come back as values. |
| `ClickyCore/ClickyProfileIntentDetector.swift` | ~580 | Decides from the transcript alone whether the user stated a lasting fact, preference, update or standing instruction (the gate), asked to forget something (verb anywhere in a clause, polite lead-ins, one request per clause, several targets, a wipe of everything which is refused, a request with a question which is not executed), or said they no longer use something. |
| `ClickyCore/ClickyMemoryKeyWords.swift` | ~170 | Cautious key-word matching: best single match for "forget <thing>" with a generic-word guard and tie detection, and the "essentially the same text" test used to avoid saving a statement twice. Also defines the removal result type shared by the profile and notes. |
| `ClickyCore/ClickyProfileSlots.swift` | ~240 | The few things about the user with one current value (name, editor, indentation, shell, main language, answer language, answer length, operating system), recognised by narrow phrase patterns. A fact can fill several slots; additive, qualified and other-people facts fill none; replacement and "forget my editor" work through slots. |
| `ClickyCore/ClickySecretDetector.swift` | ~340 | Decides whether text holds a secret: a secret keyword followed by a value (with a short list of benign values), or a credential shape (provider keys, tokens, IBANs, Luhn-checked card numbers, spelled-out keys). Applied to every save path: profile tags, note tags and the dictated-note fallback. |
| `ClickyCore/ClickyTurnFinisher.swift` | ~750 | `ClickyTurnFinisher.finishTurn`: parses the reply, handles forget requests and "i no longer use X", saves gated profile facts and notes (secret check, no double save, hard limit) and words the spoken reply and history so memory never says something false (no false confirmation, no false "forgotten"). |
| `ClickyCore/ClickyNoteIntentDetector.swift` | ~80 | Decides from the transcript alone whether the user asked to save a note (strict start-of-sentence phrases plus a loose gate) or to recall notes. |
| `ClickyCore/ClickySkillLibrary.swift` | ~200 | Loads `skill_*.md` files and selects up to two per turn by frontmost app (100) and keyword (40). |
| `ClickyCore/ClickyPromptAssembler.swift` | ~200 | Builds each turn's system prompt (`prepareSystemPrompt`, including the profile section) from the base prompt, skills, the "right now" block, the profile and the notes. |
| `ClickyCore/ClickyClaudeRequestSupport.swift` | ~81 | Foundation-only helpers for the Claude request: builds the two-block `system` array (cached static block first, per-turn block second) and reads token usage (input, output, cache creation, cache read) out of the streaming events. |
| `ClickyCore/ClickyTurnMetricsLog.swift` | ~304 | Foundation-only per-turn metrics: a record of durations, sizes and counts (no transcript, reply, note text or paths; includes the delays from key release and the early-speech outcome), the compact console line, and the log that appends one JSON line per turn to `~/Library/Logs/Clicky/turn_metrics.jsonl` (newest 500 lines kept, write failures swallowed). |
| `ClickyCore/ClickySpeechPrefetchSupport.swift` | ~94 | Foundation-only pure decisions for the early speech fetch: the spoken text before the first reply tag (same cleaning as the parser), the transcript gate that skips memory turns, the exact-text rule for playing early audio, and the outcome identifiers logged in the metrics. |
| `ClickyPrompts/clicky_base_system_prompt.md` | ~850 words | Base system prompt: brevity, spoken style, pointing rules, note grammar, recall rules, and the short profile block (`[PROFILE:text]`, lasting statements only, six-word confirmation, forget, no secrets). Loaded at runtime from the bundle. |
| `ClickyPrompts/skill_*.md` | ~230 words each | Per-app skills (general coding, Xcode, VS Code family, terminals). Plain resource files, not compiled. |
| `ClickyWorkerConfiguration.swift` | ~65 | Reads the Worker base URL and app token from the git-ignored `ClickyWorkerSecrets.plist` and adds the `X-Clicky-App-Token` header to Worker requests. |
| `worker/src/index.ts` | ~142 | Cloudflare Worker proxy. Three routes: `/chat` (Claude), `/tts` (ElevenLabs), `/transcribe-token` (AssemblyAI temp token). |

## Build & Run

```bash
# Open in Xcode
open leanring-buddy.xcodeproj

# Select the leanring-buddy scheme, set signing team, Cmd+R to build and run

# Known non-blocking warnings: Swift 6 concurrency warnings,
# deprecated onChange warning in OverlayWindow.swift. Do NOT attempt to fix these.
```

**Do NOT run `xcodebuild` from the terminal** — it invalidates TCC (Transparency, Consent, and Control) permissions and the app will need to re-request screen recording, accessibility, etc.

## Cloudflare Worker

```bash
cd worker
npm install

# Add secrets
npx wrangler secret put ANTHROPIC_API_KEY
npx wrangler secret put ASSEMBLYAI_API_KEY
npx wrangler secret put ELEVENLABS_API_KEY
npx wrangler secret put CLICKY_APP_TOKEN   # any long random string, e.g. from: openssl rand -hex 32

# Deploy
npx wrangler deploy

# Local dev (create worker/.dev.vars with your keys)
npx wrangler dev
```

## Code Style & Conventions

### Variable and Method Naming

IMPORTANT: Follow these naming rules strictly. Clarity is the top priority.

- Be as clear and specific with variable and method names as possible
- **Optimize for clarity over concision.** A developer with zero context on the codebase should immediately understand what a variable or method does just from reading its name
- Use longer names when it improves clarity. Do NOT use single-character variable names
- Example: use `originalQuestionLastAnsweredDate` instead of `originalAnswered`
- When passing props or arguments to functions, keep the same names as the original variable. Do not shorten or abbreviate parameter names. If you have `currentCardData`, pass it as `currentCardData`, not `card` or `cardData`

### Code Clarity

- **Clear is better than clever.** Do not write functionality in fewer lines if it makes the code harder to understand
- Write more lines of code if additional lines improve readability and comprehension
- Make things so clear that someone with zero context would completely understand the variable names, method names, what things do, and why they exist
- When a variable or method name alone cannot fully explain something, add a comment explaining what is happening and why

### Swift/SwiftUI Conventions

- Use SwiftUI for all UI unless a feature is only supported in AppKit (e.g., `NSPanel` for floating windows)
- All UI state updates must be on `@MainActor`
- Use async/await for all asynchronous operations
- Comments should explain "why" not just "what", especially for non-obvious AppKit bridging
- AppKit `NSPanel`/`NSWindow` bridged into SwiftUI via `NSHostingView`
- All buttons must show a pointer cursor on hover
- For any interactive element, explicitly think through its hover behavior (cursor, visual feedback, and whether hover should communicate clickability)

### Do NOT

- Do not add features, refactor code, or make "improvements" beyond what was asked
- Do not add docstrings, comments, or type annotations to code you did not change
- Do not try to fix the known non-blocking warnings (Swift 6 concurrency, deprecated onChange)
- Do not rename the project directory or scheme (the "leanring" typo is intentional/legacy)
- Do not run `xcodebuild` from the terminal — it invalidates TCC permissions

## Git Workflow

- Branch naming: `feature/description` or `fix/description`
- Commit messages: imperative mood, concise, explain the "why" not the "what"
- Do not force-push to main

## Self-Update Instructions

<!-- AI agents: follow these instructions to keep this file accurate. -->

When you make changes to this project that affect the information in this file, update this file to reflect those changes. Specifically:

1. **New files**: Add new source files to the "Key Files" table with their purpose and approximate line count
2. **Deleted files**: Remove entries for files that no longer exist
3. **Architecture changes**: Update the architecture section if you introduce new patterns, frameworks, or significant structural changes
4. **Build changes**: Update build commands if the build process changes
5. **New conventions**: If the user establishes a new coding convention during a session, add it to the appropriate conventions section
6. **Line count drift**: If a file's line count changes significantly (>50 lines), update the approximate count in the Key Files table

Do NOT update this file for minor edits, bug fixes, or changes that don't affect the documented architecture or conventions.
