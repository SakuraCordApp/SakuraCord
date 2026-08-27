import assert from "node:assert/strict";
import { test } from "node:test";
import { updateAppcastDisplayVersion } from "./update_appcast_display_version.mjs";

const appcast = `<?xml version="1.0"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>SakuraCord</title>
    <item>
      <title>0.2.0</title>
      <sparkle:shortVersionString>0.2.0</sparkle:shortVersionString>
    </item>
  </channel>
</rss>`;

test("adds the beta label to nightly Sparkle display metadata", () => {
  const updated = updateAppcastDisplayVersion(appcast, "v0.2.0-Beta-3");

  assert.match(updated, /<title>0\.2\.0 Beta 3<\/title>/);
  assert.match(
    updated,
    /<sparkle:shortVersionString>0\.2\.0 Beta 3<\/sparkle:shortVersionString>/,
  );
  assert.match(updated, /<title>SakuraCord<\/title>/);
});

test("rejects malformed nightly tags and ambiguous generated values", () => {
  assert.throws(
    () => updateAppcastDisplayVersion(appcast, "v0.2.0"),
    /nightly tag/,
  );
  assert.throws(
    () => updateAppcastDisplayVersion(appcast.replace("</item>", `${appcast}</item>`), "v0.2.0-Beta-3"),
    /exactly one/,
  );
});
