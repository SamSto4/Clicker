#!/usr/bin/env node
// Builds <loop-folder>/leaderboard.md from every round*.json summary in that folder.
// Usage: node eval/make_leaderboard.mjs <loop-folder>
// (run_simulations.mjs calls this automatically when --summary-out is given.)

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

function formatScore(value) {
  return value === null || value === undefined ? "-" : String(value);
}

export function writeLeaderboard(loopFolder) {
  const summaryFileNames = fs.readdirSync(loopFolder)
    .filter((fileName) => /^round\d+.*\.json$/.test(fileName))
    .sort((a, b) => Number(/^round(\d+)/.exec(a)[1]) - Number(/^round(\d+)/.exec(b)[1]) || a.localeCompare(b));

  // The scenario set grew before round 2 grading (fresh holdout cases). Rows are labelled by how many
  // scenarios they ran so that scores from different set sizes are not read as directly comparable.
  const ORIGINAL_SCENARIO_COUNT = 45;
  const summaries = summaryFileNames.map((fileName) => ({ fileName, summary: JSON.parse(fs.readFileSync(path.join(loopFolder, fileName), "utf8")) }));
  const FOUR_DIMENSIONS = ["pointing", "brevity", "coding", "notes"];
  // A summary that ran none of the four weighted dimensions (a personalization-only run) has no place
  // in the main table; it appears only in the personalization table below.
  const ranAnyWeightedDimension = (summary) => FOUR_DIMENSIONS.some((dimension) => summary.dimensions?.[dimension]?.score !== null && summary.dimensions?.[dimension]?.score !== undefined);
  const rows = summaries.filter(({ summary }) => ranAnyWeightedDimension(summary)).map(({ fileName, summary }) => {
    const dimensions = summary.dimensions ?? {};
    const scenarioCount = Object.values(dimensions).reduce(
      (runningTotal, dimension) => runningTotal + (dimension.details?.scenarios_scored ?? 0) + (dimension.details?.scenarios_errored ?? 0), 0);
    const scenarioSetLabel = scenarioCount > ORIGINAL_SCENARIO_COUNT ? `expanded (${scenarioCount})` : `original (${scenarioCount})`;
    return `| ${summary.round} | ${summary.label ?? fileName} | ${scenarioSetLabel} | ${formatScore(dimensions.pointing?.score)} | ${formatScore(dimensions.brevity?.score)} | ${formatScore(dimensions.coding?.score)} | ${formatScore(dimensions.notes?.score)} | **${formatScore(summary.total)}** | ${formatScore(summary.total_equal_weight)} | ${formatScore(summary.split_scores?.visible?.total)} | ${formatScore(summary.split_scores?.holdout?.total)} | ${summary.calls_used?.total ?? "-"} |`;
  });

  // Round 4B: personalization is tracked separately and never enters the weighted total.
  const personalizationRows = summaries.filter(({ summary }) => summary.personalization).map(({ fileName, summary }) => {
    const personalization = summary.personalization;
    const scenarioCount = (personalization.details?.scenarios_scored ?? 0) + (personalization.details?.scenarios_errored ?? 0);
    return `| ${summary.round} | ${summary.label ?? fileName} | ${scenarioCount} | **${formatScore(personalization.score)}** | ${formatScore(personalization.split_scores?.visible)} | ${formatScore(personalization.split_scores?.holdout)} | ${personalization.details?.tags_dropped_by_gate_count ?? "-"} | ${summary.calls_used?.total ?? "-"} |`;
  });

  // Round 6: visual (drawing on the screen and the explanation card) is tracked separately as well.
  const visualRows = summaries.filter(({ summary }) => summary.visual).map(({ fileName, summary }) => {
    const visual = summary.visual;
    const scenarioCount = (visual.details?.scenarios_scored ?? 0) + (visual.details?.scenarios_errored ?? 0);
    const kindScore = (kind) => formatScore(visual.details?.by_kind?.[kind]?.score);
    return `| ${summary.round} | ${summary.label ?? fileName} | ${scenarioCount} | **${formatScore(visual.score)}** | ${formatScore(visual.split_scores?.visible)} | ${formatScore(visual.split_scores?.holdout)} | ${kindScore("mark")} | ${kindScore("second_screen")} | ${kindScore("callouts")} | ${kindScore("card")} | ${kindScore("absent")} | ${kindScore("edit")} | ${kindScore("control")} | ${visual.details?.tags_dropped_by_the_app_parser_total ?? "-"} | ${summary.calls_used?.total ?? "-"} |`;
  });

  // Round 14: context (old screens versus the screen now) is tracked separately as well.
  const contextRows = summaries.filter(({ summary }) => summary.context).map(({ fileName, summary }) => {
    const context = summary.context;
    const scenarioCount = (context.details?.scenarios_scored ?? 0) + (context.details?.scenarios_errored ?? 0);
    const kindScore = (kind) => formatScore(context.details?.by_kind?.[kind]?.score);
    const rate = (block) => (block?.rate_percent === null || block?.rate_percent === undefined ? "-" : `${block.rate_percent}%`);
    return `| ${summary.round} | ${summary.label ?? fileName} | ${scenarioCount} | **${formatScore(context.score)}** | ${formatScore(context.split_scores?.visible)} | ${formatScore(context.split_scores?.holdout)} | ${rate(context.details?.old_screen_bleed)} | ${rate(context.details?.meta_remark)} | ${kindScore("switch-new-topic")} | ${kindScore("switch-ambiguous-this")} | ${kindScore("follow-up-across-switch")} | ${kindScore("same-screen-follow-up")} | ${kindScore("pointing-after-switch")} | ${summary.calls_used?.total ?? "-"} |`;
  });

  // Round 16: memories (does a memory from an earlier chat help when it should and stay quiet when it should) is tracked separately as well.
  const memoriesRows = summaries.filter(({ summary }) => summary.memories).map(({ fileName, summary }) => {
    const memories = summary.memories;
    const scenarioCount = (memories.details?.scenarios_scored ?? 0) + (memories.details?.scenarios_errored ?? 0);
    const classScore = (className) => formatScore(memories.details?.by_class?.[className]?.score);
    const rate = (block) => (block?.rate_percent === null || block?.rate_percent === undefined ? "-" : `${block.rate_percent}%`);
    return `| ${summary.round} | ${summary.label ?? fileName} | ${scenarioCount} | **${formatScore(memories.score)}** | ${formatScore(memories.split_scores?.visible)} | ${formatScore(memories.split_scores?.holdout)} | ${rate(memories.details?.unrelated_memory_mentions)} | ${rate(memories.details?.invented_details)} | ${rate(memories.details?.missed_recall)} | ${classScore("unrelated-keyword")} | ${classScore("paraphrased-recall")} | ${classScore("missing-detail")} | ${classScore("what-do-you-remember")} | ${classScore("one-of-several")} | ${memories.details?.scenarios_invalid_setup ?? "-"} | ${summary.calls_used?.total ?? "-"} |`;
  });

  const markdown = [
    "# Clicky improvement loop leaderboard",
    "",
    "Weighted total = 0.30 brevity/speed + 0.30 pointing/honesty + 0.20 coding + 0.20 notes (UX-weighted). Early stop at >= 90.",
    "",
    "| Round | Label | Scenario set | Pointing | Brevity+speed | Coding | Notes | Weighted total | Equal-weight avg | Visible total | Holdout total | API calls |",
    "|---|---|---|---|---|---|---|---|---|---|---|---|",
    ...rows,
    "",
    "Scores are 0-100. Single sample per scenario at the app's default temperature, so expect roughly +/- 5 points of run-to-run noise.",
    "",
    "Scenario set: `original` is the 45-scenario set used for rounds 0 and 1; `expanded` adds 13 fresh holdout scenarios (58 total) that were added before round 2 grading. Only rows with the same scenario set are directly comparable.",
    "",
    ...(personalizationRows.length === 0 ? [] : [
      "## Personalization (round 4B; tracked separately, excluded from the weighted total)",
      "",
      "| Round | Label | Scenarios | Personalization | Visible | Holdout | Profile tags dropped by the gate | API calls |",
      "|---|---|---|---|---|---|---|---|",
      ...personalizationRows,
      "",
      "Scored on what the app's real turn finisher saved or removed in a temporary profile, not on the model's tag alone. Rubric in eval/README.md.",
      "",
    ]),
    ...(visualRows.length === 0 ? [] : [
      "## Visual: drawing on the screen and the explanation card (round 6; tracked separately, excluded from the weighted total)",
      "",
      "| Round | Label | Scenarios | Visual | Visible | Holdout | Mark an element | Mark on screen 2 | Label the parts | Explanation card | Element absent | Edit marks | Controls (must not draw) | Tags dropped by the app parser | API calls |",
      "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
      ...visualRows,
      "",
      "Tags are read by the app's own ClickyDrawTagParser through the eval driver; marks are compared with the fixtures' known element boxes. Rubric in eval/README.md.",
      "",
    ]),
    ...(contextRows.length === 0 ? [] : [
      "## Context: old screens versus the screen now (round 14; tracked separately, excluded from the weighted total)",
      "",
      "| Round | Label | Scenarios | Context | Visible | Holdout | Old-screen bleed | Meta remarks | New topic | Ambiguous this | Follow-up across switch | Same-screen follow-up | Pointing after switch | API calls |",
      "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
      ...contextRows,
      "",
      "Old-screen bleed = share of switch scenarios whose spoken reply used words that only belong to the earlier exchange; meta remarks = share of all scenarios whose reply apologised for or commented on the switch. Rubric in eval/README.md.",
      "",
    ]),
    ...(memoriesRows.length === 0 ? [] : [
      "## Memories: memories from earlier chats in the prompt (round 16; tracked separately, excluded from the weighted total)",
      "",
      "| Round | Label | Scenarios | Memories | Visible | Holdout | Unrelated-memory mentions | Invented details | Missed recall | Unrelated keyword | Paraphrased recall | Missing detail | What do you remember | One of several | Invalid setups | API calls |",
      "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|",
      ...memoriesRows,
      "",
      "Unrelated-memory mentions = share of replies, where the question only shares a word with a memory (or other memories are seeded), that brought a memory up anyway; invented details = share of recall replies that said a day, time, amount or fact no memory holds. A scenario whose prompt did not hold the memories it expects is invalid_setup and is in neither score. Rubric in eval/README.md.",
      "",
    ]),
  ].join("\n");
  fs.writeFileSync(path.join(loopFolder, "leaderboard.md"), markdown);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  const loopFolder = process.argv[2];
  if (!loopFolder) {
    console.error("usage: node make_leaderboard.mjs <loop-folder>");
    process.exit(1);
  }
  writeLeaderboard(loopFolder);
  console.log(`wrote ${path.join(loopFolder, "leaderboard.md")}`);
}
