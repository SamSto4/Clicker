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
  const rows = summaryFileNames.map((fileName) => {
    const summary = JSON.parse(fs.readFileSync(path.join(loopFolder, fileName), "utf8"));
    const dimensions = summary.dimensions ?? {};
    const scenarioCount = Object.values(dimensions).reduce(
      (runningTotal, dimension) => runningTotal + (dimension.details?.scenarios_scored ?? 0) + (dimension.details?.scenarios_errored ?? 0), 0);
    const scenarioSetLabel = scenarioCount > ORIGINAL_SCENARIO_COUNT ? `expanded (${scenarioCount})` : `original (${scenarioCount})`;
    return `| ${summary.round} | ${summary.label ?? fileName} | ${scenarioSetLabel} | ${formatScore(dimensions.pointing?.score)} | ${formatScore(dimensions.brevity?.score)} | ${formatScore(dimensions.coding?.score)} | ${formatScore(dimensions.notes?.score)} | **${formatScore(summary.total)}** | ${formatScore(summary.total_equal_weight)} | ${formatScore(summary.split_scores?.visible?.total)} | ${formatScore(summary.split_scores?.holdout?.total)} | ${summary.calls_used?.total ?? "-"} |`;
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
