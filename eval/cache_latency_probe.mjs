#!/usr/bin/env node
// Round 4A probe: does sending the system prompt as a cached static block + dynamic block change
// latency, and does the Worker accept the exact request shapes the app now builds?
//
// Budget: 8 pairs x 2 calls (latency) + 2 shape-acceptance calls = 18 Worker calls. Nothing is retried.
// Text-only for the latency pairs (same prompt text with and without the cache block, streaming like
// the app, effort low). The two shape calls use harness fixtures (synthetic notes, two fixture screens).
//
// Usage:
//   node eval/cache_latency_probe.mjs --driver <driver binary> --out <report.json> [--pairs 8]
//
// Never prints the Worker token. Replies are not written anywhere (only timings and token counts).

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const evalDirectory = path.dirname(fileURLToPath(import.meta.url));
const secretsPlistPath = "/Users/samsto/Clicker/leanring-buddy/ClickyWorkerSecrets.plist";
const promptsDirectory = "/Users/samsto/Clicker/leanring-buddy/ClickyPrompts";
const MODEL_NAME = "claude-sonnet-5-5";
const MAX_TOTAL_CALLS = 20;

function parseArguments(argumentList) {
  // --image <fixture.jpg> puts a fixture screenshot in every latency call (the app always sends one);
  // --no-shape-checks skips the two shape-acceptance calls so a small follow-up stays within budget.
  const options = { driver: null, out: null, pairs: 8, imageFixture: null, shapeChecks: true };
  for (let index = 0; index < argumentList.length; index++) {
    const argument = argumentList[index];
    const nextValue = () => argumentList[++index];
    if (argument === "--driver") options.driver = nextValue();
    else if (argument === "--out") options.out = nextValue();
    else if (argument === "--pairs") options.pairs = Number(nextValue());
    else if (argument === "--image") options.imageFixture = nextValue();
    else if (argument === "--no-shape-checks") options.shapeChecks = false;
    else throw new Error(`unknown argument ${argument}`);
  }
  if (!options.driver || !options.out) throw new Error("--driver and --out are required");
  return options;
}

function readWorkerConfiguration() {
  const readKey = (key) => execFileSync("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, secretsPlistPath], { encoding: "utf8" }).trim();
  return { baseUrl: readKey("WorkerBaseURL").replace(/\/+$/, ""), appToken: readKey("WorkerAppToken") };
}

// Runs the app's prompt assembler through the eval driver for one turn context (zero API calls).
function assembleWithDriver(driverBinaryPath, turnInput) {
  const workDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "clicky-eval-io-"));
  const notesRootDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "clicky-eval-notes-"));
  try {
    const inputPath = path.join(workDirectory, "prepare_input.json");
    const outputPath = path.join(workDirectory, "prepare_output.json");
    fs.writeFileSync(inputPath, JSON.stringify([turnInput]));
    execFileSync(driverBinaryPath, ["prepare", inputPath, outputPath, promptsDirectory, notesRootDirectory], { stdio: ["ignore", "pipe", "pipe"] });
    return JSON.parse(fs.readFileSync(outputPath, "utf8"))[0];
  } finally {
    fs.rmSync(workDirectory, { recursive: true, force: true });
    fs.rmSync(notesRootDirectory, { recursive: true, force: true });
  }
}

function screenLabel(screenIndex, screenCount, width, height) {
  let label;
  if (screenCount === 1) label = "user's screen (cursor is here)";
  else if (screenIndex === 0) label = `screen ${screenIndex + 1} of ${screenCount} — cursor is on this screen (primary focus)`;
  else label = `screen ${screenIndex + 1} of ${screenCount} — secondary screen`;
  return `${label} (image dimensions: ${width}x${height} pixels; center is at ${Math.floor(width / 2)},${Math.floor(height / 2)})`;
}

function imageBlocksForFixtures(fixtureNames) {
  const manifest = JSON.parse(fs.readFileSync(path.join(evalDirectory, "fixtures", "manifest.json"), "utf8")).fixtures;
  const blocks = [];
  fixtureNames.forEach((fixtureName, index) => {
    const bytes = fs.readFileSync(path.join(evalDirectory, "fixtures", fixtureName));
    blocks.push({ type: "image", source: { type: "base64", media_type: "image/jpeg", data: bytes.toString("base64") } });
    blocks.push({ type: "text", text: screenLabel(index, fixtureNames.length, manifest[fixtureName].width, manifest[fixtureName].height) });
  });
  return blocks;
}

// Same body as ClaudeAPI.streamReply: model, max_tokens 1024, stream true, effort low, system, messages.
function appShapedBody(systemValue, contentBlocks) {
  return { model: MODEL_NAME, max_tokens: 1024, stream: true, output_config: { effort: "low" }, system: systemValue, messages: [{ role: "user", content: contentBlocks }] };
}

let callsMade = 0;

// Streams one request. Returns timings (ms to response headers, to first text delta, to stream end),
// the usage read from message_start / message_delta exactly as the app's accumulator does, and the status.
async function streamOnce(configuration, body) {
  if (callsMade >= MAX_TOTAL_CALLS) throw new Error("probe call cap reached");
  callsMade += 1;
  const startedAt = performance.now();
  const response = await fetch(`${configuration.baseUrl}/chat`, {
    method: "POST",
    headers: { "content-type": "application/json", "X-Clicky-App-Token": configuration.appToken },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(120_000),
  });
  const headersAtMs = performance.now() - startedAt;
  if (!response.ok) {
    const errorText = (await response.text()).slice(0, 300);
    return { status: response.status, error: errorText, headersAtMs };
  }
  const usage = { input_tokens: null, output_tokens: null, cache_creation_input_tokens: null, cache_read_input_tokens: null };
  let firstTextAtMs = null;
  let textCharacters = 0;
  let stopReason = null;
  let buffered = "";
  const decoder = new TextDecoder();
  for await (const chunk of response.body) {
    buffered += decoder.decode(chunk, { stream: true });
    let newlineIndex;
    while ((newlineIndex = buffered.indexOf("\n")) >= 0) {
      const line = buffered.slice(0, newlineIndex).trim();
      buffered = buffered.slice(newlineIndex + 1);
      if (!line.startsWith("data: ")) continue;
      let event;
      try { event = JSON.parse(line.slice(6)); } catch { continue; }
      if (event.type === "message_start" && event.message?.usage) {
        for (const key of Object.keys(usage)) usage[key] = event.message.usage[key] ?? null;
      }
      if (event.type === "message_delta") {
        if (typeof event.usage?.output_tokens === "number") usage.output_tokens = event.usage.output_tokens;
        stopReason = event.delta?.stop_reason ?? stopReason;
      }
      if (event.type === "content_block_delta" && event.delta?.type === "text_delta") {
        if (firstTextAtMs === null) firstTextAtMs = performance.now() - startedAt;
        textCharacters += event.delta.text.length;
      }
    }
  }
  const endAtMs = performance.now() - startedAt;
  return { status: response.status, headersAtMs: Math.round(headersAtMs), firstTextAtMs: firstTextAtMs === null ? null : Math.round(firstTextAtMs), endAtMs: Math.round(endAtMs), usage, textCharacters, stopReason };
}

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const configuration = readWorkerConfiguration();
  const report = { started_at: new Date().toISOString(), model: MODEL_NAME, pairs: [], shape_checks: [], calls_made: 0 };

  // One turn context for every latency call: Safari frontmost, one screen, no notes, plain question.
  const latencyTurn = assembleWithDriver(options.driver, { id: "probe_latency", transcript: "what's a good way to name a git branch", appName: "Safari", bundleId: "com.apple.Safari", screenCount: 1, seedNotes: [] });
  const userContent = [...(options.imageFixture ? imageBlocksForFixtures([options.imageFixture]) : []), { type: "text", text: "what's a good way to name a git branch" }];
  report.latency_image_fixture = options.imageFixture;
  const blockedSystem = latencyTurn.systemBlocks;
  const stringSystem = latencyTurn.systemPromptText;
  report.latency_prompt = { static_chars: latencyTurn.staticSystemPromptText.length, dynamic_chars: latencyTurn.dynamicSystemPromptText.length, block_count: blockedSystem.length };

  for (let pairIndex = 0; pairIndex < options.pairs; pairIndex++) {
    // Alternate which arm goes first so slow drift in the network does not favour one arm.
    const order = pairIndex % 2 === 0 ? ["blocks", "string"] : ["string", "blocks"];
    const pair = { pair: pairIndex + 1, order };
    for (const arm of order) {
      const body = appShapedBody(arm === "blocks" ? blockedSystem : stringSystem, userContent);
      const result = await streamOnce(configuration, body);
      pair[arm] = result;
      console.log(`pair ${pairIndex + 1} ${arm.padEnd(6)} status ${result.status} headers ${result.headersAtMs}ms first-text ${result.firstTextAtMs}ms end ${result.endAtMs}ms usage in=${result.usage?.input_tokens} cw=${result.usage?.cache_creation_input_tokens} cr=${result.usage?.cache_read_input_tokens} out=${result.usage?.output_tokens}`);
      if ([401, 402, 429].includes(result.status)) { report.aborted = `HTTP ${result.status}`; break; }
    }
    report.pairs.push(pair);
    if (report.aborted) break;
  }

  if (!report.aborted && options.shapeChecks) {
    // Shape 1: empty dynamic block -> one cached system block, one screen image, streaming (app shape).
    const oneBlockSystem = [{ type: "text", text: latencyTurn.staticSystemPromptText, cache_control: { type: "ephemeral" } }];
    const shapeOne = await streamOnce(configuration, appShapedBody(oneBlockSystem, [...imageBlocksForFixtures(["browser_main.jpg"]), { type: "text", text: "what's on my screen" }]));
    report.shape_checks.push({ name: "empty dynamic block (one cached block) + one screen image, streaming", status: shapeOne.status, error: shapeOne.error ?? null, usage: shapeOne.usage ?? null, endAtMs: shapeOne.endAtMs ?? null });
    console.log(`shape: one block + image -> HTTP ${shapeOne.status} usage ${JSON.stringify(shapeOne.usage ?? shapeOne.error)}`);

    // Shape 2: dynamic block with synthetic notes (seeded through the app's own note store) + two screen images, streaming.
    const notesTurn = assembleWithDriver(options.driver, {
      id: "probe_notes", transcript: "what did i tell you about the test printer", appName: "Safari", bundleId: "com.apple.Safari", screenCount: 2,
      seedNotes: [{ date: "2026-11-03", text: "the test printer on floor two needs the long paper tray" }, { date: "2026-11-05", text: "probe fixture note: standup moved to ten" }],
    });
    const notesSystem = notesTurn.systemBlocks;
    const shapeTwo = await streamOnce(configuration, appShapedBody(notesSystem, [...imageBlocksForFixtures(["xcode_main.jpg", "browser_main.jpg"]), { type: "text", text: "what did i tell you about the test printer" }]));
    report.shape_checks.push({ name: "dynamic block with notes + two screen images, streaming", status: shapeTwo.status, error: shapeTwo.error ?? null, usage: shapeTwo.usage ?? null, endAtMs: shapeTwo.endAtMs ?? null, dynamic_has_notes_heading: notesTurn.dynamicSystemPromptText.includes("what you remember about the user"), block_count: notesSystem.length });
    console.log(`shape: notes + two screens -> HTTP ${shapeTwo.status} usage ${JSON.stringify(shapeTwo.usage ?? shapeTwo.error)}`);
  }

  const completedPairs = report.pairs.filter((pair) => pair.blocks?.status === 200 && pair.string?.status === 200);
  const diffs = (field) => completedPairs.map((pair) => pair.blocks[field] - pair.string[field]);
  report.summary = {
    completed_pairs: completedPairs.length,
    blocks_arm: { median_headers_ms: median(completedPairs.map((p) => p.blocks.headersAtMs)), median_first_text_ms: median(completedPairs.map((p) => p.blocks.firstTextAtMs)), median_end_ms: median(completedPairs.map((p) => p.blocks.endAtMs)), min_end_ms: Math.min(...completedPairs.map((p) => p.blocks.endAtMs)), max_end_ms: Math.max(...completedPairs.map((p) => p.blocks.endAtMs)), cache_reads: completedPairs.filter((p) => p.blocks.usage.cache_read_input_tokens > 0).length, cache_writes: completedPairs.filter((p) => p.blocks.usage.cache_creation_input_tokens > 0).length },
    string_arm: { median_headers_ms: median(completedPairs.map((p) => p.string.headersAtMs)), median_first_text_ms: median(completedPairs.map((p) => p.string.firstTextAtMs)), median_end_ms: median(completedPairs.map((p) => p.string.endAtMs)), min_end_ms: Math.min(...completedPairs.map((p) => p.string.endAtMs)), max_end_ms: Math.max(...completedPairs.map((p) => p.string.endAtMs)), cache_reads: completedPairs.filter((p) => p.string.usage.cache_read_input_tokens > 0).length },
    paired_diff_blocks_minus_string_ms: { first_text: diffs("firstTextAtMs"), end: diffs("endAtMs"), median_first_text: median(diffs("firstTextAtMs")), median_end: median(diffs("endAtMs")) },
    output_tokens: { blocks: completedPairs.map((p) => p.blocks.usage.output_tokens), string: completedPairs.map((p) => p.string.usage.output_tokens) },
  };
  report.calls_made = callsMade;
  fs.writeFileSync(options.out, JSON.stringify(report, null, 2));
  console.log(`calls made ${callsMade}; report ${options.out}`);
  console.log(JSON.stringify(report.summary, null, 1));
}

main().catch((error) => { console.error(`probe error: ${String(error.message).replace(/sk-ant-[A-Za-z0-9_-]+/g, "[redacted]")}`); process.exit(1); });
