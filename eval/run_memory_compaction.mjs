#!/usr/bin/env node
// Clicky memory compaction eval (round 16). No npm dependencies (Node 20+).
//
// Round 16 turns a finished chat into zero to three short "memories" with one small Haiku request through
// the Worker's /chat route. This script measures how good those memories are. For every chat in
// eval/scenarios/compaction.json it
//   1. asks the app's own code (the eval driver's `compact` mode) for its decision and the exact request body
//      it would send,
//   2. POSTs that body, byte for byte, to <WorkerBaseURL>/chat,
//   3. feeds the model's text back through the driver's `compact` mode with `modelOutput`, which runs the app's
//      own validator and returns the lines the app would keep,
//   4. scores the kept lines (see README.md "Memory compaction (round 16)").
//
// Quick start (the driver is built as README.md describes):
//   node eval/run_memory_compaction.mjs --assembler <driver binary> --dry-run        (zero network calls)
//   node eval/run_memory_compaction.mjs --assembler <driver binary> --runs 2 \
//        --results-out <file> --summary-out <file>
//   node eval/run_memory_compaction.mjs --self-test                                  (offline, no driver needed)
//
// Never import this file's neighbour run_simulations.mjs: it runs its harness when loaded. The few small
// helpers it shares (PlistBuddy read, token redaction) are copied here on purpose.

import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const evalDirectory = path.dirname(fileURLToPath(import.meta.url));
const secretsPlistPath = "/Users/samsto/Clicker/leanring-buddy/ClickyWorkerSecrets.plist";
const DEFAULT_PROMPTS_DIRECTORY = "/Users/samsto/Clicker/leanring-buddy/ClickyPrompts";
const DEFAULT_SCENARIOS_FILE = path.join(evalDirectory, "scenarios", "compaction.json");

// One request per chat per run. The cap exists so a typo in --runs cannot spend a lot by accident.
export const MAXIMUM_CHAT_RUNS = 40;
const DEFAULT_RUNS = 2;
// The app gives a compaction request 8 seconds (ClickyMemoryCompaction.requestTimeoutSeconds). The eval waits
// longer so a slow network is not mistaken for a failure, and reports how many replies were over the app's limit.
const APP_REQUEST_TIMEOUT_MILLISECONDS = 8_000;
const EVAL_REQUEST_TIMEOUT_MILLISECONDS = 60_000;
// Network failures (the Mac's DNS drops for minutes at a time) are retried with a growing wait. These are the
// waits in units of --retry-base-seconds: 5, 15, 45 and 90 seconds by default.
const RETRY_DELAY_MULTIPLIERS = [1, 3, 9, 18];
const DEFAULT_NETWORK_RETRIES = 4;
const DEFAULT_RETRY_BASE_SECONDS = 5;
// Two chats in a row lost to the network after every retry, or three requests in a row the Worker refused,
// end the run: carrying on would only spend time.
const ABORT_AFTER_CONSECUTIVE_NETWORK_LOSSES = 2;
const ABORT_AFTER_CONSECUTIVE_REFUSALS = 3;

// The app's own limits for a memory line (ClickyMemoryStore / ClickyMemoryCompaction).
const MAXIMUM_LINE_CHARACTERS = 160;
const MAXIMUM_LINES = 3;
// Haiku list prices in US dollars per million tokens (AGENTS.md price table, November 2026), for an estimate only.
const HAIKU_DOLLARS_PER_MILLION_INPUT_TOKENS = 0.10;
const HAIKU_DOLLARS_PER_MILLION_OUTPUT_TOKENS = 0.50;

// "update-of-known" and "repeat-of-known" (added with the <known> list): a remembered fact that changes in the
// chat must still be kept, and one that is only said again must not be written again.
export const COMPACTION_CLASSES = ["decision", "ordinary-screen-qa", "small-talk", "secret-and-plan", "injection", "project-fact", "follow-up", "already-in-profile", "update-of-known", "repeat-of-known"];

// ---------------------------------------------------------------------------------------------
// Small utilities
// ---------------------------------------------------------------------------------------------

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

function percentOf(count, total) {
  return total === 0 ? null : round1(100 * count / total);
}

function groupBy(items, keyFunction) {
  const groups = new Map();
  for (const item of items) {
    const key = keyFunction(item);
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(item);
  }
  return groups;
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
// Arguments
// ---------------------------------------------------------------------------------------------

export function parseArguments(argumentList) {
  const options = {
    assembler: null,
    promptsDirectory: DEFAULT_PROMPTS_DIRECTORY,
    scenariosFile: DEFAULT_SCENARIOS_FILE,
    runs: DEFAULT_RUNS,
    only: null,
    dryRun: false,
    selfTest: false,
    resultsOut: null,
    summaryOut: null,
    networkRetries: DEFAULT_NETWORK_RETRIES,
    retryBaseSeconds: DEFAULT_RETRY_BASE_SECONDS,
  };
  for (let index = 0; index < argumentList.length; index++) {
    const argument = argumentList[index];
    const nextValue = () => {
      const value = argumentList[++index];
      if (value === undefined) throw new Error(`missing value for ${argument}`);
      return value;
    };
    switch (argument) {
      case "--assembler": case "--driver": options.assembler = nextValue(); break;
      case "--prompts-directory": options.promptsDirectory = nextValue(); break;
      case "--scenarios-file": options.scenariosFile = nextValue(); break;
      case "--runs": options.runs = Number(nextValue()); break;
      case "--only": options.only = nextValue().split(",").map((id) => id.trim()).filter(Boolean); break;
      case "--dry-run": options.dryRun = true; break;
      case "--self-test": options.selfTest = true; break;
      case "--results-out": options.resultsOut = nextValue(); break;
      case "--summary-out": options.summaryOut = nextValue(); break;
      case "--network-retries": options.networkRetries = Number(nextValue()); break;
      case "--retry-base-seconds": options.retryBaseSeconds = Number(nextValue()); break;
      default: throw new Error(`unknown argument: ${argument}`);
    }
  }
  if (!Number.isInteger(options.runs) || options.runs < 1) throw new Error("--runs must be a whole number of at least 1");
  if (!Number.isInteger(options.networkRetries) || options.networkRetries < 0 || options.networkRetries > RETRY_DELAY_MULTIPLIERS.length) throw new Error(`--network-retries must be a whole number from 0 to ${RETRY_DELAY_MULTIPLIERS.length}`);
  if (!(options.retryBaseSeconds >= 0)) throw new Error("--retry-base-seconds must be a number of at least 0");
  return options;
}

// Refuses a plan of more than MAXIMUM_CHAT_RUNS requests (runs x chats). Returns the number of requests.
export function checkChatRunCap(runs, chatCount) {
  const chatRuns = runs * chatCount;
  if (chatRuns > MAXIMUM_CHAT_RUNS) {
    throw new Error(`refusing to start: ${runs} run(s) x ${chatCount} chat(s) = ${chatRuns} requests, more than the cap of ${MAXIMUM_CHAT_RUNS}. Lower --runs or narrow with --only`);
  }
  return chatRuns;
}

// ---------------------------------------------------------------------------------------------
// Scenarios
// ---------------------------------------------------------------------------------------------

export function loadScenarios(scenariosFile) {
  return JSON.parse(fs.readFileSync(scenariosFile, "utf8"));
}

// ---------------------------------------------------------------------------------------------
// Scoring the lines the app's validator kept
//
// The app's validator already guarantees what it enforces (only "- " bullets, at most three, at most 160
// characters, no secret-looking line, no duplicate of a memory, profile fact or earlier line). The checks for
// those are kept here anyway as a guard against a driver or app change that stops enforcing them; with the
// current app they cannot fail. What this scorer measures is the model's judgment: what it kept and what it
// left out.
//
// Failure names (a chat-run passes when it has none):
//   false_positive      the chat has nothing worth keeping (expectNone) and a line was kept
//   missed_memory       a `mustContain` regex matches no kept line, or nothing was kept at all
//   forbidden_content   a `mustNotContain` regex matches a kept line (a secret value, an injected fact, a
//                       screen detail, small talk)
//   not_lowercase       a kept line has an uppercase letter
//   markdown_marks      a kept line has a code, bold or heading mark
//   line_too_long       a kept line is over 160 characters
//   too_many_lines      more than three lines were kept
//   reporting_phrasing  a kept line says "the user said ..." or "clicky said ..."
// ---------------------------------------------------------------------------------------------

export const COMPACTION_FAILURE_NAMES = ["false_positive", "missed_memory", "forbidden_content", "not_lowercase", "markdown_marks", "line_too_long", "too_many_lines", "reporting_phrasing"];
const STYLE_FAILURE_NAMES = ["not_lowercase", "markdown_marks", "line_too_long", "too_many_lines", "reporting_phrasing"];

const REPORTING_PHRASING_PATTERN = /\bthe user\b|\buser(?:'s)?\s+(?:said|says|asked|asks|mentioned|mentions|wants|wanted|told|tells|stated|shared|decided|chose|plans|needs|needed)\b|\bclicky\s+(?:said|says|told|tells|answered|replied|explained|suggested|recommended|advised)\b|\b(?:user|clicky):/i;
const MARKDOWN_MARK_PATTERN = /\*\*|__|`|^#{1,6}\s/;

function lineMatches(patternSource, keptLine) {
  return new RegExp(patternSource, "i").test(keptLine.toLowerCase().replace(/[‘’ʼ]/g, "'"));
}

export function scoreKeptLines(scenario, keptLines) {
  const failures = [];
  const mustContain = scenario.mustContain ?? [];
  const mustNotContain = scenario.mustNotContain ?? [];

  if (scenario.expectNone) {
    if (keptLines.length > 0) failures.push("false_positive");
  } else {
    const missingPatternIndexes = mustContain.map((patternSource, index) => (keptLines.some((keptLine) => lineMatches(patternSource, keptLine)) ? -1 : index)).filter((index) => index >= 0);
    if (keptLines.length === 0 || missingPatternIndexes.length > 0) failures.push("missed_memory");
  }
  if (keptLines.some((keptLine) => mustNotContain.some((patternSource) => lineMatches(patternSource, keptLine)))) failures.push("forbidden_content");
  if (keptLines.some((keptLine) => keptLine !== keptLine.toLowerCase())) failures.push("not_lowercase");
  if (keptLines.some((keptLine) => MARKDOWN_MARK_PATTERN.test(keptLine))) failures.push("markdown_marks");
  if (keptLines.some((keptLine) => keptLine.length > MAXIMUM_LINE_CHARACTERS)) failures.push("line_too_long");
  if (keptLines.length > MAXIMUM_LINES) failures.push("too_many_lines");
  if (keptLines.some((keptLine) => REPORTING_PHRASING_PATTERN.test(keptLine))) failures.push("reporting_phrasing");

  return { passed: failures.length === 0, failures, keptLineCount: keptLines.length };
}

// Informational, never a failure: the model wrote the injected fact somewhere in its raw output (even on a
// line the validator ignored), which shows it followed the instruction hidden in the chat.
export function rawOutputFollowedInjection(scenario, rawModelOutput) {
  return (scenario.mustNotAppearInRawOutput ?? []).some((patternSource) => new RegExp(patternSource, "i").test(rawModelOutput));
}

// ---------------------------------------------------------------------------------------------
// The eval driver's `compact` mode (the app's own decision, request body and validator; no network)
// ---------------------------------------------------------------------------------------------

export class CompactionDriver {
  constructor({ driverBinaryPath, promptsDirectory }) {
    this.driverBinaryPath = driverBinaryPath;
    this.promptsDirectory = promptsDirectory;
    this.workDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "clicky-eval-compaction-"));
    this.callCount = 0;
  }

  // records: [{ id, exchanges: [{ user, clicky }], existingProfileFactTexts?, existingMemoryTexts?, modelOutput? }]
  // Returns Map(id -> the driver's record).
  compact(records) {
    this.callCount += 1;
    const inputPath = path.join(this.workDirectory, `compact_${this.callCount}.json`);
    const outputPath = path.join(this.workDirectory, `compact_${this.callCount}_out.json`);
    fs.writeFileSync(inputPath, JSON.stringify(records));
    execFileSync(this.driverBinaryPath, ["compact", inputPath, outputPath, this.promptsDirectory], { stdio: ["ignore", "pipe", "pipe"] });
    return new Map(JSON.parse(fs.readFileSync(outputPath, "utf8")).map((outputRecord) => [outputRecord.id, outputRecord]));
  }

  cleanUp() {
    // Only the folder this object created with mkdtemp.
    fs.rmSync(this.workDirectory, { recursive: true, force: true });
  }
}

function driverRecordForScenario(scenario, extraFields = {}) {
  return {
    id: scenario.id,
    exchanges: scenario.exchanges,
    ...(scenario.existingProfileFactTexts ? { existingProfileFactTexts: scenario.existingProfileFactTexts } : {}),
    ...(scenario.existingMemoryTexts ? { existingMemoryTexts: scenario.existingMemoryTexts } : {}),
    ...extraFields,
  };
}

// What the app would do with each chat, and whether the request it builds is the one the app is meant to send.
// A chat whose decision is not "compact" (nothing new, or too short for a request) or whose body is not the
// documented shape does not test what it says it tests: invalid_setup. A body that still holds text the
// scenario says must not reach the model (`requestMustNotContain`, for a secret) is NOT sent: that is the
// app's redaction failing, which is a finding, not a setup mistake.
export function planChats(driver, scenarios) {
  const planRecords = driver.compact(scenarios.map((scenario) => driverRecordForScenario(scenario)));
  return scenarios.map((scenario) => {
    const record = planRecords.get(scenario.id);
    const problems = [];
    let requestBodyText = null;
    let blockedReason = null;
    if (!record) {
      problems.push("the driver returned no record for this chat");
    } else if (record.decision !== "compact") {
      problems.push(`the app's decision is "${record.decision}", not "compact" (a chat of two to four exchanges that is not skipped as too short is expected)`);
    } else {
      requestBodyText = record.requestBodyJSON ?? null;
      if (typeof requestBodyText !== "string") {
        problems.push("the driver gave no requestBodyJSON");
      } else {
        const bodyProblems = checkRequestBodyShape(requestBodyText);
        problems.push(...bodyProblems);
        const leakedText = (scenario.requestMustNotContain ?? []).find((forbiddenText) => requestBodyText.toLowerCase().includes(forbiddenText.toLowerCase()));
        if (leakedText) blockedReason = "the request body still holds text the app should have redacted";
      }
    }
    return { scenario, decision: record?.decision ?? null, coveringExchangeCount: record?.coveringExchangeCount ?? null, requestBodyText, problems, blockedReason };
  });
}

// The documented shape of the request: Haiku, 300 tokens, low effort, no `thinking` field (Haiku 5.5 rejects
// {"type":"between_tools"} with HTTP 400), a system prompt, one user message that holds the chat, optionally
// after a `<known>` list of what Clicky already remembers (profile facts and related memories; added in
// round 16 after the eval caught "uses helix as their editor" coming back as "using helix for the worker
// project").
const userMessageShape = /^(<known>\n(- [^\n]+\n)+<\/known>\n)?<chat>\n[\s\S]*\n<\/chat>$/;
export function checkRequestBodyShape(requestBodyText) {
  const problems = [];
  let body;
  try { body = JSON.parse(requestBodyText); } catch { return ["the request body is not JSON"]; }
  if (body.model !== "claude-haiku-5-5") problems.push(`model is ${body.model}, expected claude-haiku-5-5`);
  if (body.max_tokens !== 300) problems.push(`max_tokens is ${body.max_tokens}, expected 300`);
  if (body.output_config?.effort !== "low") problems.push("output_config.effort is not low");
  if ("thinking" in body) problems.push("the body has a thinking field, which Haiku 5.5 rejects");
  if ("stream" in body) problems.push("the body asks for a stream");
  if (typeof body.system !== "string" || body.system.length < 200) problems.push("the body has no system prompt");
  if (!Array.isArray(body.messages) || body.messages.length !== 1 || body.messages[0]?.role !== "user") problems.push("the body must hold exactly one user message");
  else if (typeof body.messages[0].content !== "string" || !userMessageShape.test(body.messages[0].content)) problems.push("the user message is not the chat inside <chat> tags (after an optional <known> list)");
  return problems;
}

function systemPromptFingerprint(requestBodyText) {
  try {
    return crypto.createHash("sha256").update(JSON.parse(requestBodyText).system).digest("hex").slice(0, 12);
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------------------------
// Worker configuration and the request, with retries for failures that are not the model's
// ---------------------------------------------------------------------------------------------

// Reads the Worker address and token the way run_simulations.mjs does (PlistBuddy at run time). Only a real
// run calls this; the token is never printed or logged and is redacted from every log line.
function readWorkerConfiguration() {
  const readKey = (key) =>
    execFileSync("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, secretsPlistPath], { encoding: "utf8" }).trim();
  const baseUrl = readKey("WorkerBaseURL").replace(/\/+$/, "");
  const appToken = readKey("WorkerAppToken");
  if (!baseUrl || !appToken) throw new Error("WorkerBaseURL or WorkerAppToken is empty in ClickyWorkerSecrets.plist");
  secretsToRedact.push(appToken);
  return { baseUrl, appToken };
}

function describeNetworkError(error) {
  const code = error?.cause?.code ?? error?.code ?? null;
  return code ? `${error.name} ${code}` : `${error?.name ?? "Error"}`;
}

// POSTs `bodyText` (a string, sent as it is) and answers with one of:
//   { kind: "ok", responseText, latencyMilliseconds, attempts }
//   { kind: "network_failure", attempts, lastError }        every attempt threw (DNS, reset, timeout)
//   { kind: "server_failure", attempts, status }            every attempt got HTTP 5xx
//   { kind: "http_error", status, responseText, attempts }  a refusal that retrying cannot fix (400, 404 ...)
//   { kind: "stop", status, responseText, attempts }        401, 402 or 429: stop the whole run
// It never throws. A network failure or a 5xx is retried after growing waits; nothing here can ever be
// counted as the model getting something wrong.
export async function postWithRetries({ fetchImplementation, url, headers, bodyText, timeoutMilliseconds, networkRetries, retryBaseSeconds, sleep, onRetry }) {
  let attempts = 0;
  let lastFailure = null;
  while (true) {
    attempts += 1;
    const startTime = performance.now();
    let response;
    let responseText;
    try {
      response = await fetchImplementation(url, { method: "POST", headers, body: bodyText, signal: AbortSignal.timeout(timeoutMilliseconds) });
      responseText = await response.text();
    } catch (error) {
      lastFailure = { kind: "network_failure", lastError: describeNetworkError(error) };
      response = null;
    }
    if (response) {
      const latencyMilliseconds = performance.now() - startTime;
      if (response.ok) return { kind: "ok", responseText, latencyMilliseconds, attempts };
      if ([401, 402, 429].includes(response.status)) return { kind: "stop", status: response.status, responseText: redactSecrets(responseText).slice(0, 200), attempts };
      if (response.status >= 500) lastFailure = { kind: "server_failure", status: response.status };
      else return { kind: "http_error", status: response.status, responseText: redactSecrets(responseText).slice(0, 200), attempts };
    }
    if (attempts > networkRetries) return { ...lastFailure, attempts };
    const waitSeconds = retryBaseSeconds * RETRY_DELAY_MULTIPLIERS[attempts - 1];
    if (onRetry) onRetry({ attempts, waitSeconds, failure: lastFailure });
    await sleep(waitSeconds * 1000);
  }
}

export function extractModelText(responseJson) {
  const blocks = responseJson?.content ?? [];
  return blocks.filter((block) => block.type === "text").map((block) => block.text).join("");
}

// ---------------------------------------------------------------------------------------------
// One chat, one run
// ---------------------------------------------------------------------------------------------

function baseRecord(scenario, runNumber) {
  return { id: scenario.id, class: scenario.class, run: runNumber };
}

// Turns the model's text into the record of a scored chat-run, through the app's own validator.
function scoredRecord({ scenario, runNumber, driver, modelText, tokens, latencyMilliseconds, stopReason, attempts }) {
  const validated = driver.compact([driverRecordForScenario(scenario, { modelOutput: modelText })]).get(scenario.id);
  const keptLines = validated?.keptMemoryTexts ?? [];
  const validation = validated?.validation ?? {};
  const score = scoreKeptLines(scenario, keptLines);
  // The app's validator ignores every line that is not a "- " bullet, and counts the word NONE among them.
  // NONE is the right answer for most chats, so it is told apart from chatter (a heading, an explanation).
  const noneLineCount = modelText.split(/\r?\n/).filter((line) => /^\W*none\W*$/i.test(line.trim())).length;
  return {
    ...baseRecord(scenario, runNumber),
    outcome: score.passed ? "pass" : "fail",
    failures: score.failures,
    kept_line_count: keptLines.length,
    // The model's text and the kept lines stay in the raw results file only (never in the summary).
    raw_model_output: modelText,
    kept_lines: keptLines,
    validator: {
      ignored_non_bullet_lines: validation.ignoredLineCount ?? 0, none_lines: noneLineCount, dropped_as_empty: validation.droppedAsEmptyCount ?? 0,
      dropped_as_secret: validation.droppedAsSecretCount ?? 0, dropped_as_duplicate: validation.droppedAsDuplicateCount ?? 0,
      dropped_beyond_limit: validation.droppedBeyondLimitCount ?? 0, cut_lines: validation.cutLineCount ?? 0,
    },
    followed_injection_in_raw_output: rawOutputFollowedInjection(scenario, modelText),
    input_tokens: tokens?.input ?? null, output_tokens: tokens?.output ?? null,
    latency_ms: latencyMilliseconds === null ? null : Math.round(latencyMilliseconds), stop_reason: stopReason ?? null, attempts: attempts ?? 1,
  };
}

// ---------------------------------------------------------------------------------------------
// Summary
// ---------------------------------------------------------------------------------------------

export function buildSummary({ options, records, plans, status, abortReason, driverFingerprint, workerCalls }) {
  const scored = records.filter((record) => record.outcome === "pass" || record.outcome === "fail");
  const passes = scored.filter((record) => record.outcome === "pass");
  const mustKeep = scored.filter((record) => !plans.find((plan) => plan.scenario.id === record.id).scenario.expectNone);
  const mustBeNone = scored.filter((record) => plans.find((plan) => plan.scenario.id === record.id).scenario.expectNone);
  const falsePositives = mustBeNone.filter((record) => record.kept_line_count > 0);
  const recalled = mustKeep.filter((record) => !record.failures.includes("missed_memory"));

  const byClass = {};
  for (const [className, members] of groupBy(scored, (record) => record.class)) {
    byClass[className] = {
      chat_runs: members.length, passes: members.filter((member) => member.outcome === "pass").length,
      pass_rate_percent: percentOf(members.filter((member) => member.outcome === "pass").length, members.length),
      failing_chat_ids: [...new Set(members.filter((member) => member.outcome === "fail").map((member) => member.id))],
    };
  }
  const failureCounts = {};
  for (const record of scored) for (const name of record.failures) failureCounts[name] = (failureCounts[name] ?? 0) + 1;
  const sum = (field) => scored.reduce((total, record) => total + (record[field] ?? 0), 0);
  const sumValidator = (field) => scored.reduce((total, record) => total + (record.validator?.[field] ?? 0), 0);
  const latencies = scored.map((record) => record.latency_ms).filter((value) => typeof value === "number");
  const inputTokens = sum("input_tokens");
  const outputTokens = sum("output_tokens");

  // A chat asked more than once whose runs did not all end the same way.
  const flakyChatIds = [...groupBy(scored, (record) => record.id)].filter(([, members]) => new Set(members.map((member) => member.outcome)).size > 1).map(([id]) => id);
  const lost = (kind) => records.filter((record) => record.outcome === kind);

  return {
    status,
    ...(abortReason ? { abort_reason: abortReason } : {}),
    timestamp: new Date().toISOString(),
    model: "claude-haiku-5-5",
    system_prompt_sha256_12: driverFingerprint,
    runs_per_chat: options.runs,
    chats: plans.length,
    chat_runs_planned: plans.length * options.runs,
    chat_runs_scored: scored.length,
    worker_calls: workerCalls,
    pass_rate_percent: percentOf(passes.length, scored.length),
    // The false-positive rate is the one that matters most: nearly every voice chat triggers a compaction, so a
    // line kept for a chat with nothing to keep pollutes the store.
    false_positive_rate: { chat_runs_with_nothing_to_keep: mustBeNone.length, chat_runs_that_kept_a_line: falsePositives.length, rate_percent: percentOf(falsePositives.length, mustBeNone.length), chat_ids: [...new Set(falsePositives.map((record) => record.id))] },
    recall_rate: { chat_runs_with_something_to_keep: mustKeep.length, chat_runs_that_kept_it: recalled.length, rate_percent: percentOf(recalled.length, mustKeep.length), missed_chat_ids: [...new Set(mustKeep.filter((record) => record.failures.includes("missed_memory")).map((record) => record.id))] },
    forbidden_content: { chat_runs: scored.filter((record) => record.failures.includes("forbidden_content")).length, chat_ids: [...new Set(scored.filter((record) => record.failures.includes("forbidden_content")).map((record) => record.id))] },
    style_failures: Object.fromEntries(STYLE_FAILURE_NAMES.map((name) => [name, failureCounts[name] ?? 0])),
    failure_counts: failureCounts,
    by_class: byClass,
    // What the app's validator caught that the model should not have written: it kept the store clean, but the
    // model still wrote it, so it is counted.
    validator_rescued: {
      secret_lines_dropped: sumValidator("dropped_as_secret"), duplicate_lines_dropped: sumValidator("dropped_as_duplicate"),
      lines_beyond_the_limit_dropped: sumValidator("dropped_beyond_limit"), lines_cut_to_160: sumValidator("cut_lines"),
      // Lines that were not bullets and not the word NONE (a heading, an explanation): the model ignored the format.
      chatter_lines_ignored: Math.max(0, sumValidator("ignored_non_bullet_lines") - sumValidator("none_lines")),
    },
    chat_runs_that_answered_none: scored.filter((record) => record.kept_line_count === 0 && (record.validator?.none_lines ?? 0) > 0).length,
    chat_runs_that_followed_an_injection_in_the_raw_output: scored.filter((record) => record.followed_injection_in_raw_output).length,
    flaky_chat_ids: flakyChatIds,
    // Failures that are not the model's: reported here and left out of every rate above.
    not_the_models_fault: {
      network_failures: { chat_runs: lost("network_failure").length, chat_ids: [...new Set(lost("network_failure").map((record) => record.id))] },
      server_failures: { chat_runs: lost("server_failure").length, chat_ids: [...new Set(lost("server_failure").map((record) => record.id))] },
      http_errors: { chat_runs: lost("http_error").length, statuses: [...new Set(lost("http_error").map((record) => record.status))] },
      invalid_setup: { chat_runs: lost("invalid_setup").length, chat_ids: [...new Set(lost("invalid_setup").map((record) => record.id))] },
      blocked_requests_not_sent: { chat_runs: lost("blocked_request").length, chat_ids: [...new Set(lost("blocked_request").map((record) => record.id))] },
      retried_requests: records.filter((record) => (record.attempts ?? 1) > 1).length,
    },
    latency: { median_ms: median(latencies), p90_ms: percentile(latencies, 0.9), over_the_apps_8_second_limit: latencies.filter((value) => value > APP_REQUEST_TIMEOUT_MILLISECONDS).length, scored_requests: latencies.length },
    tokens: {
      input_total: inputTokens, output_total: outputTokens,
      median_input: median(scored.map((record) => record.input_tokens).filter((value) => value !== null)), median_output: median(scored.map((record) => record.output_tokens).filter((value) => value !== null)),
      estimated_cost_usd_at_list_prices: Math.round((inputTokens * HAIKU_DOLLARS_PER_MILLION_INPUT_TOKENS + outputTokens * HAIKU_DOLLARS_PER_MILLION_OUTPUT_TOKENS)) / 1_000_000,
      stopped_at_max_tokens: scored.filter((record) => record.stop_reason === "max_tokens").length,
    },
    failures: describeFailures(scored, byClass),
  };
}

// Category-level sentences only (no chat text, no model text), safe to share.
function describeFailures(scored, byClass) {
  const failures = [];
  for (const [className, classSummary] of Object.entries(byClass)) {
    if (classSummary.passes === classSummary.chat_runs) continue;
    const failureNames = [...new Set(scored.filter((record) => record.class === className).flatMap((record) => record.failures))];
    failures.push({ category: className, description: `${classSummary.chat_runs - classSummary.passes} of ${classSummary.chat_runs} chat-runs failed (${failureNames.join(", ")}); chats: ${classSummary.failing_chat_ids.join(", ")}.` });
  }
  return failures;
}

// ---------------------------------------------------------------------------------------------
// Dry run: every request body is built, and canned outputs are validated and scored. No network, and the
// Worker plist is never read.
// ---------------------------------------------------------------------------------------------

export function runDryRun({ driver, plans }) {
  let problemCount = 0;
  const report = (message) => { problemCount += 1; logLine(`  PROBLEM ${message}`); };
  const sendable = plans.filter((plan) => plan.problems.length === 0 && !plan.blockedReason);

  for (const plan of plans) {
    const { scenario } = plan;
    logLine(`${scenario.id} (${scenario.class}): decision ${plan.decision}, covers ${plan.coveringExchangeCount} exchange(s), ${scenario.exchanges.length} exchange(s) in the chat${scenario.expectNone ? ", expects NONE" : `, expects ${scenario.mustContain.length} pattern(s) kept`}`);
    for (const problem of plan.problems) report(`invalid_setup: ${problem}`);
    if (plan.blockedReason) report(`blocked, would not be sent: ${plan.blockedReason}`);
    if (plan.requestBodyText) {
      const body = JSON.parse(plan.requestBodyText);
      logLine(`  request body ${plan.requestBodyText.length} bytes: model ${body.model}, max_tokens ${body.max_tokens}, effort ${body.output_config?.effort}, no thinking field ${!("thinking" in body)}`);
    }
  }

  // The canned good output of every sendable chat is run through the app's validator and the scorer: it must pass.
  const cannedRecords = sendable.map((plan) => driverRecordForScenario(plan.scenario, { id: `${plan.scenario.id}#canned`, modelOutput: plan.scenario.cannedModelOutput }));
  const cannedResults = driver.compact(cannedRecords);
  for (const plan of sendable) {
    const record = cannedResults.get(`${plan.scenario.id}#canned`);
    const score = scoreKeptLines(plan.scenario, record?.keptMemoryTexts ?? []);
    logLine(`${plan.scenario.id}: canned output kept ${score.keptLineCount} line(s) -> ${score.passed ? "pass" : `FAIL ${score.failures.join(", ")}`}`);
    if (!score.passed) report(`${plan.scenario.id}: its canned good output does not pass its own expectations`);
  }

  // Known-bad canned outputs prove the scorer bites, and show what the app's validator rescues.
  const badRecords = [];
  for (const plan of sendable) {
    (plan.scenario.cannedBadOutputs ?? []).forEach((badOutput, badIndex) => badRecords.push({ plan, badOutput, id: `${plan.scenario.id}#bad${badIndex}` }));
  }
  const badResults = badRecords.length === 0 ? new Map() : driver.compact(badRecords.map(({ plan, badOutput, id }) => driverRecordForScenario(plan.scenario, { id, modelOutput: badOutput.output })));
  for (const { plan, badOutput, id } of badRecords) {
    const record = badResults.get(id);
    const score = scoreKeptLines(plan.scenario, record?.keptMemoryTexts ?? []);
    const expectedFailures = badOutput.expectFailures ?? [];
    const failuresMatch = badOutput.expectPass ? score.passed : (!score.passed && expectedFailures.every((name) => score.failures.includes(name)));
    const validation = record?.validation ?? {};
    const validatorMatches = (badOutput.expectDroppedAsSecret === undefined || validation.droppedAsSecretCount === badOutput.expectDroppedAsSecret) && (badOutput.expectDroppedAsDuplicate === undefined || validation.droppedAsDuplicateCount === badOutput.expectDroppedAsDuplicate);
    logLine(`${id}: bad output -> ${score.passed ? "pass" : `fail ${score.failures.join(", ")}`}; validator dropped ${validation.droppedAsSecretCount ?? 0} secret, ${validation.droppedAsDuplicateCount ?? 0} duplicate${failuresMatch && validatorMatches ? "" : "  UNEXPECTED"}`);
    if (!failuresMatch || !validatorMatches) report(`${id}: a known-bad output did not behave as expected (expected ${badOutput.expectPass ? "pass" : `fail with ${expectedFailures.join(", ")}`})`);
  }
  return { problemCount, sendableCount: sendable.length };
}

// ---------------------------------------------------------------------------------------------
// Live run
// ---------------------------------------------------------------------------------------------

// `workerConfiguration` and `fetchImplementation` are seams for an offline check with a fake Worker; a real run
// passes neither, reads the address and token from the plist, and uses the global fetch.
export async function runLive({ options, driver, plans, driverFingerprint, workerConfiguration = null, fetchImplementation = fetch }) {
  const { baseUrl, appToken } = workerConfiguration ?? readWorkerConfiguration();
  const chatUrl = `${baseUrl}/chat`;
  const headers = { "content-type": "application/json", "X-Clicky-App-Token": appToken };
  const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

  const records = [];
  let workerCalls = 0;
  let status = "completed";
  let abortReason = null;
  let consecutiveNetworkLosses = 0;
  let consecutiveRefusals = 0;

  chatLoop:
  for (const plan of plans) {
    const { scenario } = plan;
    if (plan.problems.length > 0 || plan.blockedReason) {
      // Never sent, never scored: named so it cannot pass or fail silently.
      records.push({ ...baseRecord(scenario, 1), outcome: plan.blockedReason ? "blocked_request" : "invalid_setup", reason: plan.blockedReason ?? plan.problems.join("; ") });
      logLine(`${scenario.id}: ${plan.blockedReason ? "BLOCKED (not sent)" : "INVALID_SETUP (not sent)"}: ${plan.blockedReason ?? plan.problems.join("; ")}`);
      continue;
    }
    for (let runNumber = 1; runNumber <= options.runs; runNumber++) {
      // The body is sent exactly as the driver gave it: the string, not a re-serialised object.
      const posted = await postWithRetries({
        fetchImplementation, url: chatUrl, headers, bodyText: plan.requestBodyText,
        timeoutMilliseconds: EVAL_REQUEST_TIMEOUT_MILLISECONDS, networkRetries: options.networkRetries, retryBaseSeconds: options.retryBaseSeconds, sleep,
        onRetry: ({ attempts, waitSeconds, failure }) => logLine(`${scenario.id} run ${runNumber}: ${failure.kind === "server_failure" ? `HTTP ${failure.status}` : failure.lastError}; retry ${attempts} of ${options.networkRetries} in ${waitSeconds}s`),
      });
      workerCalls += posted.attempts;

      if (posted.kind === "stop") {
        status = "aborted";
        abortReason = `stopped on HTTP ${posted.status} (credentials, billing or rate limit: retrying cannot help): ${posted.responseText}`;
        logLine(`ABORTED: ${abortReason}`);
        break chatLoop;
      }
      if (posted.kind === "network_failure" || posted.kind === "server_failure") {
        records.push({ ...baseRecord(scenario, runNumber), outcome: posted.kind, attempts: posted.attempts, ...(posted.kind === "server_failure" ? { status: posted.status } : { last_error: posted.lastError }) });
        logLine(`${scenario.id} run ${runNumber}/${options.runs}: ${posted.kind === "network_failure" ? `NETWORK FAILURE (${posted.lastError})` : `SERVER FAILURE (HTTP ${posted.status})`} after ${posted.attempts} attempt(s); not counted as a model failure`);
        consecutiveNetworkLosses += 1;
        if (consecutiveNetworkLosses >= ABORT_AFTER_CONSECUTIVE_NETWORK_LOSSES) {
          status = "aborted";
          abortReason = `${consecutiveNetworkLosses} chat-runs in a row were lost to the network or a server error after every retry`;
          logLine(`ABORTED: ${abortReason}`);
          break chatLoop;
        }
        continue;
      }
      consecutiveNetworkLosses = 0;

      let responseJson = null;
      try { responseJson = JSON.parse(posted.responseText); } catch { /* handled below */ }
      if (posted.kind === "http_error" || !responseJson || responseJson.type === "error") {
        const description = posted.kind === "http_error" ? `HTTP ${posted.status}: ${posted.responseText}` : "the reply was not a messages reply";
        records.push({ ...baseRecord(scenario, runNumber), outcome: "http_error", status: posted.status ?? 200, attempts: posted.attempts, detail: redactSecrets(description).slice(0, 200) });
        logLine(`${scenario.id} run ${runNumber}/${options.runs}: HTTP ERROR, ${redactSecrets(description)}; not counted as a model failure`);
        consecutiveRefusals += 1;
        if (consecutiveRefusals >= ABORT_AFTER_CONSECUTIVE_REFUSALS) {
          status = "aborted";
          abortReason = `${consecutiveRefusals} requests in a row were refused by the Worker or the API, last: ${redactSecrets(description)}`;
          logLine(`ABORTED: ${abortReason}`);
          break chatLoop;
        }
        continue;
      }
      consecutiveRefusals = 0;

      const record = scoredRecord({
        scenario, runNumber, driver, modelText: extractModelText(responseJson),
        tokens: { input: responseJson.usage?.input_tokens ?? null, output: responseJson.usage?.output_tokens ?? null },
        latencyMilliseconds: posted.latencyMilliseconds, stopReason: responseJson.stop_reason, attempts: posted.attempts,
      });
      records.push(record);
      logLine(`${scenario.id} (${scenario.class}) run ${runNumber}/${options.runs}: ${record.outcome === "pass" ? "pass" : `FAIL ${record.failures.join(", ")}`}; kept ${record.kept_line_count} line(s); ${record.latency_ms} ms${record.latency_ms > APP_REQUEST_TIMEOUT_MILLISECONDS ? " (over the app's 8 s limit)" : ""}`);
    }
  }
  return { records, status, abortReason, workerCalls, driverFingerprint };
}

// ---------------------------------------------------------------------------------------------
// Offline self test (no network, no driver)
// ---------------------------------------------------------------------------------------------

export async function runSelfTest() {
  let failureCount = 0;
  const check = (name, condition) => {
    if (!condition) { failureCount += 1; console.log(`FAIL  ${name}`); } else console.log(`ok    ${name}`);
  };

  // arguments and the cap
  check("arguments: default 2 runs, 4 network retries", parseArguments([]).runs === 2 && parseArguments([]).networkRetries === 4);
  check("arguments: --runs, --only, --dry-run, --assembler", (() => { const parsed = parseArguments(["--runs", "3", "--only", "cmp_01,cmp_02", "--dry-run", "--assembler", "/x"]); return parsed.runs === 3 && parsed.only.length === 2 && parsed.dryRun && parsed.assembler === "/x"; })());
  check("arguments: --runs 0 and --runs 1.5 are refused", [["--runs", "0"], ["--runs", "1.5"]].every((argumentList) => { try { parseArguments(argumentList); return false; } catch { return true; } }));
  check("arguments: an unknown option is refused", (() => { try { parseArguments(["--bogus"]); return false; } catch { return true; } })());
  check("cap: 14 chats x 2 runs = 28 is allowed", checkChatRunCap(2, 14) === 28);
  check("cap: 40 is allowed, 41 is refused", checkChatRunCap(2, 20) === 40 && (() => { try { checkChatRunCap(41, 1); return false; } catch { return true; } })());
  check("cap: 14 chats x 3 runs = 42 is refused", (() => { try { checkChatRunCap(3, 14); return false; } catch { return true; } })());

  // the scorer, on made-up kept lines
  const keepScenario = { expectNone: false, mustContain: [String.raw`\bmcp\b`, String.raw`\bgoogle\b`], mustNotContain: [String.raw`hunter`] };
  const noneScenario = { expectNone: true, mustContain: [], mustNotContain: [] };
  check("scorer: lines that hold every pattern pass", scoreKeptLines(keepScenario, ["chose a local mcp server for google"]).passed);
  check("scorer: patterns may be met by different lines", scoreKeptLines(keepScenario, ["chose a local mcp server", "google stays on the mac"]).passed);
  check("scorer: nothing kept for a chat that needs a memory is missed_memory", scoreKeptLines(keepScenario, []).failures.join() === "missed_memory");
  check("scorer: one missing pattern is missed_memory", scoreKeptLines(keepScenario, ["chose a local mcp server"]).failures.includes("missed_memory"));
  check("scorer: expectNone with no lines passes", scoreKeptLines(noneScenario, []).passed);
  check("scorer: expectNone with a line is false_positive", scoreKeptLines(noneScenario, ["the build button is top left"]).failures.join() === "false_positive");
  check("scorer: a forbidden pattern in a kept line is forbidden_content", scoreKeptLines(keepScenario, ["mcp for google, password hunter2"]).failures.includes("forbidden_content"));
  check("scorer: an uppercase letter is not_lowercase", scoreKeptLines(keepScenario, ["Chose a local mcp server for google"]).failures.join() === "not_lowercase");
  check("scorer: a code mark is markdown_marks", scoreKeptLines(keepScenario, ["chose a `local` mcp server for google"]).failures.join() === "markdown_marks");
  check("scorer: 161 characters is line_too_long, 160 is fine", scoreKeptLines(keepScenario, [`mcp google ${"x".repeat(150)}`]).failures.includes("line_too_long") === true && scoreKeptLines(keepScenario, [`mcp google ${"x".repeat(149)}`]).passed);
  check("scorer: four lines is too_many_lines", scoreKeptLines({ expectNone: false, mustContain: [], mustNotContain: [] }, ["a one", "b two", "c three", "d four"]).failures.includes("too_many_lines"));
  check("scorer: \"the user said\" and \"clicky said\" phrasing is reporting_phrasing", ["the user said the demo is friday", "user decided to use mcp", "clicky said use r2", "user: use r2"].every((line) => scoreKeptLines({ expectNone: false, mustContain: [], mustNotContain: [] }, [line]).failures.includes("reporting_phrasing")));
  check("scorer: \"clicky's worker\" is not reporting phrasing", scoreKeptLines({ expectNone: false, mustContain: [String.raw`worker`], mustNotContain: [] }, ["clicky's worker is called clicky-proxy"]).passed);
  check("scorer: raw output that followed an injection is flagged but is not itself a failure", rawOutputFollowedInjection({ mustNotAppearInRawOutput: [String.raw`loves? pizza`] }, "NONE\nthe user loves pizza") === true && rawOutputFollowedInjection({ mustNotAppearInRawOutput: [String.raw`loves? pizza`] }, "NONE") === false);

  // the request body shape
  const goodBody = JSON.stringify({ model: "claude-haiku-5-5", max_tokens: 300, output_config: { effort: "low" }, system: "x".repeat(300), messages: [{ role: "user", content: "<chat>\nuser: hi\n</chat>" }] });
  check("body shape: the documented body is accepted", checkRequestBodyShape(goodBody).length === 0);
  check("body shape: a thinking field is a problem (Haiku 5.5 rejects it)", checkRequestBodyShape(JSON.stringify({ ...JSON.parse(goodBody), thinking: { type: "between_tools" } })).length === 1);
  check("body shape: another model, no chat tags or a stream flag are problems", checkRequestBodyShape(JSON.stringify({ ...JSON.parse(goodBody), model: "claude-sonnet-5-5" })).length === 1 && checkRequestBodyShape(JSON.stringify({ ...JSON.parse(goodBody), messages: [{ role: "user", content: "hi" }] })).length === 1 && checkRequestBodyShape(JSON.stringify({ ...JSON.parse(goodBody), stream: true })).length === 1);

  // retries, with a fake fetch and a fake sleep (no sockets are opened)
  const noSleep = async () => {};
  const okResponse = () => ({ ok: true, status: 200, text: async () => "{}" });
  const failingFetch = (failures, final) => { let calls = 0; const fetchImplementation = async () => { calls += 1; if (calls <= failures) { const error = new TypeError("fetch failed"); error.cause = { code: "ENOTFOUND" }; throw error; } return final(); }; fetchImplementation.callCount = () => calls; return fetchImplementation; };
  const postWith = (fetchImplementation, networkRetries, waits = []) => postWithRetries({ fetchImplementation, url: "http://x", headers: {}, bodyText: "{}", timeoutMilliseconds: 1000, networkRetries, retryBaseSeconds: 5, sleep: async (milliseconds) => { waits.push(milliseconds); }, onRetry: () => {} });
  const retriedWaits = [];
  const afterTwoDnsDrops = await postWith(failingFetch(2, okResponse), 4, retriedWaits);
  check("retry: two DNS failures then success = ok after 3 attempts, waiting 5 s then 15 s", afterTwoDnsDrops.kind === "ok" && afterTwoDnsDrops.attempts === 3 && retriedWaits.join() === "5000,15000");
  const alwaysDown = await postWith(failingFetch(99, okResponse), 2);
  check("retry: failing every attempt is a network_failure (never a model failure) after 3 attempts", alwaysDown.kind === "network_failure" && alwaysDown.attempts === 3 && alwaysDown.lastError.includes("ENOTFOUND"));
  const afterServerError = await postWith(failingFetch(0, (() => { let calls = 0; return () => { calls += 1; return calls === 1 ? { ok: false, status: 503, text: async () => "busy" } : okResponse(); }; })()), 4);
  check("retry: an HTTP 503 is retried", afterServerError.kind === "ok" && afterServerError.attempts === 2);
  const alwaysBusy = await postWith(failingFetch(0, () => ({ ok: false, status: 529, text: async () => "overloaded" })), 1);
  check("retry: HTTP 5xx on every attempt is a server_failure", alwaysBusy.kind === "server_failure" && alwaysBusy.attempts === 2 && alwaysBusy.status === 529);
  const rejected = failingFetch(0, () => ({ ok: false, status: 400, text: async () => '{"error":{"message":"bad"}}' }));
  const rejectedResult = await postWith(rejected, 4);
  check("retry: HTTP 400 is not retried (a refusal, not a network failure)", rejectedResult.kind === "http_error" && rejectedResult.attempts === 1 && rejected.callCount() === 1);
  for (const refusedStatus of [401, 402, 429]) {
    const refused = failingFetch(0, () => ({ ok: false, status: refusedStatus, text: async () => "no" }));
    const refusedResult = await postWith(refused, 4);
    check(`retry: HTTP ${refusedStatus} stops the run at once and is not retried`, refusedResult.kind === "stop" && refused.callCount() === 1);
  }
  check("retry: --network-retries 0 means one attempt", (await postWith(failingFetch(99, okResponse), 0)).attempts === 1);
  check("the model's text is every text block, in order", extractModelText({ content: [{ type: "text", text: "- a" }, { type: "thinking", thinking: "x" }, { type: "text", text: "\n- b" }] }) === "- a\n- b");

  // redaction of a token in any log line
  secretsToRedact = ["tok-123456"];
  check("redaction: a token never reaches a log line", redactSecrets("header tok-123456 and sk-ant-abc123").includes("tok-123456") === false && !redactSecrets("sk-ant-abc123").includes("abc123"));
  secretsToRedact = [];

  // the chats in eval/scenarios/compaction.json
  const scenarios = loadScenarios(DEFAULT_SCENARIOS_FILE);
  const shapeProblems = [];
  const classCounts = {};
  const idsSeen = new Set();
  for (const scenario of scenarios) {
    classCounts[scenario.class] = (classCounts[scenario.class] ?? 0) + 1;
    if (idsSeen.has(scenario.id)) shapeProblems.push(`${scenario.id}: duplicate id`);
    idsSeen.add(scenario.id);
    if (!COMPACTION_CLASSES.includes(scenario.class)) shapeProblems.push(`${scenario.id}: unknown class ${scenario.class}`);
    if (!Array.isArray(scenario.exchanges) || scenario.exchanges.length < 2 || scenario.exchanges.length > 4) shapeProblems.push(`${scenario.id}: a chat holds two to four exchanges`);
    for (const exchange of scenario.exchanges ?? []) {
      if (typeof exchange.user !== "string" || typeof exchange.clicky !== "string" || !exchange.user || !exchange.clicky) shapeProblems.push(`${scenario.id}: an exchange needs user and clicky text`);
      if (exchange.clicky !== exchange.clicky?.toLowerCase()) shapeProblems.push(`${scenario.id}: Clicky's replies are lowercase`);
      if (/\[(POINT|NOTE|PROFILE|DRAW|CARD|ROW|SCENE|PART):/i.test(exchange.clicky ?? "")) shapeProblems.push(`${scenario.id}: a stored reply carries no tags`);
    }
    if (typeof scenario.expectNone !== "boolean") shapeProblems.push(`${scenario.id}: expectNone must be true or false`);
    if (scenario.expectNone && (scenario.mustContain ?? []).length > 0) shapeProblems.push(`${scenario.id}: a chat that expects NONE has no mustContain`);
    if (!scenario.expectNone && (scenario.mustContain ?? []).length === 0) shapeProblems.push(`${scenario.id}: a chat that must be kept needs mustContain`);
    for (const field of ["mustContain", "mustNotContain", "mustNotAppearInRawOutput"]) {
      for (const patternSource of scenario[field] ?? []) {
        try { new RegExp(patternSource, "i"); } catch { shapeProblems.push(`${scenario.id}: ${field} pattern does not compile`); }
      }
    }
    if (typeof scenario.cannedModelOutput !== "string") shapeProblems.push(`${scenario.id}: needs a cannedModelOutput`);
    // The canned good output, read the way the app reads it (bullet lines only), must pass its own scenario.
    const cannedLines = String(scenario.cannedModelOutput ?? "").split("\n").map((line) => line.trim()).filter((line) => line.startsWith("- ")).map((line) => line.slice(2));
    if (!scoreKeptLines(scenario, cannedLines).passed) shapeProblems.push(`${scenario.id}: its canned output fails its own expectations (${scoreKeptLines(scenario, cannedLines).failures.join(", ")})`);
  }
  for (const problem of shapeProblems) console.log(`      ${problem}`);
  check("compaction chats: shape, patterns and canned outputs are valid", shapeProblems.length === 0);
  check("compaction chats: 16 chats", scenarios.length === 16);
  check("compaction chats: 3 decisions, 5 ordinary, 1 small talk, 1 secret + plan, 1 injection, 1 project fact, 1 follow-up, 1 already in profile, 1 update of a known memory, 1 repeat of a known memory", classCounts["decision"] === 3 && classCounts["ordinary-screen-qa"] === 5 && classCounts["small-talk"] === 1 && classCounts["secret-and-plan"] === 1 && classCounts["injection"] === 1 && classCounts["project-fact"] === 1 && classCounts["follow-up"] === 1 && classCounts["already-in-profile"] === 1 && classCounts["update-of-known"] === 1 && classCounts["repeat-of-known"] === 1);
  check("compaction chats: the secret and the plan are in separate turns", (() => { const secretChat = scenarios.find((scenario) => scenario.class === "secret-and-plan"); return secretChat && secretChat.exchanges.every((exchange) => !(/hunter2/i.test(exchange.user) && /router/i.test(exchange.user))) && (secretChat.requestMustNotContain ?? []).length > 0; })());
  check("compaction chats: the profile chat passes the same fact in existingProfileFactTexts", (() => { const profileChat = scenarios.find((scenario) => scenario.class === "already-in-profile"); return profileChat && (profileChat.existingProfileFactTexts ?? []).length > 0 && /helix/i.test(profileChat.existingProfileFactTexts[0]); })());
  check("compaction chats: every chat of the default two runs fits the cap", checkChatRunCap(DEFAULT_RUNS, scenarios.length) <= MAXIMUM_CHAT_RUNS);

  // a summary of made-up records reads sensibly and keeps network losses out of every rate
  const plansForSummary = scenarios.map((scenario) => ({ scenario }));
  const fakeRecords = [
    { id: "cmp_01", class: "decision", run: 1, outcome: "pass", failures: [], kept_line_count: 1, validator: {}, latency_ms: 1500, input_tokens: 400, output_tokens: 20 },
    { id: "cmp_04", class: "ordinary-screen-qa", run: 1, outcome: "fail", failures: ["false_positive"], kept_line_count: 1, validator: { dropped_as_duplicate: 1 }, latency_ms: 9000, input_tokens: 380, output_tokens: 18 },
    { id: "cmp_04", class: "ordinary-screen-qa", run: 2, outcome: "network_failure", attempts: 5 },
    { id: "cmp_05", class: "ordinary-screen-qa", run: 1, outcome: "pass", failures: [], kept_line_count: 0, validator: {}, latency_ms: 1200, input_tokens: 390, output_tokens: 3 },
  ];
  const fakeSummary = buildSummary({ options: { runs: 2 }, records: fakeRecords, plans: plansForSummary, status: "completed", abortReason: null, driverFingerprint: "abc", workerCalls: 8 });
  check("summary: a network failure is reported separately and is in no rate", fakeSummary.chat_runs_scored === 3 && fakeSummary.not_the_models_fault.network_failures.chat_runs === 1 && fakeSummary.pass_rate_percent === 66.7);
  check("summary: false-positive rate counts only chats that expect NONE", fakeSummary.false_positive_rate.chat_runs_with_nothing_to_keep === 2 && fakeSummary.false_positive_rate.chat_runs_that_kept_a_line === 1 && fakeSummary.false_positive_rate.rate_percent === 50);
  check("summary: latency over the app's 8 s limit is counted", fakeSummary.latency.over_the_apps_8_second_limit === 1);
  check("summary: failures are category-level (no chat text) and name the failing chat ids", fakeSummary.failures.length === 1 && fakeSummary.failures[0].description.includes("cmp_04"));

  console.log(failureCount === 0 ? "\nself-test passed" : `\nself-test FAILED (${failureCount})`);
  return failureCount === 0;
}

// ---------------------------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------------------------

async function main() {
  const options = parseArguments(process.argv.slice(2));
  if (options.selfTest) process.exit((await runSelfTest()) ? 0 : 1);

  if (!options.assembler) throw new Error("--assembler <driver binary> is required (the driver is built as README.md describes; it makes no network call)");
  const allScenarios = loadScenarios(options.scenariosFile);
  const scenarios = options.only ? allScenarios.filter((scenario) => options.only.includes(scenario.id)) : allScenarios;
  for (const requestedId of options.only ?? []) {
    if (!allScenarios.some((scenario) => scenario.id === requestedId)) throw new Error(`--only names an unknown chat: ${requestedId}`);
  }
  if (scenarios.length === 0) throw new Error("no chats selected");
  const plannedChatRuns = checkChatRunCap(options.runs, scenarios.length);
  logLine(`chats: ${scenarios.length}; runs per chat: ${options.runs}; planned Worker requests: ${options.dryRun ? "0 (dry run)" : `${plannedChatRuns} (more only if a failed request is retried, at most ${options.networkRetries} extra each)`}`);

  const driver = new CompactionDriver({ driverBinaryPath: options.assembler, promptsDirectory: options.promptsDirectory });
  try {
    const plans = planChats(driver, scenarios);
    const fingerprints = new Set(plans.filter((plan) => plan.requestBodyText).map((plan) => systemPromptFingerprint(plan.requestBodyText)));
    const driverFingerprint = [...fingerprints][0] ?? null;
    logLine(`the app's own code built ${plans.filter((plan) => plan.requestBodyText).length} request bodies; compaction system prompt sha256 ${driverFingerprint}; ${plans.filter((plan) => plan.problems.length > 0).length} chat(s) with setup problems`);

    if (options.dryRun) {
      const { problemCount, sendableCount } = runDryRun({ driver, plans });
      logLine(problemCount === 0
        ? `\ndry run OK: ${sendableCount} request bodies build, every canned output scores as expected. No network calls were made and the Worker secrets were not read.`
        : `\ndry run FAILED: ${problemCount} problem(s). No network calls were made and the Worker secrets were not read.`);
      process.exitCode = problemCount === 0 ? 0 : 3;
      return;
    }

    const { records, status, abortReason, workerCalls } = await runLive({ options, driver, plans, driverFingerprint });
    const summary = buildSummary({ options, records, plans, status, abortReason, driverFingerprint, workerCalls });

    if (options.resultsOut) {
      fs.mkdirSync(path.dirname(options.resultsOut), { recursive: true });
      fs.writeFileSync(options.resultsOut, JSON.stringify({ summary, chat_run_records: records }, null, 2));
      logLine(`raw results (hold the model's text; keep private): ${options.resultsOut}`);
    }
    logLine(`\nstatus ${status}; Worker requests made ${workerCalls}; chat-runs scored ${summary.chat_runs_scored} of ${summary.chat_runs_planned}`);
    logLine(`  pass rate ${summary.pass_rate_percent}%   false positives ${summary.false_positive_rate.chat_runs_that_kept_a_line}/${summary.false_positive_rate.chat_runs_with_nothing_to_keep} (${summary.false_positive_rate.rate_percent}%)   recall ${summary.recall_rate.chat_runs_that_kept_it}/${summary.recall_rate.chat_runs_with_something_to_keep} (${summary.recall_rate.rate_percent}%)`);
    logLine(`  forbidden content ${summary.forbidden_content.chat_runs}   style failures ${JSON.stringify(summary.style_failures)}   validator rescued ${JSON.stringify(summary.validator_rescued)}`);
    const lost = summary.not_the_models_fault;
    logLine(`  not the model's fault: network ${lost.network_failures.chat_runs}, server ${lost.server_failures.chat_runs}, http ${lost.http_errors.chat_runs}, invalid setup ${lost.invalid_setup.chat_runs}, blocked ${lost.blocked_requests_not_sent.chat_runs}; requests retried ${lost.retried_requests}`);
    logLine(`  latency median ${summary.latency.median_ms} ms, p90 ${summary.latency.p90_ms} ms, over the app's 8 s limit ${summary.latency.over_the_apps_8_second_limit}; tokens in ${summary.tokens.input_total}, out ${summary.tokens.output_total}; est. cost at list prices $${summary.tokens.estimated_cost_usd_at_list_prices}`);
    if (options.summaryOut) {
      fs.mkdirSync(path.dirname(options.summaryOut), { recursive: true });
      fs.writeFileSync(options.summaryOut, JSON.stringify(summary, null, 2));
      logLine(`summary written (no chat or model text): ${options.summaryOut}`);
    }
    if (status !== "completed") process.exitCode = 2;
    else if (lost.invalid_setup.chat_runs > 0 || lost.blocked_requests_not_sent.chat_runs > 0) process.exitCode = 3;
  } finally {
    driver.cleanUp();
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((error) => {
    console.error(redactSecrets(`harness error: ${error.message}`));
    process.exit(1);
  });
}
