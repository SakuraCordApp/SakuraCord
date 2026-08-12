#!/usr/bin/env node

import { createHash } from "node:crypto";
import { realpathSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

export const RELEASE_ACTION_MARKER = "<!-- sakuracord-release-action:v1 -->";
const DISCORD_API = "https://discord.com/api/v10";

export function validateReleaseCopy(value, expectedTag) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Release copy must be a JSON object.");
  }
  const allowedKeys = new Set([
    "schemaVersion",
    "tagName",
    "githubDescription",
    "discordTitle",
    "discordAnnouncement",
  ]);
  const unexpected = Object.keys(value).filter((key) => !allowedKeys.has(key));
  if (unexpected.length) {
    throw new Error(`Release copy contains unsupported fields: ${unexpected.join(", ")}.`);
  }
  if (value.schemaVersion !== 1) throw new Error("Release copy schemaVersion must be 1.");
  const tagName = requiredString(value.tagName, "tagName");
  if (!/^v\d+\.\d+\.\d+$/.test(tagName)) {
    throw new Error("tagName must use vMAJOR.MINOR.PATCH.");
  }
  if (expectedTag && tagName !== expectedTag) {
    throw new Error(`Release copy belongs to ${tagName}, not ${expectedTag}.`);
  }
  const limits = {
    githubDescription: 20_000,
    discordTitle: 100,
    discordAnnouncement: 3_800,
  };
  const copy = { schemaVersion: 1, tagName };
  for (const [key, maximum] of Object.entries(limits)) {
    const text = value[key];
    if (typeof text !== "string" || !text.trim() || text.length > maximum) {
      throw new Error(`${key} must contain between 1 and ${maximum} characters.`);
    }
    copy[key] = text.trim();
  }
  copy.discordTitle = stripDiscordMentions(copy.discordTitle);
  copy.discordAnnouncement = stripDiscordMentions(copy.discordAnnouncement);
  return copy;
}

export function prepareReleaseCopy(value, expectedTag) {
  const copy = validateReleaseCopy(value, expectedTag);
  return {
    ...copy,
    githubDescription: [
      copy.githubDescription.replaceAll(RELEASE_ACTION_MARKER, "").trim(),
      RELEASE_ACTION_MARKER,
    ].join("\n\n"),
  };
}

export function createDiscordPayload(copy, repository, releaseId, releaseUrl, roleId) {
  const validated = validateReleaseCopy(copy);
  const nonce = createHash("sha256")
    .update(`release:${repository}:${releaseId}`)
    .digest("hex")
    .slice(0, 25);
  return {
    content: `<@&${roleId}>`,
    embeds: [
      {
        title: validated.discordTitle,
        description: validated.discordAnnouncement,
        color: 0xce6096,
      },
    ],
    components: [
      {
        type: 1,
        components: [{ type: 2, style: 5, label: "View release", url: releaseUrl }],
      },
    ],
    allowed_mentions: { parse: [], roles: [roleId], replied_user: false },
    nonce,
    enforce_nonce: true,
  };
}

export async function announceDiscord({
  token,
  channelId,
  roleId,
  repository,
  releaseId,
  releaseUrl,
  copy,
  fetchImpl = fetch,
}) {
  if (!/^\d{17,20}$/.test(channelId) || !/^\d{17,20}$/.test(roleId)) {
    throw new Error("Discord release channel and updates role IDs must be 17-20 digits.");
  }
  if (!Number.isSafeInteger(releaseId) || releaseId <= 0) {
    throw new Error("Invalid GitHub release ID.");
  }
  maskSecret(token);
  const payload = createDiscordPayload(copy, repository, releaseId, releaseUrl, roleId);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const response = await fetchImpl(`${DISCORD_API}/channels/${channelId}/messages`, {
      method: "POST",
      headers: { Authorization: `Bot ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(30_000),
    });
    const bodyText = await response.text();
    if (response.ok) {
      let message;
      try {
        message = JSON.parse(bodyText);
      } catch {
        throw new Error("Discord returned invalid JSON after accepting the announcement.");
      }
      if (!/^\d{17,20}$/.test(String(message.id))) {
        throw new Error("Discord returned no message ID.");
      }
      return String(message.id);
    }
    if ((response.status === 429 || response.status >= 500) && attempt < 2) {
      let delayMs = 500 * 2 ** attempt;
      try {
        const retryAfter = JSON.parse(bodyText).retry_after;
        if (Number.isFinite(retryAfter)) {
          delayMs = Math.min(30_000, Math.max(500, retryAfter * 1_000));
        }
      } catch {}
      await new Promise((resolve) => setTimeout(resolve, delayMs));
      continue;
    }
    throw new Error(formatUpstreamFailure("Discord release announcement", response, bodyText));
  }
  throw new Error("Discord release announcement exhausted its retry budget.");
}

function stripDiscordMentions(value) {
  return value
    .replaceAll("@everyone", "@\u200beveryone")
    .replaceAll("@here", "@\u200bhere")
    .replace(/<@!?&?\d{17,20}>/g, "[mention removed]");
}

function formatUpstreamFailure(label, response, bodyText) {
  let detail = "";
  try {
    const parsed = JSON.parse(bodyText);
    detail =
      optionalString(parsed?.error?.message) ??
      optionalString(parsed?.message) ??
      optionalString(parsed?.detail) ??
      "";
  } catch {}
  return `${label} failed with HTTP ${response.status}${detail ? `: ${redact(detail).slice(0, 500)}` : "."}`;
}

function redact(value) {
  return String(value).replace(/(?:Bot|Bearer)\s+\S+/gi, "[REDACTED]");
}

function maskSecret(value) {
  if (process.env.GITHUB_ACTIONS === "true" && value) {
    process.stdout.write(`::add-mask::${value}\n`);
  }
}

function requiredString(value, name) {
  const result = optionalString(value);
  if (!result) throw new Error(`${name} is missing.`);
  return result;
}

function optionalString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function parseArguments(argv) {
  const [command, ...rest] = argv;
  const options = {};
  for (let index = 0; index < rest.length; index += 1) {
    const key = rest[index];
    if (!key?.startsWith("--")) throw new Error(`Unexpected argument: ${key}`);
    const value = rest[index + 1];
    if (!value || value.startsWith("--")) throw new Error(`Missing value for ${key}.`);
    options[key.slice(2)] = value;
    index += 1;
  }
  return { command, options };
}

async function writeJson(path, value) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`);
}

async function main() {
  const { command, options } = parseArguments(process.argv.slice(2));
  if (command === "validate-copy") {
    const copy = validateReleaseCopy(
      JSON.parse(await readFile(requiredString(options.input, "--input"), "utf8")),
      options.tag,
    );
    console.log(`Validated pre-made release copy for ${copy.tagName}.`);
    return;
  }
  if (command === "prepare") {
    const copy = prepareReleaseCopy(
      JSON.parse(await readFile(requiredString(options.input, "--input"), "utf8")),
      requiredString(options.tag, "--tag"),
    );
    await writeJson(requiredString(options.output, "--output"), copy);
    const notesOutput = requiredString(options["notes-output"], "--notes-output");
    await mkdir(dirname(notesOutput), { recursive: true });
    await writeFile(notesOutput, `${copy.githubDescription}\n`);
    console.log(`Prepared pre-made release copy for ${copy.tagName}.`);
    return;
  }
  if (command === "announce-discord") {
    const copy = JSON.parse(await readFile(requiredString(options.input, "--input"), "utf8"));
    const messageId = await announceDiscord({
      token: requiredString(process.env.DISCORD_BOT_TOKEN, "DISCORD_BOT_TOKEN"),
      channelId: requiredString(
        process.env.DISCORD_RELEASE_CHANNEL_ID,
        "DISCORD_RELEASE_CHANNEL_ID",
      ),
      roleId: requiredString(process.env.DISCORD_UPDATES_ROLE_ID, "DISCORD_UPDATES_ROLE_ID"),
      repository: requiredString(options.repo, "--repo"),
      releaseId: Number(requiredString(options["release-id"], "--release-id")),
      releaseUrl: requiredString(options["release-url"], "--release-url"),
      copy,
    });
    console.log(`Discord release announcement checkpoint: ${messageId}`);
    return;
  }
  throw new Error("Expected validate-copy, prepare, or announce-discord.");
}

if (
  process.argv[1] &&
  realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])
) {
  main().catch((error) => {
    console.error(redact(error instanceof Error ? error.message : String(error)));
    process.exitCode = 1;
  });
}
