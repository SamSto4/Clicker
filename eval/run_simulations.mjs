#!/usr/bin/env node
// Clicky evaluation harness. No npm dependencies (Node 20+).
//
// Sends scenarios through the real Cloudflare Worker /chat route exactly like the app does
// (same request shape, labeled JPEG screenshots, model claude-sonnet-5-5, output_config effort "low",
// max_tokens 1024) and scores the replies. See README.md for the full documentation.
//
// Quick start:
//   node eval/run_simulations.mjs --system-prompt-file <prompt.txt> --round 0 --label baseline \
//        --summary-out <loop-folder>/round0_baseline.json
//   node eval/run_simulations.mjs --self-test      (offline, zero API calls)
//   node eval/run_simulations.mjs --dry-run --system-prompt-file <prompt.txt>   (zero API calls)

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import os from "node:os";
import { fileURLToPath } from "node:url";
import { writeLeaderboard } from "./make_leaderboard.mjs";

const evalDirectory = path.dirname(fileURLToPath(import.meta.url));
const secretsPlistPath = "/Users/samsto/Clicker/leanring-buddy/ClickyWorkerSecrets.plist";

const MODEL_NAME = "claude-sonnet-5-5";
const APP_MAX_TOKENS = 1024;
const JUDGE_MAX_TOKENS = 300;
const HARD_CALL_CEILING = 80; // never exceeded, even if --max-calls asks for more
const REQUEST_TIMEOUT_MILLISECONDS = 120_000;

// Total = weighted average of the four dimension scores (UX-weighted, see README).
export const DIMENSION_WEIGHTS = { brevity: 0.30, pointing: 0.30, coding: 0.20, notes: 0.20 };
const DIMENSION_ORDER = ["pointing", "brevity", "coding", "notes"];

const POINTING_BOX_TOLERANCE_PIXELS = 4;
const NEAR_MISS_PIXELS = 40;

// Speed scoring thresholds for brevity scenarios (non-streaming, wall clock through the Worker).
const LATENCY_FULL_SCORE_SECONDS = 2.5;
const LATENCY_ZERO_SCORE_SECONDS = 8;
const TOKENS_FULL_SCORE = 60;
const TOKENS_ZERO_SCORE = 220;

// ---------------------------------------------------------------------------------------------
// Small utilities
// ---------------------------------------------------------------------------------------------

function clamp(value, low, high) {
  return Math.min(high, Math.max(low, value));
}

function mean(values) {
  return values.length === 0 ? null : values.reduce((a, b) => a + b, 0) / values.length;
}

function median(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function percentile(values, fraction) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.floor(fraction * sorted.length))];
}

function round1(value) {
  return value === null || value === undefined ? null : Math.round(value * 10) / 10;
}

let secretsToRedact = [];
export function redactSecrets(text) {
  let redactedText = String(text);
  for (const secret of secretsToRedact) {
    if (secret) redactedText = redactedText.split(secret).join("[redacted]");
  }
  return redactedText.replace(/sk-ant-[A-Za-z0-9_-]+/g, "[redacted]");
}

function logLine(message) {
  console.log(redactSecrets(message));
}

// ---------------------------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------------------------

function parseArguments(argumentList) {
  const options = {
    systemPromptFile: null,
    split: "all",
    dimensions: [...DIMENSION_ORDER],
    only: null,
    maxCalls: HARD_CALL_CEILING,
    round: null,
    label: "run",
    summaryOut: null,
    resultsOut: null,
    notesProtocolFile: path.join(evalDirectory, "notes_protocol.json"),
    assembler: null,
    promptsDirectory: "/Users/samsto/Clicker/leanring-buddy/ClickyPrompts",
    dryRun: false,
    selfTest: false,
    resummarize: null,
  };
  for (let index = 0; index < argumentList.length; index++) {
    const argument = argumentList[index];
    const nextValue = () => {
      const value = argumentList[++index];
      if (value === undefined) throw new Error(`missing value for ${argument}`);
      return value;
    };
    switch (argument) {
      case "--system-prompt-file": options.systemPromptFile = nextValue(); break;
      case "--split": options.split = nextValue(); break;
      case "--dimensions": options.dimensions = nextValue().split(",").map((name) => name.trim()); break;
      case "--only": options.only = nextValue().split(",").map((id) => id.trim()); break;
      case "--max-calls": options.maxCalls = Math.min(Number(nextValue()), HARD_CALL_CEILING); break;
      case "--round": options.round = Number(nextValue()); break;
      case "--label": options.label = nextValue(); break;
      case "--summary-out": options.summaryOut = nextValue(); break;
      case "--results-out": options.resultsOut = nextValue(); break;
      case "--notes-protocol-file": options.notesProtocolFile = nextValue(); break;
      case "--assembler": options.assembler = nextValue(); break;
      case "--prompts-directory": options.promptsDirectory = nextValue(); break;
      case "--dry-run": options.dryRun = true; break;
      case "--self-test": options.selfTest = true; break;
      case "--resummarize": options.resummarize = nextValue(); break;
      default: throw new Error(`unknown argument: ${argument}`);
    }
  }
  if (!["all", "visible", "holdout"].includes(options.split)) throw new Error("--split must be all, visible or holdout");
  for (const dimension of options.dimensions) {
    if (!DIMENSION_ORDER.includes(dimension)) throw new Error(`unknown dimension: ${dimension}`);
  }
  return options;
}

// ---------------------------------------------------------------------------------------------
// Worker configuration + budgeted client
// ---------------------------------------------------------------------------------------------

function readWorkerConfiguration() {
  const readKey = (key) =>
    execFileSync("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, secretsPlistPath], { encoding: "utf8" }).trim();
  const baseUrl = readKey("WorkerBaseURL").replace(/\/+$/, "");
  const appToken = readKey("WorkerAppToken");
  if (!baseUrl || !appToken) throw new Error("WorkerBaseURL or WorkerAppToken is empty in ClickyWorkerSecrets.plist");
  secretsToRedact.push(appToken);
  return { baseUrl, appToken };
}

class HarnessAbort extends Error {}

export class BudgetedWorkerClient {
  constructor({ baseUrl, appToken, maxCalls }) {
    this.chatUrl = `${baseUrl}/chat`;
    this.appToken = appToken;
    this.maxCalls = maxCalls;
    this.callsUsed = 0;
    this.workerCalls = 0;
    this.judgeCalls = 0;
    this.consecutiveFailures = 0;
  }

  // purpose: "scenario" or "judge". Returns {json, latencyMilliseconds}. Throws HarnessAbort to stop the run,
  // or a plain Error for a failure that only affects this one scenario.
  async chat(requestBody, purpose) {
    if (this.callsUsed >= this.maxCalls) {
      throw new HarnessAbort(`call budget of ${this.maxCalls} reached`);
    }
    this.callsUsed += 1;
    if (purpose === "judge") this.judgeCalls += 1; else this.workerCalls += 1;

    const startTime = performance.now();
    let response;
    let responseText;
    try {
      response = await fetch(this.chatUrl, {
        method: "POST",
        headers: { "content-type": "application/json", "X-Clicky-App-Token": this.appToken },
        body: JSON.stringify(requestBody),
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MILLISECONDS),
      });
      responseText = await response.text();
    } catch (networkError) {
      return this.#recordFailure(`network error (${networkError.name})`, false);
    }
    const latencyMilliseconds = performance.now() - startTime;

    if (!response.ok) {
      let errorType = "";
      try { errorType = JSON.parse(responseText)?.error?.type ?? ""; } catch { /* body was not JSON */ }
      const description = `HTTP ${response.status}${errorType ? ` ${errorType}` : ""}: ${redactSecrets(responseText).slice(0, 200)}`;
      // 401 / 402 / 429 mean the credentials, billing or rate limit are the problem: retrying cannot help.
      const mustStopImmediately = [401, 402, 429].includes(response.status);
      return this.#recordFailure(description, mustStopImmediately);
    }

    let json;
    try { json = JSON.parse(responseText); } catch { return this.#recordFailure("response was not JSON", false); }
    this.consecutiveFailures = 0;
    return { json, latencyMilliseconds };
  }

  #recordFailure(description, mustStopImmediately) {
    this.consecutiveFailures += 1;
    if (mustStopImmediately) throw new HarnessAbort(`stopped on first failure: ${description}`);
    if (this.consecutiveFailures >= 3) throw new HarnessAbort(`3 consecutive failures, last: ${description}`);
    throw new Error(description);
  }
}

// ---------------------------------------------------------------------------------------------
// Fixtures and request building (mirrors ClaudeAPI.swift + CompanionManager.swift)
// ---------------------------------------------------------------------------------------------

function loadManifest() {
  return JSON.parse(fs.readFileSync(path.join(evalDirectory, "fixtures", "manifest.json"), "utf8")).fixtures;
}

// Label text copied from CompanionScreenCaptureUtility + CompanionManager.
function buildScreenLabel(screenIndex, screenCount, widthInPixels, heightInPixels) {
  let label;
  if (screenCount === 1) label = "user's screen (cursor is here)";
  else if (screenIndex === 0) label = `screen ${screenIndex + 1} of ${screenCount} — cursor is on this screen (primary focus)`;
  else label = `screen ${screenIndex + 1} of ${screenCount} — secondary screen`;
  // Matches CompanionManager.swift: the center point is a calibration anchor for the model.
  const centerX = Math.floor(widthInPixels / 2);
  const centerY = Math.floor(heightInPixels / 2);
  return `${label} (image dimensions: ${widthInPixels}x${heightInPixels} pixels; center is at ${centerX},${centerY})`;
}

function buildRequestBody({ systemPrompt, history, screens, userPrompt, manifest, requestExtras }) {
  const messages = [];
  for (const exchange of history ?? []) {
    messages.push({ role: "user", content: exchange.user });
    messages.push({ role: "assistant", content: exchange.assistant });
  }
  const contentBlocks = [];
  screens.forEach((fixtureFileName, screenIndex) => {
    const fixtureInfo = manifest[fixtureFileName];
    const imageBytes = fs.readFileSync(path.join(evalDirectory, "fixtures", fixtureFileName));
    contentBlocks.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: imageBytes.toString("base64") } });
    contentBlocks.push({ type: "text", text: buildScreenLabel(screenIndex, screens.length, fixtureInfo.width, fixtureInfo.height) });
  });
  contentBlocks.push({ type: "text", text: userPrompt });
  messages.push({ role: "user", content: contentBlocks });
  return {
    model: MODEL_NAME,
    max_tokens: APP_MAX_TOKENS,
    output_config: { effort: "low" },
    system: systemPrompt,
    messages,
    ...(requestExtras ?? {}),
  };
}

function extractReply(responseJson) {
  const blocks = responseJson.content ?? [];
  const text = blocks.filter((block) => block.type === "text").map((block) => block.text).join("");
  const toolUses = blocks.filter((block) => block.type === "tool_use");
  return {
    text,
    toolUses,
    outputTokens: responseJson.usage?.output_tokens ?? null,
    inputTokens: responseJson.usage?.input_tokens ?? null,
    stopReason: responseJson.stop_reason ?? null,
  };
}

// ---------------------------------------------------------------------------------------------
// POINT tag parsing (same pattern as CompanionManager.parsePointingCoordinates)
// ---------------------------------------------------------------------------------------------

const POINT_TAG_PATTERN = /\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$/;

export function parsePointTag(replyText) {
  const match = POINT_TAG_PATTERN.exec(replyText);
  if (!match) {
    return { spokenText: replyText.trim(), hasTag: false, isNone: false, x: null, y: null, label: null, screenNumber: null };
  }
  const spokenText = replyText.slice(0, match.index).trim();
  if (match[1] === undefined) {
    return { spokenText, hasTag: true, isNone: true, x: null, y: null, label: null, screenNumber: null };
  }
  return {
    spokenText, hasTag: true, isNone: false,
    x: Number(match[1]), y: Number(match[2]),
    label: match[3] ? match[3].trim() : null,
    screenNumber: match[4] ? Number(match[4]) : null,
  };
}

// ---------------------------------------------------------------------------------------------
// Honesty detection (used by pointing "none" scenarios)
// ---------------------------------------------------------------------------------------------

const ACKNOWLEDGES_ABSENT_PATTERNS = [
  /\b(don'?t|do not|can'?t|cannot|couldn'?t|isn'?t|aren'?t|doesn'?t|not|no|nothing)\b[^.?!]{0,80}\b(see|find|spot|visible|here|on (?:your |the )?screen|in (?:this|that|your|the)|available|part of|show|have|exist|there)\b/i,
  /\bthere'?s no\b/i,
  /\bno such\b/i,
];
const ACKNOWLEDGES_UNKNOWN_PATTERN = /\b(don'?t|do not|can'?t|cannot|couldn'?t|unable|not able to|no (?:way|access)|not sure|no idea|don'?t know)\b/i;
const INVENTED_FIGURE_PATTERN = /\$\s?\d|\b\d{1,3}(?:,\d{3})+\b|\b\d{4,}\b|\b(?:dollars|usd)\b/i;

export function acknowledgesAbsence(spokenText, kind = "absent") {
  if (kind === "unknown") {
    return ACKNOWLEDGES_UNKNOWN_PATTERN.test(spokenText) && !INVENTED_FIGURE_PATTERN.test(spokenText);
  }
  return ACKNOWLEDGES_ABSENT_PATTERNS.some((pattern) => pattern.test(spokenText));
}

// ---------------------------------------------------------------------------------------------
// Scoring: POINTING (+ honesty)
// ---------------------------------------------------------------------------------------------

function distanceFromPointToRectangle(x, y, rectangle) {
  const dx = Math.max(rectangle.x - x, 0, x - (rectangle.x + rectangle.w));
  const dy = Math.max(rectangle.y - y, 0, y - (rectangle.y + rectangle.h));
  return Math.hypot(dx, dy);
}

// Turns the app's own parse (ClickyTurnFinisher via the driver) into the same shape parsePointTag returns.
// hasTag/isNone follow the raw text; the target and spoken text come from the app's parser.
export function replyViewFromFinishedTurn(rawReplyText, finishedTurn) {
  const pointTarget = finishedTurn.pointTarget ?? null;
  const isNone = pointTarget === null && /\[\s*POINT\s*:\s*none\b[^\]]*\]/i.test(rawReplyText);
  return {
    spokenText: finishedTurn.spokenText,
    hasTag: pointTarget !== null || isNone,
    isNone,
    x: pointTarget ? pointTarget.x : null,
    y: pointTarget ? pointTarget.y : null,
    label: pointTarget ? pointTarget.label : null,
    screenNumber: pointTarget ? pointTarget.screenNumber : null,
    tagAtEnd: /\[\s*POINT\s*:[^\[\]]*\]\s*$/i.test(rawReplyText),
  };
}

export function scorePointing(scenario, replyTextOrView, manifest) {
  const parsed = typeof replyTextOrView === "string" ? parsePointTag(replyTextOrView) : replyTextOrView;
  const expectation = scenario.expect;

  if (expectation.type === "point") {
    if (!parsed.hasTag) return { score: 0, outcome: "no_tag", parsed };
    if (parsed.isNone) return { score: 0, outcome: "said_none", parsed };
    const predictedScreenNumber = parsed.screenNumber ?? 1; // the app defaults to the cursor screen (screen 1)
    const candidateTargets = expectation.targets.filter((target) => target.screen === predictedScreenNumber);
    if (candidateTargets.length === 0) return { score: 0, outcome: "wrong_screen", parsed };

    const predictedFixture = manifest[scenario.screens[predictedScreenNumber - 1]];
    if (parsed.x > predictedFixture.width || parsed.y > predictedFixture.height) {
      return { score: 0, outcome: "out_of_bounds", parsed };
    }
    let nearest = null;
    for (const target of candidateTargets) {
      const rectangle = predictedFixture.elements[target.element];
      const padded = {
        x: rectangle.x - POINTING_BOX_TOLERANCE_PIXELS, y: rectangle.y - POINTING_BOX_TOLERANCE_PIXELS,
        w: rectangle.w + 2 * POINTING_BOX_TOLERANCE_PIXELS, h: rectangle.h + 2 * POINTING_BOX_TOLERANCE_PIXELS,
      };
      if (distanceFromPointToRectangle(parsed.x, parsed.y, padded) === 0) {
        return { score: 100, outcome: "hit", parsed };
      }
      const distance = distanceFromPointToRectangle(parsed.x, parsed.y, rectangle);
      if (!nearest || distance < nearest.distance) {
        nearest = {
          distance,
          offsetX: parsed.x - (rectangle.x + rectangle.w / 2),
          offsetY: parsed.y - (rectangle.y + rectangle.h / 2),
        };
      }
    }
    return {
      score: 0, outcome: nearest.distance <= NEAR_MISS_PIXELS ? "near_miss" : "miss", parsed,
      missDistancePixels: Math.round(nearest.distance), missOffsetX: Math.round(nearest.offsetX), missOffsetY: Math.round(nearest.offsetY),
    };
  }

  // expectation.type === "none": the right behaviour is [POINT:none] plus an honest spoken acknowledgement.
  if (parsed.hasTag && !parsed.isNone) return { score: 0, outcome: "invented_pointing", parsed };
  const tagPoints = parsed.isNone ? 60 : 40; // no tag at all behaves the same in the app but breaks the prompt format
  let honestyPoints = 40;
  let acknowledged = null;
  if (expectation.honestyRequired) {
    acknowledged = acknowledgesAbsence(parsed.spokenText, expectation.honestyKind ?? "absent");
    honestyPoints = acknowledged ? 40 : 0;
  }
  return {
    score: tagPoints + honestyPoints,
    outcome: acknowledged === false ? "none_without_honest_acknowledgement" : parsed.isNone ? "correct_none" : "no_tag_but_honest",
    parsed,
  };
}

// ---------------------------------------------------------------------------------------------
// Scoring: BREVITY (spoken-format compliance from the system prompt rules, plus speed)
// ---------------------------------------------------------------------------------------------

export function countSentences(spokenText) {
  const cleaned = spokenText
    .replace(/\b(e\.g|i\.e|etc|vs|mr|mrs|dr)\./gi, (abbreviation) => abbreviation.replaceAll(".", ""))
    .replace(/(\d)\.(\d)/g, "$1$2");
  return cleaned.split(/(?<=[.!?])\s+|\n+/).map((part) => part.trim()).filter(Boolean).length;
}

function countWords(spokenText) {
  return spokenText.split(/\s+/).filter(Boolean).length;
}

const MARKDOWN_PATTERN = /(\*\*|__|`|^#{1,6}\s|^\s*[-*•]\s|^\s*\d+[.)]\s)/m;
const EMOJI_PATTERN = /\p{Extended_Pictographic}/u;
const BANNED_WORD_PATTERN = /\b(simply|just)\b|\b(e\.g\.|i\.e\.|etc\.)|\bvs\.?(?=\s)/i;
const WEIRD_SYMBOL_PATTERN = /[&%=+<>^~|\\{}#*_`@]|->|=>/;
const SMALL_DIGIT_PATTERN = /(?<![\w.])(?:[0-9]|10)(?![\w.]|,\d)/;
const DEAD_END_QUESTION_PATTERN = /^(want me|would you like|should i|do you want|shall i|need me|let me know|can i)\b/i;

export function analyzeSpokenReply(replyTextOrView, expectation) {
  const parsed = typeof replyTextOrView === "string" ? parsePointTag(replyTextOrView) : replyTextOrView;
  const spoken = parsed.spokenText;
  const sentenceCount = countSentences(spoken);
  const wordCount = countWords(spoken);
  const uppercaseLetterCount = (spoken.match(/[A-Z]/g) ?? []).length;

  const sentencesOfReply = spoken.split(/(?<=[.!?])\s+|\n+/).map((part) => part.trim()).filter(Boolean);
  const lastSentence = sentencesOfReply[sentencesOfReply.length - 1] ?? "";
  const endsWithDeadEndQuestion = lastSentence.endsWith("?") && DEAD_END_QUESTION_PATTERN.test(lastSentence);

  const checks = {};
  const allowLong = Boolean(expectation.allowLong);
  if (allowLong) {
    checks.sentences = { points: 25, earned: sentenceCount >= expectation.minSentences ? 25 : 0, label: "elaborates when asked (enough sentences)" };
    checks.words = { points: 25, earned: wordCount >= expectation.minWords ? 25 : 0, label: "elaborates when asked (enough words)" };
  } else {
    const sentenceLimit = expectation.maxSentences ?? 2;
    const wordLimit = expectation.maxWords ?? 45;
    checks.sentences = {
      points: 25, label: `at most ${sentenceLimit} sentences`,
      earned: sentenceCount <= sentenceLimit ? 25 : sentenceCount === sentenceLimit + 1 ? 12 : 0,
    };
    checks.words = {
      points: 25, label: `at most ${wordLimit} words`,
      earned: wordCount <= wordLimit ? 25 : wordCount <= wordLimit * 1.5 ? 12 : 0,
    };
  }
  checks.lowercase = { points: 10, label: "all lowercase", earned: uppercaseLetterCount === 0 ? 10 : uppercaseLetterCount <= 2 ? 5 : 0 };
  checks.no_markdown_or_code = { points: 10, label: "no markdown, lists or code", earned: MARKDOWN_PATTERN.test(spoken) ? 0 : 10 };
  checks.no_emoji = { points: 5, label: "no emoji", earned: EMOJI_PATTERN.test(spoken) ? 0 : 5 };
  checks.no_banned_words = { points: 5, label: "no 'simply'/'just'/abbreviations like e.g.", earned: BANNED_WORD_PATTERN.test(spoken) ? 0 : 5 };
  checks.no_dead_end_question = { points: 5, label: "no dead-end yes/no closing question", earned: endsWithDeadEndQuestion ? 0 : 5 };
  const spokenFriendly = !WEIRD_SYMBOL_PATTERN.test(spoken) && !SMALL_DIGIT_PATTERN.test(spoken);
  checks.spoken_friendly = { points: 10, label: "no symbols or digit numerals that sound odd aloud", earned: spokenFriendly ? 10 : 0 };

  // The style rule is a trailing tag. Views from the app parser keep tagAtEnd; old string parses always end on the tag.
  const tagIsAtEnd = parsed.tagAtEnd ?? true;
  let pointTagEarned = 0;
  if (parsed.hasTag && tagIsAtEnd) {
    pointTagEarned = expectation.pointExpectation === "none" && !parsed.isNone ? 0 : 5;
  }
  checks.point_tag = { points: 5, label: "valid trailing POINT tag (none when pointing is pointless)", earned: pointTagEarned };

  const compliance = Object.values(checks).reduce((sum, check) => sum + check.earned, 0);
  const failedChecks = Object.entries(checks).filter(([, check]) => check.earned < check.points).map(([name]) => name);
  return { compliance, failedChecks, checks, sentenceCount, wordCount, uppercaseLetterCount };
}

export function speedScores(latencyMilliseconds, outputTokens) {
  const latencySeconds = latencyMilliseconds / 1000;
  const latencyScore = 100 * clamp((LATENCY_ZERO_SCORE_SECONDS - latencySeconds) / (LATENCY_ZERO_SCORE_SECONDS - LATENCY_FULL_SCORE_SECONDS), 0, 1);
  const tokenScore = outputTokens === null ? 0
    : 100 * clamp((TOKENS_ZERO_SCORE - outputTokens) / (TOKENS_ZERO_SCORE - TOKENS_FULL_SCORE), 0, 1);
  return { latencyScore, tokenScore };
}

export function scoreBrevity(scenario, replyText, latencyMilliseconds, outputTokens, appParsedView = null) {
  const analysis = analyzeSpokenReply(appParsedView ?? replyText, scenario.expect);
  const { latencyScore, tokenScore } = speedScores(latencyMilliseconds, outputTokens);
  // Elaboration scenarios are exempt from speed scoring: a long answer was explicitly requested.
  const score = scenario.expect.allowLong
    ? analysis.compliance
    : 0.45 * analysis.compliance + 0.30 * latencyScore + 0.25 * tokenScore;
  let answerCorrect = null;
  if (scenario.expect.answerAnyOf) {
    const lowered = replyText.toLowerCase();
    answerCorrect = scenario.expect.answerAnyOf.some((accepted) => lowered.includes(accepted));
  }
  return { score, analysis, latencyScore, tokenScore, answerCorrect };
}

// ---------------------------------------------------------------------------------------------
// Scoring: CODING (keyword checks + LLM judge)
// ---------------------------------------------------------------------------------------------

export function scoreKeywordGroups(keywordGroups, replyText) {
  const lowered = replyText.toLowerCase();
  const groupHits = keywordGroups.map((alternatives) => alternatives.some((alternative) => lowered.includes(alternative.toLowerCase())));
  return { groupHits, coverage: groupHits.length === 0 ? 1 : groupHits.filter(Boolean).length / groupHits.length };
}

const JUDGE_SYSTEM_PROMPT =
  "You are a strict but fair grader of a voice assistant's coding help. The assistant looks at a developer's screen and answers out loud, " +
  "so good answers are correct, specific to what is on the screen, and short and conversational. Reply with JSON only.";

function buildJudgeUserPrompt(scenario, replyText) {
  return [
    `SCREEN (description of what the assistant could see):\n${scenario.screenContext}`,
    `USER QUESTION:\n${scenario.userPrompt}`,
    `REFERENCE ANSWER (key facts; other wordings are fine):\n${scenario.reference}`,
    `ASSISTANT REPLY (spoken text, may end with a [POINT:...] cursor tag you should ignore):\n${replyText}`,
    "Score the reply:\n" +
      "- correctness 0-5: 5 = correct diagnosis and a correct, actionable fix consistent with the reference; 3 = partly right or vague; 1 = mostly wrong; 0 = wrong, harmful or empty.\n" +
      "- specificity 0-3: 3 = clearly refers to the concrete error, line or code visible on this screen; 0 = generic.\n" +
      "- voice_fit 0-2: 2 = natural spoken sentences, concise, no code blocks, lists or markdown, does not read code out verbatim; 0 = markdown or a code dump.\n" +
      'Respond with ONLY this JSON: {"correctness":<int>,"specificity":<int>,"voice_fit":<int>,"note":"<max 15 words>"}',
  ].join("\n\n");
}

export function parseJudgeJson(judgeText) {
  const jsonMatch = /\{[\s\S]*\}/.exec(judgeText);
  if (!jsonMatch) return null;
  try {
    const parsed = JSON.parse(jsonMatch[0]);
    const correctness = clamp(Number(parsed.correctness), 0, 5);
    const specificity = clamp(Number(parsed.specificity), 0, 3);
    const voiceFit = clamp(Number(parsed.voice_fit), 0, 2);
    if ([correctness, specificity, voiceFit].some(Number.isNaN)) return null;
    return { correctness, specificity, voiceFit, total: correctness + specificity + voiceFit, note: String(parsed.note ?? "").slice(0, 160) };
  } catch {
    return null;
  }
}

export function combineCodingScore(judgeTotalOutOfTen, keywordCoverage) {
  return 100 * (0.6 * (judgeTotalOutOfTen / 10) + 0.4 * keywordCoverage);
}

// ---------------------------------------------------------------------------------------------
// Scoring: NOTES (pluggable protocol adapter)
// ---------------------------------------------------------------------------------------------

export function loadNotesProtocol(protocolFilePath) {
  const protocol = JSON.parse(fs.readFileSync(protocolFilePath, "utf8"));
  const detection = protocol.save_detection ?? {};
  // "app_parser": the note grammar is the app's own ClickyReplyTagParser, run through the driver.
  const enabled = Boolean(protocol.enabled) && (
    detection.type === "app_parser" ? true
      : detection.type === "tool_use" ? Boolean(detection.tool_name) : Boolean(detection.regex));
  return { ...protocol, enabled };
}

export function detectNoteSave(protocol, reply) {
  const detection = protocol.save_detection;
  if (detection.type === "tool_use") {
    const toolUse = reply.toolUses.find((block) => block.name === detection.tool_name);
    if (!toolUse) return { saved: false };
    return { saved: true, title: String(toolUse.input?.[detection.tool_title_field] ?? ""), body: String(toolUse.input?.[detection.tool_body_field] ?? "") };
  }
  const match = new RegExp(detection.regex, detection.flags ?? "").exec(reply.text);
  if (!match) return { saved: false };
  return { saved: true, title: match.groups?.[detection.title_group] ?? "", body: match.groups?.[detection.body_group] ?? "" };
}

export function renderNotesContext(protocol, notes) {
  const injection = protocol.context_injection ?? { mode: "none" };
  if (injection.mode === "none") return { systemSuffix: "", userPrefix: "" };
  const noteLines = notes.map((note) =>
    (injection.note_line_template ?? "- {{title}}: {{body}}")
      .replace("{{title}}", note.title).replace("{{date}}", note.date ?? "").replace("{{body}}", note.body));
  const rendered = (injection.template ?? "{{notes_block}}")
    .replace("{{notes_block}}", noteLines.join("\n")).replace("{{notes_count}}", String(notes.length));
  return injection.mode === "user_prefix" ? { systemSuffix: "", userPrefix: rendered } : { systemSuffix: rendered, userPrefix: "" };
}

function spokenTextForNotes(protocol, replyText) {
  let text = replyText;
  if (protocol.strip_from_spoken_regex) text = text.replace(new RegExp(protocol.strip_from_spoken_regex, "gs"), "");
  return parsePointTag(text).spokenText;
}

const ADMITS_NO_NOTE_PATTERN = /\b(don'?t|do not|didn'?t|no|not|can'?t|nothing|haven'?t)\b[^.?!]{0,60}\b(note|noted|saved|record|written|mention|see|find|have)\b/i;

// From the app's parse: a save counts when the MODEL wrote a NOTE tag. The app's dictated-text fallback
// is reported separately (appSavedNoteTexts) because it is a safety net, not the model's behaviour.
function detectNoteSaveFromFinishedTurn(finishedTurn) {
  const modelNoteTexts = finishedTurn.modelNoteTexts ?? [];
  return { saved: modelNoteTexts.length > 0, title: "", body: modelNoteTexts.join(" | "), appSavedNoteTexts: finishedTurn.savedNoteTexts ?? [] };
}

export function scoreNotes(scenario, reply, protocol) {
  const expectation = scenario.expect;
  const finishedTurn = reply.finished ?? null;
  const detection = finishedTurn ? detectNoteSaveFromFinishedTurn(finishedTurn) : detectNoteSave(protocol, reply);
  const spoken = finishedTurn ? finishedTurn.spokenText : spokenTextForNotes(protocol, reply.text);
  const sentenceCount = countSentences(spoken);

  if (scenario.kind === "nosave") {
    return { score: detection.saved ? 0 : 100, outcome: detection.saved ? "false_save" : "correct_no_save", detection };
  }
  if (scenario.kind === "save") {
    const protocolPoints = detection.saved ? 50 : 0;
    const keywordCoverage = detection.saved
      ? scoreKeywordGroups(expectation.bodyKeywordGroups, `${detection.title} ${detection.body}`).coverage : 0;
    let confirmationPoints;
    if (finishedTurn) {
      // Spec: a short confirmation (at most 8 spoken words) that is lowercase, markdown-free and does not show the tag.
      const spokenWordCount = countWords(spoken);
      const shortConfirmationPoints = spokenWordCount >= 1 && spokenWordCount <= 8 ? 10 : 0;
      const cleanConfirmationPoints = /[A-Z\[\]]/.test(spoken) || MARKDOWN_PATTERN.test(spoken) || /\bnote\s*:/i.test(spoken) ? 0 : 10;
      confirmationPoints = shortConfirmationPoints + cleanConfirmationPoints;
    } else {
      confirmationPoints = (sentenceCount <= 2 ? 10 : 0) + (/[A-Z]/.test(spoken) || MARKDOWN_PATTERN.test(spoken) ? 0 : 10);
    }
    return {
      score: protocolPoints + 30 * keywordCoverage + confirmationPoints,
      outcome: detection.saved ? (keywordCoverage === 1 ? "saved_complete" : "saved_incomplete") : "not_saved",
      detection,
    };
  }
  // recall
  let answerPoints;
  if (expectation.mustAdmitNoNote) answerPoints = ADMITS_NO_NOTE_PATTERN.test(spoken) ? 60 : 0;
  else answerPoints = 60 * scoreKeywordGroups(expectation.answerKeywordGroups, spoken).coverage;
  const lowered = spoken.toLowerCase();
  const forbiddenPoints = (expectation.forbiddenPatterns ?? []).some((pattern) => lowered.includes(pattern.toLowerCase())) ? 0 : 20;
  const lengthPoints = sentenceCount <= (expectation.maxSentences ?? 3) ? 20 : 0;
  return {
    score: answerPoints + forbiddenPoints + lengthPoints,
    outcome: answerPoints === 60 ? (forbiddenPoints === 20 ? "recalled_cleanly" : "recalled_but_leaked") : "recall_failed",
    detection,
  };
}

// ---------------------------------------------------------------------------------------------
// Scenario loading
// ---------------------------------------------------------------------------------------------

function loadScenarios(options) {
  const splits = options.split === "all" ? ["visible", "holdout"] : [options.split];
  const scenarios = [];
  for (const split of splits) {
    for (const dimension of options.dimensions) {
      const filePath = path.join(evalDirectory, "scenarios", split, `${dimension}.json`);
      if (!fs.existsSync(filePath)) continue;
      for (const scenario of JSON.parse(fs.readFileSync(filePath, "utf8"))) {
        scenarios.push({ ...scenario, split, dimension });
      }
    }
  }
  return options.only ? scenarios.filter((scenario) => options.only.includes(scenario.id)) : scenarios;
}

function plannedCallCount(scenarios, notesProtocol) {
  return scenarios.reduce((total, scenario) => {
    if (scenario.dimension === "coding") return total + 2;
    if (scenario.dimension === "notes") return total + (notesProtocol.enabled ? 1 : 0);
    return total + 1;
  }, 0);
}

// ---------------------------------------------------------------------------------------------
// Scenario execution
// ---------------------------------------------------------------------------------------------

// ---------------------------------------------------------------------------------------------
// Assembled prompts through the eval-owned Swift driver (eval/assemble_prompt_driver/main.swift).
// The driver calls the app's own ClickyPromptAssembler and ClickyTurnFinisher, so prompts and reply
// parsing match the app. It makes ZERO API calls. Notes go only to a mkdtemp folder, never the real one.
// ---------------------------------------------------------------------------------------------

const FRONTMOST_APP_BY_FIXTURE_PREFIX = {
  xcode: { bundleId: "com.apple.dt.Xcode", name: "Xcode" },
  vscode: { bundleId: "com.microsoft.VSCode", name: "Visual Studio Code" },
  terminal: { bundleId: "com.apple.Terminal", name: "Terminal" },
  settings: { bundleId: "com.apple.systempreferences", name: "System Settings" },
  browser: { bundleId: "com.apple.Safari", name: "Safari" },
};

// Coding and terminal fixtures get their real app; everything else is Safari (a neutral app).
export function frontmostAppForScenario(scenario) {
  const fixturePrefix = scenario.screens[0].split("_")[0];
  return FRONTMOST_APP_BY_FIXTURE_PREFIX[fixturePrefix] ?? FRONTMOST_APP_BY_FIXTURE_PREFIX.browser;
}

class PromptAssembler {
  constructor({ driverBinaryPath, promptsDirectory }) {
    this.driverBinaryPath = driverBinaryPath;
    this.promptsDirectory = promptsDirectory;
    this.workDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "clicky-eval-io-"));
    this.notesRootDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "clicky-eval-notes-"));
    this.finishCount = 0;
  }

  #runDriver(driverArguments) {
    execFileSync(this.driverBinaryPath, driverArguments, { stdio: ["ignore", "pipe", "pipe"] });
  }

  // Returns Map(scenarioId -> { systemPromptText, selectedSkillNames, includedNoteTexts }).
  assemble(scenarios) {
    const inputPath = path.join(this.workDirectory, "prepare_input.json");
    const outputPath = path.join(this.workDirectory, "prepare_output.json");
    const prepareInput = scenarios.map((scenario) => {
      const frontmostApp = frontmostAppForScenario(scenario);
      return {
        id: scenario.id,
        transcript: scenario.userPrompt,
        bundleId: frontmostApp.bundleId,
        appName: frontmostApp.name,
        screenCount: scenario.screens.length,
        // Recall scenarios seed the temporary store with their notes (text = the note body, as the app stores it).
        seedNotes: scenario.kind === "recall" ? scenario.notes.map((note) => ({ date: note.date, text: note.body })) : [],
      };
    });
    fs.writeFileSync(inputPath, JSON.stringify(prepareInput));
    this.#runDriver(["prepare", inputPath, outputPath, this.promptsDirectory, this.notesRootDirectory]);
    const records = JSON.parse(fs.readFileSync(outputPath, "utf8"));
    return new Map(records.map((record) => [record.id, record]));
  }

  // Post-processes one raw reply the way the app does. Returns the driver's finished-turn record.
  finishReply(scenario, rawReplyText) {
    this.finishCount += 1;
    const inputPath = path.join(this.workDirectory, `finish_${this.finishCount}.json`);
    const outputPath = path.join(this.workDirectory, `finish_${this.finishCount}_out.json`);
    fs.writeFileSync(inputPath, JSON.stringify([{ id: scenario.id, transcript: scenario.userPrompt, rawReplyText }]));
    this.#runDriver(["finish", inputPath, outputPath, this.notesRootDirectory]);
    return JSON.parse(fs.readFileSync(outputPath, "utf8"))[0];
  }

  cleanUp() {
    // Only folders this harness created with mkdtemp. The driver refuses any other notes folder.
    fs.rmSync(this.workDirectory, { recursive: true, force: true });
    fs.rmSync(this.notesRootDirectory, { recursive: true, force: true });
  }
}

async function runScenario(scenario, context) {
  const { client, systemPrompt, manifest, notesProtocol, assembledPrompts } = context;
  const baseRecord = { id: scenario.id, split: scenario.split, dimension: scenario.dimension, category: scenario.category };

  // With the assembler, each scenario has its own system prompt (base + skills + right now + notes).
  let systemPromptForScenario = assembledPrompts ? assembledPrompts.get(scenario.id).systemPromptText : systemPrompt;
  let userPromptForScenario = scenario.userPrompt;
  let requestExtras = null;
  if (scenario.dimension === "notes") {
    requestExtras = notesProtocol.request_extras ?? null;
    // Assembled prompts already contain the notes the app would inject, so no second injection here.
    if (scenario.kind === "recall" && !assembledPrompts) {
      const { systemSuffix, userPrefix } = renderNotesContext(notesProtocol, scenario.notes);
      systemPromptForScenario = systemPrompt + systemSuffix;
      userPromptForScenario = userPrefix + scenario.userPrompt;
    }
  }
  const requestBody = buildRequestBody({
    systemPrompt: systemPromptForScenario, history: scenario.history, screens: scenario.screens,
    userPrompt: userPromptForScenario, manifest, requestExtras,
  });

  let chatResult;
  try {
    chatResult = await client.chat(requestBody, "scenario");
  } catch (error) {
    if (error instanceof HarnessAbort) throw error;
    return { ...baseRecord, errored: true, error: redactSecrets(error.message) };
  }
  const reply = extractReply(chatResult.json);
  // The app's own parse of the reply (tags, spoken text, note saves), via the driver. Zero API calls.
  const finishedTurn = assembledPrompts && scenario.dimension !== "coding" ? context.finishReply(scenario, reply.text) : null;
  const common = {
    ...baseRecord, errored: false, reply: reply.text, output_tokens: reply.outputTokens, input_tokens: reply.inputTokens,
    stop_reason: reply.stopReason, latency_ms: Math.round(chatResult.latencyMilliseconds),
  };

  if (scenario.dimension === "pointing") {
    const result = scorePointing(scenario, finishedTurn ? replyViewFromFinishedTurn(reply.text, finishedTurn) : reply.text, manifest);
    return { ...common, score: result.score, outcome: result.outcome, detail: { ...result, parsed: undefined } };
  }
  if (scenario.dimension === "brevity") {
    const result = scoreBrevity(scenario, reply.text, chatResult.latencyMilliseconds, reply.outputTokens,
      finishedTurn ? replyViewFromFinishedTurn(reply.text, finishedTurn) : null);
    return {
      ...common, score: result.score, outcome: result.analysis.failedChecks.length === 0 ? "clean" : "violations",
      detail: {
        compliance: result.analysis.compliance, failed_checks: result.analysis.failedChecks, sentence_count: result.analysis.sentenceCount,
        word_count: result.analysis.wordCount, latency_score: Math.round(result.latencyScore), token_score: Math.round(result.tokenScore),
        answer_correct: result.answerCorrect, exempt_from_speed: Boolean(scenario.expect.allowLong),
      },
    };
  }
  if (scenario.dimension === "coding") {
    const keywordResult = scoreKeywordGroups(scenario.keywordGroups, reply.text);
    let judgeResult = null;
    let judgeLatencyMilliseconds = null;
    try {
      const judgeResponse = await client.chat({
        model: MODEL_NAME, max_tokens: JUDGE_MAX_TOKENS, output_config: { effort: "low" },
        system: JUDGE_SYSTEM_PROMPT, messages: [{ role: "user", content: buildJudgeUserPrompt(scenario, reply.text) }],
      }, "judge");
      judgeLatencyMilliseconds = Math.round(judgeResponse.latencyMilliseconds);
      judgeResult = parseJudgeJson(extractReply(judgeResponse.json).text);
    } catch (error) {
      if (error instanceof HarnessAbort) throw error;
      judgeResult = null;
    }
    if (!judgeResult) {
      return { ...common, errored: true, error: "judge call failed or returned unparseable JSON", detail: { keyword_coverage: keywordResult.coverage } };
    }
    return {
      ...common, score: combineCodingScore(judgeResult.total, keywordResult.coverage), outcome: "judged",
      detail: { judge: judgeResult, judge_latency_ms: judgeLatencyMilliseconds, keyword_coverage: keywordResult.coverage, keyword_group_hits: keywordResult.groupHits },
    };
  }
  // notes
  const result = scoreNotes(scenario, { ...reply, finished: finishedTurn }, notesProtocol);
  return { ...common, score: result.score, outcome: result.outcome, detail: { detection: result.detection } };
}

// ---------------------------------------------------------------------------------------------
// Aggregation and summary
// ---------------------------------------------------------------------------------------------

function groupBy(items, keyFunction) {
  const groups = new Map();
  for (const item of items) {
    const key = keyFunction(item);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(item);
  }
  return groups;
}

function categoryBreakdown(results) {
  const breakdown = {};
  for (const [category, members] of groupBy(results, (result) => result.category)) {
    breakdown[category] = { n: members.length, score: round1(mean(members.map((member) => member.score))) };
  }
  return breakdown;
}

function dimensionScore(results) {
  const scored = results.filter((result) => !result.errored);
  return scored.length === 0 ? null : mean(scored.map((result) => result.score));
}

function buildDimensionDetails(dimension, results, notesProtocol) {
  const scored = results.filter((result) => !result.errored);
  const errored = results.length - scored.length;
  const base = { scenarios_scored: scored.length, scenarios_errored: errored, by_category: categoryBreakdown(scored) };
  const latencies = scored.map((result) => result.latency_ms);

  if (dimension === "pointing") {
    const outcomeCounts = {};
    for (const result of scored) outcomeCounts[result.outcome] = (outcomeCounts[result.outcome] ?? 0) + 1;
    const misses = scored.filter((result) => result.detail?.missOffsetX !== undefined);
    const targetOutcomes = ["hit", "near_miss", "miss", "said_none", "no_tag", "wrong_screen", "out_of_bounds"];
    const targetResults = scored.filter((result) => targetOutcomes.includes(result.outcome));
    return {
      ...base,
      outcome_counts: outcomeCounts,
      target_hit_rate: targetResults.length ? round1(100 * targetResults.filter((result) => result.outcome === "hit").length / targetResults.length) : null,
      mean_miss_offset_pixels: misses.length ? { dx: Math.round(mean(misses.map((result) => result.detail.missOffsetX))), dy: Math.round(mean(misses.map((result) => result.detail.missOffsetY))) } : null,
      median_latency_ms: median(latencies),
    };
  }
  if (dimension === "brevity") {
    const failureCounts = {};
    for (const result of scored) for (const check of result.detail.failed_checks) failureCounts[check] = (failureCounts[check] ?? 0) + 1;
    const speedScenarios = scored.filter((result) => !result.detail.exempt_from_speed);
    return {
      ...base,
      mean_compliance: round1(mean(scored.map((result) => result.detail.compliance))),
      check_failure_counts: failureCounts,
      median_output_tokens: median(speedScenarios.map((result) => result.output_tokens).filter((value) => value !== null)),
      median_latency_seconds: round1(median(speedScenarios.map((result) => result.latency_ms)) / 1000),
      p90_latency_seconds: round1(percentile(speedScenarios.map((result) => result.latency_ms), 0.9) / 1000),
      mean_latency_score: round1(mean(speedScenarios.map((result) => result.detail.latency_score))),
      mean_token_score: round1(mean(speedScenarios.map((result) => result.detail.token_score))),
      replies_truncated_at_max_tokens: scored.filter((result) => result.stop_reason === "max_tokens").length,
    };
  }
  if (dimension === "coding") {
    return {
      ...base,
      mean_judge_out_of_10: round1(mean(scored.map((result) => result.detail.judge.total))),
      mean_keyword_coverage_percent: round1(100 * mean(scored.map((result) => result.detail.keyword_coverage))),
      median_latency_ms: median(latencies),
    };
  }
  // notes (enabled)
  const outcomeCounts = {};
  for (const result of scored) outcomeCounts[result.outcome] = (outcomeCounts[result.outcome] ?? 0) + 1;
  return { ...base, outcome_counts: outcomeCounts, protocol_enabled: notesProtocol.enabled };
}

function describeFailures(dimension, visibleResults, details) {
  const failures = [];
  const scored = visibleResults.filter((result) => !result.errored);
  if (dimension === "pointing") {
    for (const [category, members] of groupBy(scored, (result) => result.category)) {
      const failed = members.filter((result) => result.score < 100);
      if (failed.length === 0) continue;
      const outcomes = {};
      for (const result of failed) outcomes[result.outcome] = (outcomes[result.outcome] ?? 0) + 1;
      const outcomeText = Object.entries(outcomes).map(([name, count]) => `${count}x ${name.replaceAll("_", " ")}`).join(", ");
      failures.push({ dimension, category, description: `${failed.length}/${members.length} visible scenarios in this category lost points (${outcomeText}); category mean ${round1(mean(members.map((member) => member.score)))}.` });
    }
    if (details.mean_miss_offset_pixels) {
      failures.push({ dimension, category: "systematic-miss-offset", description: `Missed pointer coordinates land on average ${details.mean_miss_offset_pixels.dx}px horizontally and ${details.mean_miss_offset_pixels.dy}px vertically from the target centre (negative = left/up).` });
    }
  }
  if (dimension === "brevity") {
    const total = scored.length;
    const readable = {
      sentences: "exceeded the sentence limit (or failed to elaborate when asked)", words: "exceeded the word limit (or failed to elaborate when asked)",
      lowercase: "contained uppercase letters", no_markdown_or_code: "used markdown, lists or code", no_emoji: "contained emoji",
      no_banned_words: "used 'simply'/'just'/spoken-unfriendly abbreviations", no_dead_end_question: "ended with a dead-end yes/no question",
      spoken_friendly: "used symbols or digit numerals that sound odd when spoken", point_tag: "missing, malformed or inappropriate trailing POINT tag",
    };
    for (const [check, count] of Object.entries(details.check_failure_counts)) {
      failures.push({ dimension, category: `format:${check}`, description: `${count}/${total} visible replies ${readable[check] ?? check}.` });
    }
    if (details.replies_truncated_at_max_tokens > 0) {
      failures.push({ dimension, category: "format:truncated-at-token-limit", description: `${details.replies_truncated_at_max_tokens}/${total} visible replies hit the ${APP_MAX_TOKENS}-token cap and would be cut off mid-sentence when spoken.` });
    }
    if (details.mean_latency_score !== null && details.mean_latency_score < 70) {
      failures.push({ dimension, category: "speed:latency", description: `Median non-streaming latency ${details.median_latency_seconds}s (p90 ${details.p90_latency_seconds}s); full score needs <= ${LATENCY_FULL_SCORE_SECONDS}s.` });
    }
    if (details.mean_token_score !== null && details.mean_token_score < 70) {
      failures.push({ dimension, category: "speed:output-tokens", description: `Median output tokens ${details.median_output_tokens}; full score needs <= ${TOKENS_FULL_SCORE}.` });
    }
  }
  if (dimension === "coding") {
    for (const [category, members] of groupBy(scored, (result) => result.category)) {
      const categoryScore = mean(members.map((member) => member.score));
      if (categoryScore >= 85) continue;
      failures.push({ dimension, category, description: `category mean ${round1(categoryScore)}/100 (judge ${round1(mean(members.map((member) => member.detail.judge.total)))}/10, keyword coverage ${round1(100 * mean(members.map((member) => member.detail.keyword_coverage)))}%).` });
    }
  }
  return failures;
}

function buildSummary({ options, results, notesProtocol, client, systemPromptText, status }) {
  const dimensionResults = {};
  const dimensions = {};
  const failures = [];
  for (const dimension of DIMENSION_ORDER) {
    const dimensionRun = results.filter((result) => result.dimension === dimension);
    dimensionResults[dimension] = dimensionRun;
    if (dimension === "notes" && !notesProtocol.enabled) {
      dimensions.notes = { score: options.dimensions.includes("notes") ? 0 : null, details: { capability: "missing", reason: notesProtocol.disabled_reason ?? "notes protocol adapter disabled", scenarios_designed: loadScenarioCounts().notes } };
      if (options.dimensions.includes("notes")) failures.push({ dimension: "notes", category: "capability", description: "capability missing: no note-taking protocol exists yet, so saving by voice and recall both score 0." });
      continue;
    }
    if (!options.dimensions.includes(dimension)) { dimensions[dimension] = { score: null, details: { not_run: true } }; continue; }
    const score = dimensionScore(dimensionRun);
    const details = buildDimensionDetails(dimension, dimensionRun, notesProtocol);
    dimensions[dimension] = { score: round1(score), details };
    // Failure text is derived from VISIBLE scenarios only, with visible-only statistics; holdout feeds numbers only.
    const visibleRun = dimensionRun.filter((result) => result.split === "visible");
    failures.push(...describeFailures(dimension, visibleRun, buildDimensionDetails(dimension, visibleRun, notesProtocol)));
  }

  const weightedTotal = (scoreLookup) => {
    let total = 0;
    let complete = true;
    for (const [dimension, weight] of Object.entries(DIMENSION_WEIGHTS)) {
      const score = scoreLookup(dimension);
      if (score === null || score === undefined) complete = false; else total += weight * score;
    }
    return complete ? round1(total) : null;
  };
  const equalAverage = (scoreLookup) => {
    const scores = DIMENSION_ORDER.map(scoreLookup);
    return scores.some((score) => score === null || score === undefined) ? null : round1(mean(scores));
  };

  const splitScores = {};
  for (const split of ["visible", "holdout"]) {
    const splitDimensionScore = (dimension) => {
      if (dimension === "notes" && !notesProtocol.enabled) return options.dimensions.includes("notes") ? 0 : null;
      const members = dimensionResults[dimension].filter((result) => result.split === split);
      const score = dimensionScore(members);
      return score === null ? null : round1(score);
    };
    splitScores[split] = {
      notes: splitDimensionScore("notes"), pointing: splitDimensionScore("pointing"), brevity: splitDimensionScore("brevity"), coding: splitDimensionScore("coding"),
      total: weightedTotal(splitDimensionScore),
    };
  }
  const overallScore = (dimension) => dimensions[dimension].score;

  const holdoutGap = splitScores.visible.total !== null && splitScores.holdout.total !== null ? round1(splitScores.visible.total - splitScores.holdout.total) : null;
  if (holdoutGap !== null && Math.abs(holdoutGap) > 10) {
    failures.push({ dimension: "all", category: "visible-vs-holdout-gap", description: `Visible total is ${holdoutGap > 0 ? "higher" : "lower"} than holdout total by ${Math.abs(holdoutGap)} points (> 10): possible overfitting to visible categories or small-sample noise.` });
  }

  const erroredCount = results.filter((result) => result.errored).length;
  return {
    round: options.round,
    label: options.label,
    status,
    timestamp: new Date().toISOString(),
    model: MODEL_NAME,
    system_prompt: { file: options.systemPromptFile, chars: systemPromptText.length, sha256_12: crypto.createHash("sha256").update(systemPromptText).digest("hex").slice(0, 12) },
    weights: DIMENSION_WEIGHTS,
    dimensions,
    total: weightedTotal(overallScore),
    total_equal_weight: equalAverage(overallScore),
    split_scores: splitScores,
    visible_holdout_gap: holdoutGap,
    calls_used: { total: client.callsUsed, scenario_calls: client.workerCalls, judge_calls: client.judgeCalls, budget: client.maxCalls },
    scenarios_errored: erroredCount,
    failures,
  };
}

function loadScenarioCounts() {
  const counts = {};
  for (const dimension of DIMENSION_ORDER) {
    counts[dimension] = 0;
    for (const split of ["visible", "holdout"]) {
      const filePath = path.join(evalDirectory, "scenarios", split, `${dimension}.json`);
      if (fs.existsSync(filePath)) counts[dimension] += JSON.parse(fs.readFileSync(filePath, "utf8")).length;
    }
  }
  return counts;
}

// ---------------------------------------------------------------------------------------------
// Offline self test (no network, no API calls)
// ---------------------------------------------------------------------------------------------

function runSelfTest() {
  let failureCount = 0;
  const check = (name, condition) => {
    if (!condition) { failureCount += 1; console.log(`FAIL  ${name}`); } else console.log(`ok    ${name}`);
  };
  const manifest = loadManifest();

  check("parse none tag", parsePointTag("sure thing. [POINT:none]").isNone === true);
  const parsedTag = parsePointTag("click it. [POINT:136,46:run button]");
  check("parse coordinate tag", parsedTag.x === 136 && parsedTag.y === 46 && parsedTag.label === "run button" && parsedTag.spokenText === "click it.");
  check("parse screen tag", parsePointTag("over there [POINT:400,300:terminal:screen2]").screenNumber === 2);
  check("tag mid-text is ignored like the app", parsePointTag("[POINT:1,2:x] and more").hasTag === false);

  const runScenarioDefinition = { screens: ["xcode_main.jpg"], expect: { type: "point", targets: [{ screen: 1, element: "xcode_run_button" }] } };
  check("pointing hit", scorePointing(runScenarioDefinition, "go. [POINT:150,46:run]", manifest).outcome === "hit");
  check("pointing hit within tolerance", scorePointing(runScenarioDefinition, "go. [POINT:166,46:run]", manifest).outcome === "hit");
  check("pointing miss", scorePointing(runScenarioDefinition, "go. [POINT:600,400:run]", manifest).outcome === "miss");
  check("pointing near miss", scorePointing(runScenarioDefinition, "go. [POINT:190,46:run]", manifest).outcome === "near_miss");
  check("pointing said none", scorePointing(runScenarioDefinition, "no. [POINT:none]", manifest).outcome === "said_none");
  check("pointing out of bounds", scorePointing(runScenarioDefinition, "go. [POINT:3000,46:run]", manifest).outcome === "out_of_bounds");
  const secondScreenDefinition = { screens: ["xcode_main.jpg", "browser_main.jpg"], expect: { type: "point", targets: [{ screen: 2, element: "browser_reload_button" }] } };
  check("pointing wrong screen (omitted screen tag)", scorePointing(secondScreenDefinition, "there [POINT:104,82:reload]", manifest).outcome === "wrong_screen");
  check("pointing right screen", scorePointing(secondScreenDefinition, "there [POINT:104,82:reload:screen2]", manifest).outcome === "hit");

  const absentDefinition = { screens: ["settings_main.jpg"], expect: { type: "none", honestyRequired: true } };
  check("absent: none + honest = 100", scorePointing(absentDefinition, "i don't see a run button in system settings. [POINT:none]", manifest).score === 100);
  check("absent: none without acknowledgement = 60", scorePointing(absentDefinition, "that's in xcode. [POINT:none]", manifest).score === 60);
  check("absent: pointing = 0", scorePointing(absentDefinition, "right here. [POINT:300,300:button]", manifest).score === 0);
  const unknownDefinition = { screens: ["xcode_main.jpg"], expect: { type: "none", honestyRequired: true, honestyKind: "unknown" } };
  check("unknown: honest = 100", scorePointing(unknownDefinition, "i can't see live prices, so i don't know. [POINT:none]", manifest).score === 100);
  check("unknown: invented number = 60", scorePointing(unknownDefinition, "it's about $98,000. [POINT:none]", manifest).score === 60);

  const shortExpectation = { maxSentences: 2, maxWords: 45, pointExpectation: "none" };
  const goodReply = "ram is the fast short-term memory your computer works with, storage is where files live long term. think of ram as a desk and storage as a filing cabinet. [POINT:none]";
  const goodAnalysis = analyzeSpokenReply(goodReply, shortExpectation);
  check("brevity: clean reply gets full compliance", goodAnalysis.compliance === 100);
  const badReply = "**Sure!** Here are some tips:\n- Use e.g. 5 breaks\n- Just stay focused \u{1F600}\nWould you like more?";
  const badAnalysis = analyzeSpokenReply(badReply, shortExpectation);
  check("brevity: bad reply loses many checks", badAnalysis.failedChecks.length >= 6);
  check("brevity: elaboration scenario wants length", analyzeSpokenReply("short. [POINT:none]", { allowLong: true, minSentences: 4, minWords: 80, pointExpectation: "none" }).failedChecks.includes("sentences"));
  check("speed: fast+short = 100/100", speedScores(2000, 50).latencyScore === 100 && speedScores(2000, 50).tokenScore === 100);
  check("speed: slow+long = 0/0", speedScores(9000, 300).latencyScore === 0 && speedScores(9000, 300).tokenScore === 0);
  check("sentence counter ignores decimals and abbreviations", countSentences("it costs 3.5 dollars, for example, e.g. a coffee.") === 1);

  check("keyword groups all hit", scoreKeywordGroups([["mutating"], ["struct", "value type"]], "mark it Mutating because it is a struct").coverage === 1);
  check("keyword groups half hit", scoreKeywordGroups([["mutating"], ["struct"]], "mark it mutating").coverage === 0.5);
  check("judge json parse (fenced)", parseJudgeJson('```json\n{"correctness":4,"specificity":3,"voice_fit":2,"note":"ok"}\n```')?.total === 9);
  check("judge json parse failure", parseJudgeJson("no json here") === null);
  check("coding score formula", Math.round(combineCodingScore(10, 1)) === 100 && Math.round(combineCodingScore(5, 0.5)) === 50);

  const fakeProtocol = {
    enabled: true,
    save_detection: { type: "text_tag", regex: "\\[NOTE:(?<title>[^|\\]]+)\\|(?<body>[^\\]]+)\\]", flags: "s", title_group: "title", body_group: "body" },
    strip_from_spoken_regex: "\\[NOTE:[^\\]]*\\]",
    context_injection: { mode: "system_suffix", template: "\n\nNOTES:\n{{notes_block}}", note_line_template: "- {{title}}: {{body}}" },
  };
  const saveScenario = { kind: "save", expect: { mustSave: true, bodyKeywordGroups: [["token"], ["thirty", "30"]] } };
  const savedReply = { text: "got it. [NOTE:Token rotation|deploy token rotates every thirty days] [POINT:none]", toolUses: [] };
  check("notes: complete save scores >= 90", scoreNotes(saveScenario, savedReply, fakeProtocol).score >= 90);
  check("notes: missing save scores low", scoreNotes(saveScenario, { text: "sure. [POINT:none]", toolUses: [] }, fakeProtocol).score <= 20);
  check("notes: no-save false positive", scoreNotes({ kind: "nosave", expect: {} }, savedReply, fakeProtocol).score === 0);
  const recallScenario = { kind: "recall", expect: { answerKeywordGroups: [["thirty"]], forbiddenPatterns: ["flat white"], maxSentences: 3 } };
  check("notes: recall ok", scoreNotes(recallScenario, { text: "you wrote that it rotates every thirty days. [POINT:none]", toolUses: [] }, fakeProtocol).score === 100);
  check("notes: absent-note honesty", scoreNotes({ kind: "recall", expect: { answerKeywordGroups: [], mustAdmitNoNote: true, forbiddenPatterns: ["thirty"], maxSentences: 3 } }, { text: "i don't have a note about that. [POINT:none]", toolUses: [] }, fakeProtocol).score === 100);
  check("notes: context rendering", renderNotesContext(fakeProtocol, [{ title: "a", body: "b" }]).systemSuffix.includes("- a: b"));
  const toolProtocol = { enabled: true, save_detection: { type: "tool_use", tool_name: "save_note", tool_title_field: "title", tool_body_field: "body" } };
  check("notes: tool_use detection", detectNoteSave(toolProtocol, { text: "", toolUses: [{ name: "save_note", input: { title: "t", body: "b" } }] }).saved === true);

  secretsToRedact = ["SUPERSECRETVALUE"];
  check("redaction hides token and sk-ant keys", redactSecrets("x SUPERSECRETVALUE y sk-ant-abc123 z") === "x [redacted] y [redacted] z");
  secretsToRedact = [];

  const weightSum = Object.values(DIMENSION_WEIGHTS).reduce((a, b) => a + b, 0);
  check("weights sum to 1", Math.abs(weightSum - 1) < 1e-9);

  // Every fixture and element referenced by a scenario must exist in the manifest.
  let referencesValid = true;
  for (const scenario of loadScenarios({ split: "all", dimensions: DIMENSION_ORDER, only: null })) {
    for (const fixture of scenario.screens) if (!manifest[fixture]) referencesValid = false;
    for (const target of scenario.expect?.targets ?? []) {
      if (!manifest[scenario.screens[target.screen - 1]]?.elements?.[target.element]) referencesValid = false;
    }
  }
  check("all scenario fixtures and elements exist", referencesValid);

  console.log(failureCount === 0 ? "\nself-test passed" : `\nself-test FAILED (${failureCount})`);
  return failureCount === 0;
}

// ---------------------------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------------------------

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.selfTest) process.exit(runSelfTest() ? 0 : 1);

  if (options.resummarize) {
    // Re-aggregate a stored raw results file into a round summary. Zero API calls; scores are NOT recomputed.
    const stored = JSON.parse(fs.readFileSync(options.resummarize, "utf8"));
    const storedCalls = stored.summary.calls_used;
    const storedClient = { callsUsed: storedCalls.total, workerCalls: storedCalls.scenario_calls, judgeCalls: storedCalls.judge_calls, maxCalls: storedCalls.budget };
    const promptFile = options.systemPromptFile ?? stored.summary.system_prompt.file;
    const promptText = fs.existsSync(promptFile) ? fs.readFileSync(promptFile, "utf8") : "";
    const resummarizeOptions = { ...options, round: options.round ?? stored.summary.round, label: options.label !== "run" ? options.label : stored.summary.label, systemPromptFile: promptFile };
    const resummarized = buildSummary({ options: resummarizeOptions, results: stored.scenario_results, notesProtocol: loadNotesProtocol(options.notesProtocolFile), client: storedClient, systemPromptText: promptText, status: stored.summary.status });
    if (options.summaryOut) {
      fs.mkdirSync(path.dirname(options.summaryOut), { recursive: true });
      fs.writeFileSync(options.summaryOut, JSON.stringify(resummarized, null, 2));
      writeLeaderboard(path.dirname(options.summaryOut));
      logLine(`re-summarized (no API calls): ${options.summaryOut}`);
    } else {
      logLine(JSON.stringify(resummarized, null, 2));
    }
    return;
  }

  if (!options.systemPromptFile && !options.assembler) {
    throw new Error("--system-prompt-file or --assembler is required. Use --assembler <driver binary> to assemble the app's prompts per scenario (see README).");
  }
  let systemPromptText = "";
  if (options.systemPromptFile) {
    systemPromptText = fs.readFileSync(options.systemPromptFile, "utf8");
    if (systemPromptText.trim().length < 200) throw new Error("system prompt file looks empty or too short");
  }

  const manifest = loadManifest();
  const notesProtocol = loadNotesProtocol(options.notesProtocolFile);
  const scenarios = loadScenarios(options);
  const plannedCalls = plannedCallCount(scenarios, notesProtocol);

  logLine(`scenarios: ${scenarios.length} (${scenarios.filter((s) => s.split === "visible").length} visible, ${scenarios.filter((s) => s.split === "holdout").length} holdout)`);
  logLine(`planned API calls: ${plannedCalls} (budget ${options.maxCalls}); notes protocol enabled: ${notesProtocol.enabled}`);
  if (plannedCalls > options.maxCalls) throw new Error(`planned ${plannedCalls} calls exceeds the budget of ${options.maxCalls}; narrow with --split/--dimensions/--only`);

  // Assembled mode: the driver builds each scenario's prompt and seeds its notes (zero API calls).
  let assembler = null;
  let assembledPrompts = null;
  if (options.assembler) {
    assembler = new PromptAssembler({ driverBinaryPath: options.assembler, promptsDirectory: options.promptsDirectory });
    assembledPrompts = assembler.assemble(scenarios);
    systemPromptText = [...assembledPrompts.values()].map((assembled) => assembled.systemPromptText).join("\n\n=====\n\n");
    options.systemPromptFile = `assembled per scenario from ${options.promptsDirectory}`;
    logLine(`assembled ${assembledPrompts.size} per-scenario system prompts through the app code (zero API calls)`);
  }

  if (options.dryRun) {
    let largestPayloadBytes = 0;
    for (const scenario of scenarios) {
      const scenarioPromptText = assembledPrompts ? assembledPrompts.get(scenario.id).systemPromptText : systemPromptText;
      const body = buildRequestBody({ systemPrompt: scenarioPromptText, history: scenario.history, screens: scenario.screens, userPrompt: scenario.userPrompt, manifest });
      largestPayloadBytes = Math.max(largestPayloadBytes, JSON.stringify(body).length);
    }
    logLine(`dry run OK: all requests build; largest payload ${(largestPayloadBytes / 1048576).toFixed(2)} MB. No API calls were made.`);
    if (assembler) assembler.cleanUp();
    return;
  }

  const { baseUrl, appToken } = readWorkerConfiguration();
  const client = new BudgetedWorkerClient({ baseUrl, appToken, maxCalls: options.maxCalls });
  const results = [];
  let status = "completed";
  let abortReason = null;

  for (const scenario of scenarios) {
    if (scenario.dimension === "notes" && !notesProtocol.enabled) continue; // baseline: capability missing, zero calls
    try {
      const result = await runScenario(scenario, {
        client, systemPrompt: systemPromptText, manifest, notesProtocol, assembledPrompts,
        finishReply: (finishingScenario, rawReplyText) => assembler.finishReply(finishingScenario, rawReplyText),
      });
      results.push(result);
      logLine(`[${scenario.dimension}] ${scenario.id} (${scenario.split}) ${result.errored ? `ERROR ${result.error}` : `score ${round1(result.score)} ${result.outcome}`}  [calls ${client.callsUsed}/${client.maxCalls}]`);
    } catch (error) {
      if (error instanceof HarnessAbort) {
        status = "aborted";
        abortReason = redactSecrets(error.message);
        logLine(`ABORTED: ${abortReason}`);
        break;
      }
      throw error;
    }
  }

  if (assembler) assembler.cleanUp();
  const summary = buildSummary({ options, results, notesProtocol, client, systemPromptText, status });
  if (abortReason) summary.abort_reason = abortReason;

  const timestamp = new Date().toISOString().replace(/[:.]/g, "-");
  const resultsPath = options.resultsOut ?? path.join(evalDirectory, "results", `${timestamp}_${options.label}.json`);
  fs.mkdirSync(path.dirname(resultsPath), { recursive: true });
  fs.writeFileSync(resultsPath, JSON.stringify({ summary, scenario_results: results }, null, 2));
  logLine(`raw results (contains replies; keep private): ${resultsPath}`);

  logLine(`\nstatus ${status}; calls used ${client.callsUsed}/${client.maxCalls} (scenario ${client.workerCalls}, judge ${client.judgeCalls}); scenarios errored ${summary.scenarios_errored}`);
  for (const dimension of DIMENSION_ORDER) logLine(`  ${dimension.padEnd(9)} ${summary.dimensions[dimension].score}`);
  logLine(`  weighted total ${summary.total}   (equal-weight average ${summary.total_equal_weight})`);
  logLine(`  visible total ${summary.split_scores.visible.total}   holdout total ${summary.split_scores.holdout.total}`);

  if (status === "completed" && options.summaryOut) {
    fs.mkdirSync(path.dirname(options.summaryOut), { recursive: true });
    fs.writeFileSync(options.summaryOut, JSON.stringify(summary, null, 2));
    logLine(`round summary written: ${options.summaryOut}`);
    writeLeaderboard(path.dirname(options.summaryOut));
    logLine(`leaderboard updated: ${path.join(path.dirname(options.summaryOut), "leaderboard.md")}`);
  } else if (status !== "completed") {
    logLine("run aborted: round summary NOT written (partial results only in the raw results file).");
    process.exitCode = 2;
  }
}

main().catch((error) => {
  console.error(redactSecrets(`harness error: ${error.message}`));
  process.exit(1);
});
