#!/usr/bin/env node

import { readFile, writeFile } from "node:fs/promises";
import { pathToFileURL } from "node:url";

const nightlyTagPattern = /^v(\d+\.\d+\.\d+)-Beta-(\d+)$/;

export function updateAppcastDisplayVersion(source, tagName) {
  const match = nightlyTagPattern.exec(tagName);
  if (match === null) {
    throw new Error("Expected a vMAJOR.MINOR.PATCH-Beta-NUMBER nightly tag.");
  }

  const [, version, betaNumber] = match;
  const displayVersion = `${version} Beta ${betaNumber}`;
  const replacements = [
    [`<title>${version}</title>`, `<title>${displayVersion}</title>`],
    [
      `<sparkle:shortVersionString>${version}</sparkle:shortVersionString>`,
      `<sparkle:shortVersionString>${displayVersion}</sparkle:shortVersionString>`,
    ],
  ];

  let updated = source;
  for (const [expected, replacement] of replacements) {
    const firstIndex = updated.indexOf(expected);
    if (firstIndex === -1 || updated.indexOf(expected, firstIndex + expected.length) !== -1) {
      throw new Error(`Expected exactly one generated appcast value: ${expected}`);
    }
    updated = updated.replace(expected, replacement);
  }
  return updated;
}

async function main() {
  const [inputPath, tagName] = process.argv.slice(2);
  if (!inputPath || !tagName) {
    throw new Error("usage: update_appcast_display_version.mjs APPCAST_PATH NIGHTLY_TAG");
  }
  const source = await readFile(inputPath, "utf8");
  await writeFile(inputPath, updateAppcastDisplayVersion(source, tagName));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : String(error));
    process.exitCode = 1;
  });
}
