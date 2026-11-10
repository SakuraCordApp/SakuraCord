// Build a bounded prompt from the canonical issue and recent discussion.
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { releaseRefs, fixEvidence } from "./release-evidence.mjs";

const [instructionsPath, outputPath, mode] = process.argv.slice(2);
const number = Number(process.env.ISSUE_NUMBER);
if (!Number.isSafeInteger(number) || number < 1) throw new Error("Invalid issue number");
const issue = JSON.parse(execFileSync("gh", ["issue", "view", String(number), "--json", "number,title,body,labels,comments"], {
  encoding: "utf8", maxBuffer: 20 * 1024 * 1024,
}));
const strip = (text, limit = 12000) => String(text ?? "").replace(/<!--[\s\S]*?-->/g, "").slice(0, limit);
const comments = issue.comments.slice(-30).map((comment) =>
  `--- comment by ${comment.author?.login ?? "unknown"} ---\n${strip(comment.body, 2000)}`,
).join("\n\n");
let extra = "";
if (mode === "--triage") {
  const response = await fetch(`https://roadmap.sakuracord.app/api/v2/issues/${number}/assessment-context`, {
    headers: { "User-Agent": "SakuraCord-Assessment" }, signal: AbortSignal.timeout(30000),
  });
  if (!response.ok) throw new Error(`Assessment context unavailable (${response.status})`);
  const context = await response.json();
  if (!Array.isArray(context.areas) || !Array.isArray(context.candidates) || context.candidates.length > 12) throw new Error("Invalid assessment context");
  const refs = releaseRefs(context, process.env.SOURCE_SHA ?? "HEAD");
  context.releaseEvidence = refs;
  for (const candidate of context.candidates) {
    candidate.fixes = (candidate.fixes ?? []).map((fix) => ({ ...fix, evidence: fixEvidence(fix.sha, refs) }));
  }
  writeFileSync(join(dirname(outputPath), "assessment-context.json"), JSON.stringify({
    refs, reportedKind: context.reportedKind, questionsAllowed: context.questionsAllowed !== false,
    // Lets the assessment say which replies it read; its own earlier result is not discussion.
    lastComment: issue.comments.filter((comment) => !comment.body?.startsWith("<!-- sakuracord:investigation -->")).at(-1)?.createdAt ?? null,
    number, sourceTitle: issue.title, bodyHash: createHash("sha256").update(issue.body ?? "").digest("hex"),
    areas: context.areas.map((area) => area.id), candidates: context.candidates.map((candidate) => candidate.number),
  }));
  extra = `\n<untrusted-assessment-context>\n${JSON.stringify(context)}\n</untrusted-assessment-context>\n`;
}

// Download image evidence before the agent's network access is disabled. No
// credentials are attached, redirects are checked, and downloads are bounded.
const allowedImageUrl = (value) => {
  let url;
  try { url = new URL(value); } catch { return false; }
  return url.protocol === "https:" && !url.username && !url.password && (!url.port || url.port === "443") && (
    ["cdn.discordapp.com", "media.discordapp.net", "user-images.githubusercontent.com", "private-user-images.githubusercontent.com"].includes(url.hostname) ||
    (url.hostname === "github.com" && url.pathname.startsWith("/user-attachments/")) ||
    (url.hostname === "roadmap.sakuracord.app" && url.pathname.startsWith("/attachments/")) ||
    url.hostname === "github-production-user-asset-6210df.s3.amazonaws.com"
  );
};
const urls = [...String(issue.body ?? "").matchAll(/!?\[[^\]]*\]\((https:\/\/[^)\s]+)\)/g)].map((match) => match[1]);
const images = [];
for (const original of [...new Set(urls)].filter(allowedImageUrl).slice(0, 4)) {
  try {
    let url = original;
    let response;
    for (let redirects = 0; redirects <= 4; redirects++) {
      if (!allowedImageUrl(url)) throw new Error("Unsupported image host");
      response = await fetch(url, { redirect: "manual", signal: AbortSignal.timeout(15000) });
      if (![301, 302, 303, 307, 308].includes(response.status)) break;
      const location = response.headers.get("location");
      if (!location) throw new Error("Missing image redirect");
      await response.body?.cancel();
      url = new URL(location, url).href;
    }
    const type = response.headers.get("content-type")?.split(";")[0];
    const ext = { "image/png": "png", "image/jpeg": "jpg", "image/webp": "webp", "image/gif": "gif" }[type];
    if (!response.ok || !ext) throw new Error("Image unavailable or unsupported");
    const chunks = [];
    let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > 10 * 1024 * 1024) throw new Error("Image too large");
      chunks.push(chunk);
    }
    const path = join(dirname(outputPath), `report-image-${images.length + 1}.${ext}`);
    writeFileSync(path, Buffer.concat(chunks));
    images.push(path);
  } catch {
    // Do not print signed attachment URLs into workflow logs.
    images.push("[An attached image could not be downloaded.]");
  }
}
writeFileSync(outputPath, `${readFileSync(instructionsPath, "utf8")}

<untrusted-issue number="${issue.number}">
Title: ${issue.title}
Labels: ${issue.labels.map((label) => label.name).join(", ")}

${strip(issue.body, 24000)}

${comments}
</untrusted-issue>
${extra}
<untrusted-images>
${images.join("\n") || "No supported screenshots attached."}
</untrusted-images>
`);
