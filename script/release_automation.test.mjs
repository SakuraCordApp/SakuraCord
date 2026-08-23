import assert from "node:assert/strict";
import { test } from "node:test";
import {
  RELEASE_ACTION_MARKER,
  createDiscordPayload,
  prepareReleaseCopy,
  validateReleaseCopy,
} from "./release_automation.mjs";

function releaseCopy(overrides = {}) {
  return {
    schemaVersion: 1,
    tagName: "v0.1.2",
    githubDescription: "## Changes\n\n- Good things.\n\n**Full Changelog:** hand-written",
    discordAnnouncement:
      "**Message forwarding and GIFs 🌸**\n\n**Highlights**\n- Good things",
    ...overrides,
  };
}

test("validates a pre-made release file against its tag", () => {
  assert.equal(validateReleaseCopy(releaseCopy(), "v0.1.2").tagName, "v0.1.2");
  assert.throws(() => validateReleaseCopy(releaseCopy(), "v0.1.3"), /not v0\.1\.3/);
  assert.throws(
    () => validateReleaseCopy({ ...releaseCopy(), generatedAt: "today" }),
    /unsupported fields/,
  );
  assert.throws(
    () => validateReleaseCopy({ ...releaseCopy(), discordTitle: "Redundant title" }),
    /unsupported fields: discordTitle/,
  );
  assert.throws(
    () =>
      validateReleaseCopy(
        releaseCopy({
          discordAnnouncement:
            "**Message forwarding and GIFs 🌸**\nA focused update.\n\n**Highlights**\n- Good things",
        }),
      ),
    /no paragraph/,
  );
  assert.throws(
    () =>
      validateReleaseCopy(
        releaseCopy({
          discordAnnouncement:
            "**Message forwarding and GIFs 🌸**\n\n**Highlights**\n\n- Good things",
        }),
      ),
    /blank line after \*\*Highlights\*\*/,
  );
});

test("requires nightly tags and announcements to use their moon framing", () => {
  const nightly = releaseCopy({
    tagName: "v0.2.0-nightly.3",
    discordAnnouncement:
      "**Message forwarding and GIFs 🌙**\n\n**Highlights**\n- Good things",
  });
  assert.equal(validateReleaseCopy(nightly).tagName, "v0.2.0-nightly.3");
  assert.throws(
    () =>
      validateReleaseCopy({
        ...nightly,
        discordAnnouncement:
          "**Message forwarding and GIFs 🌸**\n\n**Highlights**\n- Good things",
      }),
    /ending in 🌙/,
  );
  assert.throws(
    () => validateReleaseCopy({ ...nightly, tagName: "v0.2.0-nightly.beta" }),
    /vMAJOR\.MINOR\.PATCH-nightly\.NUMBER/,
  );
});

test("preserves hand-written notes and appends only the ownership marker", () => {
  const prepared = prepareReleaseCopy(releaseCopy(), "v0.1.2");
  assert.match(prepared.githubDescription, /Full Changelog:\*\* hand-written/);
  assert.ok(prepared.githubDescription.endsWith(RELEASE_ACTION_MARKER));
  assert.equal(prepared.githubDescription.match(/sakuracord-release-action/g)?.length, 1);
});

test("sanitizes pre-made Discord mentions and constrains allowed mentions", () => {
  const copy = validateReleaseCopy(
    releaseCopy({
      discordAnnouncement:
        "**A specific headline 🌸**\n\n**Highlights**\n- Hello <@&1528177363995590795> and @here",
    }),
  );
  const payload = createDiscordPayload(
    copy,
    "SakuraCordApp/SakuraCord",
    123,
    "https://github.com/SakuraCordApp/SakuraCord/releases/tag/v0.1.2",
    "1528177363995590795",
  );
  assert.equal(payload.allowed_mentions.parse.length, 0);
  assert.deepEqual(payload.allowed_mentions.roles, ["1528177363995590795"]);
  assert.equal(payload.embeds[0].title, "SakuraCord v0.1.2");
  assert.doesNotMatch(payload.embeds[0].description, /<@|@here/);
  assert.equal(payload.nonce.length, 25);
  assert.equal(payload.enforce_nonce, true);
});

test("gives nightly announcements distinct visual framing", () => {
  const payload = createDiscordPayload(
    releaseCopy({
      tagName: "v0.2.0-nightly.3",
      discordAnnouncement:
        "**A specific nightly headline 🌙**\n\n**Highlights**\n- Good things",
    }),
    "SakuraCordApp/SakuraCord",
    124,
    "https://github.com/SakuraCordApp/SakuraCord/releases/tag/v0.2.0-nightly.3",
    "1541194051196289157",
  );

  assert.equal(payload.embeds[0].title, "SakuraCord v0.2.0-nightly.3 🌙");
  assert.equal(payload.embeds[0].color, 0x5865f2);
  assert.deepEqual(payload.allowed_mentions.roles, ["1541194051196289157"]);
});
