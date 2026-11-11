#!/usr/bin/env node
// Extracts a Swift multi-line string constant (default: companionVoiceResponseSystemPrompt) into a plain text file
// so it can be passed to run_simulations.mjs --system-prompt-file.
//
// Usage: node eval/extract_system_prompt.mjs <CompanionManager.swift> <out.txt> [symbolName]
// Read-only on the Swift file. Swift strips the closing delimiter's indentation from every line; so do we.
// Warns if the string contains Swift interpolation (backslash-paren) or escapes, which this simple extractor does not evaluate.

import fs from "node:fs";

const [swiftSourcePath, outputPath, symbolName = "companionVoiceResponseSystemPrompt"] = process.argv.slice(2);
if (!swiftSourcePath || !outputPath) {
  console.error("usage: node extract_system_prompt.mjs <swift file> <out.txt> [symbolName]");
  process.exit(1);
}

const lines = fs.readFileSync(swiftSourcePath, "utf8").split("\n");
const startIndex = lines.findIndex((line) => line.includes(symbolName) && line.includes('"""'));
if (startIndex === -1) {
  console.error(`could not find ${symbolName} = """ in ${swiftSourcePath}`);
  process.exit(1);
}
let endIndex = -1;
for (let index = startIndex + 1; index < lines.length; index++) {
  if (lines[index].trim() === '"""') { endIndex = index; break; }
}
if (endIndex === -1) {
  console.error("could not find the closing triple quote");
  process.exit(1);
}
const indentation = /^\s*/.exec(lines[endIndex])[0];
const promptText = lines.slice(startIndex + 1, endIndex)
  .map((line) => (line.startsWith(indentation) ? line.slice(indentation.length) : line.trimStart()))
  .join("\n");

if (promptText.includes("\\(") || /\\[nt"\\]/.test(promptText)) {
  console.error("WARNING: the prompt contains Swift interpolation or escapes that were NOT evaluated; fill them in by hand.");
}
fs.writeFileSync(outputPath, promptText + "\n");
console.log(`wrote ${outputPath}: ${promptText.length} chars, ${promptText.split("\n").length} lines`);
